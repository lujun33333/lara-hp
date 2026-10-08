"""Bounded Core-self numerical CFG parity; no native execution or writer authority."""
from __future__ import annotations

import math
import struct
from unicorn import arm64_const as ar
from core_set_action_cycle_probe import STACK, SCRATCH, RETURN
from core_set_action_selection_probe import SelectionRunner, f32


class CompensationRunner(SelectionRunner):
    def _step(self, engine, address, size, data):
        # Deterministic pure libm substitutions. These never call native imports.
        if address in (0x100725CA0, 0x100725A40, 0x1007255F0, 0x1007255E0):
            value = (math.hypot(self.rf(ar.UC_ARM64_REG_S0), self.rf(ar.UC_ARM64_REG_S1))
                     if address == 0x100725CA0 else
                     math.exp(self.rf(ar.UC_ARM64_REG_S0)) if address == 0x100725A40 else
                     math.atan(self.rf(ar.UC_ARM64_REG_S0)) if address == 0x1007255F0 else
                     math.atan2(self.rf(ar.UC_ARM64_REG_S0), self.rf(ar.UC_ARM64_REG_S1)))
            self.sf(ar.UC_ARM64_REG_S0, value)
            engine.reg_write(ar.UC_ARM64_REG_PC, engine.reg_read(ar.UC_ARM64_REG_X30)); return
        super()._step(engine, address, size, data)

    def prediction(self, case):
        self.sf(ar.UC_ARM64_REG_S0, case["distance"])
        self.bounded(0x1000C6304, RETURN)
        return {"gain": self.rf(ar.UC_ARM64_REG_S0)}

    def angular(self, case):
        self.uc.reg_write(ar.UC_ARM64_REG_X0, SCRATCH)
        self.uc.reg_write(ar.UC_ARM64_REG_X1, SCRATCH + 4)
        for index, value in enumerate(case["position"] + case["velocity"]):
            self.sf(getattr(ar, f"UC_ARM64_REG_S{index}"), value)
        self.bounded(0x1000C642C, RETURN)
        return {"valid": self.uc.reg_read(ar.UC_ARM64_REG_X0), "value": list(self.get(SCRATCH, "ff"))}

    def residual(self, case):
        self.uc.reg_write(ar.UC_ARM64_REG_X21, SCRATCH)
        self.uc.reg_write(ar.UC_ARM64_REG_X19, SCRATCH + 0x1000)
        self.uc.reg_write(ar.UC_ARM64_REG_X20, SCRATCH + 0x2000)
        self.put(SCRATCH + 0x18, "ffB", *case["before"], case["present"])
        self.put(SCRATCH + 0x200C, "ff", 360, 240)
        sp = STACK + 0x80000
        self.uc.reg_write(ar.UC_ARM64_REG_X29, sp + 0x130)
        self.put(sp + 0x60, "f", 0.01)
        self.put(sp + 0xA8, "ff", -500, 500)  # callee pitch/yaw output slots
        self.sf(ar.UC_ARM64_REG_S0, f32(1 - f32(math.exp(f32(-f32(.01) / f32(.05))))))
        self.sf(ar.UC_ARM64_REG_S12, case["error"])
        self.sf(ar.UC_ARM64_REG_S11, .1)
        self.bounded(0x1000C5134 if case["measured"] else 0x1000C51B0,
                     0x1000C5244, (0x1000C5074,))
        return {"eligible": int(self.uc.reg_read(ar.UC_ARM64_REG_PC) == 0x1000C5244),
                "afterPresent": self.get(SCRATCH + 0x20, "B")[0],
                "after": list(self.get(SCRATCH + 0x18, "ff"))}

    def compensation(self, case):
        self.uc.reg_write(ar.UC_ARM64_REG_X19, SCRATCH)
        self.uc.reg_write(ar.UC_ARM64_REG_X20, SCRATCH + 0x1000)
        self.uc.reg_write(ar.UC_ARM64_REG_X22, case["present"])
        self.put(SCRATCH + 0x1000, "fffffff", .7, .1, case["curve"], 360, 240, 0, .5)
        self.put(SCRATCH + 0x101C, "f", .1)
        sp = STACK + 0x80000
        self.put(sp + 0x60, "f", .01)
        self.put(sp + 0x70, "f", case["error"][0])
        self.put(sp + 0x20, "f", case["error"][1])
        self.sf(ar.UC_ARM64_REG_S12, abs(case["error"][0]))
        self.sf(ar.UC_ARM64_REG_S8, -.01)
        self.sf(ar.UC_ARM64_REG_S9, case["angular"][0])
        self.sf(ar.UC_ARM64_REG_S10, case["angular"][1])
        self.bounded(0x1000C5244, 0x1000C5494)
        return {"delta": list(self.get(SCRATCH + 0x18, "ff")),
                "addition": list(self.get(SCRATCH + 0x20, "ff")),
                "saturated": list(self.get(SCRATCH + 3, "BB"))}

    def write_record(self, address, record):
        self.put(address, "B7xQQB3x6f4x", *record)

    def read_record(self, address):
        return list(self.get(address, "B7xQQB3x6f4x"))

    def post(self, case):
        before = case["before"]
        self.put(SCRATCH, "B", before[0])
        self.put(SCRATCH + 8, "QQIII", *before[1:6])
        self.write_record(SCRATCH + 0x28, before[6])
        self.write_record(SCRATCH + 0x1000, case["current"])
        self.put(SCRATCH + 0x2000, "fffffIB3xffff", .7, .35, .05, 1.3, .8, 6,
                 case["tail"], case["secondStrength"], 1, .4, .8)
        for register, value in ((ar.UC_ARM64_REG_X0, SCRATCH), (ar.UC_ARM64_REG_X1, SCRATCH + 0x1000),
                                (ar.UC_ARM64_REG_X2, SCRATCH + 0x2000), (ar.UC_ARM64_REG_X3, case["binding"]),
                                (ar.UC_ARM64_REG_X8, SCRATCH + 0x3000)):
            self.uc.reg_write(register, value)
        self.bounded(0x1000C416C, RETURN)
        status, reset, _pad, code, *values = self.get(SCRATCH + 0x3000, "HBBIffffff")
        return {"valid": int(status != 0), "after": list(self.get(SCRATCH, "B")) +
                list(self.get(SCRATCH + 8, "QQIII")) + [self.read_record(SCRATCH + 0x28)],
                "status": status, "reset": reset, "phaseCode": code, "value": values}

    def caller_merge(self, case):
        self.sf(ar.UC_ARM64_REG_S11, case["caller"])
        self.sf(ar.UC_ARM64_REG_S0, case["raw"])
        self.sf(ar.UC_ARM64_REG_S3, .7)
        self.sf(ar.UC_ARM64_REG_S14, 0)
        self.bounded(0x1000C2D34, 0x1000C2DB0)
        return {"result": self.rf(ar.UC_ARM64_REG_S15)}

    def geometry(self, case):
        before = case["before"]
        self.put(SCRATCH, "B7xQQffB", before[0], before[1], before[2], before[4], before[5], before[3])
        self.put(SCRATCH + 0x2000, "ffffffffff", .7, .1, .8, 360, 240, case["prediction"], .5, .1, .25, .1)
        self.put(STACK + 0x80000, "fff", case["velocity"][2], 0, 0)
        for register, value in ((ar.UC_ARM64_REG_X0, SCRATCH), (ar.UC_ARM64_REG_X1, 11),
                                (ar.UC_ARM64_REG_X2, case["velocityPresent"]), (ar.UC_ARM64_REG_X3, SCRATCH + 0x2000),
                                (ar.UC_ARM64_REG_X4, case["now"]), (ar.UC_ARM64_REG_X8, SCRATCH + 0x1000)):
            self.uc.reg_write(register, value)
        for index, value in enumerate([0, 0, 0] + case["target"] + case["velocity"][:2]):
            self.sf(getattr(ar, f"UC_ARM64_REG_S{index}"), value)
        self.bounded(0x1000C4AF8, RETURN)
        local = self.get(SCRATCH, "B7xQQffB")
        return {"after": [local[0], local[1], local[2], local[5], local[3], local[4]],
                "flags": list(self.get(SCRATCH + 0x1000, "BBBBB")) + [self.get(SCRATCH + 0x1034, "B")[0]],
                "value": list(self.get(SCRATCH + 0x1008, "11f")) + list(self.get(SCRATCH + 0x1038, "9f"))}

    def feedback(self, case):
        self.put(0x100C51AD4, "f", .9)
        self.put(STACK + 0x80000 + 0x64, "B", case["receipt"])
        for register, value in ((ar.UC_ARM64_REG_X19, case["input"]), (ar.UC_ARM64_REG_X22, 1 - case["recoil"]),
                                (ar.UC_ARM64_REG_X20, case["aim"])):
            self.uc.reg_write(register, value)
        self.sf(ar.UC_ARM64_REG_S13, .3)
        self.sf(ar.UC_ARM64_REG_S15, -.3 if case["zero"] else .1)
        self.sf(ar.UC_ARM64_REG_S14, 0); self.sf(ar.UC_ARM64_REG_S12, 0)
        self.bounded(0x1000C2E24 if case["zero"] else 0x1000C3098,
                     0x1000C30D4, (0x1000C2170, 0x1000C3148))
        return {"value": self.get(0x100C51AD4, "f")[0]}


