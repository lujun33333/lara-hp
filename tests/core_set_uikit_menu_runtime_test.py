from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
menu = (ROOT / "lara/views/app/CoreSetMenuViewController.swift").read_text(encoding="utf-8")
coordinator = (ROOT / "lara/views/app/CoreSetRuntimeCoordinator.swift").read_text(encoding="utf-8")
host = (ROOT / "lara/overlay/CoreSetHUDHost.mm").read_text(encoding="utf-8")
render = (ROOT / "lara/overlay/CoreSetRenderCommands.mm").read_text(encoding="utf-8")

# The complete UIKit menu is the only production menu controller.
for token in (
    "private let menu = CoreSetMenuViewController()",
    "host.contentOwnsLayout = true",
    "menu?.localHostHitRegions ?? []",
    "menu runtime backend=UIKit-CoreAnimation",
    "menuController: self.menu",
    "menuController: menu)",
):
    assert token in coordinator, token
for removed in ("menuSurface", "menu.enableImGuiRuntime()"):
    assert removed not in coordinator, removed

# UIKit owns actual controls, hit testing, sliders, scrolling, and the complete
# Core v1.7 pages that were missing from the reduced ImGui model.
for token in (
    "final class CoreSetMenuViewController: UIViewController",
    "var localHostHitRegions: [UIView]",
    "func hostedControlID(at point: CGPoint)",
    "func handleHostedControl(",
    "private func backStylePreview",
    "for index in 0..<6",
    "private func showHostedColorEditor",
    "pageProgress",
    "firmwareProgress",
    'private let pageTitles = ["主页", "玩家", "物资", "调整", "雷达", "自瞄", "压枪"]',
):
    assert token in menu, token
for token in (
    "import QuartzCore",
    "applyHostedContentScale(displayScale, to: view)",
    "root.contentScaleFactor = scale",
    "root.layer.contentsScale = scale",
    "root.layer.sublayers?.forEach { $0.contentsScale = scale }",
    "private func commitHostedMenuUpdate()",
    "CATransaction.flush()",
    "menu presentation stage=uikit-ca committed=1",
):
    assert token in menu, token

# SpringBoard hosting remains a passive CALayerHost surface. One HID owner
# resolves a UIKit control on begin and dispatches its lifecycle on main.
for token in (
    "hostedControlIDAtSurfacePoint",
    "handleHostedPointer:",
    'source=HID control=%@',
    "dispatchHostedMenuControl",
    "consumer.hostedMenuRevision",
    "hostedControlAllowsDrag",
):
    assert token in host, token

# Hosted drawing remains retained CoreAnimation; the source app does not need
# a background Metal command buffer to update player frames.
for token in (
    "CoreSetCoreAnimationConsumer *_layers",
    "[_layers setVisible:_activeBackend == CoreSetHUDBackendCoreAnimation]",
    "[CATransaction flush]",
    "CoreSetHostedDrawContent",
):
    assert token in host + render, token

print("PASS: production uses complete Retina UIKit/CA menu, CALayerHost/HID input, and retained CA drawing")
