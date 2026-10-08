"""Original selector/state CFG edges in synthetic memory, never native target execution."""
from __future__ import annotations

import struct
import math
import numpy as np
from unicorn import arm64_const as ar
from core_set_action_cycle_probe import MicroRunner, CONFIG, STACK, SCRATCH, RETURN


def f32(value):
    return struct.unpack("<f", struct.pack("<f", value))[0]


class SelectionRunner(MicroRunner):
    def __init__(self, core):
        self.extra_stops = set()
        super().__init__(core)

    def _step(self, engine, address, size, data):
        if address in self.extra_stops:
            engine.emu_stop(); return
        if address == 0x1007268F0:
            # Pure libc remainderf substitute, never a native imported call.
            self.sf(ar.UC_ARM64_REG_S0, math.remainder(self.rf(ar.UC_ARM64_REG_S0), self.rf(ar.UC_ARM64_REG_S1)))
            engine.reg_write(ar.UC_ARM64_REG_PC, engine.reg_read(ar.UC_ARM64_REG_X30)); return
        super()._step(engine, address, size, data)

    def bounded(self, start, stop, extra=()):
        self.stopping_address = stop; self.extra_stops = set(extra); self.sink = None
        self.uc.reg_write(ar.UC_ARM64_REG_SP, STACK + 0x80000)
        self.uc.reg_write(ar.UC_ARM64_REG_X30, RETURN)
        self.uc.emu_start(start, stop, count=20000)
        pc = self.uc.reg_read(ar.UC_ARM64_REG_PC)
        assert pc in {stop, RETURN} | self.extra_stops, hex(pc)
        assert self.sink is None, "selector/state edge must never reach the write sink"
        return pc

    def put(self, address, fmt, *values):
        self.uc.mem_write(address, struct.pack("<" + fmt, *values))

    def get(self, address, fmt):
        return struct.unpack("<" + fmt, self.uc.mem_read(address, struct.calcsize("<" + fmt)))

    def sf(self, register, value):
        self.uc.reg_write(register, struct.unpack("<I", struct.pack("<f", value))[0])

    def rf(self, register):
        return struct.unpack("<f", struct.pack("<I", self.uc.reg_read(register)))[0]

    def actor_gate(self, case):
        self.uc.reg_write(ar.UC_ARM64_REG_X24, SCRATCH)
        self.uc.reg_write(ar.UC_ARM64_REG_X19, SCRATCH + 0x1000)
        self.uc.reg_write(ar.UC_ARM64_REG_X27, CONFIG)
        self.put(STACK + 0x80000 + 0x16C, "I", 1)
        self.put(SCRATCH + 0x10, "I", case["state"])
        self.put(SCRATCH + 0x14, "B", case["flag"])
        self.put(SCRATCH + 0x58, "B", case["bone"])
        self.put(SCRATCH + 0x1000 + 0x240, "B", case["bot"])
        self.put(SCRATCH + 0x1000 + 0x244, "f", 100)
        self.put(CONFIG + 0x169, "B", case["exclude"])
        self.put(CONFIG + 0x16A, "B", case["include"])
        self.put(CONFIG + 0x160, "i", 300)
        self.sf(ar.UC_ARM64_REG_S13, 50)
        return self.bounded(0x1000DD464, 0x1000DD4DC, (0x1000DBDC8,)) == 0x1000DD4DC

    def point(self, case):
        self.uc.reg_write(ar.UC_ARM64_REG_X24, SCRATCH)
        self.uc.reg_write(ar.UC_ARM64_REG_X27, CONFIG)
        self.put(SCRATCH + 0x58, "B", case["bone"])
        self.put(SCRATCH + 0x18, "fff", 1, 2, 3)
        self.put(SCRATCH + 0x1E0, "fff", 101, 202, 303)
        self.put(SCRATCH + 0x1EC, "fff", 11, 22, 33)
        self.put(CONFIG + 0x150, "i", case["point"])
        self.uc.reg_write(ar.UC_ARM64_REG_X9, case["bone"])
        self.bounded(0x1000DD4DC, 0x1000DD5A0)
        return list(self.get(STACK + 0x80000 + 0x300, "fff"))

    def rank(self, case):
        self.uc.reg_write(ar.UC_ARM64_REG_X19, SCRATCH + 0x1000)
        self.uc.reg_write(ar.UC_ARM64_REG_X27, CONFIG)
        self.put(SCRATCH + 0x1004, "ff", 640, 480)
        self.put(CONFIG + 0x18E, "B", 1)
        self.put(0x100C52178, "Q", 9)
        sp = STACK + 0x80000
        self.put(sp + 0x180, "Q", 9)
        self.put(sp + 0x168, "f", case["radius"])
        self.put(sp + 0x24, "f", f32(case["radius"] * f32(1.15)))
        self.put(sp + 0x70, "f", case["best"])
        self.sf(ar.UC_ARM64_REG_S0, case["x"]); self.sf(ar.UC_ARM64_REG_S1, case["y"])
        self.bounded(0x1000DD5B8, 0x1000DBDC8)
        return {"updated": self.get(sp + 0x50, "I")[0], "sticky": self.get(sp + 0x60, "I")[0],
                "newBest": self.get(sp + 0x70, "f")[0]}

    def clock(self, case):
        self.uc.reg_write(ar.UC_ARM64_REG_X21, SCRATCH)
        self.uc.reg_write(ar.UC_ARM64_REG_X19, SCRATCH + 0x1000)
        self.uc.reg_write(ar.UC_ARM64_REG_X24, case["key"])
        self.uc.reg_write(ar.UC_ARM64_REG_X23, case["nowNS"])
        self.put(SCRATCH, "B", case["initialized"])
        self.put(SCRATCH + 8, "QQffB", case["previousKey"], case["previousNS"], 2, 4, 1)
        pc = self.bounded(0x1000C5014, 0x1000C50E4, (0x1000C5074,))
        return {"first": self.get(SCRATCH + 0x1001, "B")[0], "eligible": pc == 0x1000C50E4,
                "dt": self.get(SCRATCH + 0x1030, "f")[0],
                "residualPresent": self.get(SCRATCH + 0x20, "B")[0],
                "residual": list(self.get(SCRATCH + 0x18, "ff"))}

    def route(self, case):
        self.uc.reg_write(ar.UC_ARM64_REG_X21, case["fire"])
        self.uc.reg_write(ar.UC_ARM64_REG_X20, 0)
        self.uc.reg_write(ar.UC_ARM64_REG_X25, 0)
        for register, value in ((ar.UC_ARM64_REG_S15, 1), (ar.UC_ARM64_REG_S13, 4),
                                (ar.UC_ARM64_REG_S14, 2), (ar.UC_ARM64_REG_S12, 5)):
            self.sf(register, value)
        # Explicit synthetic profile operands test selection, not an installed
        # runtime target profile. Core's static slots65/66 are separately checked.
        for offset, value in ((0x208, 0x620), (0x210, 0x828), (0x460, 0), (0x468, 0)):
            self.put(0x100BD8660 + offset, "Q", value)
        start = (0x1000C2E14, 0x1000C3914, 0x1000C3988)[case["predecessor"]]
        self.bounded(start, 0x1000C2F24)
        offset = self.uc.reg_read(ar.UC_ARM64_REG_X9)
        assert offset in (0x620, 0x828)
        return {"slot": 1 if offset == 0x620 else 2, "w19": self.uc.reg_read(ar.UC_ARM64_REG_X19)}

    def takeover(self, case):
        self.uc.reg_write(ar.UC_ARM64_REG_X20, 1)
        self.uc.reg_write(ar.UC_ARM64_REG_X8, 0)  # Explicit non-tiny-input predecessor.
        self.put(STACK + 0x80000 + 0x38, "f", 0.05)
        self.put(STACK + 0x80000 + 0x124, "i", 2)
        self.put(STACK + 0x80000 + 0x34, "i", 300)
        self.put(0x100C519B4, "I", case["oldCount"])
        self.put(0x100C519C0, "d", case["oldDeadline"])
        self.uc.reg_write(ar.UC_ARM64_REG_D8, struct.unpack("<Q", struct.pack("<d", 1.0))[0])
        self.sf(ar.UC_ARM64_REG_S0, case["magnitude"])
        self.sf(ar.UC_ARM64_REG_S13, 4); self.sf(ar.UC_ARM64_REG_S12, 5)
        self.bounded(0x1000C38C8 if case["force"] else 0x1000C3854, 0x1000C2E24)
        return {"allowed": self.uc.reg_read(ar.UC_ARM64_REG_X20) != 0,
                "zeroFirst": self.rf(ar.UC_ARM64_REG_S13) == 0,
                "zeroSecond": self.rf(ar.UC_ARM64_REG_S12) == 0,
                "predecessor": 1 if self.uc.reg_read(ar.UC_ARM64_REG_X20) else 2,
                "newCount": self.get(0x100C519B4, "I")[0], "newDeadline": self.get(0x100C519C0, "d")[0]}

    def recoil(self, case):
        state = case["before"]
        self.put(SCRATCH, "H", state[0])
        self.put(SCRATCH + 8, "QIIfff", *state[1:])
        self.put(SCRATCH + 0x2000, "fffffffI", case["strength"], 0.72, 0.08, 1.5, 1.25, 0.005, 0.2, 3)
        for register, value in ((ar.UC_ARM64_REG_X0, SCRATCH), (ar.UC_ARM64_REG_X1, case["fire"]),
                                (ar.UC_ARM64_REG_X2, case["key"]), (ar.UC_ARM64_REG_X3, case["binding"]),
                                (ar.UC_ARM64_REG_X4, 1), (ar.UC_ARM64_REG_X5, SCRATCH + 0x2000),
                                (ar.UC_ARM64_REG_X8, SCRATCH + 0x1000)):
            self.uc.reg_write(register, value)
        self.sf(ar.UC_ARM64_REG_S0, case["pitch"]); self.sf(ar.UC_ARM64_REG_S1, case["priorAim"])
        self.bounded(0x1000C571C, RETURN)
        return {"after": list(self.get(SCRATCH, "H")) + list(self.get(SCRATCH + 8, "QIIfff")),
                "result": list(self.get(SCRATCH + 0x1000, "HBBfffff"))}

    def motion(self, case):
        before = case["before"]
        self.put(0x100C51960, "B", before[0])
        self.put(0x100C51968, "QQdfffffffff", *before[1:13])
        self.put(0x100C519A4, "B", before[13])
        self.put(0x100C519A8, "d", before[14])
        self.put(SCRATCH + 8, "Qffffff", case["key"], 110, 240, 360, 15, 30, 45)
        self.put(SCRATCH + 0x30, "Q", case["generation"])
        self.uc.reg_write(ar.UC_ARM64_REG_X0, SCRATCH)
        self.uc.reg_write(ar.UC_ARM64_REG_D0, struct.unpack("<Q", struct.pack("<d", case["now"]))[0])
        self.bounded(0x1000C494C, RETURN)
        return {"after": list(self.get(0x100C51960, "B")) + list(self.get(0x100C51968, "QQdfffffffff")) +
                         list(self.get(0x100C519A4, "B")) + list(self.get(0x100C519A8, "d"))}


