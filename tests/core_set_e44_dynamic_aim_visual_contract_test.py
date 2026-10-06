"""Local dynamic Aim decoration mirrors the evidenced Core geometry only."""

from pathlib import Path
from core_set_basic_aim_boundary import BASIC_FIELDS, PROFILE_GUARD, assert_basic_aim_boundary


ROOT = Path(__file__).resolve().parents[1]
DISPLAY = ROOT / "lara/views/app/CoreSetAimDisplayConsumer.swift"
ACTION = ROOT / "lara/views/app/CoreSetAimConsumer.swift"
RECOIL = ROOT / "lara/views/app/CoreSetRecoilConsumer.swift"


def gate(display: str, action: str, recoil: str) -> None:
    for token in (
        "private var dynamicCandidateKey: UInt64?",
        "private var dynamicReadIdentity: (generation: UInt64, pid: Int32, base: UInt64)?",
        "private var dynamicStartedAt: CFTimeInterval?",
        "$0.generation != frame.sessionGeneration",
        "$0.pid != frame.processID || $0.base != frame.imageBase",
        "if identityChanged || dynamicCandidateKey != target.actorAddress",
        "dynamicCandidateKey != target.actorAddress",
        "return min(elapsed, 10)",
        "let decay = exp(-1.8 * elapsed)",
        "let oscillation = exp(-3.6 * elapsed) * cos(12 * elapsed)",
        "let primaryAlpha = CGFloat(Int(32 + 38 * decay)) / 255",
        "let secondaryAlpha = CGFloat(Int(175 + 60 * decay)) / 255",
        "alpha: CGFloat(Int(195 + 60 * decay)) / 255",
        "for index in 0..<4",
        "let start = CGFloat(index) * quarter + 0.13",
        "let end = CGFloat(index + 1) * quarter - 0.13",
        "segments: 16, color: primary, width: 5.2",
        "segments: 16, color: secondary, width: 2.4",
        "let pulsing = ring * CGFloat(0.54 + 0.24 * oscillation)",
        "let innerRadius = min(ring * 0.8, max(ring * 0.43, pulsing))",
        "let pointerLength = min(16, max(8, ring * 0.055))",
        "let angle = -CGFloat.pi / 2 + CGFloat(index) * quarter",
        "let halfSpan = CGFloat(0.16 + 0.04 * decay)",
        "segments: 10, color: directionColor, width: 4.2",
        "resetDynamicAnimation()",
        "lane: .aimDisplay",
        "receipt.snapshotID == expectedSnapshot",
        "receipt.hostGeneration == expectedGeneration",
        "if !receipt.acceptedByLocalRenderer, activeToken == receipt.requestToken {",
        "clearStale(token: receipt.requestToken, canvas: canvas,",
    ):
        assert token in display, token
    assert display.count("clearLane(.aimDisplay") == 2
    assert "CoreSetTargetWriteSession" not in display
    assert "RemoteCall" not in display
    assert_basic_aim_boundary(action)
    assert "var supportedFields: Set<CoreSetField> { [] }" in recoil


def main() -> None:
    values = [path.read_text(encoding="utf-8") for path in (DISPLAY, ACTION, RECOIL)]
    gate(*values)
    mutations = (
        (0, "if identityChanged || dynamicCandidateKey != target.actorAddress",
         "if dynamicCandidateKey != target.actorAddress"),
        (0, "$0.generation != frame.sessionGeneration", "false"),
        (0, "return min(elapsed, 10)", "return elapsed"),
        (0, "exp(-1.8 * elapsed)", "exp(-0.18 * elapsed)"),
        (0, "exp(-3.6 * elapsed) * cos(12 * elapsed)", "cos(elapsed)"),
        (0, "CGFloat(Int(32 + 38 * decay))", "CGFloat(32 + 38 * decay)"),
        (0, "CGFloat(Int(32 + 38 * decay))",
         "CGFloat(Int(32 + 38 * decay + oscillation))"),
        (0, "CGFloat(0.16 + 0.04 * decay)", "CGFloat(0.16 + 0.039 * decay)"),
        (0, "segments: 16, color: primary, width: 5.2",
         "segments: 8, color: primary, width: 5.2"),
        (0, "let pointerLength = min(16, max(8, ring * 0.055))",
         "let pointerLength = ring"),
        (0, "lane: .aimDisplay", "lane: .player"),
        (0, "if !receipt.acceptedByLocalRenderer, activeToken == receipt.requestToken {",
         "if false {"),
        (1, BASIC_FIELDS, "[.localAimDynamicCircle]"),
        (1, PROFILE_GUARD, "guard true else"),
        (2, "var supportedFields: Set<CoreSetField> { [] }",
         "var supportedFields: Set<CoreSetField> { [.localAimDynamicCircle] }"),
    )
    for index, old, new in mutations:
        altered = values.copy()
        assert old in altered[index], old
        altered[index] = altered[index].replace(old, new, 1)
        try:
            gate(*altered)
        except AssertionError:
            continue
        raise AssertionError(f"unsafe E44 dynamic visual mutation passed: {old}")
    print(f"PASS: E44 local dynamic Aim geometry and {len(mutations)} negatives")


if __name__ == "__main__":
    main()
