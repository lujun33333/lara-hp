"""Read-only Aim preview selection and local-only decoration gates."""

from pathlib import Path
import json
from core_set_basic_aim_boundary import BASIC_FIELDS, PROFILE_GUARD, assert_basic_aim_boundary

ROOT = Path(__file__).resolve().parents[1]
PATHS = (
    ROOT / "lara/views/app/CoreSetAimPreviewConsumer.swift",
    ROOT / "lara/views/app/CoreSetAimDisplayConsumer.swift",
    ROOT / "lara/views/app/CoreSetFeatureState.swift",
    ROOT / "lara/views/app/CoreSetMenuViewController.swift",
    ROOT / "lara/views/app/CoreSetRuntimeCoordinator.swift",
    ROOT / "lara/views/app/CoreSetAimConsumer.swift",
)


def gate(values: list[str]) -> None:
    preview, display, state, menu, coordinator, action = values
    for token in (
        "private let session = CoreSetReadSession()",
        "session.ready && session.capabilities == 1",
        "playerBones: true, botBones: true",
        "includeOffscreen: false, includeRadar: false, includeBattleInputs: false",
        "includeWarningYaw: false, maximumDrawDistance: Double(maximumDistance)",
        "snapshot.sessionGeneration == generation",
        "snapshot.processID == pid, snapshot.imageBase == base",
        "CACurrentMediaTime() - snapshot.captureCompletedMonotonicSeconds <= 0.5",
        "guard mark.onScreen, includeBots || !mark.bot",
        "mark.distanceUnitsDividedBy100 <= Double(maximumDistance)",
        "if let bone = mark.boneSegments.first?.start",
        "else { point = mark.center }",
        "score.isFinite, score <= radius * radius",
        "score == existing.score && target.actorAddress < existing.target.actorAddress",
        "CACurrentMediaTime() - frame.captureCompletedMonotonicSeconds <= 0.5",
        "target: best?.target",
        "self.session.generation == generation",
        "let cleanup = worker.sync { session.disconnect() }",
    ):
        assert token in preview, token
    assert "CoreSetTargetWriteSession" not in preview and "RemoteCall" not in preview
    assert "if preview.ready {" in display
    for field in (".localAimPreviewLine", ".localAimPreviewMarker",
                  ".localAimDynamicCircle", ".localAimPreviewBots", ".localAimPreviewDistance"):
        assert field in display and field in state
    assert "if targetRequired && frame?.target == nil {" in display
    assert "resetDynamicAnimation()" in display
    assert "return [] // No candidate: clear this lane." in display
    assert "frame?.snapshotID ?? UUID()" in display
    assert "expectedReadIdentity = frame.map" in display
    assert "expectedCapturedAt = frame?.captureCompletedMonotonicSeconds" in display
    assert "identityValid, freshnessValid" in display
    assert "preview.matchesIdentity($0)" in display
    assert "preview.capture(canvas: canvas.size, radius: ring" in display
    assert "if self.pendingApply != nil { self.capture() }" in display
    assert "refresh = Timer.scheduledTimer(withTimeInterval: 0.15" in display
    assert "clearLane(.aimDisplay" in display
    assert "preview.shutdown()" in display
    assert "request.desired.dynamicCircle == true && request.desired.circleVisible != true" in display
    assert "case .localAimDisplay: return [.localAimCircle, .localAimCircleSize," in state
    assert "capability == .localAimDisplay) &&" in state
    for control in ("changeLocalAimPreviewDistance", "toggleLocalAimPreviewField",
                    "controlAvailability(field, in: featureState.aimDisplay)"):
        assert control in menu
    assert menu.count("controlAvailability(.localAimPreviewDistance, in: featureState.aimDisplay)") == 2
    assert "let previewReadClean = self.aimDisplayConsumer?.shutdownPreview() ?? true" in coordinator
    assert_basic_aim_boundary(action)
    inventory = json.loads((ROOT / "artifacts/core-set-v1.7/ui-point-inventory.json").read_text(encoding="utf-8"))
    contract = inventory["e_field_contract"]["localAimDisplay"]
    assert contract["required_count"] == contract["conditional_source_supported_count"] == 7
    assert contract["aimControl_ready"] is False
    for point in inventory["points"]:
        if point["title"] in ("自瞄连接线", "预瞄标记圈", "动态自瞄圈", "瞄准人机") or (
            point["card"] == "目标筛选" and point["title"] == "最大距离"
        ):
            assert point["capability"] == "localAimDisplay"
            assert point["source_supported_if_identity_ready"] is True
            assert "no aimControl action" in point["field_availability"]


def main() -> None:
    sources = [p.read_text(encoding="utf-8") for p in PATHS]
    gate(sources)
    mutations = (
        (0, "session.ready && session.capabilities == 1", "true"),
        (0, "snapshot.sessionGeneration == generation", "true"),
        (0, "mark.distanceUnitsDividedBy100 <= Double(maximumDistance)", "true"),
        (0, "score.isFinite, score <= radius * radius", "score.isFinite"),
        (0, "else { point = mark.center }", "else { point = .zero }"),
        (1, "if preview.ready {", "if true {"),
        (1, "if targetRequired && frame?.target == nil {", "if false {"),
        (1, "preview.matchesIdentity($0)", "true"),
        (1, "if self.pendingApply != nil { self.capture() }", "return"),
        (1, "identityValid, freshnessValid", "identityValid"),
        (3, "controlAvailability(.localAimPreviewDistance, in: featureState.aimDisplay)", "true"),
        (5, BASIC_FIELDS, "[.localAimPreviewLine]"),
        (5, PROFILE_GUARD, "guard true else"),
    )
    for index, old, new in mutations:
        altered = sources.copy()
        assert old in altered[index], old
        altered[index] = altered[index].replace(old, new, 1)
        try:
            gate(altered)
        except AssertionError:
            continue
        raise AssertionError(f"unsafe AimPreview mutation passed: {old}")
    print(f"PASS: E25 read-only preview target and local decorations; {len(mutations)} negatives")


if __name__ == "__main__":
    main()
