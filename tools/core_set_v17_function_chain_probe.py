"""Identity-bound ARM64 function/control/state probe, without executing Core.

Direct call edges and local register propagation are evidence slices, not a
whole-program decompiler or a claim that an indirect/dynamic path is absent.
The sample has no LC_FUNCTION_STARTS; range boundaries remain explicitly graded.
"""

from __future__ import annotations

import argparse
import bisect
from hashlib import sha256
import json
from pathlib import Path
import re
import struct
import sys
import zipfile

from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
import lief
import numpy as np


IPA_SHA = "57412d36a1092931d81a9a820c57eb5c1eb92dcf77076ce865dc95035a3a41cb"
IMAGE_SHA = "c842be92434b88b4d535d0d10a30ace068ce6b9a7b9a97ec5a6ca8fd97fa3dd5"
CONFIG = 0x100C58270
CORE_ENTRY_ROOTS = {
    "home": 0x1000CB874, "player_ui": 0x1000CD6A4,
    "radar_ui": 0x1000CEA6C, "aim_ui": 0x1000CEEE0,
    "recoil_ui": 0x1000CFDB8, "material_ui": 0x1000F8DD0,
    "frame_draw": 0x1000DB144, "action_worker": 0x1000C1A04,
    "home_snapshot": 0x100004010, "information_action": 0x10000538C,
    "persist_configuration": 0x10001161C, "derive_scene": 0x1000C1378,
    "publish_action_input": 0x1000C182C,
    "start_action_timer": 0x1000C1924,
    "read_snapshot_lease": 0x100064C7C, "read_exact": 0x100064D04,
    "read_exact_backend": 0x100060818,
    "checked_write": 0x1000620B8, "write_merge": 0x1000C5AD8,
    "recoil_state": 0x1000C571C, "read_rotation_state": 0x1000C46B4,
    "aim_geometry": 0x1000C4AF8, "fps_get": 0x100017D98,
    "fps_set": 0x100017DBC, "fps_update": 0x10002236C,
    "ui_checkbox": 0x1000C8928, "ui_scalar": 0x1000C9158,
    "ui_integer": 0x1000C9B9C, "ui_color": 0x1000C9BE8,
    "ui_selector": 0x1000CF9E0, "ui_button": 0x1000CA028,
    "weapon_mode": 0x1000CE0EC, "count_mode": 0x1000CE210,
    "information_mode": 0x1000CE344, "material_controls": 0x1000CE45C,
    "adjustment_ui": 0x1000CE6EC, "adjustment_colors": 0x1000CE960,
    "material_categories": 0x1000FA1D0, "material_range": 0x1000FA820,
    "material_range_update": 0x1000FA958,
    "read_lease_backend": 0x1000606F4, "read_target_locked": 0x100061994,
    "read_target_serialized": 0x1000618F0, "translate_target_page": 0x1000646A0,
    "bind_read_region": 0x100064544, "copy_read_region": 0x1000635CC,
    "read_chunks": 0x100031ABC, "read_socket_primitive": 0x100031910,
    "actor_scan": 0x1000D4A08, "actor_prepare": 0x1000D7A88,
    "cover_update": 0x1000D3EAC, "action_result_state": 0x1000C416C,
    "kernel_action": 0x100004F00, "draw_text_sink": 0x10013BAE0,
    "draw_text": 0x1000DF47C, "read_player_name": 0x1000DF55C,
}


def hx(value: int | None) -> str | None:
    return hex(value) if value is not None else None


