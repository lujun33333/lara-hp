"""Local aim-circle preview must never become an aim action receipt."""

from pathlib import Path
import json
from core_set_basic_aim_boundary import BASIC_FIELDS, PROFILE_GUARD, assert_basic_aim_boundary

ROOT = Path(__file__).resolve().parents[1]
PATHS = (
    ROOT / "lara/views/app/CoreSetFeatureState.swift",
    ROOT / "lara/views/app/CoreSetAimDisplayConsumer.swift",
    ROOT / "lara/views/app/CoreSetAimConsumer.swift",
    ROOT / "lara/views/app/CoreSetRuntimeCoordinator.swift",
    ROOT / "lara/views/app/CoreSetMenuViewController.swift",
)


def gate(sources: list[str]) -> None:
    state, display, action, coordinator, menu = sources
    assert "case aimControl, recoilControl, localAimDisplay" in state
    assert "case .localAimDisplay: return [.localAimCircle, .localAimCircleSize," in state
    assert "var aimDisplay = CoreSetFeatureChannel(capability: .localAimDisplay" in state
    assert "var circleSize = CoreSetIntSetting(30...525)" in state
    assert "guard capability == .localAimDisplay, pendingStop == nil else { return }" in state
    assert "generation = UUID(); pendingApply = nil; actual = nil; phase = .unknown" in state
    assert "let capability = CoreSetCapability.localAimDisplay" in display
    assert "coordinator?.playerCanvas != nil ? .ready" in display
    assert "let raw = short * CGFloat(size) / 1170" in display
    assert "let value = raw < 30 ? CGFloat(30) : min(raw, upper)" in display
    assert "result.append(CoreSetRenderCommand(kind: .ellipse" in display
    assert "CoreSetTargetWriteSession" not in display and "RemoteCall" not in display
    assert "lane: .aimDisplay" in display and display.count("clearLane(.aimDisplay") == 2
    for receipt in ("receipt.configRevision == revision", "receipt.snapshotID == expectedSnapshot",
                    "receipt.hostGeneration == expectedGeneration", "receipt.requestToken",
                    "receipt.acceptedByLocalRenderer"):
        assert receipt in display
    assert "let capability = CoreSetCapability.aimControl" in action
    assert_basic_aim_boundary(action)
    assert "case player, materials, radar, warning, appearance, aimDisplay" in coordinator
    assert "menu.bindGameConsumer(aimDisplayConsumer, to: \\.aimDisplay)" in coordinator
    assert "self.aimDisplayConsumer?.consumed(receipt)" in coordinator
    assert coordinator.count("menu.invalidateLocalAimDisplayAfterHostReset()") == 2
    assert "stop(\\.radar); stop(\\.aim); stop(\\.aimDisplay); stop(\\.recoil)" in menu
    assert 'button.accessibilityLabel = "显示自瞄圈（仅本地预览）"' in menu
    assert 'button.accessibilityValue = observed ? "本地已显示"' in menu
    assert "controlAvailability(.localAimCircle, in: featureState.aimDisplay) == .ready" in menu
    assert "controlAvailability(.localAimCircleSize, in: featureState.aimDisplay) == .ready" in menu
    assert "editGame(\\.aimDisplay) { $0.circleVisible = !current }" in menu
    assert "editGame(\\.aimDisplay) { $0.circleSize.set(value) }" in menu
    inventory = json.loads((ROOT / "artifacts/core-set-v1.7/ui-point-inventory.json").read_text(encoding="utf-8"))
    for point in inventory["points"]:
        if point["title"] in ("显示自瞄圈", "自瞄圈大小"):
            assert point["capability"] == "localAimDisplay"
            assert point["source_supported_if_host_ready"] is True
            assert "no aimControl action" in point["field_availability"]
    assert inventory["e_field_contract"]["localAimDisplay"]["aimControl_ready"] is False


def main() -> None:
    sources = [p.read_text(encoding="utf-8") for p in PATHS]
    gate(sources)
    mutations = (
        (0, "case .localAimDisplay: return [.localAimCircle, .localAimCircleSize,", "case .localAimDisplay: return ["),
        (0, "guard capability == .localAimDisplay, pendingStop == nil else { return }", "guard pendingStop == nil else { return }"),
        (1, "let capability = CoreSetCapability.localAimDisplay", "let capability = CoreSetCapability.aimControl"),
        (1, "lane: .aimDisplay", "lane: .player"),
        (1, "clearLane(.aimDisplay", "clearLane(.player"),
        (1, "receipt.snapshotID == expectedSnapshot", "true"),
        (2, BASIC_FIELDS, "[.localAimCircle]"),
        (2, PROFILE_GUARD, "guard true else"),
        (3, "self.aimDisplayConsumer?.consumed(receipt)", "self.aimConsumer?.consumed(receipt)"),
        (3, "menu.invalidateLocalAimDisplayAfterHostReset()", "menu.refreshConsumerAvailability()"),
        (4, 'button.accessibilityLabel = "显示自瞄圈（仅本地预览）"', 'button.accessibilityLabel = "自瞄已生效"'),
    )
    for index, old, new in mutations:
        altered = sources.copy()
        assert old in altered[index]
        altered[index] = altered[index].replace(old, new, 1)
        try:
            gate(altered)
        except AssertionError:
            continue
        raise AssertionError(f"unsafe local-circle mutation passed: {old}")
    print(f"PASS: E24 local circle isolated from aimControl; {len(mutations)} negatives")


if __name__ == "__main__":
    main()