def differential(core, model):
    assert model["scope"] == "Core-self compensation CFG only; no target authority"
    groups = ("prediction", "angular", "residual", "compensation", "post", "caller_merge", "geometry", "feedback")
    for group in groups:
        for case in model[group]:
            actual = getattr(CompensationRunner(core), group)(case)
            assert actual == {key: case[key] for key in actual}, (group, case, actual)
    return {"case_counts": {group: len(model[group]) for group in groups},
            "checked_write_executions": 0, "write_ready": False,
            "scope": "bounded synthetic finite-input Core-self parity, not target action",
            "libm_substitutions": ["f32 Python hypot/exp/atan/atan2/remainder; no native imported calls"]}


def static_edges(core):
    anchors = [(0x1000C6304, 296), (0x1000C642C, 372), (0x1000C5134, 276),
               (0x1000C5244, 652), (0x1000C416C, 1000), (0x1000C5D7C, 452),
               (0x1000C2D34, 124), (0x1000C2A00, 196), (0x1000C2C80, 192),
               (0x1000C3278, 112), (0x1000C32E0, 36), (0x1000C2E24, 312),
               (0x1000C3168, 96), (0x1000C2438, 112), (0x1000C4AF8, 0x9D4),
               (0x1000C3098, 120),
               (0x1000C1A78, 276), (0x1000C1C50, 88), (0x1000C1D14, 552)]
    calls = {hex(function): [hex(site) for site in core.callers.get(function, [])]
             for function in (0x1000C4AF8, 0x1000C416C, 0x1000C571C, 0x1000C5AD8, 0x1000C642C, 0x1000C6304)}
    assert calls["0x1000c4af8"] == ["0x1000c2a84"]
    assert calls["0x1000c416c"] == ["0x1000c32e0"]
    assert calls["0x1000c571c"] == ["0x1000c2cd8"]
    assert calls["0x1000c5ad8"] == ["0x1000c2f4c"]
    # CoreImage's proof window is deliberately <=512 bytes. Large local
    # numerical functions are represented by contiguous bounded chunks.
    windows = [(address + offset, min(0x200, size - offset))
               for address, size in anchors for offset in range(0, size, 0x200)]
    return {"reference_windows": [core.proof_window(address, size) for address, size in windows],
            "constant_words": [{"address": hex(address), "bytes": core.raw(address, size).hex()}
                               for address, size in ((0x1008A9A34, 100), (0x1008A3730, 4), (0x1008A9970, 16))],
            "direct_call_sites": calls,
            "closed_edges": {
                "prediction_distance_gain": "full c6304 two smoothstep segments: <=12=.3, 12..30=.3+.42*s, 30..45=.72+.28*s, >=45=1",
                "angular_motion_projection": "full c642c displacement/relative velocity -> two angular derivatives; no projectile/gravity operand",
                "residual_filter": "c5134..c5244 finite state: clamp input, 50ms exponential interpolation/decay, <=.05 local expiration, error/deadzone eligibility",
                "compensation_curve": "c5244..c5490 finite error/dt/residual inputs: smoothstep error/selector gain, exponential easing, same-sign bounded residual and per-axis speed clamp",
                "post_state_two_axis": "full c416c finite-input record/key/owner-pointer/binding context, active derivative, bounded quiet-frame local tail and independent two-axis outputs",
                "geometry_full": "full c4af8 finite-input composition: Core-local camera/target/relative velocity, clamped half-Z prediction, wrapped angles, deadzone, history and two-axis compensation",
                "prior_aim_feedback": "c3098..c30d0 stores s13 at Core BSS c51ad4 only for slot66 path, first-axis accepted flag, current Aim active and Recoil enabled; c2cc8 consumes that prior component, not merged recoil",
                "recoil_caller_merge": "c2d34..c2dac finite s11+raw combined constrained to +/-1.5*strength",
                "single_worker_sink": "whole-text direct call scan: c4af8/c416c/c571c each has one worker call site; c5ad8 only c2f4c, which sums Aim/Recoil then emits one two-axis draft; this is not game-thread exclusion",
                "stop_post_state_local": "c3168/c2438 clear only local raw/post histories; no inverse target write or target restore receipt at these sites"},
            "remaining_edges": ["reference components are not verified current-device actions",
                                "local ownerToken/binding/prior-feedback cannot establish a live request lease",
                                "single-worker order is not mutual exclusion against another invocation or game thread",
                                "local clear/zero draft is not an independent effect/restoration receipt"],
            "case_counts": {"prediction": 10, "angular": 8, "residual": 40, "compensation": 48, "post": 80, "caller_merge": 12, "geometry": 80, "feedback": 32},
            "write_ready": False, "target_effect_restored": False,
            "boundary": "exact finite-input reference components; local clear never authorizes a target restore"}
