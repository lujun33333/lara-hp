"""Fixed-identity, offline action micro-CFG/target ownership probe.

Unicorn executes only bounded pure instruction slices in synthetic memory.
The checked-write entry is a STOP hook: it is never executed. No process is
opened, no target mutation occurs, and no IPA is extracted or loaded natively.
"""

from __future__ import annotations

import argparse
from hashlib import sha256
import json
from pathlib import Path
import plistlib
import struct
import sys
import zipfile

from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM, UC_HOOK_CODE
from unicorn.arm64_const import (
    UC_ARM64_REG_PC, UC_ARM64_REG_SP, UC_ARM64_REG_X0, UC_ARM64_REG_X1,
    UC_ARM64_REG_X2, UC_ARM64_REG_X3, UC_ARM64_REG_X4, UC_ARM64_REG_X8,
    UC_ARM64_REG_X10, UC_ARM64_REG_X21, UC_ARM64_REG_X24, UC_ARM64_REG_X25,
    UC_ARM64_REG_X26, UC_ARM64_REG_X28, UC_ARM64_REG_X30,
    UC_ARM64_REG_S0, UC_ARM64_REG_S1, UC_ARM64_REG_S9, UC_ARM64_REG_S10,
    UC_ARM64_REG_S15, UC_ARM64_REG_D0, UC_ARM64_REG_D8,
)

from core_set_v17_function_chain_probe import CoreImage, IMAGE_SHA, IPA_SHA

TARGET_SHA = "e3b3e8d47f1ad116b74d0a578d3394f5f1ab85e85c9ceb4f61293bd7ba76dc98"
TARGET_UUID = "34b785b20dab3992985d359e6bf45585"
CONFIG = 0x100C58270
STACK = 0x3000000000
SCRATCH = 0x2000000000
RETURN = 0x4000000000
CHECKED_WRITE = 0x1000620B8


def float_bits(value: float) -> int:
    return struct.unpack("<I", struct.pack("<f", value))[0]


def double_bits(value: float) -> int:
    return struct.unpack("<Q", struct.pack("<d", value))[0]


