"""Identity-bound, stdout-only ARM64 display chain probe; never executes samples."""

import argparse
from hashlib import sha256
import json
from pathlib import Path
import struct
import zipfile

from capstone import CS_ARCH_ARM64, CS_MODE_ARM, Cs


ROOT = Path(__file__).resolve().parents[1]
BASE = 0x100000000
CORE_SHA = "c842be92434b88b4d535d0d10a30ace068ce6b9a7b9a97ec5a6ca8fd97fa3dd5"
TARGET_SHA = "e3b3e8d47f1ad116b74d0a578d3394f5f1ab85e85c9ceb4f61293bd7ba76dc98"
SITES = {
    "player_distance_conversion": (0x1000DC80C, "fcvtzs", "w0, s13"),
    "player_distance_unit_xref": (0x1000DC820, "add", "#0x8eb"),
    "warning_name_read": (0x1000DB960, "bl", "#0x1000df55c"),
    "warning_name_fallback": (0x1000DB9C4, "bl", "#0x100006ec0"),
    "warning_distance_conversion": (0x1000DB9EC, "fcvtas", "w8, s13"),
    "warning_record_distance_weapon": (0x1000DB9FC, "orr", "x8, x9, lsl #32"),
    "warning_weapon_name": (0x1000DD94C, "bl", "#0x1000dfa10"),
    "warning_unknown_weapon_gate": (0x1000DD9BC, "b.hs", "#0x1000dde9c"),
    "warning_unknown_weapon_format": (0x1000DD9F4, "add", "#0x91e"),
    "warning_named_weapon_suffix": (0x1000DDA54, "add", "#0x913"),
    "warning_distance_suffix": (0x1000DDA7C, "add", "#0x940"),
    "warning_invalid_weapon_suffix": (0x1000DDEA8, "add", "#0x92f"),
    "warning_traversal_next": (0x1000DDE88, "add", "x26, x26, #0x20"),
    "warning_text_size": (0x1000DD774, "ldr", "#0x10c"),
    "warning_text_size_max": (0x1000DD778, "cmp", "w10, #0xc8"),
    "warning_text_size_min": (0x1000DD784, "cmp", "w10, #0xa"),
    "grenade_timer_subtract": (0x1000D9A90, "fsub", "s0, s11, s13"),
    "grenade_timer_limit": (0x1000D9AA0, "fmov", "#30.00000000"),
    "grenade_animation_scalar": (0x1000DE05C, "ldr", "#0x44"),
    "grenade_animation_limit": (0x1000DE064, "fminnm", "s13, s0, s1"),
    "grenade_animation_loop": (0x1000DE20C, "cmp", "w25, #0x1d"),
    "grenade_local_circle": (0x1000DE2A0, "bl", "#0x10013b888"),
    "opened_crate_proxy": (0x1000D9D70, "cmp", "w22, #1"),
    "opened_crate_filter": (0x1000D9DF4, "ldrb", "#0x114"),
    "count_player_source": (0x1000DEDC4, "ldr", "#0x8b0"),
    "count_bot_source": (0x1000DEDEC, "ldr", "#0x8b4"),
    "vehicle_percent_conversion": (0x1000DE3EC, "fcvtas", ""),
    "material_distance_conversion": (0x1000DE400, "fcvtzs", ""),
    "metro_fixed_size": (0x1000DD2EC, "fmov", "#14.00000000"),
    "material_size_setting": (0x1000DE540, "ldr", "#0x34"),
    "player_head_offset": (0x1000D8788, "mov", "w8, #0x42b40000"),
    "player_feet_offset": (0x1000D879C, "mov", "w8, #-0x3d4c0000"),
    "player_box_half_height": (0x1000DC7B8, "fmul", "s0, s0, s1"),
    "player_box_half_width": (0x1000DC7BC, "fmul", "s0, s0, s1"),
    "player_ray_top_origin": (0x1000DC76C, "mov", "w8, #0x41200000"),
    "information_health_ratio": (0x1000DC0F0, "fdiv", "s0, s0, s1"),
}
STRINGS = {
    0x1007448B5: "人机", 0x1007448BC: "未知玩家", 0x1007448EB: " 米",
    0x100744913: " 瞄准您", 0x10074491E: "未知武器({})",
    0x10074492F: " 正在瞄准您", 0x100744940: "{}m",
    0x1007449A8: "%s[血%d%%油%d%%]%d米", 0x1007449C0: "%s[血%d%%]%d米",
    0x1007449D1: "%s[油%d%%]%d米", 0x1007449EB: "%s   %d米",
    0x1007449F6: "玩家 %d", 0x100744A00: "人机 %d",
}


def load_member(path: Path, member: str, expected: str) -> bytes:
    with zipfile.ZipFile(path) as archive:
        binary = archive.read(member)
    actual = sha256(binary).hexdigest()
    assert actual == expected, f"identity mismatch: {path.name} {actual}"
    return binary


def property_at(binary: bytes, descriptor: int) -> tuple[str, int]:
    pointer = struct.unpack_from("<Q", binary, descriptor + 8 - BASE)[0]
    assert BASE <= pointer < BASE + len(binary)
    raw = binary[pointer - BASE:pointer - BASE + 128].split(b"\0", 1)[0]
    return raw.decode("ascii"), struct.unpack_from("<Q", binary, descriptor + 0x30 - BASE)[0]


