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
CORE_IPA_SHA = "57412d36a1092931d81a9a820c57eb5c1eb92dcf77076ce865dc95035a3a41cb"
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
PLAYER_FILTER_SITES = {
    "speed_offset_descriptor": (0x1000D5468, "ldr", "[x10, #0x258]"),
    "speed_read_float32": (0x1000D5478, "bl", "#0x1000d60d0"),
    "speed_finite_gate": (0x1000D548C, "b.gt", "#0x1000d56a4"),
    "speed_tolerance_gate": (0x1000D549C, "b.pl", "#0x1000d56a4"),
    "local_actor_gate": (0x1000D54A4, "cmp", "x8, x24"),
    "team_read_u32": (0x1000D54C4, "bl", "#0x1000d5fd8"),
    "team_range_lowering": (0x1000D54C8, "sub", "w8, w0, #0x65"),
    "team_local_compare": (0x1000D54D4, "ccmp", "w0, w8, #4, hs"),
    "state_owner_read_u64": (0x1000D54FC, "bl", "#0x1000d61cc"),
    "state_flags_read_u32": (0x1000D5514, "bl", "#0x1000d6498"),
    "lifecycle_read_u8": (0x1000D5538, "bl", "#0x1000d6590"),
    "state_bit20_gate": (0x1000D553C, "tbnz", "w23, #0x14"),
    "lifecycle_four_gate": (0x1000D5540, "cmp", "w0, #4"),
    "health_read_float32": (0x1000D5564, "bl", "#0x1000d60d0"),
    "maximum_read_float32": (0x1000D5584, "bl", "#0x1000d60d0"),
    "health_nonnegative_gate": (0x1000D55C4, "fcmp", "s11, #0.0"),
    "maximum_times_one_point_five": (0x1000D55D0, "fmul", "s0, s10, s14"),
    "root_component_read_u64": (0x1000D55F8, "bl", "#0x1000d61cc"),
    "mesh_component_read_u64": (0x1000D5614, "bl", "#0x1000d61cc"),
    "ai_read_u8": (0x1000D565C, "bl", "#0x1000d6590"),
    "hide_bot_option_gate": (0x1000D5674, "cbnz", "w0, #0x1000d5980"),
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
    assert sha256(core_path.read_bytes()).hexdigest() == CORE_IPA_SHA, "Core IPA identity mismatch"
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
    player_filter_observed = {}
    for label, (va, mnemonic, operand) in PLAYER_FILTER_SITES.items():
        instruction = next(decoder.disasm(core[va - BASE:va - BASE + 4], va))
        assert instruction.mnemonic == mnemonic and operand in instruction.op_str, (
            label, instruction.mnemonic, instruction.op_str)
        player_filter_observed[label] = {"va": hex(va), "file_offset": hex(va - BASE),
                                         "instruction": f"{instruction.mnemonic} {instruction.op_str}"}
    setup = [(i.mnemonic, i.op_str) for i in decoder.disasm(
        core[0xD542C:0xD543C], 0x1000D542C)]
    assert setup == [("ldr", "s12, [x8, #0x2d4]"), ("adrp", "x8, #0x100797000"),
                     ("ldr", "s13, [x8, #0x978]"), ("fmov", "s14, #1.50000000")]
    assert abs(struct.unpack_from("<f", core, 0xAC82D4)[0] + 479.5) < 1e-7
    assert abs(struct.unpack_from("<f", core, 0x797978)[0] - 0.1) < 1e-6
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
              for index in (12, 16, 18, 34, 35, 36, 37, 38, 47, 49, 57, 63, 68)}
    assert values == {12: 0xB78, 16: 0x260, 18: 0x658, 34: 0xB94,
                      35: 0x1060, 36: 0x1068, 37: 0x10BC, 38: 0x1700,
                      47: 0x258, 49: 0x88C, 57: 0x190, 63: 0x2758, 68: 0x3BE0}
    # Micro-CFG: history ready -> distance/dt gate -> local delta velocity ->
    # range gate -> optional smoothing -> sample commit -> .35s/2s/25 gate.
    # None of these sites reads target RepMovement.LinearVelocity.
    remaining_core_sites = {
        "motion_local_clock": (0x1000D9514, "bl", "#0x100123d2c"),
        "motion_clock_double": (0x100123D34, "ldr", "d0, [x8, #0x10]"),
        "motion_distance_gate": (0x1000D9B20, "fmov", "#0.75000000"),
        "motion_interval": (0x1000D9B2C, "fsub", "d3, d8, d0"),
        "motion_min_interval": (0x1000D9B34, "b.lt", "#0x1000d9c00"),
        "motion_max_interval": (0x1000D9B38, "fmov", "#1.00000000"),
        "motion_delta_divide": (0x1000D9B4C, "fdiv", "s3, s4, s0"),
        "motion_speed_gate": (0x1000D9B80, "fcmp", "s2, s14"),
        "motion_smoothing": (0x1000D9BA8, "fmla", "v0.2s, v3.2s, v2.2s"),
        "motion_sample_commit": (0x1000D9BD8, "str", "d8, [x0, #0x38]"),
        "motion_first_seen": (0x1000D9BF0, "stp", "d8, d8, [x0, #0x30]"),
        "motion_latest_seen": (0x1000D9C04, "str", "d8, [x0, #0x40]"),
        "motion_lifetime": (0x1000D9C34, "fmov", "#2.00000000"),
        "motion_sample_age": (0x1000D9C48, "ldr", "d1, [x9, #0xf98]"),
        "motion_min_speed": (0x1000D9C6C, "fmov", "#25.00000000"),
        "prediction_gravity": (0x1000DDEF4, "mov", "w21, #-0x3c0b0000"),
        "prediction_position_z": (0x1000DE094, "ldr", "s1, [x20, #0x28]"),
        "prediction_velocity_z": (0x1000DE098, "ldr", "s2, [x20, #0x34]"),
        "prediction_linear_z": (0x1000DE09C, "fmadd", "s1, s2, s0, s1"),
        "prediction_quadratic_z": (0x1000DE0A8, "fmadd", "s1, s2, s0, s1"),
        "bone_head_profile_first": (0x1000D8BA8, "ldr", "w27, [x8]"),
        "bone_head_transform": (0x1000D9010, "bl", "#0x1000e3654"),
        "bone_head_top_record": (0x1000D94E4, "str", "s1, [sp, #0x3cc]"),
        "bone_array_raw_count_cap": (0x1000E35F8, "cmp", "w25, #0x100"),
        "bone_array_zero_num_uses_max": (0x1000E3614, "csel", "w9, w8, w25, eq"),
        "bone_array_effective_minimum": (0x1000E3618, "cmp", "w9, #6"),
        "bone_array_capacity_gate": (0x1000E3620, "cmp", "w8, w9"),
        "bone_array_effective_store": (0x1000E3630, "str", "w9, [x19, #0x10]"),
        "information_health_clamp": (0x1000DC108, "fcsel", "s12, s0, s1, mi"),
        "information_native_background": (0x1000DC168, "bl", "#0x10013b28c"),
        "information_health_renderer": (0x1000DC200, "bl", "#0x1000d3f70"),
        "information_native_font_measure": (0x1000DC28C, "bl", "#0x100143400"),
    }
    remaining_target_sites = {
        "bone_native_registered": (0x10A3C4124, "ldrb", "w8, [x0, #0xe0]"),
        "bone_native_registration_gate": (0x10A3C4128, "tbnz", "#2"),
        "bone_native_flags": (0x10A3C4150, "ldr", "w9, [x0, #0x25c]"),
        "bone_native_plain_transform": (0x10A3C4158, "ldp", "[x21, #0x1f0]"),
        "bone_native_decoder_branch": (0x10A3C4178, "tbz", "#0x16"),
        "bone_native_decoder_dispatch": (0x10A3C41A0, "blr", "x8"),
        "bone_array_count": (0x10A95EC68, "ldr", "w9, [x0, #0x840]"),
        "bone_array_data": (0x10A95EC74, "ldr", "x9, [x0, #0x838]"),
        "bone_array_stride": (0x10A95EC78, "mov", "w10, #0x30"),
        "opened_class_slot": (0x10679CB4C, "ldr", "x0, [x8, #0xf80]"),
        "opened_class_owner": (0x10679CBAC, "add", "x1, x1, #0xdf4"),
        "opened_bool_setter": (0x10679CB40, "strb", "w8, [x0, #0x5fd]"),
        "opened_onrep_dispatch": (0x10679C990, "bl", "#0x104081b74"),
        "opened_onrep_byte": (0x104081C1C, "ldrb", "w8, [x19, #0x5fd]"),
        "opened_onrep_old_compare": (0x104081C20, "cmp", "w8, w20"),
        "opened_onrep_callback": (0x104081C2C, "bl", "#0x10679c8a4"),
        "wrong_opened_owner": (0x106E727E8, "add", "x1, x1, #0x726"),
        "wrong_opened_setter": (0x106E7277C, "strb", "w8, [x0, #0x68c]"),
    }
    remaining_observed = {}
    for domain, binary, sites in (("core", core, remaining_core_sites), ("target", target, remaining_target_sites)):
        for label, (va, mnemonic, operand) in sites.items():
            instruction = next(decoder.disasm(binary[va - BASE:va - BASE + 4], va))
            assert instruction.mnemonic == mnemonic and operand in instruction.op_str, (label, instruction.mnemonic, instruction.op_str)
            remaining_observed[label] = {"binary": domain, "va": hex(va), "file_offset": hex(va - BASE),
                                         "instruction": f"{instruction.mnemonic} {instruction.op_str}"}
    motion_constants = {"min_interval": (0x100AC83D0, "d", 0.004), "max_speed": (0x100AC82D8, "f", 30000),
                        "max_sample_age": (0x1008A5F98, "d", 0.35), "old_weight": (0x1008A3AB0, "f", 0.35),
                        "new_weight": (0x1008A3AB4, "f", 0.65)}
    for label, (va, kind, expected) in motion_constants.items():
        actual = struct.unpack_from("<" + kind, core, va - BASE)[0]
        assert abs(actual - expected) < 1e-7, (label, actual)
    head_profiles = {}
    for count, va in ((61, 0x100AC8698), (63, 0x100AC8708), (64, 0x100AC8778),
                      (65, 0x100AC87E8), (66, 0x100AC87E8), (70, 0x100AC8858), (71, 0x100AC8858),
                      (72, 0x100AC88C8), (73, 0x100AC8938), (95, 0x100AC89A8)):
        index = struct.unpack_from("<i", core, va - BASE)[0]
        assert index == (28 if count in (70, 71) else 6)
        head_profiles[count] = {"table": hex(va), "head_index": index}
    for va, expected in ((0x10CD16DF4, "InteractiveTreasureBox"), (0x10CE8C726, "STExtraLootTruckAISpawner")):
        assert target[va - BASE:va - BASE + 120].decode("utf-16le").split("\0", 1)[0] == expected
    assert property_at(target, 0x10F2CCD68) == ("GrenadeRadius", 0x628)
    assert property_at(target, 0x1100510A0) == ("LastRepReplicatedMovementTime", 0x5D8)
    return {"core_ipa_sha256": CORE_IPA_SHA, "core_sha256": CORE_SHA,
            "target_sha256": TARGET_SHA, "sites": observed,
            "player_filter_sites": player_filter_observed,
            "strings": {hex(va): text for va, text in STRINGS.items()}, "warning_prefix": prefix,
            "target_properties": properties, "template_values": values,
            "warning_fallback_lifecycle_sites": target_observed,
            "grenade_clock_lifecycle_sites": clock_observed,
            "health_status_enum": health_status,
            "ray_ui_selector_fixups": ui_selectors,
            "remaining_semantic_sites": remaining_observed, "bone_head_profiles": head_profiles,
            "motion_producer_micro_cfg": ["history-ready", "distance>.75 and .004<=dt<=1", "local-delta/dt",
                "1<speed<30000", "new*.65+old*.35", "sample-commit", "first-age<=2 and sample-age<=.35 and speed>25"],
            "boundary": {"timer": "target_clock_owner_closed_reference_258_is_children_num", "radius": "local_circle_is_not_world_blast_radius",
                         "warning_fallback": "owner_rep_movement_rotation_yaw_closed_capture_stability_not_network_freshness",
                         "opened": "children_num_eq1_proxy_not_gameplay_state",
                         "information": "native_background_health_renderer_and_font_measure_not_local_text_layout",
                         "ray": "known_requested_bone_head_closed_full_coverage_and_device_pixels_not_verified",
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
        print(f"PASS: hash-bound Core {len(result['sites'])} display + {len(result['player_filter_sites'])} player-filter / target lifecycle {target_count} instructions / {len(result['strings'])} strings / {len(result['target_properties'])} properties")
        print(f"PASS: remaining micro-CFG {len(result['remaining_semantic_sites'])} instructions / {len(result['bone_head_profiles'])} head profiles")
        print("LIMIT: local animation is not target physics/blast radius; sync-opened is not children equivalence; network freshness, full information layout and device remain unverified")
