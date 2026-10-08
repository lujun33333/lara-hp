"""Core 1.7 floating-scene/hosting source contract; no device-effect claim."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
read = lambda name: (ROOT / name).read_text(encoding="utf-8")

manager = read("lara/overlay/CoreSetFloatingSceneManager.mm")
adapter = read("lara/overlay/CoreSetRemoteHostingAdapter.mm")
host = read("lara/overlay/CoreSetHUDHost.mm")
owner = read("lara/views/app/CoreSetRuntimeCoordinator.swift")
app = read("lara/lara.swift")
plist = read("lara/Info.plist")
metal = read("lara/overlay/CoreSetMetalRenderAdapter.mm")
imgui = read("lara/third_party/imgui/imgui.h")

for token in (
    'CSClassObject(@"FBSceneManager")',
    'CSClassObject(@"FBSMutableSceneDefinition")',
    'CSClassObject(@"FBSSceneIdentity")',
    'CSClassObject(@"FBSSceneClientIdentity")',
    'CSClassObject(@"UIApplicationSceneSpecification")',
    'CSClassObject(@"FBSMutableSceneParameters")',
    'CSClassObject(@"UIMutableApplicationSceneSettings")',
    'CSClassObject(@"UIRootWindowScenePresentationBinder")',
    '@"-touchFloating"', '@"-noTouchFloating"',
    '@"setLevel:", 1', '@"setForeground:", YES',
    '@"setInterruptionPolicy:", 1',
    '@"setDeviceOrientationEventsEnabled:", YES',
    '@"setInterfaceOrientation:", UIInterfaceOrientationPortrait',
    '@"setStatusBarStyle:", 0',
    'binderAllocation, binderInit, 0, displayConfiguration',
):
    assert token in manager, token

assert "<true/>" in plist[plist.index("UIApplicationSupportsMultipleScenes"):]
for token in (
    "CoreSetFloatingSceneManager.isFloating(identifier:",
    "configuration.delegateClass = CoreSetFloatingSceneDelegate.self",
    "CoreSetFloatingSceneManager.shared().connect(",
    "CoreSetFloatingSceneManager.shared().disconnect(scene:",
):
    assert token in app, token

for token in (
    'CSClass(_process, "SBSAccessibilityWindowHostingController")',
    'CSSel(_process, "registerWindowWithContextID:atLevel:")',
    "_primary.level = 999998.0",
    "menu.level = 1000000.0",
    "draw.level = 999999.0",
    "primaryReady && menuReady && drawReady",
):
    assert token in adapter, token
assert "CALayerHost" not in adapter

for token in (
    'UIImage imageNamed:@"CoreSetLoading"',
    "CGRectMake(0, 0, 64, 64)",
    '@"hud_button_center_x"', '@"hud_button_center_y"',
    "UITapGestureRecognizer", "UIPanGestureRecognizer",
):
    assert token in host, token

for forbidden in (
    "CoreSetLocalHostingAdapter", "prepareLocalHosting", "fallbackToSpringBoard",
    "verifyHostedWindows", "confirmHostedReadbackAsync", "armHostedInput()",
):
    assert forbidden not in owner, forbidden
for token in (
    "CoreSetFloatingSceneManager.shared().createScenes",
    "CoreSetRemoteHostingAdapter(remoteCall: process, primaryWindow: primaryWindow)",
    "host.startHosted(menuScene: touchScene, drawScene: drawScene",
    "hosting mode=core17-floating-scenes registered=1",
):
    assert token in owner, token

assert '#define IMGUI_VERSION       "1.92.8"' in imgui
for token in (
    "ImGui_ImplMetal_Init(device)", "ImGui_ImplMetal_NewFrame(pass)",
    "ImGui::NewFrame()", "ImGui::GetBackgroundDrawList()",
    "ImGui_ImplMetal_RenderDrawData", "addPresentedHandler",
):
    assert token in metal, token
for forbidden in ("CIContext", "CoreSetCoreAnimationConsumer", "renderInContext"):
    assert forbidden not in metal, forbidden

print("PASS: Core 1.7 floating scenes, three SBS contexts, UIKit floating button and ImGui/Metal are the only active host path; source only")
