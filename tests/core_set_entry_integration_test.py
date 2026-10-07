"""D1 engineering/lifecycle/layout contracts. Does not compile or run UIKit."""
from pathlib import Path
import hashlib
import re

ROOT = Path(__file__).resolve().parents[1]
paths = ["lara/views/app/CoreSetRuntimeCoordinator.swift", "lara/views/app/CoreSetMenuViewController.swift",
         "lara/views/app/ContentView.swift", "lara/overlay/CoreSetHUDHost.h", "lara/overlay/CoreSetHUDHost.mm",
         "lara/lara.swift", "lara/lara-Bridging-Header.h", "lara.xcodeproj/project.pbxproj"]
data = {name: (ROOT / name).read_text(encoding="utf-8-sig") for name in paths}
coordinator, menu, launcher, header, host, app, bridge, project = [data[name] for name in paths]


def need(text, *tokens):
    for token in tokens:
        assert token in text, "missing " + token


def balanced(text, start):
    depth = 1
    for end in range(start + 1, len(text)):
        depth += (text[end] == "{") - (text[end] == "}")
        if depth == 0:
            return text[start + 1:end]
    raise AssertionError("unclosed block")


def swift(text, name):
    match = re.search(r"func " + name + r"\b", text)
    assert match, name
    return balanced(text, text.index("{", match.end()))


def objc(text, name):
    match = re.search(r"^- \([^\n]+?\)" + name + r"(?=[:\s{])", text, re.M)
    assert match, name
    return balanced(text, text.index("{", match.end()))


# Enumerate actual PBX objects, resolving fileRef -> BuildFile -> Sources. Do not
# count repeated comments as references, or explicit + synchronized membership twice.
objects = {}
for match in re.finditer(r"^\t\t([A-F0-9]{24})(?: /\*.*?\*/)? = \{", project, re.M):
    identifier = match.group(1)
    assert identifier not in objects, "duplicate PBX object " + identifier
    objects[identifier] = balanced(project, match.end() - 1)
source_phase = [text for text in objects.values() if "isa = PBXSourcesBuildPhase;" in text]
assert len(source_phase) == 1
exceptions = [text for text in objects.values() if "isa = PBXFileSystemSynchronizedBuildFileExceptionSet;" in text]
assert len(exceptions) == 1
files = ["views/app/CoreSetFeatureState.swift", "views/app/CoreSetRuntimeCoordinator.swift",
         "overlay/CoreSetHUDHost.mm", "overlay/CoreSetRenderCommands.mm", "overlay/CoreSetHUDHost.h",
         "overlay/CoreSetHUDLifecycle.h", "overlay/CoreSetRenderCommands.h"]
for relative in files:
    assert (ROOT / "lara" / relative).is_file()
    refs = [identifier for identifier, text in objects.items()
            if "isa = PBXFileReference;" in text and re.search(r'path = "?' + re.escape("lara/" + relative) + r'"?;', text)]
    assert len(refs) == 1, (relative, refs)
    assert re.findall(re.escape(relative) + r",", exceptions[0]) == [relative + ","], "sync exclusion mismatch " + relative
    builds = [identifier for identifier, text in objects.items()
              if "isa = PBXBuildFile;" in text and "fileRef = " + refs[0] in text]
    if relative.endswith((".swift", ".mm")):
        assert len(builds) == 1 and source_phase[0].count(builds[0]) == 1, relative
    else:
        assert not builds, "header compiled as source " + relative
for implicit in ["views/app/CoreSetMenuViewController.swift", "views/app/ContentView.swift", "lara.swift"]:
    assert implicit not in exceptions[0]
    assert not any(re.search(r'path = "?' + re.escape("lara/" + implicit) + r'"?;', text) for text in objects.values())
need(project, "PBXFileSystemSynchronizedRootGroup", "QuartzCore.framework in Frameworks", 'SWIFT_OBJC_BRIDGING_HEADER = "lara/lara-Bridging-Header.h"')
assert bridge.count('#import "overlay/CoreSetHUDHost.h"') == 1
need(header, "NS_SWIFT_NAME(startLocal(in:menuController:))", "NS_SWIFT_NAME(startHosted(in:menuController:completion:))", "NS_SWIFT_NAME(applyLocalMenu(visible:colors:))")
start_host = objc(host[host.index("@implementation CoreSetHUDHost {"):], "startPreparedInScene")
assert start_host.index("_drawWindow.hidden = NO; _menuWindow.hidden = NO;") < start_host.index("[CATransaction flush];") < start_host.index("registerBothSurfacesAsync:menuWindow")