class MicroRunner:
    def __init__(self, core: CoreImage):
        self.core = core
        self.uc = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
        for segment in core.image.segments:
            if segment.virtual_address and segment.virtual_size:
                self.uc.mem_map(segment.virtual_address, (segment.virtual_size + 0xFFF) & ~0xFFF)
                if segment.file_size:
                    self.uc.mem_write(segment.virtual_address,
                                      core.data[segment.file_offset:segment.file_offset + segment.file_size])
        self.uc.mem_map(STACK, 0x100000)
        self.uc.mem_map(SCRATCH, 0x10000)
        self.uc.mem_map(RETURN, 0x1000)
        # Synthetic runtime fixup for the imported stack guard, not code bytes.
        self.uc.mem_write(0x100B8DB58, struct.pack("<Q", SCRATCH + 0xFF00))
        self.uc.mem_write(SCRATCH + 0xFF00, struct.pack("<Q", 0x123456789ABCDE))
        self.stopping_address = RETURN
        self.sink = None
        self.uc.hook_add(UC_HOOK_CODE, self._step)

    def _step(self, engine: Uc, address: int, size: int, _data: object):
        if address == self.stopping_address or address == RETURN:
            engine.emu_stop()
            return
        if address == CHECKED_WRITE:
            length = engine.reg_read(UC_ARM64_REG_X4)
            assert length in (4, 8), "unexpected draft length"
            self.sink = {"address": engine.reg_read(UC_ARM64_REG_X1), "length": length,
                         "expectedOld": bytes(engine.mem_read(engine.reg_read(UC_ARM64_REG_X2), length)).hex(),
                         "newValue": bytes(engine.mem_read(engine.reg_read(UC_ARM64_REG_X3), length)).hex(),
                         "executed": False}
            engine.emu_stop()
            return
        if address in (0x1007267A0, 0x1007267C0):
            # Only scene's own mutex stubs; no host pthread call occurs.
            engine.reg_write(UC_ARM64_REG_X0, 0)
            engine.reg_write(UC_ARM64_REG_PC, engine.reg_read(UC_ARM64_REG_X30))
            return
        instruction = next(self.core.md.disasm(bytes(engine.mem_read(address, size)), address))
        if instruction.mnemonic in ("pacibsp", "autibsp"):
            engine.reg_write(UC_ARM64_REG_PC, address + size)
        elif instruction.mnemonic == "retab":
            engine.reg_write(UC_ARM64_REG_PC, engine.reg_read(UC_ARM64_REG_X30))

    def run(self, start: int, stop: int = RETURN):
        self.stopping_address = stop
        self.sink = None
        self.uc.reg_write(UC_ARM64_REG_SP, STACK + 0x80000)
        self.uc.reg_write(UC_ARM64_REG_X30, RETURN)
        self.uc.emu_start(start, stop, count=20000)
        pc = self.uc.reg_read(UC_ARM64_REG_PC)
        assert pc in (stop, RETURN, CHECKED_WRITE), f"micro-CFG did not reach a permitted boundary: {pc:#x}"

    def set_i32(self, offset: int, value: int):
        self.uc.mem_write(CONFIG + offset, struct.pack("<i", value))

    def read_i32(self, address: int) -> int:
        return struct.unpack("<i", self.uc.mem_read(address, 4))[0]

    def trigger(self, case: dict) -> dict:
        self.set_i32(0x14C, case["mode"])
        self.uc.reg_write(UC_ARM64_REG_X24, CONFIG)
        self.uc.reg_write(UC_ARM64_REG_X25, int(case["enabled"]))
        self.uc.reg_write(UC_ARM64_REG_X8, int(case["ads"]) & 1)
        self.uc.reg_write(UC_ARM64_REG_X21, int(case["fire"]) & 1)
        self.uc.reg_write(UC_ARM64_REG_D8, double_bits(case["now"]))
        self.uc.reg_write(UC_ARM64_REG_D0, 0)
        self.run(0x1000C22B0, 0x1000C2320)
        deadline = struct.unpack("<d", self.uc.mem_read(0x100C519B8, 8))[0]
        return {"deadline": deadline, "active": self.uc.reg_read(UC_ARM64_REG_X10) & 1}

    def scene(self, case: dict) -> dict:
        self.set_i32(0x180, case["scene"])
        self.set_i32(0x184, case["lockStrength"])
        for offset, value in zip((0x190, 0x194, 0x198, 0x19C, 0x1A0, 0x1A8, 0x1A4, 0x1B4, 0x1B8), case["custom"], strict=True):
            self.set_i32(offset, value)
        self.run(0x1000C1378)
        self.uc.reg_write(UC_ARM64_REG_X8, SCRATCH + 0x1000)
        self.run(0x1000C4854)
        values = [self.read_i32(CONFIG + offset) for offset in (0x158, 0x15C, 0x160, 0x170, 0x174, 0x17C)]
        lock = [self.read_i32(SCRATCH + 0x1000 + offset) for offset in (0x10, 0x14, 0x18)]
        return {"effective": values + lock, "normalizedLock": self.read_i32(CONFIG + 0x184)}

    def post_flag(self, case: dict) -> int:
        self.uc.reg_write(UC_ARM64_REG_X24, CONFIG)
        self.uc.reg_write(UC_ARM64_REG_X28, case["vertical"])
        self.uc.reg_write(UC_ARM64_REG_X21, case["fire"])
        self.uc.mem_write(CONFIG + 0x18D, bytes([case["storedContinue"]]))
        self.run(0x1000C3278, 0x1000C32B4)
        return bytes(self.uc.mem_read(STACK + 0x80000 + 0x6C, 1))[0]

    def draft(self, case: dict) -> dict:
        base = 0x123450000
        offset = 0x620 if case["slot"] == 1 else 0x828
        self.uc.mem_write(SCRATCH, struct.pack("<Iff", 1, *case["old"]))
        self.uc.reg_write(UC_ARM64_REG_X0, 15915)
        self.uc.reg_write(UC_ARM64_REG_X1, base + offset)
        self.uc.reg_write(UC_ARM64_REG_X2, SCRATCH)
        self.uc.reg_write(UC_ARM64_REG_X8, SCRATCH + 0x100)
        self.uc.reg_write(UC_ARM64_REG_S0, float_bits(case["delta"][0]))
        self.uc.reg_write(UC_ARM64_REG_S1, float_bits(case["delta"][1]))
        self.run(0x1000C5AD8)
        if self.sink is None:
            return {"offset": 0, "length": 0, "noWrite": True,
                    "expectedOld": "", "newValue": "", "sinkExecuted": False}
        return {"offset": self.sink["address"] - base, "length": self.sink["length"],
                "noWrite": False, "expectedOld": self.sink["expectedOld"],
                "newValue": self.sink["newValue"], "sinkExecuted": self.sink["executed"]}