def analyze(core_path: Path, target_path: Path) -> dict:
    core = load_member(core_path, "Payload/Core.app/Core", CORE_SHA)
    target = load_member(target_path, "Payload/ShadowTrackerExtra.app/ShadowTrackerExtra", TARGET_SHA)
    decoder = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    observed = {}
    for label, (va, mnemonic, operand) in SITES.items():
        instruction = next(decoder.disasm(core[va - BASE:va - BASE + 4], va))
        assert instruction.mnemonic == mnemonic and operand in instruction.op_str, (label, instruction.mnemonic, instruction.op_str)
        observed[label] = {"va": hex(va), "file_offset": hex(va - BASE),
                           "instruction": f"{instruction.mnemonic} {instruction.op_str}"}
    for va, expected in STRINGS.items():
        actual = core[va - BASE:va - BASE + 128].split(b"\0", 1)[0].decode("utf-8")
        assert actual == expected, (hex(va), actual)
    # Inline warning prefix at dd984..dd994 is constructed as an eight-byte
    # UTF-8 string, not merely a coincidental cstring hit.
    prefix = struct.pack("<Q", 0x20A894E7BFBDE420).decode("utf-8")
    assert prefix == " 使用 "
    prefix_sites = list(decoder.disasm(core[0xDD984:0xDD994], 0x1000DD984))
    assert [(i.mnemonic, i.op_str) for i in prefix_sites] == [
        ("mov", "x8, #0xe420"), ("movk", "x8, #0xbfbd, lsl #16"),
        ("movk", "x8, #0x94e7, lsl #32"), ("movk", "x8, #0x20a8, lsl #48")]
    properties = {
        "PlayerName": property_at(target, 0x11002AD08),
        "TeamID": property_at(target, 0x11002AB70),
        "ServerControlRotation": property_at(target, 0x10F7C0C50),
        "Yaw": property_at(target, 0x1103E7118),
        "Children": property_at(target, 0x1107BB0D8),
        "ExplosionTime": property_at(target, 0x10F124BC0),
        "CurrentUsingWeaponSafety": property_at(target, 0x10F842DE0),
        "RepWeaponID": property_at(target, 0x10FAD45E8),
        "VehicleCommon": property_at(target, 0x10FAA5BF0),
        "HPMax": property_at(target, 0x10FC611F8),
        "HP": property_at(target, 0x10FC611C0),
        "FuelMax": property_at(target, 0x10FC60F20),
        "Fuel": property_at(target, 0x10FC60EE8),
        "Redundant_AvatarSyncData": property_at(target, 0x10F7B3E08),
        "TypeSpecificID": property_at(target, 0x10FDD8F00),
    }
    assert properties == {"PlayerName": ("PlayerName", 0xAF8), "TeamID": ("TeamID", 0xB78),
                          "ServerControlRotation": ("ServerControlRotation", 0x2754), "Yaw": ("Yaw", 4),
                          "Children": ("Children", 0x250), "ExplosionTime": ("ExplosionTime", 0x88C),
                          "CurrentUsingWeaponSafety": ("CurrentUsingWeaponSafety", 0x1170),
                          "RepWeaponID": ("RepWeaponID", 0xDD0), "VehicleCommon": ("VehicleCommon", 0xC00),
                          "HPMax": ("HPMax", 0x1F4), "HP": ("HP", 0x1F8),
                          "FuelMax": ("FuelMax", 0x218), "Fuel": ("Fuel", 0x21C),
                          "Redundant_AvatarSyncData": ("Redundant_AvatarSyncData", 0x5198),
                          "TypeSpecificID": ("TypeSpecificID", 4)}
    template = 0x100797628
    values = {index: struct.unpack_from("<Q", core, template + index * 8 - BASE)[0]
              for index in (47, 49, 57, 63)}
    assert values == {47: 0x258, 49: 0x88C, 57: 0x190, 63: 0x2758}
    return {"core_sha256": CORE_SHA, "target_sha256": TARGET_SHA, "sites": observed,
            "strings": {hex(va): text for va, text in STRINGS.items()}, "warning_prefix": prefix,
            "target_properties": properties, "template_values": values,
            "boundary": {"timer": "needs_same-owner_clock_and_lifecycle", "radius": "local_circle_is_not_world_blast_radius",
                         "warning_fallback": "needs_owner_at_190", "opened": "children_num_eq1_proxy_not_gameplay_state",
                         "information": "graphical_layout_not_closed",
                         "ray": "reference_top_origin_current_local_geometry_not_pixel_parity",
                         "device": "not_verified"}}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference-ipa", type=Path, default=ROOT.parent / "源码 - 和平/自签Core-SET和平-v1.7.ipa")
    parser.add_argument("--target-ipa", type=Path, default=ROOT.parent / "和平精英-1.38.12.ipa")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    result = analyze(args.reference_ipa, args.target_ipa)
    if args.json:
        print(json.dumps(result, ensure_ascii=True, indent=2))
    else:
        print(f"PASS: hash-bound {len(result['sites'])} instruction anchors / {len(result['strings'])} strings / target properties")
        print("LIMIT: static text/field chain; grenade clock/radius, fallback yaw owner, information layout and device remain unverified")
