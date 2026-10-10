"""iOS 26 Core-shaped three-surface host/input contract; source only."""

from hashlib import sha256
from pathlib import Path
import plistlib
import struct
import zipfile

ROOT = Path(__file__).resolve().parents[1]
read = lambda name: (ROOT / name).read_text(encoding="utf-8")
REFERENCE_IPA = ROOT.parent / "源码 - 和平" / "自签Core-SET和平-v1.7.ipa"

with zipfile.ZipFile(REFERENCE_IPA) as archive:
    reference_image = archive.read("Payload/Core.app/Core")
    reference_info = plistlib.loads(archive.read("Payload/Core.app/Info.plist"))
assert sha256(reference_image).hexdigest() == "c842be92434b88b4d535d0d10a30ace068ce6b9a7b9a97ec5a6ca8fd97fa3dd5"
assert reference_info["UIApplicationSceneManifest"]["UIApplicationSupportsMultipleScenes"] is False
assert reference_image[0x7401CB:0x7401CB + 40].startswith(b"SBSAccessibilityWindowHostingController\0")
assert [struct.unpack_from("<d", reference_image, offset)[0]
        for offset in (0x8A3A40, 0x8A3A10, 0x8A3A48)] == [999998.0, 1000000.0, 999999.0]

adapter = read("lara/overlay/CoreSetRemoteHostingAdapter.mm")
adapter_header = read("lara/overlay/CoreSetRemoteHostingAdapter.h")
host = read("lara/overlay/CoreSetHUDHost.mm")
host_header = read("lara/overlay/CoreSetHUDHost.h")
owner = read("lara/views/app/CoreSetRuntimeCoordinator.swift")
app = read("lara/lara.swift")
project = read("lara.xcodeproj/project.pbxproj")
plist = read("lara/Info.plist")
pending = read("lara/overlay/CoreSetPendingTouchQueue.h")
hit_owner = read("lara/overlay/CoreSetHostedHitOwnership.h")

# Keep Core's visible topology while replacing only the iOS-removed SBS owner.
for token in (
    "kCoreSetDrawLevel = 999998.0",
    "kCoreSetIconLevel = 1000000.0",
    "kCoreSetMenuLevel = 999999.0",
    'draw.role = @"darkswordOverlayDrawHostController"',
    'icon.role = @"darkswordOverlayIconHostController"',
    'menu.role = @"darkswordOverlayMenuHostController"',
    'CSClass(_process, "UIWindow")',
    'CSClass(_process, "CALayerHost")',
    'CSClass(_process, "SBMainWorkspace")',
    'CSSel(_process, "setContextId:")',
    "mainWindowScene", "addSublayer:", "remoteSideObserved",
    '@"ios26-springboard-calayerhost-v1"',
):
    assert token in adapter, token
for forbidden in (
    "SBSAccessibilityWindowHostingController",
    "registerWindowWithContextID:atLevel:",
    "initWithCoreHosting", "isCoreHostingAvailable",
):
    assert forbidden not in adapter + adapter_header, forbidden
assert "initWithRemoteCall:(RemoteCall *)remoteCall" in adapter_header

register = adapter[adapter.index("- (void)registerThreeSurfacesAsync:"):
                   adapter.index("- (void)unregisterBothSurfacesAsync:")]
assert register.index("createSide:draw level:kCoreSetDrawLevel") < \
       register.index("createSide:icon level:kCoreSetIconLevel") < \
       register.index("createSide:menu level:kCoreSetMenuLevel")
assert "drawReady && iconReady && menuReady" in register
assert "dispatch_async(_readbackQueue" in register

# Cross-app presentation is passive; one background HID owner routes only
# explicit menu/floating hit regions into the existing semantic consumer.
for token in (
    "BKSHIDEventRegisterEventCallback", "IOHIDEventSystemClient",
    "AXEventRepresentation", "UIApplicationEvents",
    "CoreSetPendingTouchQueue.h", "CoreSetHostedHitOwnership.h",
    "surfacePointMayHitHostedInteraction", "outside-interaction-bounds",
    "unowned-game-pointer", "_queuedInputPointer.compare_exchange_strong",
    "CoreSetIconWindow", "CoreSetMenuWindow", "CoreSetDrawWindow",
    "registerThreeSurfacesAsync:menu iconWindow:icon drawWindow:draw",
    "armHostedInput", "disarmHostedInput",
):
    assert token in host, token
assert "kExpirationInterval = 0.75" in pending
assert "enum class Owner" in hit_owner and "ownerAtPoint" in hit_owner
assert "CoreSetHostedInputCalibration" not in host

for token in (
    'rcinit(process: "SpringBoard"',
    "CoreSetRemoteHostingAdapter(remoteCall: process)",
    "host.startHosted(in: scene, menuController:",
    "host.armHostedInput()",
    "hosting mode=ios26-springboard-calayerhost",
):
    assert token in owner, token
for forbidden in ("CoreSetFloatingSceneManager", "core17-local-sbs"):
    assert forbidden not in owner + app + project, forbidden
assert "<false/>" in plist[plist.index("UIApplicationSupportsMultipleScenes"):]

print("PASS: Core three-window UI topology uses the iOS 26 CALayerHost/HID transport")
print("LIMIT: source contract only; device visibility and physical touch still require a fresh log")