def differential(core: CoreImage, planner: dict) -> dict:
    runners = {}
    for case in planner["trigger"]:
        if case["group"] not in runners:
            runners[case["group"]] = MicroRunner(core)
        runner = runners[case["group"]]
        actual = runner.trigger(case)
        assert actual["deadline"] == case["deadline"] and actual["active"] == case["active"], (case, actual)
    for case in planner["scene"]:
        assert MicroRunner(core).scene(case) == {key: case[key] for key in ("effective", "normalizedLock")}
    for case in planner["post_flag"]:
        assert MicroRunner(core).post_flag(case) == case["flag"]
    for case in planner["draft"]:
        actual = MicroRunner(core).draft(case)
        assert not actual.pop("sinkExecuted")
        assert actual == {key: case[key] for key in actual}, (case, actual)
    # Complete worker SSA definition scan, not a nearby-name heuristic.
    writes = [{"site": hex(instruction.address), "instruction": instruction.mnemonic + " " + instruction.op_str}
              for instruction in core.instructions(0x1000C1A04, 0x2774)
              if any(instruction.reg_name(register) in ("w28", "x28") for register in instruction.regs_access()[1])]
    assert writes == [{"site": "0x1000c1a80", "instruction": "ldrb w28, [x24, #0x1bc]"},
                      {"site": "0x1000c21d4", "instruction": "ldp x28, x27, [sp, #0x40]"}]
    return {"scope": "offline pure-CFG differential only; no original game action receipt",
            "reference_ipa_sha256": IPA_SHA, "reference_image_sha256": IMAGE_SHA,
            "cases": {key: len(planner[key]) for key in ("trigger", "scene", "post_flag", "draft")},
            "worker_w28_definitions": writes, "checked_write_executions": 0,
            "synthetic_substitutions": ["stack guard fixup", "PAC/RET authentication without native pointer execution", "scene pthread mutex stubs", "checked-write stop hook"]}


def target_evidence(path: Path) -> dict:
    with zipfile.ZipFile(path) as archive:
        data = archive.read("Payload/ShadowTrackerExtra.app/ShadowTrackerExtra")
        info = plistlib.loads(archive.read("Payload/ShadowTrackerExtra.app/Info.plist"))
    assert sha256(data).hexdigest() == TARGET_SHA
    assert info["CFBundleVersion"] == "15915" and info["CFBundleShortVersionString"] == "1.38.12"
    cursor, uuid = 32, None
    segments = []
    for _ in range(struct.unpack_from("<I", data, 16)[0]):
        command, length = struct.unpack_from("<II", data, cursor)
        assert 8 <= length <= len(data) - cursor
        if command == 0x1B: uuid = data[cursor + 8:cursor + 24].hex()
        if command == 0x19:
            segments.append(struct.unpack_from("<QQQQ", data, cursor + 24))
        cursor += length
    assert uuid == TARGET_UUID
    def offset(va):
        for address, _size, fileoff, filesize in segments:
            if address <= va < address + filesize: return fileoff + va - address
        raise ValueError("unbacked target VA")
    def q(va): return struct.unpack_from("<Q", data, offset(va))[0]
    properties = []
    for name, descriptor, relative in (("ControlRotation", 0x11081AAB8, 0x620),
                                       ("RotationInput", 0x110948700, 0x828),
                                       ("Pitch", 0x1103E7150, 0), ("Yaw", 0x1103E7118, 4)):
        label = q(descriptor + 8)
        assert data[offset(label):offset(label) + len(name) + 1] == name.encode() + b"\0"
        assert q(descriptor + 0x30) == relative
        properties.append({"name": name, "descriptor": hex(descriptor), "nameVA": hex(label), "relativeOffset": relative})
    table = 0x10E7BBC38
    slots = {0x960: 0x104C5F584, 0x600: 0x104CC74D4, 0xE00: 0x104C970CC,
             0xE10: 0x104CE7800, 0xEE0: 0x107CFD600, 0xEE8: 0x107CFD69C}
    for slot, function in slots.items(): assert q(table + slot) == function
    md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    anchors = [0x106F37508, 0x106F375B4, 0x106F3F024, 0x104C7AFD4, 0x104C76770,
               0x107CFD680, 0x107CFD71C, 0x104CE7884, 0x104CE7990, 0x104CE79A0,
               0x104CE7CF0, 0x10A8381AC, 0x10A838598, 0x104C5F584,
               0x106DB8470, 0x106D2D6D0, 0x103D2F784, 0x1039B826C]
    windows = [{"address": hex(va), "file_offset": hex(offset(va)),
                "instructions": [{"address": hex(i.address), "bytes": bytes(i.bytes).hex(),
                                  "instruction": i.mnemonic + " " + i.op_str}
                                 for i in md.disasm(data[offset(va):offset(va) + 32], va)]}
               for va in anchors]
    return {"image_sha256": TARGET_SHA, "uuid": uuid, "version": "1.38.12", "build": "15915",
            "properties": properties, "stextra_vtable": hex(table),
            "vtable_slots": {hex(slot): hex(function) for slot, function in slots.items()},
            "windows": windows, "zero_reset_source": "0x111120f20",
            "boundary": "specific STExtra ctor/vtable + two-axis additive input/UpdateRotation/conditional reset static chain; not atomic against game threads and not an external restore contract"}