def validate_owner(text):
    owner = text.split("private final class CoreSetLocalHostConsumer:")[0]
    need(owner, "private static var retained: [UUID: CoreSetRuntimeCoordinator] = [:]", "private let menu = CoreSetMenuViewController()",
         "private let host = CoreSetHUDHost(hostingAdapter: nil)", "private var consumer: CoreSetLocalHostConsumer!",
         "var featureState: CoreSetFeatureState { menu.featureState }", "Self.retained[identity] = self", "menu.bindMenuHostConsumer(consumer)")
    assert owner.count("CoreSetMenuViewController()") == 1
    assert owner.count("menu.bindGameConsumer(playerConsumer, to: \\.player)") == 1
    assert "CoreSetPlayerConsumer(coordinator: self)" in owner
    assert "playerConsumer?.consumed(receipt)" in owner
    need(swift(owner, "activate"), "guard !stopping, let scene", "host.startLocal(in: scene, menuController: menu)")
    need(swift(owner, "hostChanged"), "submittedGeneration != host.renderGeneration", "generation: host.renderGeneration, sequence: 1", "commands: []")
    need(swift(owner, "publishStatus"), "host.lastConsumedSequence > 0", "跨应用 unavailable")
    stop = swift(owner, "stop")
    need(stop, "precondition(Thread.isMainThread)", "if stopping, let result = lastStopResult", "stopReceiptsPending = true",
         "let result = host.stop()", "menu.suspendGameConsumers", "menu.suspendMenuHostConsumer", "self.stopReceiptsPending = false",
         "host.hostedCleanupInFlight", "self.stopChannelsConfirmed = channelsRestored",
         "self.releaseStoppedOwnerIfReady()")
    release = swift(owner, "releaseStoppedOwnerIfReady")
    need(release, "stopChannelsConfirmed", "stopWindowsConfirmed", "!host.cleanupPending",
         "Self.retained.removeValue(forKey: identity)")
    assert not re.search(r"\.wait\(|DispatchQueue\.main\.sync|semaphore", swift(owner, "stopAllForTermination"), re.I)
    consumer = text.split("private final class CoreSetLocalHostConsumer:")[1]
    apply = swift(consumer, "apply")
    need(apply, "guard availability == .ready", "host.applyLocalMenu(visible:", "host.observedFloatingColors",
         "observed.count == colors.count", "zip(observed, colors).allSatisfy", "host.panelVisible == request.desired.menuVisible",
         ".applied(observed: State(menuVisible: host.panelVisible, floatingPalette: palette))")
    assert apply.index("host.observedFloatingColors") < apply.index(".applied(observed:")
    need(swift(consumer, "stop"), "let result = host.stop()", "host.hostedCleanupInFlight",
         "host.stopHostedAsync", "final.complete.boolValue ? .restored : .failed")
    assert "crossApplicationHosted" not in consumer


validate_owner(coordinator)
for old in ["stopWindowsConfirmed", "host.observedFloatingColors",
            "submittedGeneration != host.renderGeneration", "CoreSetHUDHost(hostingAdapter: nil)"]:
    try:
        validate_owner(coordinator.replace(old, "REMOVED_GATE"))
    except AssertionError:
        pass
    else:
        raise AssertionError("owner negative control accepted: " + old)

need(app, "private var coreSetRuntime: CoreSetRuntimeCoordinator?", "coreSetRuntime = runtime", "launcher.coreSetRuntime = runtime")
need(swift(app, "sceneDidBecomeActive"), "coreSetRuntime?.activate()")
for name in ["sceneWillResignActive", "sceneDidEnterBackground"]:
    need(swift(app, name), "coreSetRuntime?.deactivate()")
need(swift(app, "sceneDidDisconnect"), "coreSetRuntime?.stop()", "coreSetRuntime = nil")
need(swift(app, "applicationWillTerminate"), "CoreSetRuntimeCoordinator.stopAllForTermination()")
need(launcher, "weak var coreSetRuntime: CoreSetRuntimeCoordinator?")
need(swift(launcher, "toggleMenu"), "guard let coreSetRuntime", "coreSetRuntime.toggleMenu()")
assert "CoreSetMenuViewController()" not in launcher and "present(menu" not in launcher
need(swift(launcher, "updateRuntimePresentation"), "menuRequestedVisible = menuVisible", "if !menuVisible { presentPendingNotices() }")
need(swift(launcher, "presentPendingNotices"), "!menuRequestedVisible")

# Content owns full-window layout: only its real panel/close button and the
# floating button accept hits. Hidden ancestors reject stale regions; local
# UIKit modals are separately allowed. No game touch dispatch is introduced.
need(coordinator, "host.contentOwnsLayout = true", "host.contentHitRegions = { [weak menu = self.menu]", "menu?.localHostHitRegions ?? []")
need(menu, "var localHostHitRegions: [UIView] { [panel, closeButton] }")
layout = objc(host, "layoutSurfaces")
content_branch = re.search(r"if \(self.contentOwnsLayout\) \{([\s\S]*?)\} else", layout).group(1)
need(content_branch, "_panel.transform = CGAffineTransformIdentity", "_panel.frame = root.bounds")
assert "MakeScale" not in content_branch
window = host.split("@implementation CoreSetMenuWindow")[1].split("@end")[0]
need(window, "controller.presentedViewController", "self.contentHitRegions()", "[region isDescendantOfView:self]",
     "ancestor.hidden || ancestor.alpha <= 0.01 || !ancestor.userInteractionEnabled", "[region convertPoint:point fromView:self]")
