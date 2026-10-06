"""E42 negative controls: local preview never promotes target time or Aim writes."""

import copy
from pathlib import Path
import runpy
from core_set_basic_aim_boundary import BASIC_FIELDS, PROFILE_GUARD, assert_basic_aim_boundary


ROOT = Path(__file__).resolve().parents[1]
AUDIT = runpy.run_path(str(ROOT / "tools/core_set_e42_visual_grenade_boundary.py"))
PATHS = (
    ROOT / "lara/views/app/CoreSetAimPreviewConsumer.swift",
    ROOT / "lara/views/app/CoreSetAimDisplayConsumer.swift",
    ROOT / "lara/views/app/CoreSetAimConsumer.swift",
    ROOT / "lara/views/app/CoreSetRecoilConsumer.swift",
    ROOT / "lara/overlay/CoreSetPlayerSnapshot.h",
)


def gate(evidence: dict, source: list[str]) -> None:
    sites = evidence["sites"]
    assert len(sites) == 28
    assert sites[0x1000DE810] == ("bl", "#0x100123d2c")
    assert "[x8, #0x10]" in sites[0x100123D34][1]
    assert "[x8, #0x3b8]" in sites[0x1000DE820][1]
    assert "[x8, #0x3c0]" in sites[0x1000DE88C][1]
    assert sites[0x1000DE9F4] == ("cmp", "w24, #4")
    assert sites[0x1000DEB3C] == ("cmp", "w23, #4")
    assert "[x27, #0x1c4]" in sites[0x1000DEBE8][1]
    assert "[x27, #0x16b]" in sites[0x1000DEC30][1]
    assert "x8, x28" in sites[0x1000DECCC][1]
    assert sites[0x1000DE840] == ("mov", "w20, #0")
    assert abs(evidence["floats"][0x100AC8338] + 1.8) < 0.00001
    assert abs(evidence["floats"][0x100AC833C] + 3.6) < 0.00001
    assert evidence["retention_scalar"] == 0.075
    assert evidence["target_properties"] == {
        "SpawnTime": ("SpawnTime", 0x888),
        "ExplosionTime": ("ExplosionTime", 0x88C),
        "Children": ("Children", 0x250),
    }
    assert evidence["grenade_timer_ready"] is False
    assert evidence["grenade_radius_ready"] is False
    assert evidence["core_visual_parity_ready"] is False
    preview, display, aim, recoil, grenade = source
    for token in (
        "session.ready && session.capabilities == 1",
        "snapshot.sessionGeneration == generation",
        "snapshot.processID == pid, snapshot.imageBase == base",
        "mark.distanceUnitsDividedBy100.isFinite",
        "score.isFinite, score <= radius * radius",
        "CACurrentMediaTime() - frame.captureCompletedMonotonicSeconds <= 0.5",
        "self.session.generation == generation",
        "let cleanup = worker.sync { session.disconnect() }",
    ):
        assert token in preview, token
    for token in (
        "if targetRequired && frame?.target == nil {",
        "return [] // No candidate: clear this lane.",
        "expectedReadIdentity = frame.map",
        "identityValid, freshnessValid",
        "receipt.snapshotID == expectedSnapshot",
        "receipt.hostGeneration == expectedGeneration",
        "clearLane(.aimDisplay",
        "preview.shutdown()",
    ):
        assert token in display, token
    assert display.count("clearLane(.aimDisplay") == 2
    for token in (
        "let decay = exp(-1.8 * elapsed)",
        "let oscillation = exp(-3.6 * elapsed) * cos(12 * elapsed)",
        "for index in 0..<4",
        "segments: 16, color: primary, width: 5.2",
        "segments: 16, color: secondary, width: 2.4",
        "let pulsing = ring * CGFloat(0.54 + 0.24 * oscillation)",
        "let innerRadius = min(ring * 0.8, max(ring * 0.43, pulsing))",
        "let pointerLength = min(16, max(8, ring * 0.055))",
        "let halfSpan = CGFloat(0.16 + 0.04 * decay)",
        "segments: 10, color: directionColor, width: 4.2",
        "dynamicCandidateKey != target.actorAddress",
        "return min(elapsed, 10)",
    ):
        assert token in display, token
    assert ".applied(observed: pending.1)" in display
    assert_basic_aim_boundary(aim)
    assert "var supportedFields: Set<CoreSetField> { [] }" in recoil
    grenade_mark = grenade.split("@interface CoreSetGrenadeMark : NSObject", 1)[1].split("@end", 1)[0]
    assert "distanceUnitsDividedBy100" in grenade_mark
    assert "remainingSeconds" not in grenade_mark and "blastRadius" not in grenade_mark


def main() -> None:
    evidence = AUDIT["analyze"]()
    source = [path.read_text(encoding="utf-8") for path in PATHS]
    gate(evidence, source)
    mutations = (
        ("evidence", "target_properties", "SpawnTime", ("SpawnTime", 0x258)),
        ("evidence", "target_properties", "Children", ("Children", 0x258)),
        ("evidence", "grenade_timer_ready", None, True),
        ("evidence", "grenade_radius_ready", None, True),
        ("evidence", "core_visual_parity_ready", None, True),
        ("evidence", "sites", 0x1000DE9F4, ("cmp", "w24, #3")),
        ("evidence", "sites", 0x1000DEBE8, ("ldrb", "[x27, #0x16b]")),
        ("evidence", "retention_scalar", None, 0.75),
        ("source", 0, "mark.distanceUnitsDividedBy100.isFinite", "true"),
        ("source", 0, "snapshot.sessionGeneration == generation", "true"),
        ("source", 0, "self.session.generation == generation", "true"),
        ("source", 1, "identityValid, freshnessValid", "identityValid"),
        ("source", 1, "receipt.snapshotID == expectedSnapshot", "true"),
        ("source", 1, "receipt.hostGeneration == expectedGeneration", "true"),
        ("source", 1, "clearLane(.aimDisplay", "clearLane(.player"),
        ("source", 1, "preview.shutdown()", "true"),
        ("source", 1, "dynamicCandidateKey != target.actorAddress", "false"),
        ("source", 1, "let decay = exp(-1.8 * elapsed)", "let decay = 1.0"),
        ("source", 1, "segments: 16, color: primary, width: 5.2",
         "segments: 8, color: primary, width: 5.2"),
        ("source", 2, BASIC_FIELDS, "[.localAimDynamicCircle]"),
        ("source", 2, PROFILE_GUARD, "guard true else"),
        ("source", 4, "distanceUnitsDividedBy100", "remainingSeconds"),
    )
    for mutation in mutations:
        changed = copy.deepcopy(evidence)
        altered = source.copy()
        kind, key, old, new = mutation
        if kind == "evidence":
            if old is None:
                changed[key] = new
            else:
                changed[key][old] = new
        else:
            assert old in altered[key]
            if key == 4:
                before, mark = altered[key].split("@interface CoreSetGrenadeMark : NSObject", 1)
                assert old in mark
                altered[key] = before + "@interface CoreSetGrenadeMark : NSObject" + mark.replace(old, new, 1)
            else:
                altered[key] = altered[key].replace(old, new, 1)
        try:
            gate(changed, altered)
        except AssertionError:
            continue
        raise AssertionError(f"unsafe E42 mutation passed: {mutation}")
    print(f"PASS: E42 visual/grenade boundary and {len(mutations)} negatives")


if __name__ == "__main__":
    main()