def action_evidence(core: CoreImage, native_map: dict, target: dict) -> dict:
    """Reproducible static evidence; component parity is not point completion."""
    selected = native_map["points"][106:137]
    assert [point["id"] for point in selected] == [f"v17-{number:03}" for number in range(106, 137)]
    assert native_map["reference_image_sha256"] == IMAGE_SHA
    anchors = [(0x1000C1A78, 32), (0x1000C22A0, 0x80), (0x1000C3278, 64),
               (0x1000C1378, 0x180), (0x1000C1664, 0x180), (0x1000C4854, 0x160),
               (0x1000C5AD8, 0x100), (0x1000C6730, 0x64), (0x1000C2E24, 64),
               (0x1000C3914, 32), (0x1000C3988, 32), (0x1000C46B4, 96), (0x1000C571C, 96)]
    tables = []
    for va, count in ((0x1008A9990, 24), (0x1008A9940, 4), (0x1008A9950, 4),
                      (0x1008A9CF4, 5), (0x1008A98F8, 2), (0x1008A9900, 2)):
        raw = core.raw(va, count * 4)
        tables.append({"address": hex(va), "file_offset": hex(core.file_offset(va)),
                       "bytes": raw.hex(), "int32_values": list(struct.unpack(f"<{count}i", raw))})
    common_edges = ["candidate/publishedKey/controller generation → trusted current request/snapshot authority",
                    "all c2e24 predecessors including c3914/c3988 → slot65/66 choice",
                    "checked-write result → current independent readback under game-thread concurrency",
                    "disable/target-loss/scene-change → stopped producers/drained writer/all owned effects restored"]
    points = []
    scene_points = set(range(117, 131))
    for point in selected:
        number = int(point["id"][4:])
        components = []
        if number in (106, 109): components.append("trigger-latch-valid-input-parity")
        if number in scene_points: components.append("six-scene-three-lock-parameter-parity")
        if number in (132, 133): components.append("post-state-w28-policy-parity")
        edge = ("c4af8/c571c prior-state/history/delta-time → same-cycle two-axis increment" if number >= 126 else
                "candidate worldpoint/filter/sticky state → original selector/result observable")
        if number == 114:
            edge = "Core pawn-state bit19 producer/owner → build15915 PawnStateRepSyncData+1700 storage/knocked semantics"
        if number in (120, 129, 130):
            edge = "lock threshold/confirmation count/pause → c416c result state and takeover lifetime"
        points.append({"id": point["id"], "title": point["title"],
                       "evidence_key": "action-cycle/" + point["id"],
                       "prior_native_evidence_key": point["reference_evidence_key"],
                       "local_configuration": point["local_configuration"],
                       "core_self_storage": point["storage"], "control_sites": point["control_sites"],
                       "current_alternative_preview": point["alternative_preview"],
                       "component_parity_contracts": components,
                       "next_exact_edges": [edge] + common_edges,
                       "original_runtime_receipt_verified": False, "one_to_one_complete": False})
    return {"schema_version": 1, "reference_ipa_sha256": IPA_SHA,
            "reference_image_sha256": IMAGE_SHA, "reference_uuid": native_map["reference_uuid"],
            "scope": "static bytes + offline pure-CFG parity contracts; no target writer authority or original device action receipt",
            "point_count": len(points), "one_to_one_complete_count": 0,
            "reference_windows": [core.proof_window(va, size) for va, size in anchors],
            "reference_tables": tables, "target_static_evidence": target,
            "function_edges": [
                {"caller": "0x1000c1a04", "slice": "0x1000c22a0..0x1000c2318", "sink": "Core-self BSS 0x100c519b8",
                 "semantics": "valid-input mode 1=ADS/2=fire/0=either/3=both; match sets deadline=now+0.25; active iff enabled and now<deadline"},
                {"caller": "0x1000c1378", "callee": "0x1000c1664", "call_site": "0x1000c139c", "separate_lock_helper": "0x1000c4854",
                 "semantics": "six named scene parameters + three lock values; remaining table columns not given invented semantics"},
                {"caller": "0x1000c1a04", "definition": "0x1000c1a80", "slice": "0x1000c3278..0x1000c32b0", "sink": "0x1000c416c input sp+0x6c",
                 "semantics": "(verticalEnabled w28 & 1) & storedContinue C18d; not raw fire or target-stop restoration"},
                {"caller": "0x1000c5ad8", "callee": "0x1000620b8", "single_axis_helper": "0x1000c6730",
                 "semantics": "explicit caller-provided slot; old+delta; expected-old/new 4/8 bytes; both-zero=no-write not restored"}],
            "offline_parity_case_counts": {"trigger": 24, "scene": 12, "post_flag": 16, "draft": 8},
            "direct_call_sites": {hex(function): [hex(site) for site in core.callers.get(function, [])]
                                  for function in (0x1000C1664, 0x1000C4854, 0x1000C416C, 0x1000C5AD8, 0x1000C6730)},
            "cleanup_contract": {"no_write_resources_clean": True, "any_mapped_write_attempt_without_restore": False,
                                 "explicit_synthetic_verified_receipt": True,
                                 "production_restoration_verifier_installed": False,
                                 "automatic_writeback_or_rotation_input_clear": False},
            "next_probe_log_schema": ["lane/pointID/pid/imageBase/UUID/read generation/capture cycle/snapshotID",
                                      "raw ADS/fire/capture completion monotonic time/age/transport diagnostic",
                                      "candidate key/bone producer/scene/predecessor/slot/axis/expected-old-new hashes only",
                                      "request token/effect epoch/readback cycle/producer drain/restoration verifier result"],
            "current_probe_scope": "existing audited read session only; 30s bounded ADS/fire capture; synthetic-unit canvas; no selector/write/canvas receipt",
            "reproduce": "python -B tests/core_set_action_cycle_contract_test.py --reference-ipa <exact-v1.7-ipa> --target-ipa <exact-1.38.12-ipa> --planner-exe tests/.action-cycle-build/core_set_action_cycle_plan_test.exe",
            "points": points}


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description="Static action-cycle evidence only; JSON to stdout, no writes")
    parser.add_argument("--reference-ipa", type=Path, required=True)
    parser.add_argument("--target-ipa", type=Path, required=True)
    parser.add_argument("--point-id")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    native = json.loads((root / "tests/fixtures/core_set_v17_native_point_chain_map.json").read_text(encoding="utf-8"))
    evidence = action_evidence(CoreImage(args.reference_ipa), native, target_evidence(args.target_ipa))
    if args.point_id:
        evidence = next(point for point in evidence["points"] if point["id"] == args.point_id)
    print(json.dumps(evidence, ensure_ascii=False, indent=2))
