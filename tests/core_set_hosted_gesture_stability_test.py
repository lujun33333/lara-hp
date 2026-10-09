"""WZ SpringBoard mirror/hosted-input source contract; no device-effect claim."""

from hashlib import sha256
from pathlib import Path
import struct
import zipfile

ROOT = Path(__file__).resolve().parents[1]
read = lambda name: (ROOT / name).read_text(encoding="utf-8")
REFERENCE_IPA = ROOT.parent / "源码 - 和平" / "自签Core-SET和平-v1.7.ipa"
with zipfile.ZipFile(REFERENCE_IPA) as archive:
    reference_image = archive.read("Payload/Core.app/Core")
assert sha256(reference_image).hexdigest() == "c842be92434b88b4d535d0d10a30ace068ce6b9a7b9a97ec5a6ca8fd97fa3dd5"
assert reference_image[0x7401CB:0x7401CB + 40].startswith(b"SBSAccessibilityWindowHostingController\0")
assert reference_image[0x7401F3:0x7401F3 + 43].startswith(b"registerWindowWithContextID:atLevel:\0")
assert struct.unpack_from("<d", reference_image, 0x8A3A40)[0] == 999998.0
assert struct.unpack_from("<d", reference_image, 0x8A3A10)[0] == 1000000.0
assert struct.unpack_from("<d", reference_image, 0x8A3A48)[0] == 999999.0
assert struct.unpack_from("<I", reference_image, 0x5A1B0)[0] == 0x97FF8BE5

def decode_role(offset, length):
    state = 0
    decoded = bytearray()
    for value in reference_image[offset:offset + length]:
        decoded.append(value ^ (((state >> 22) ^ 6) & 0xff))
        state = (state + 0x1e3779b9) & 0xffffffff
    return decoded.decode("utf-8")

assert decode_role(0x8A3B58, 0x22) == "darkswordOverlayDrawHostController"
assert decode_role(0x8A3B7B, 0x22) == "darkswordOverlayIconHostController"
assert decode_role(0x8A3B9E, 0x22) == "darkswordOverlayMenuHostController"
assert decode_role(0x8A3BC1, 0x1E) == "unregisterWindowWithContextID:"
assert [struct.unpack_from("<I", reference_image, offset)[0]
        for offset in (0x564B8, 0x564C8, 0x564D8)] == [0x52800020, 0x52800040, 0x52800060]
assert [struct.unpack_from("<I", reference_image, offset)[0]
        for offset in (0x56510, 0x56540, 0x56570)] == [0x94000EEC, 0x94000EE0, 0x94000ED4]
# 0x1000560e8 reads three source objects in draw/icon/menu order, resolves
# their contextId values, and publishes the three distinct UInt32 contexts.
assert [struct.unpack_from("<I", reference_image, offset)[0]
        for offset in (0x56108, 0x5611C, 0x56130)] == [0xF9476900, 0xF9477100, 0xF9477D00]
assert [struct.unpack_from("<I", reference_image, offset)[0]
        for offset in (0x56114, 0x56128, 0x5613C)] == [0xB90FC660, 0xB90FCE80, 0xB90FD500]

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
    "SBSAccessibilityWindowHostingController",
    "registerWindowWithContextID:atLevel:",
    "unregisterWindowWithContextID:",
    "kCoreSetCoreDrawLevel = 999998.0",
    "kCoreSetCoreMenuLevel = 999999.0",
    "kCoreSetCoreIconLevel = 1000000.0",
    "kCoreSetWZRemoteDrawLevel = 10000009.0",
    "kCoreSetWZRemoteMenuLevel = 10000010.0",
    "initWithCoreHosting",
    'CSClass(_process, "CALayerHost")',
    'CSClass(_process, "SBMainWorkspace")',
    'CSSel(_process, "setContextId:")',
    "kCoreSetCoreMenuLevel",
    "kCoreSetCoreDrawLevel",
    "drawReady && iconReady && menuReady",
    "registerThreeSurfacesAsync",
    "unregisterThreeSurfacesAsync",
    "objc_setAssociatedObject(UIApplication.sharedApplication, side.associationKey",
    "OBJC_ASSOCIATION_RETAIN_NONATOMIC",
    '@"darkswordOverlayDrawHostController"',
    '@"darkswordOverlayIconHostController"',
    '@"darkswordOverlayMenuHostController"',
    "RemoteCall *_process",
    "remote_getClass(process, name)",
    "doRemoteCallCheckedWithTimeout:10000",
    "remoteSideObserved",
    "localSideObserved",
    '@"core-sbs-three-surface-wz-fallback-v4"',
):
    assert token in adapter, token