def differential(core, planner):
    assert planner["scope"] == "original selector and state edges only; no target action authority"
    groups = ("actor_gate", "point", "rank", "clock", "route", "takeover", "recoil", "motion")
    for group in groups:
        for case in planner[group]:
            actual = getattr(SelectionRunner(core), group)(case)
            expected = (case["eligible"] if group == "actor_gate" else case["value"] if group == "point" else
                        {key: case[key] for key in actual})
            assert actual == expected, (group, case, actual)
    return {"scope": "synthetic selector/state differential only; no native target execution",
            "cases": {group: len(planner[group]) for group in groups},
            "checked_write_executions": 0,
            "synthetic_route_profile": {"slot65": "0x620", "slot66": "0x828"}}


def static_edges(core):
    start, end = 0x1000C1A04, 0x1000C3AA4
    instructions = core.instructions(start, end - start)
    merge_incoming = []
    indirect = []
    for instruction in instructions:
        mnemonic = instruction.mnemonic
        if mnemonic in ("br", "braa", "brab", "blr", "blraa", "blrab"):
            indirect.append(hex(instruction.address))
        if mnemonic == "b" or mnemonic.startswith("b.") or mnemonic in ("cbz", "cbnz", "tbz", "tbnz"):
            target = instruction.operands[-1].imm
            if target == 0x1000C2E24:
                merge_incoming.append({"site": hex(instruction.address), "kind": "direct-branch"})
        if instruction.address == 0x1000C2E20:
            assert mnemonic == "stp"
            merge_incoming.append({"site": hex(instruction.address), "kind": "fallthrough"})
    assert merge_incoming == [{"site": "0x1000c2e20", "kind": "fallthrough"},
                              {"site": "0x1000c3918", "kind": "direct-branch"},
                              {"site": "0x1000c3990", "kind": "direct-branch"}]
    assert not indirect
    words = np.frombuffer(core.data, dtype="<u4", count=core.text.size // 4, offset=core.text.offset)
    corpus_incoming = []
    encodings = ((0xFC000000, 0x14000000, 0, 26),
                 (0xFF000010, 0x54000000, 5, 19),
                 (0x7E000000, 0x34000000, 5, 19),
                 (0x7E000000, 0x36000000, 5, 14))
    for mask, opcode, shift, bits in encodings:
        for index in np.flatnonzero((words & mask) == opcode):
            site = core.text.virtual_address + int(index) * 4
            immediate = (int(words[index]) >> shift) & ((1 << bits) - 1)
            if immediate & (1 << (bits - 1)): immediate -= 1 << bits
            if site + immediate * 4 == 0x1000C2E24:
                corpus_incoming.append(hex(site))
    assert sorted(corpus_incoming) == ["0x1000c3918", "0x1000c3990"]
    anchors = [(0x1000DD46C, 112), (0x1000DD4DC, 196), (0x1000DD5B8, 268),
               (0x1000DB4D0, 96), (0x1000DE5D0, 224), (0x1000DE788, 100),
               (0x1000C182C, 248), (0x1000C5014, 208), (0x1000C518C, 8),
               (0x1000C2E14, 20), (0x1000C2EF4, 48), (0x1000C3914, 8),
               (0x1000C3988, 12), (0x1000C3854, 320), (0x1000C3994, 124),
               (0x1000C494C, 424), (0x1000C1D14, 384), (0x1000C1A58, 24),
               (0x1000C571C, 384), (0x1000C589C, 384), (0x1000C5A1C, 188),
               (0x1000C65A0, 400), (0x1000C2C80, 96), (0x1000C4554, 352)]
    return {"worker_range": {"start": hex(start), "end": hex(end),
                              "basis": "authenticated-prologue to next authenticated-prologue; no LC_FUNCTION_STARTS"},
            "merge_incoming_edges": merge_incoming, "indirect_branch_sites": indirect,
            "whole_text_direct_branch_to_merge": sorted(corpus_incoming),
            "reference_windows": [core.proof_window(address, size) for address, size in anchors],
            "publisher_direct_call_sites": [hex(site) for site in core.callers[0x1000C182C]],
            "closed_edges": {
                "raw_actor_gate": "dd46c..dd4d8 exact Core-local state/bot/flag/distance predicate; target flag14 owner still unresolved",
                "world_point": "dd4dc..dd59c exact local anchor interpolation/root fallback; branch reachability/target bone producer still unresolved",
                "screen_rank": "dd5b8..dd6c0 screen interior, ordinary <=radius/strict score improvement, independent sticky <=1.15*radius",
                "candidate_publish": "de694..de730 → c182c under mutex; valid publish increments BSS serial generation, null clears record",
                "geometry_clock": "c5014..c50e0 same key/clock monotonic delta; first/change/nonincrease/>50ms resets local residual without target restore",
                "candidate_motion": "full c494c finite-input publication key/generation motion state: target-minus-camera difference/dt, unchanged-generation no new sample, velocity expires after0.3s",
                "takeover": "c3018/c38c8..c3990 zero/cache/inactive/tiny input bypass, threshold-confirmation counter/pause deadline, per-axis Aim suppression",
                "merge_slot": "all three direct incoming edges resolve w19=0→slot65/+620, w19=1→slot66/+828; upstream branch authority still unresolved",
                "recoil_raw_state": "full c571c valid-input state/output, nonfire pause/resume/key-binding reset/3-frame positive gate/FMADD and multiplication order; caller old-sample lifetime still unresolved",
                "stop_local_only": "c1d14..c1f38 invalid main/scene gates clear Core-local candidate/history/deadline state; no target-memory restoration inferred"},
            "remaining_edges": ["actual bone-valid + anchor producers and build15915 flag14 owner/knocked semantics",
                                "all upstream route predicates/feedback → trusted live current candidate/controller authority",
                                "c4af8 prediction/curve/residual compensation + ballistic c642c",
                                "c571c caller binding/prior-aim source + c416c horizontal/post-state + c2d34/c3188 numeric merge",
                                "Aim/Recoil shared write ranges concurrency and target-game thread ownership",
                                "disable/target-loss/scene-change → target effects independently restored, not merely local state cleared"],
            "offline_parity_case_counts": {"actor_gate": 64, "point": 6, "rank": 8, "clock": 8,
                                           "route": 6, "takeover": 16, "recoil": 40, "motion": 8},
            "synthetic_math_substitutions": ["remainderf via rounded f32 Python math.remainder; no native import execution"],
            "write_ready": False, "original_device_effect_verified": False}