need(objc(host, "invalidateFrames"), "_lastConsumedSequence = 0")
submit = objc(host, "submitFrame")
need(submit, "consumeFrame:frame", "} else {", "host->_lastConsumedSequence = frame.sequence")
assert submit.index("consumeFrame:frame") < submit.index("host->_lastConsumedSequence = frame.sequence")
assert not re.search(r"smoba|UnityFramework|wzhud_|wzesp_", coordinator)
launch = swift(coordinator, "launchGame")
need(launch, "axDeviceSupportStatus()", "init_offsets()", "offsets_init()", "manager.run", "prepareKernelOffsets")
assert "ForegroundTouchCalibration" not in launch
assert launch.index("axDeviceSupportStatus()") < launch.index("init_offsets()") < launch.index("offsets_init()") < launch.index("manager.run") < launch.index("prepareKernelOffsets")
kernel_offsets = swift(coordinator, "prepareKernelOffsets")
need(kernel_offsets, "fetchkcache()", "fetched && dlkcache()", "manager.hasOffsets = loaded", "prepareLocalHosting", ".seconds(180)")
assert kernel_offsets.index("fetchkcache()") < kernel_offsets.index("fetched && dlkcache()") < kernel_offsets.index("manager.hasOffsets = loaded") < kernel_offsets.index("guard loaded else") < kernel_offsets.rindex("prepareLocalHosting")
local = swift(coordinator, "prepareLocalHosting")
need(local, "CoreSetLocalHostingAdapter()", "adapter.available", "installHostedWindows(adapter: adapter, localMode: true")
remote = swift(coordinator, "rebuildHostedWindows")
need(remote, "host.transitionToRemoteHostingAdapter(adapter)", "installHostedWindows(adapter: adapter, localMode: false")
assert "stopHostedAsync" not in swift(coordinator, "fallbackToSpringBoardAfterLocalFailure")
hosting = swift(coordinator, "installHostedWindows")
need(hosting, "suspendAimConsumer", "host.attachHostingAdapter(adapter)", "verifyHostedWindows")
assert "host.stop()" not in hosting and "suspendMenuHostConsumer" not in hosting
assert "CoreSetHostedInputCalibration" not in host
attach = objc(host[host.index("@implementation CoreSetHUDHost {"):], "attachHostingAdapter")
need(attach, "_adapter = adapter", "registerBothSurfacesAsync:menu drawWindow:draw")
assert "alloc] initWithWindowScene" not in attach
transition = objc(host[host.index("@implementation CoreSetHUDHost {"):], "transitionToRemoteHostingAdapter")
need(transition, "unregisterBothSurfacesAsync:menu drawWindow:draw", "host->_adapter = adapter",
     "registerBothSurfacesAsync:menu drawWindow:draw")
assert transition.index("unregisterBothSurfacesAsync:") < transition.index("registerBothSurfacesAsync:")
assert "alloc] initWithWindowScene" not in transition
verify = swift(coordinator, "verifyHostedWindows")
need(verify, "host.confirmHostedReadbackAsync", ".milliseconds(1200)",
     "self.host.confirmHostedReadbackAsync", "guard observed else")
assert verify.index("host.confirmHostedReadbackAsync") < verify.index("self.showHostedMenuAndOpenGame")
need(swift(coordinator, "showHostedMenuAndOpenGame"), "stage=menu-visible confirmed=%d panel=%d hosted=%d")
remote_adapter = (ROOT / "lara/overlay/CoreSetRemoteHostingAdapter.mm").read_text(encoding="utf-8")
need(remote_adapter, "kCoreSetRemoteDrawLevel = 10000009.0", "kCoreSetRemoteMenuLevel = 10000010.0",
     "registerBothSurfacesAsync:", "createSide:menu level:kCoreSetRemoteMenuLevel",
     "createSide:draw level:kCoreSetRemoteDrawLevel")
assert "createSide:side level:window.windowLevel" not in remote_adapter
open_game = swift(coordinator, "showHostedMenuAndOpenGame")
need(open_game, "host.hostedRegistrationReceipt", "requestMenuVisibility(true)", "CoreSetGameTarget.openApplication", "self.host.confirmHostedReadbackAsync")
assert open_game.index("host.hostedRegistrationReceipt") < open_game.index("CoreSetGameTarget.openApplication") < open_game.index("self.host.confirmHostedReadbackAsync")
assert "CoreSetGameTarget.openApplication" not in swift(launcher, "launchApplication")
need(swift(launcher, "launchApplication"), "coreSetRuntime.launchGame")
print("PASS: D1 project/owner/host contracts and game launch gated by observed dual-window hosting; source only")
print("LIMIT: no Swift/ObjC/UIKit compile, cross-app physical touch or device lifecycle execution")
for name in paths:
    print(name + "=" + hashlib.sha256((ROOT / name).read_bytes()).hexdigest())
