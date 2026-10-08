"""Identity-bound, stdout-only ARM64 display chain probe; never executes samples."""

import argparse
from hashlib import sha256
import json
from pathlib import Path
import struct
import zipfile

import lief

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
    "count_state_field_template": (0x1000D8148, "add", "#0x880"),
    "count_finished_state_gate": (0x1000D8218, "cmp", "w8, #4"),
    "count_finished_state_skip": (0x1000D821C, "b.eq", "#0x1000d8128"),
    "count_health_negative_gate": (0x1000D849C, "fcmp", "s8, #0.0"),
    "count_health_negative_skip": (0x1000D84A0, "b.lt", "#0x1000d8128"),
    "count_health_ratio_zero_gate": (0x1000D84D8, "b.mi", "#0x1000d8128"),
    "count_distance_before_increment": (0x1000DBB50, "b.gt", "#0x1000dbdc0"),
    "count_bot_increment": (0x1000DBB60, "add", "w8, w8, #1"),
    "count_player_increment": (0x1000DBB94, "add", "w8, w8, #1"),
    "ray_native_scale_call": (0x100018C64, "bl", "#0x10072b5e0"),
    "ray_native_scale_store": (0x100018CA8, "str", "s0, [x8, #0xb20]"),
    "ray_pixel_width": (0x100018C7C, "fmul", "d8, d10, d2"),
    "ray_pixel_height": (0x100018C88, "fmul", "d9, d10, d3"),
    "ray_scale_render_load": (0x100021BB4, "ldr", "s0, [x8, #0xb20]"),
    "ray_scale_render_store": (0x100021BB8, "str", "s0, [x23]"),
    "ray_endpoint_offset": (0x1000DC774, "fmov", "#-30.00000000"),
    "ray_endpoint_native_pixels": (0x1000DC778, "fmadd", "s0, s1, s0, s11"),
    "ray_head_fallback": (0x1000D8CB4, "fadd", "s0, s0, s1"),
    "ray_head_projected_record": (0x1000D8CF4, "str", "s1, [sp, #0x3cc]"),
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
    core_image = lief.MachO.parse(core).at(0)
    fixups = {entry.address: entry.target for entry in core_image.relocations if hasattr(entry, "target")}
    ui_selectors = {}
    for va, expected in ((0x100BD2198, "mainScreen"), (0x100BD2260, "nativeScale"), (0x100BD14D8, "bounds")):
        pointer = fixups[va]
        name = core[pointer - BASE:pointer - BASE + 100].split(b"\0", 1)[0].decode("ascii")
        assert name == expected
        ui_selectors[hex(va)] = {"target": hex(pointer), "selector": name}
    assert any(entry.address == 0x100BD5518 and entry.symbol.name == "_OBJC_CLASS_$_UIScreen"
               for entry in core_image.bindings)
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
        "ReplicatedMovement": property_at(target, 0x1107BBB70),
        "RepMovement_Rotation": property_at(target, 0x11083E2D0),
        "World_GameState": property_at(target, 0x1109BB600),
        "GameState_ServerDelta": property_at(target, 0x110864C40),
        "Level_OwningWorld": property_at(target, 0x1108D48A8),
        "HealthStatus": property_at(target, 0x10F7BA498),
    }
    assert properties == {"PlayerName": ("PlayerName", 0xAF8), "TeamID": ("TeamID", 0xB78),
                          "ServerControlRotation": ("ServerControlRotation", 0x2754), "Yaw": ("Yaw", 4),
                          "Children": ("Children", 0x250), "ExplosionTime": ("ExplosionTime", 0x88C),
                          "CurrentUsingWeaponSafety": ("CurrentUsingWeaponSafety", 0x1170),
                          "RepWeaponID": ("RepWeaponID", 0xDD0), "VehicleCommon": ("VehicleCommon", 0xC00),
                          "HPMax": ("HPMax", 0x1F4), "HP": ("HP", 0x1F8),
                          "FuelMax": ("FuelMax", 0x218), "Fuel": ("Fuel", 0x21C),
                          "Redundant_AvatarSyncData": ("Redundant_AvatarSyncData", 0x5198),
                          "TypeSpecificID": ("TypeSpecificID", 4),
                          "ReplicatedMovement": ("ReplicatedMovement", 0x168),
                          "RepMovement_Rotation": ("Rotation", 0x24),
                          "World_GameState": ("GameState", 0xAD8),
                          "GameState_ServerDelta": ("ServerWorldTimeSecondsDelta", 0x600),
                          "Level_OwningWorld": ("OwningWorld", 0xC0),
                          "HealthStatus": ("HealthStatus", 0x3BE0)}
    def u64(va: int) -> int:
        return struct.unpack_from("<Q", target, va - BASE)[0]

    # Follow actual descriptor getters/metadata rather than matching bare +190.
    assert u64(0x1107BBB70 + 0x38) == 0x10ABB3108
    assert u64(0x11083E438 + 0x28) == 0x34
    assert u64(0x11083E438 + 0x38) == 0x11083E3D0
    assert u64(0x11083E438 + 0x40) == 13
    movement_members = [u64(0x11083E3D0 + index * 8) for index in range(13)]
    assert 0x11083E2D0 in movement_members
    assert u64(0x11083E2D0 + 0x38) == 0x108E070AC
    assert u64(0x1103E71A0 + 0x28) == 12
    assert u64(0x1103E71A0 + 0x38) == 0x1103E7188
    assert u64(0x1103E71A0 + 0x40) == 3
    assert 0x1103E7118 in [u64(0x1103E7188 + index * 8) for index in range(3)]
    assert properties["ReplicatedMovement"][1] + properties["RepMovement_Rotation"][1] + properties["Yaw"][1] == 0x190
    target_sites = {
        "rep_movement_metadata": (0x10ABB312C, "adrp", "x1, #0x11083e000"),
        "rep_movement_metadata_low": (0x10ABB3130, "add", "x1, x1, #0x438"),
        "rotator_metadata": (0x108E070D0, "adrp", "x1, #0x1103e7000"),
        "rotator_metadata_low": (0x108E070D4, "add", "x1, x1, #0x1a0"),
        "actor_register_owner": (0x10AB310F4, "add", "x1, x1, #0xcb0"),
        "actor_vtable": (0x10A13BCEC, "add", "x8, x8, #0xe88"),
        "onrep_dispatch": (0x10AB2C6B4, "ldr", "x1, [x8, #0x630]"),
        "onrep_postnet_dispatch": (0x10A15D80C, "mov", "w8, #0x638"),
        "postnet_yaw_compare": (0x10A15DA2C, "ldr", "s0, [x19, #0x190]"),
        "postnet_yaw_apply": (0x10A15DA44, "ldr", "s4, [x19, #0x190]"),
        "postnet_transform_apply": (0x10A15DA68, "bl", "#0x10a14c6e8"),
    }
    target_observed = {}
    for label, (va, mnemonic, operand) in target_sites.items():
        instruction = next(decoder.disasm(target[va - BASE:va - BASE + 4], va))
        assert instruction.mnemonic == mnemonic and operand in instruction.op_str, label
        target_observed[label] = {"va": hex(va), "file_offset": hex(va - BASE),
                                  "instruction": f"{instruction.mnemonic} {instruction.op_str}"}
    assert u64(0x11062FE88 + 0x630) == 0x10A15D5CC
    assert u64(0x11062FE88 + 0x638) == 0x10A15D89C
    assert target[0xD8A9CB0:0xD8A9CB0 + 12].decode("utf-16le").split("\0", 1)[0] == "Actor"
    clock_sites = {
        "elite_projectile_class_page": (0x10653F808, "adrp", "x8, #0x111b3c000"),
        "elite_projectile_class_slot": (0x10653F80C, "ldr", "x0, [x8, #0x458]"),
        "game_state_class_page": (0x10ABD9E14, "adrp", "x8, #0x1120a9000"),
        "game_state_class_slot": (0x10ABD9E18, "ldr", "x0, [x8, #0x590]"),
        "actor_getworld_outer": (0x10A13D248, "ldr", "x19, [x19, #0x20]"),
        "actor_getworld_level_world": (0x10A13D224, "ldr", "x0, [x0, #0xc0]"),
        "world_get_game_state": (0x10AB0100C, "ldr", "x0, [x0, #0xad8]"),
        "explosion_world_clock": (0x105D4AE68, "ldr", "d0, [x0, #0x15b0]"),
        "explosion_store": (0x105D4AE7C, "str", "s0, [x19, #0x88c]"),
        "spawn_world_clock": (0x105D4D810, "ldr", "d0, [x0, #0x15b0]"),
        "spawn_store": (0x105D4D818, "str", "s0, [x19, #0x888]"),
        "remaining_load": (0x105D4F134, "ldr", "s0, [x0, #0x88c]"),
        "remaining_clock_dispatch": (0x105D4F158, "ldr", "x8, [x8, #0x950]"),
        "remaining_subtract": (0x105D4F164, "fsub", "s0, s1, s0"),
        "remaining_max": (0x105D4F168, "fmov", "#10.00000000"),
        "server_clock_world_time": (0x10A529B80, "ldr", "d0, [x0, #0x15b0]"),
        "server_clock_delta": (0x10A529B84, "ldr", "s1, [x19, #0x600]"),
        "server_clock_sum": (0x10A529B8C, "fadd", "d0, d0, d1"),
        "server_clock_float": (0x10A529B90, "fcvt", "s0, d0"),
        "valid_flag_byte": (0x10653F7A4, "ldrb", "[x0, #0x7fd]"),
        "valid_flag_bit": (0x10653F7A8, "orr", "#8"),
        "exploded_flag_byte": (0x10653F7B4, "ldrb", "[x0, #0x7fd]"),
        "exploded_flag_bit": (0x10653F7B8, "orr", "#4"),
    }
    clock_observed = {}
    for label, (va, mnemonic, operand) in clock_sites.items():
        instruction = next(decoder.disasm(target[va - BASE:va - BASE + 4], va))
        assert instruction.mnemonic == mnemonic and operand in instruction.op_str, label
        clock_observed[label] = {"va": hex(va), "file_offset": hex(va - BASE),
                                 "instruction": f"{instruction.mnemonic} {instruction.op_str}"}
    assert u64(0x1106C9660 + 0x950) == 0x10A529B68
    assert u64(0x10F124C30 + 0x40) == 0x10653F7A4
    assert u64(0x10F124C78 + 0x40) == 0x10653F7B4
    assert target[0xCCA07FA:0xCCA07FA + 32].decode("utf-16le").split("\0", 1)[0] == "EliteProjectile"
    assert target[0xD8B413E:0xD8B413E + 28].decode("utf-16le").split("\0", 1)[0] == "GameStateBase"
    assert u64(0x10F7BA498 + 0x38) == 0x106AB6358
    assert u64(0x10F58CD28 + 0x38) == 0x10F58CCC8
    assert u64(0x10F58CD28 + 0x40) == 6
    health_status = {}
    for index in range(6):
        entry = 0x10F58CCC8 + index * 16
        pointer = u64(entry)
        name = target[pointer - BASE:pointer - BASE + 100].split(b"\0", 1)[0].decode("ascii")
        health_status[name] = u64(entry + 8)
    assert health_status == {"HealthyAlive": 0, "HasLastBreath": 1, "ZombieState": 2,
                             "WaitingForRevival": 3, "FinishedLastBreath": 4, "MAX": 5}
    for va, mnemonic, operand in [(0x106AB637C, "adrp", "x1, #0x10f58c000"),
                                  (0x106AB6380, "add", "x1, x1, #0xd28")]:
        instruction = next(decoder.disasm(target[va - BASE:va - BASE + 4], va))
        assert instruction.mnemonic == mnemonic and operand in instruction.op_str
    template = 0x100797628
    values = {index: struct.unpack_from("<Q", core, template + index * 8 - BASE)[0]
              for index in (38, 47, 49, 57, 63, 68)}
    assert values == {38: 0x1700, 47: 0x258, 49: 0x88C, 57: 0x190, 63: 0x2758, 68: 0x3BE0}
    return {"core_sha256": CORE_SHA, "target_sha256": TARGET_SHA, "sites": observed,
            "strings": {hex(va): text for va, text in STRINGS.items()}, "warning_prefix": prefix,
            "target_properties": properties, "template_values": values,
            "warning_fallback_lifecycle_sites": target_observed,
            "grenade_clock_lifecycle_sites": clock_observed,
            "health_status_enum": health_status,
            "ray_ui_selector_fixups": ui_selectors,
            "boundary": {"timer": "target_clock_owner_closed_reference_258_is_children_num", "radius": "local_circle_is_not_world_blast_radius",
                         "warning_fallback": "owner_rep_movement_rotation_yaw_closed_capture_stability_not_network_freshness",
                         "opened": "children_num_eq1_proxy_not_gameplay_state",
                         "information": "graphical_layout_not_closed",
                         "ray": "native_scale_points_conversion_closed_bone_head_and_device_pixels_not_verified",
                         "count": "last_breath_zero_closed_other_zero_states_and_1700_flags_owner_not_closed",
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
        target_count = len(result['warning_fallback_lifecycle_sites']) + len(result['grenade_clock_lifecycle_sites'])
        print(f"PASS: hash-bound Core {len(result['sites'])} / target lifecycle {target_count} instructions / {len(result['strings'])} strings / {len(result['target_properties'])} properties")
        print("LIMIT: fallback/clock owner statically closed; network freshness, blast radius, animation, information layout and device remain unverified")