class CoreImage:
    def __init__(self, path: Path):
        digest = sha256()
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
        assert digest.hexdigest() == IPA_SHA, "IPA identity mismatch"
        with zipfile.ZipFile(path) as archive:
            self.data = archive.read("Payload/Core.app/Core")
        assert sha256(self.data).hexdigest() == IMAGE_SHA, "image identity mismatch"
        self.image = lief.MachO.parse(self.data).at(0)
        self.text = next(section for section in self.image.sections if section.name == "__text")
        self.md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
        self.md.detail = True
        words = np.frombuffer(self.data, dtype="<u4", count=self.text.size // 4, offset=self.text.offset)
        self.prologues = [self.text.virtual_address + int(index) * 4 for index in
                          np.flatnonzero((words == 0xD503237F) | (words == 0xD503233F))]
        self.callers: dict[int, list[int]] = {}
        for index in np.flatnonzero((words & 0xFC000000) == 0x94000000):
            site = self.text.virtual_address + int(index) * 4
            immediate = int(words[index]) & 0x3FFFFFF
            if immediate & (1 << 25):
                immediate -= 1 << 26
            self.callers.setdefault(site + immediate * 4, []).append(site)
        self.prologue_set = set(self.prologues)
        self.roots = sorted(set(self.prologues) | {
            target for target in self.callers
            if self.text.virtual_address <= target < self.text.virtual_address + self.text.size
        })
        self.bindings = {binding.address: binding.symbol.name
                         for binding in self.image.bindings if binding.has_symbol}

    def file_offset(self, address: int) -> int:
        for segment in self.image.segments:
            if segment.virtual_address <= address < segment.virtual_address + segment.file_size:
                return segment.file_offset + address - segment.virtual_address
        raise ValueError(f"unbacked VA {address:#x}")

    def raw(self, address: int, length: int) -> bytes:
        offset = self.file_offset(address)
        return self.data[offset:offset + length]

    def string(self, address: int | None) -> str | None:
        if address is None:
            return None
        for section in self.image.sections:
            if section.virtual_address <= address < section.virtual_address + section.size:
                if section.name not in ("__cstring", "__objc_methname", "__objc_classname"):
                    return None
                return self.raw(address, min(256, section.virtual_address + section.size - address)).split(b"\0", 1)[0].decode("utf-8", "replace")
        return None

    def containing(self, address: int) -> dict:
        index = bisect.bisect_right(self.roots, address) - 1
        assert index >= 0
        start = self.roots[index]
        end = self.roots[index + 1] if index + 1 < len(self.roots) else self.text.virtual_address + self.text.size
        end_basis = "next-prologue-or-direct-call-target; not LC_FUNCTION_STARTS"
        if end - start <= 16 and end in self.prologue_set and index + 2 < len(self.roots):
            first = next(self.md.disasm(self.raw(start, 4), start))
            if first.mnemonic in ("cbz", "cbnz", "tbz", "tbnz"):
                # E.g. read_snapshot_lease begins with a null guard before its
                # authenticated stack prologue, not a separate 4-byte function.
                end = self.roots[index + 2]
                end_basis = "pre-prologue argument guard plus next candidate entry"
        evidence = []
        if start in self.prologue_set:
            evidence.append("authenticated-prologue")
        if start in self.callers:
            evidence.append("direct-bl-target")
        return {"entry": hx(start), "entry_file_offset": hx(self.file_offset(start)),
                "candidate_end": hx(end), "entry_basis": evidence,
                "end_basis": end_basis}

    def instructions(self, start: int, size: int):
        return list(self.md.disasm(self.raw(start, size), start))

    def proof_window(self, start: int, size: int = 16) -> dict:
        assert 4 <= size <= 0x200 and start % 4 == 0 and size % 4 == 0
        return {"address": hx(start), "file_offset": hx(self.file_offset(start)),
                "function_candidate": self.containing(start),
                "instructions": [{"address": hx(instruction.address),
                                  "file_offset": hx(self.file_offset(instruction.address)),
                                  "bytes": bytes(instruction.bytes).hex(),
                                  "instruction": instruction.mnemonic + " " + instruction.op_str}
                                 for instruction in self.instructions(start, size)]}

    def describe_function(self, address: int, maximum_size: int = 0x8000) -> dict:
        bounds = self.containing(address)
        start, end = int(bounds["entry"], 16), int(bounds["candidate_end"], 16)
        instructions = self.instructions(start, min(end - start, maximum_size))
        calls, branches, indirect, tails = [], [], [], []
        for instruction in instructions:
            if instruction.mnemonic == "bl":
                target = int(instruction.op_str.lstrip("#"), 0)
                calls.append({"site": hx(instruction.address), "file_offset": hx(self.file_offset(instruction.address)),
                              "callee": hx(target), "callee_entry_basis": self.containing(target)["entry_basis"]
                              if self.text.virtual_address <= target < self.text.virtual_address + self.text.size else ["external-or-stub"]})
            elif instruction.mnemonic in ("blr", "blraa", "blrab", "blraaz", "blrabz", "br", "braa", "brab", "braaz", "brabz"):
                indirect.append({"site": hx(instruction.address), "instruction": instruction.mnemonic + " " + instruction.op_str})
            elif instruction.mnemonic.startswith("b.") or instruction.mnemonic in ("b", "cbz", "cbnz", "tbz", "tbnz"):
                branches.append({"site": hx(instruction.address), "instruction": instruction.mnemonic + " " + instruction.op_str})
                if instruction.mnemonic == "b":
                    target = int(instruction.op_str.lstrip("#"), 0)
                    if not start <= target < end:
                        tails.append({"site": hx(instruction.address), "file_offset": hx(self.file_offset(instruction.address)),
                                      "callee": hx(target), "basis": "out-of-candidate-range direct branch; candidate tail edge"})
        return bounds | {"requested_anchor": hx(address), "callers": [hx(site) for site in self.callers.get(start, [])],
                         "calls": calls, "conditional_and_direct_branches": branches,
                         "unresolved_indirect_edges": indirect, "candidate_tail_calls": tails,
                         "truncated": end - start > maximum_size}

    def action_timer_block(self) -> dict:
        block = 0x100B92FA0
        encoded = struct.unpack("<Q", self.raw(block + 16, 8))[0]
        invoke = 0x100000000 + (encoded & 0xFFFFFFFF if encoded >> 63 else encoded & 0x7FFFFFFFFFF)
        assert invoke == CORE_ENTRY_ROOTS["action_worker"]
        return {"global_block": hx(block), "invoke_pointer_slot": hx(block + 16),
                "invoke_pointer_file_offset": hx(self.file_offset(block + 16)),
                "encoded_invoke": hx(encoded), "decoded_invoke": hx(invoke),
                "registration_call": "0x1000c19d4", "registration_function": "0x1000c1924",
                "interval_nanoseconds": 0xFE502A,
                "leeway_nanoseconds": 0x1E8480,
                "timer_parameter_sites": ["0x1000c19b4", "0x1000c19b8", "0x1000c19bc", "0x1000c19c0"],
                "basis": "on-disk chained authenticated pointer matches verified worker entry",
                "runtime_scheduling_verified": False}

    def configuration_tables(self) -> dict:
        tables = {
            "trigger_ui_to_storage": (0x1008A9FC0, [1, 2, 0, 3]),
            "trigger_storage_to_ui": (0x1008A9FB0, [2, 0, 1, 3]),
            "scene_ui_to_storage": (0x1008A9FD0, [0, 2, 1, 3]),
            "floating_ui_to_storage": (0x100AC81AC, [6, 4, 1, 0, 2, 3, 5]),
        }
        result = {}
        for name, (address, expected) in tables.items():
            values = list(struct.unpack("<" + "i" * len(expected), self.raw(address, 4 * len(expected))))
            assert values == expected, f"{name} mismatch"
            result[name] = {"address": hx(address), "file_offset": hx(self.file_offset(address)),
                            "values": values, "basis": "identity-bound int32 table bytes; not runtime defaults"}
        return result

    def read_transport_import(self) -> dict:
        stub = 0x100725C60
        instructions = self.instructions(stub, 16)
        assert [instruction.mnemonic for instruction in instructions] == ["adrp", "add", "ldr", "braa"]
        assert instructions[0].op_str.startswith("x17, #")
        assert instructions[1].op_str.startswith("x17, x17, #")
        page = int(instructions[0].op_str.split("#")[1], 0)
        offset = int(instructions[1].op_str.split("#")[1], 0)
        binding = self.bindings.get(page + offset)
        assert binding == "_getsockopt"
        return {"stub": hx(stub), "binding_slot": hx(page + offset),
                "symbol": binding, "call_site": "0x100031a38",
                "scope": "reference kernel primitive only; not a current audited target-read API"}

    def state_slice(self, start: int, size: int) -> dict:
        # Constants are propagated only through explicit instructions. Volatile
        # registers are forgotten at each call; competing CSEL values are unknown.
        values: dict[str, int] = {}
        memory, controls = [], []
        for instruction in self.instructions(start, size):
            mnemonic, operands = instruction.mnemonic, instruction.op_str
            args = operands.split(", ")
            before = values.copy()
            for register in instruction.regs_access()[1]:
                name = instruction.reg_name(register)
                values.pop("x" + name[1:] if name.startswith("w") else name, None)
            key = lambda name: "x" + name[1:] if name.startswith("w") else name
            try:
                if mnemonic == "adrp":
                    values[key(args[0])] = int(args[1].lstrip("#"), 0)
                elif mnemonic == "add" and args[2].startswith("#") and key(args[1]) in before:
                    values[key(args[0])] = before[key(args[1])] + int(args[2].lstrip("#"), 0)
                elif mnemonic == "mov":
                    if args[1].startswith("#"):
                        values[key(args[0])] = int(args[1][1:], 0)
                    elif key(args[1]) in before:
                        values[key(args[0])] = before[key(args[1])]
                for match in re.finditer(r"\[(x\d+)(?:, #(-?(?:0x[0-9a-f]+|\d+)))?\]", operands):
                    base = before.get(match[1])
                    if base is None:
                        continue
                    location = base + int(match[2] or "0", 0)
                    if CONFIG <= location < CONFIG + 0x1D0:
                        memory.append({"site": hx(instruction.address), "file_offset": hx(self.file_offset(instruction.address)),
                                       "config_offset": hx(location - CONFIG), "instruction": mnemonic + " " + operands,
                                       "kind": "read" if mnemonic.startswith("ld") else "write" if mnemonic.startswith("st") else "address-use",
                                       "source_register": match[1], "basis": "local explicit constant propagation"})
                if mnemonic == "bl":
                    target = int(operands.lstrip("#"), 0)
                    pointers = {name: hx(value - CONFIG) for name, value in before.items()
                                if name in ("x0", "x1", "x2", "x3", "x4", "x5") and CONFIG <= value < CONFIG + 0x1D0}
                    label = self.string(before.get("x0"))
                    if pointers:
                        controls.append({"site": hx(instruction.address), "file_offset": hx(self.file_offset(instruction.address)),
                                         "callee": hx(target), "label": label, "configuration_pointer_arguments": pointers})
                if mnemonic in ("bl", "blr", "blraa", "blrab", "blraaz", "blrabz"):
                    for index in range(19):
                        values.pop(f"x{index}", None)
                if mnemonic in ("pacibsp", "paciasp", "ret", "retab"):
                    values.clear()
            except (ValueError, IndexError):
                pass
        return {"start": hx(start), "size": hx(size), "configuration_owner": hx(CONFIG),
                "memory_references": memory, "configuration_calls": controls,
                "limit": "single linear slice; indirect bases/CFG merges are not asserted"}


def main() -> None:
    sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser()
    parser.add_argument("--reference-ipa", type=Path, required=True)
    parser.add_argument("--function", type=lambda value: int(value, 0), action="append")
    parser.add_argument("--state-start", type=lambda value: int(value, 0))
    parser.add_argument("--state-size", type=lambda value: int(value, 0), default=0x9000)
    parser.add_argument("--proof-site", type=lambda value: int(value, 0), action="append",
                        help="Emit a bounded 16-byte instruction window with file offsets")
    parser.add_argument("--point-id", type=str,
                        help="Query one stable v17-000...v17-136 contract and replay its proof sites")
    parser.add_argument("--compact", action="store_true")
    parser.add_argument("--checkpoint", action="store_true",
                        help="Keep complete state references and bounded inter-root edges for an evidence fixture")
    arguments = parser.parse_args()
    if arguments.point_id and arguments.function:
        parser.error("--point-id and --function select different query scopes; use one")
    core = CoreImage(arguments.reference_ipa)
    result = {"schema_version": 1, "ipa_sha256": IPA_SHA, "image_sha256": IMAGE_SHA,
              "function_starts_present": core.image.function_starts is not None,
              "evidence_grade": "static byte-bound slices; no runtime receipt",
              "functions": {name: core.describe_function(address) for name, address in CORE_ENTRY_ROOTS.items()}
              if not arguments.function else {hx(address): core.describe_function(address) for address in arguments.function}}
    result["action_timer_block"] = core.action_timer_block()
    result["configuration_tables"] = core.configuration_tables()
    result["read_transport_import"] = core.read_transport_import()
    if arguments.point_id:
        if not re.fullmatch(r"v17-\d{3}", arguments.point_id):
            raise ValueError("invalid stable point ID")
        fixture = Path(__file__).resolve().parents[1] / "tests" / "fixtures" / "core_set_v17_native_point_chain_map.json"
        manifest = json.loads(fixture.read_text(encoding="utf-8"))
        if manifest["reference_image_sha256"] != IMAGE_SHA or manifest["reference_ipa_sha256"] != IPA_SHA:
            raise ValueError("point-map identity mismatch")
        matches = [point for point in manifest["points"] if point["id"] == arguments.point_id]
        if len(matches) != 1:
            raise ValueError("stable point ID not uniquely mapped")
        point = matches[0]
        profile = manifest["chain_profiles"][point["chain_profile"]]
        names = {candidate for field, value in profile.items()
                 if isinstance(value, list) and field not in ("exact_edges", "unresolved")
                 for candidate in value if isinstance(candidate, str) and candidate in CORE_ENTRY_ROOTS}
        names.update(edge[index] for edge in profile["exact_edges"] for index in (0, 1))
        result["functions"] = {name: result["functions"][name] for name in sorted(names)}
        result["point"] = point
        result["chain_profile"] = profile
        sites = list(dict.fromkeys(point["control_sites"] + point.get("reader_sites", [])
                                   + [read["site"] for read in point["native_read_sites"]]))
        result["proof_windows"] = [core.proof_window(int(address, 16)) for address in sites]
    if arguments.proof_site:
        result["proof_windows"] = [core.proof_window(address) for address in arguments.proof_site]
    if arguments.state_start is not None:
        result["state_slice"] = core.state_slice(arguments.state_start, arguments.state_size)
    if arguments.checkpoint:
        root_addresses = {hx(address) for address in CORE_ENTRY_ROOTS.values()}
        result["functions"] = {
            name: {key: value for key, value in function.items()
                   if key not in ("calls", "conditional_and_direct_branches")}
            | {"direct_call_count": len(function["calls"]),
               "branch_count": len(function["conditional_and_direct_branches"]),
               "inter_root_calls": [edge for edge in function["calls"] if edge["callee"] in root_addresses]}
            for name, function in result["functions"].items()}
    if arguments.compact and not arguments.checkpoint:
        result = {key: value for key, value in result.items() if key != "functions"} | {
            "functions": {name: {key: value for key, value in function.items()
                                if key not in ("calls", "conditional_and_direct_branches", "unresolved_indirect_edges")}
                          | {"call_count": len(function["calls"]),
                             "unresolved_indirect_count": len(function["unresolved_indirect_edges"])}
                          for name, function in result["functions"].items()}}
        if "state_slice" in result:
            state = result["state_slice"]
            result["state_slice"] = {key: value for key, value in state.items()
                                     if key not in ("memory_references", "configuration_calls")}
            result["state_slice"].update(memory_reference_count=len(state["memory_references"]),
                                          configuration_call_count=len(state["configuration_calls"]))
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
