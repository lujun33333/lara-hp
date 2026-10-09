"""WZ SpringBoard mirror/hosted-input source contract; no device-effect claim."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
read = lambda name: (ROOT / name).read_text(encoding="utf-8")

manager = read("lara/overlay/CoreSetFloatingSceneManager.mm")
adapter = read("lara/overlay/CoreSetRemoteHostingAdapter.mm")
host = read("lara/overlay/CoreSetHUDHost.mm")
owner = read("lara/views/app/CoreSetRuntimeCoordinator.swift")
app = read("lara/lara.swift")
plist = read("lara/Info.plist")
project = read("lara.xcodeproj/project.pbxproj")
packaging = read("scripts/build_ipa_pe.sh")
frontboard_stub = read("Config/PrivateFrameworkStubs/FrontBoard.framework/FrontBoard.tbd")
fbs_stub = read("Config/PrivateFrameworkStubs/FrontBoardServices.framework/FrontBoardServices.tbd")
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
    'CSClass(_process, "CALayerHost")',
    'CSClass(_process, "SBMainWorkspace")',
    'CSSel(_process, "setContextId:")',
    "kCoreSetRemoteMenuLevel",
    "kCoreSetRemoteDrawLevel",
    "menuReady && drawReady",
    "RemoteCall *_process",
    "remote_getClass(process, name)",
    "doRemoteCallCheckedWithTimeout:10000",
    "remoteSideObserved",
    "localSideObserved",
    '@"wz-springboard-mirror-v1"',
):
    assert token in adapter, token
for forbidden in (
    "SBSAccessibilityWindowHostingController", "CSLoadCore17Frameworks",
):
    assert forbidden not in adapter, forbidden
for token in (
    '"-Wl,-needed_framework,FrontBoard"',
    '"-Wl,-needed_framework,FrontBoardServices"',
    '"-F$(SRCROOT)/Config/PrivateFrameworkStubs"',
    "/System/Library/PrivateFrameworks/FrontBoard.framework/FrontBoard",
    "/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices",
):
    assert token in project + packaging, token
assert "/System/Library/PrivateFrameworks/FrontBoard.framework/FrontBoard" in frontboard_stub
assert "/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices" in fbs_stub
assert project.count("CURRENT_PROJECT_VERSION = 5;") == 2

for token in (
    "UIButton buttonWithType:UIButtonTypeCustom",
    "CGRectMake(0, 0, 44, 44)",
    "UIControlEventTouchUpInside", "UIPanGestureRecognizer",
    "IOHIDEventSystemClient", "BKSHIDEventRegisterEventCallback",
    "confirmHostedReadbackAsync",
    "if (ready) (void)[host armHostedInput]",
    "if (ready) (void)[current armHostedInput]",
    "if (!active && !_inputArmed.load()) (void)[self armHostedInput]",
    "const BOOL hidOwnsBackground = !active && self.hostedInputMonitorArmed",
    "_menuWindow.backgroundPassThrough = hidOwnsBackground",
    "_menuWindow.userInteractionEnabled = !hidOwnsBackground",
    "surfacePointMayHitHostedInteraction",
    "outside-interaction-bounds",
    "unowned-game-pointer",
    "_queuedInputPointer.compare_exchange_strong",
    "background-landscape-lock",
    "ignored=hid-owner",
):
    assert token in host, token

for token in (
    "CoreSetRemoteHostingAdapter(remoteCall: process)",
    "host.attach(adapter)",
    "verifyWZHostedWindows",
    "hosting mode=wz-springboard-mirror registered=1",
    "confirmHostedReadbackAsync",
):
    assert token in owner, token
for token in ("prepareSpringBoardHosting", 'rcinit(process: "SpringBoard"',
              "rebuildHostedWindows(process:"):
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

print("PASS: WZ SpringBoard mirrors, remote readback, hosted input and ImGui/Metal host path; source only")