hosting_class = adapter[adapter.index("static void CSLoadCoreHostingFrameworks"):
                        adapter.index("static BOOL CSChecked")]
for framework in (
    "FrontBoard.framework/FrontBoard",
    "FrontBoardServices.framework/FrontBoardServices",
    "RunningBoardServices.framework/RunningBoardServices",
    "BoardServices.framework/BoardServices",
    "BaseBoard.framework/BaseBoard",
    "AccessibilityUtilities.framework/AccessibilityUtilities",
    "SpringBoardServices.framework/SpringBoardServices",
):
    assert framework in hosting_class, framework
assert "RTLD_LAZY | RTLD_LOCAL" in hosting_class
assert "dispatch_once" not in hosting_class
assert "static Class hostingClass" not in hosting_class
assert hosting_class.count('NSClassFromString(@"SBSAccessibilityWindowHostingController")') == 2
assert 'core-sbs probe build=%@ class=%d selector=%d' in adapter
register_three = adapter[adapter.index("- (void)registerThreeSurfacesAsync:"):
                         adapter.index("- (void)unregisterBothSurfacesAsync:")]
assert "!NSThread.isMainThread" in register_three
assert register_three.index("createSide:draw level:kCoreSetCoreDrawLevel") < \
       register_three.index("createSide:icon level:kCoreSetCoreIconLevel") < \
       register_three.index("createSide:menu level:kCoreSetCoreMenuLevel")
unregister_three = adapter[adapter.index("- (void)unregisterThreeSurfacesAsync:"):
                           adapter.index("@end", adapter.index("- (void)unregisterThreeSurfacesAsync:"))]
assert "!NSThread.isMainThread" in unregister_three
assert unregister_three.index("removeSide:draw") < unregister_three.index("removeSide:icon") < \
       unregister_three.index("removeSide:menu")
for role in ("Draw", "Icon", "Menu"):
    assert f'NSSelectorFromString(@"darkswordOverlay{role}HostController")' in register_three
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
    "_iconWindow.backgroundPassThrough = hidOwnsBackground",
    "_iconWindow.userInteractionEnabled = !hidOwnsBackground",
    "CoreSetIconWindow",
    "registerThreeSurfacesAsync:menu iconWindow:icon drawWindow:draw",
    "surfacePointMayHitHostedInteraction",
    "outside-interaction-bounds",
    "unowned-game-pointer",
    "_queuedInputPointer.compare_exchange_strong",
    "background-landscape-lock",
    "ignored=hid-owner",
):
    assert token in host, token
for token in (
    "_iconWindow = [[CoreSetIconWindow alloc] initWithWindowScene:scene]",
    "_iconWindow.hidden = YES",
    "_iconWindow.rootViewController = nil",
    "if (!_iconCleanupNeeded) _iconWindow = nil",
):
    assert token in host, token

for token in (
    "CoreSetRemoteHostingAdapter.isCoreHostingAvailable()",
    "CoreSetRemoteHostingAdapter(coreHosting: true)",
    "prepareCoreHosting(epoch:",
    "hosting mode=core-sbs roles=draw,menu,icon levels=999998,999999,1000000 registered=1",
    "CoreSetRemoteHostingAdapter(remoteCall: process)",
    "host.attach(adapter)",
    "verifyHostedWindows",
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

print("PASS: Core SBS preferred host, WZ fallback, hosted input and ImGui/Metal host path; source only")
