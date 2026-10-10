"""Core 1.7 SBS/UIKit hosting source contract; no device-effect claim."""

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
assert decode_role(0x8A3CAF, 0x22) == "darkswordOverlayDrawLockInvocation"
assert decode_role(0x8A3CD2, 0x22) == "darkswordOverlayIconLockInvocation"
assert decode_role(0x8A3CF5, 0x22) == "darkswordOverlayMenuLockInvocation"
assert decode_role(0x8A3D18, 0x24) == "darkswordOverlayDrawUnlockInvocation"
assert decode_role(0x8A3D3D, 0x24) == "darkswordOverlayIconUnlockInvocation"
assert decode_role(0x8A3D62, 0x24) == "darkswordOverlayMenuUnlockInvocation"
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
for forbidden in (
    b"BKSHIDEventRegisterEventCallback", b"IOHIDEventSystemClient",
    b"AXEventRepresentation", b"UIApplicationEvents",
    b"CALayerHost", b"SBMainWorkspace", b"setContextId:",
):
    assert forbidden not in reference_image, forbidden

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
required_dependency_stubs = {
    "/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit":
        read("Config/PrivateFrameworkStubs/IOKit.framework/IOKit.tbd"),
    "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer":
        read("Config/PrivateFrameworkStubs/IOMobileFramebuffer.framework/IOMobileFramebuffer.tbd"),
    "/System/Library/PrivateFrameworks/RunningBoardServices.framework/RunningBoardServices":
        read("Config/PrivateFrameworkStubs/RunningBoardServices.framework/RunningBoardServices.tbd"),
    "/System/Library/PrivateFrameworks/BoardServices.framework/BoardServices":
        read("Config/PrivateFrameworkStubs/BoardServices.framework/BoardServices.tbd"),
    "/System/Library/PrivateFrameworks/BaseBoard.framework/BaseBoard":
        read("Config/PrivateFrameworkStubs/BaseBoard.framework/BaseBoard.tbd"),
}
metal = read("lara/overlay/CoreSetMetalRenderAdapter.mm")
imgui = read("lara/third_party/imgui/imgui.h")
imgui_surface = read("lara/overlay/CoreSetImGuiMenuSurface.mm")

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
    'CSSel(_process, "unregisterWindowWithContextID:")',
    "draw.level = 999998.0", "icon.level = 1000000.0",
    "menu.level = 999999.0", "drawReady && iconReady && menuReady",
    '@"darkswordOverlayDrawHostController"',
    '@"darkswordOverlayIconHostController"',
    '@"darkswordOverlayMenuHostController"',
    "RemoteCall *_process", "remote_getClass(process, name)",
    "doRemoteCallCheckedWithTimeout:10000",
    'NSSelectorFromString(@"_contextId")', '[window.layer valueForKey:@"contextId"]',
    "stage=context-capture draw=%u icon=%u menu=%u",
    '@"core17-sbs-only-v3"', "stage=remote-class", "stage=remote-registered",
):
    assert token in adapter, token
for forbidden in (
    "CALayerHost", "SBMainWorkspace", "setContextId:",
    "initWithCoreHosting", "isCoreHostingAvailable", "CSLoadCoreHostingFrameworks",
):
    assert forbidden not in adapter, forbidden

for token in (
    '"-Wl,-needed_framework,IOKit"',
    '"-Wl,-needed_framework,IOMobileFramebuffer"',
    '"-Wl,-needed_framework,FrontBoard"',
    '"-Wl,-needed_framework,FrontBoardServices"',
    '"-Wl,-needed_framework,RunningBoardServices"',
    '"-Wl,-needed_framework,BoardServices"',
    '"-Wl,-needed_framework,BaseBoard"',
    '"-F$(SRCROOT)/Config/PrivateFrameworkStubs"',
    "/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit",
    "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer",
    "/System/Library/PrivateFrameworks/FrontBoard.framework/FrontBoard",
    "/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices",
    "/System/Library/PrivateFrameworks/RunningBoardServices.framework/RunningBoardServices",
    "/System/Library/PrivateFrameworks/BoardServices.framework/BoardServices",
    "/System/Library/PrivateFrameworks/BaseBoard.framework/BaseBoard",
):
    assert token in project + packaging, token
assert "/System/Library/PrivateFrameworks/FrontBoard.framework/FrontBoard" in frontboard_stub
assert "/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices" in fbs_stub
for install_name, stub in required_dependency_stubs.items():
    assert install_name in stub, install_name
assert project.count("CURRENT_PROJECT_VERSION = 5;") == 2

for token in (
    "UIButton buttonWithType:UIButtonTypeCustom",
    "CGRectMake(0, 0, 44, 44)", "CAGradientLayer",
    "UIControlEventTouchUpInside", "UIPanGestureRecognizer",
):
    assert token in host, token
for forbidden in (
    "BKSHID", "IOHIDEventSystemClient", "AXEventRepresentation",
    "UIApplicationEvents", "CoreSetPendingTouchQueue",
    "surfacePointMayHitHostedInteraction",
):
    assert forbidden not in host, forbidden
for token in ("CoreSetDrawWindow", "CoreSetIconWindow", "CoreSetMenuWindow",
              "registerThreeSurfacesAsync:menuWindow iconWindow:iconWindow drawWindow:drawWindow"):
    assert token in host, token
for token in (
    "CoreSetFloatingSceneManager.shared().createScenes",
    "CoreSetRemoteHostingAdapter(remoteCall: process)",
    "host.startHosted(menuScene: touchScene, drawScene: drawScene",
    "hosting mode=core17-springboard-sbs roles=draw,icon,menu levels=999998,1000000,999999 registered=1",
):
    assert token in owner, token
for forbidden in (
    "prepareCoreHosting", "isCoreHostingAvailable", "coreHosting: true",
    "host.attach(adapter)", "verifyHostedWindows", "confirmHostedReadbackAsync",
    "wz-springboard-mirror",
):
    assert forbidden not in owner, forbidden
for token in ("prepareSpringBoardHosting", 'rcinit(process: "SpringBoard"',
              "rebuildHostedWindows(process:"):
    assert token in owner, token
for token in (
    "touchesBegan:", "touchesMoved:", "touchesEnded:", "touchesCancelled:",
):
    assert token in imgui_surface, token

assert '#define IMGUI_VERSION       "1.92.8"' in imgui
for token in (
    "ImGui_ImplMetal_Init(device)", "ImGui_ImplMetal_NewFrame(pass)",
    "ImGui::NewFrame()", "ImGui::GetBackgroundDrawList()",
    "ImGui_ImplMetal_RenderDrawData", "addPresentedHandler",
):
    assert token in metal, token
for forbidden in ("CIContext", "CoreSetCoreAnimationConsumer", "renderInContext"):
    assert forbidden not in metal, forbidden

print("PASS: Core SBS contexts and UIKit/ImGui input are the only host path; source only")
