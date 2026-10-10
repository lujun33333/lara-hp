"""D1 engineering/lifecycle/layout contracts. Does not compile or run UIKit."""
from pathlib import Path
import hashlib
import re

ROOT = Path(__file__).resolve().parents[1]
paths = ["lara/views/app/CoreSetRuntimeCoordinator.swift", "lara/views/app/CoreSetMenuViewController.swift",
         "lara/views/app/ContentView.swift", "lara/overlay/CoreSetHUDHost.h", "lara/overlay/CoreSetHUDHost.mm",
         "lara/lara.swift", "lara/funcs/keepalive.swift", "lara/views/app/settings/SettingsView.swift",
         "lara/lara-Bridging-Header.h", "lara.xcodeproj/project.pbxproj", "lara/classes/laramgr.swift",
         "lara/kexploit/TaskRop/RemoteCall.m"]
data = {name: (ROOT / name).read_text(encoding="utf-8-sig") for name in paths}
coordinator, menu, launcher, header, host, app, audio, settings, bridge, project, manager, remote_call = [data[name] for name in paths]


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
assert start_host.index("_drawWindow.hidden = NO; _menuWindow.hidden = NO; _iconWindow.hidden = NO;") < start_host.index("[CATransaction flush];") < start_host.index("registerAdapter:_adapter")


def validate_owner(text):
    owner = text.split("private final class CoreSetHostPresentationOwner:")[0]
    need(owner, "private static var retained: [UUID: CoreSetRuntimeCoordinator] = [:]", "private let menu = CoreSetMenuViewController()",
         "private lazy var menuSurface: CoreSetImGuiMenuViewController",
         "private let host = CoreSetHUDHost(hostingAdapter: nil)", "private var hostPresentationOwner: CoreSetHostPresentationOwner!",
         "var featureState: CoreSetFeatureState { menu.featureState }", "Self.retained[identity] = self",
         "menu.bindMenuHostPresentationOwner(hostPresentationOwner)")
    assert owner.count("CoreSetMenuViewController()") == 1
    assert owner.count("menu.bindGameConsumer(playerConsumer, to: \\.player)") == 1
    assert "CoreSetPlayerConsumer(coordinator: self, battleProducer: battleProducer)" in owner
    assert "playerConsumer?.consumed(receipt)" in owner
    need(swift(owner, "activate"), "guard !stopping, let scene", "host.startLocal(in: scene, menuController: menuSurface)")
    need(swift(owner, "hostChanged"), "menu.reconcileMenuHostPresentation", "submittedGeneration != host.renderGeneration",
         "generation: host.renderGeneration, sequence: 1", "commands: []")
    need(swift(owner, "publishStatus"), "host.lastConsumedSequence > 0", "跨应用 unavailable")
    stop = swift(owner, "stop")
    need(stop, "precondition(Thread.isMainThread)", "if stopping, let result = lastStopResult", "stopReceiptsPending = true",
         "let result = host.stop()", "menu.suspendGameConsumers", "menu.stopMenuHostPresentation", "self.stopReceiptsPending = false",
         "host.hostedCleanupInFlight", "self.stopChannelsConfirmed = channelsRestored",
         "self.releaseStoppedOwnerIfReady()")
    release = swift(owner, "releaseStoppedOwnerIfReady")
    need(release, "stopChannelsConfirmed", "stopWindowsConfirmed", "!host.cleanupPending",
         "Self.retained.removeValue(forKey: identity)")
    assert not re.search(r"\.wait\(|DispatchQueue\.main\.sync|semaphore", swift(owner, "stopAllForTermination"), re.I)
    assert "static func stopAllForTermination(completion: @escaping () -> Void)" in owner
    need(swift(owner, "stopAllForTermination"),
         "terminationWaiters.append(completion)", "pollTerminationDrain()")
    drain = swift(owner, "pollTerminationDrain")
    need(drain, "$0.stopping", "!$0.stopReceiptsPending", "!$0.host.hostedCleanupInFlight",
         ".milliseconds(10)", "waiters.forEach { $0() }")
    host_owner = text.split("private final class CoreSetHostPresentationOwner:")[1]
    apply = swift(host_owner, "apply")
    need(apply, "precondition(Thread.isMainThread)", "guard availability == .ready",
         "host.applyLocalMenu(visible:", "let generation = host.generation",
         "guard matches(state, generation: generation) else", "appliedGeneration = generation",
         "appliedState = CoreSetMenuHostSettings(menuVisible: host.panelVisible, floatingPalette: palette)",
         "scope=core-style-host-snapshot-replay", "return true")
    # apply delegates the same real full-palette readback to matches. Verify
    # that helper's data source and full UIColor (RGBA) equality, not merely
    # the presence of a helper name or requested palette/configuration state.
    match = swift(host_owner, "matches")
    need(match, "host.generation == generation", "host.floatingControlReady",
         "host.panelVisible == state.menuVisible", "let palette = state.floatingPalette",
         "let expected = colors(for: palette), observed = host.observedFloatingColors",
         "func rgba(_ color: UIColor)", "epsilon = CGFloat(1.0 / 255.0)",
         "return observed.count == expected.count && zip(observed, expected).allSatisfy")
    assert ".isEqual(" not in match
    assert apply.index("host.applyLocalMenu(visible:") < apply.index("guard matches(state")
    assert apply.index("guard matches(state") < apply.index("appliedGeneration = generation") < apply.index("return true")
    reconcile = swift(host_owner, "reconcile")
    need(reconcile, "appliedState == state", "matches(state, generation: generation)", "return apply(state, source: source)")
    stop = swift(host_owner, "stop")
    need(stop, "let result = host.stop()", "host.hostedCleanupInFlight", "host.stopHostedAsync", "finish(result)", "finish(final)")
    finish = swift(host_owner, "finish")
    need(finish, "result.complete.boolValue && !host.localSurfacesReady && !host.floatingControlReady && host.observedFloatingColors.isEmpty",
         "appliedGeneration = nil; appliedState = nil; observationFailureReason = nil",
         "completion(stopped)")
    assert "CoreSetFeatureChannel" not in host_owner
    assert "crossApplicationHosted" not in host_owner


validate_owner(coordinator)
for old in ["stopWindowsConfirmed", "host.observedFloatingColors",
            "submittedGeneration != host.renderGeneration", "CoreSetHUDHost(hostingAdapter: nil)",
            "guard matches(state, generation: generation) else",
            "host.generation == generation", "host.floatingControlReady",
            "observed.count == expected.count", "zip(observed, expected)",
            "epsilon = CGFloat(1.0 / 255.0)",
            "menu.reconcileMenuHostPresentation", "return apply(state, source: source)", "finish(final)"]:
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
main_scene_delegate = app.split("final class LaraSceneDelegate", 1)[1]
need(swift(main_scene_delegate, "sceneDidDisconnect"), "coreSetRuntime?.stop()", "coreSetRuntime = nil")
termination = swift(app, "applicationWillTerminate")
need(termination, "CoreSetRuntimeCoordinator.stopAllForTermination {",
     "laramgr.shared.terminateRemoteCallSession", "while !finished { CFRunLoopRun() }",
     "CoreSetBackgroundAudio.shared.stop()", "shutdown stage=complete")
assert termination.index("CoreSetRuntimeCoordinator.stopAllForTermination") < termination.index("terminateRemoteCallSession")
assert termination.index("terminateRemoteCallSession") < termination.index("while !finished") < termination.index("CoreSetBackgroundAudio.shared.stop()")
need(swift(manager, "terminateRemoteCallSession"), "rcdestroy(completion: completion)")
for cache_contract in ("g_remote_selector_cache_key", "g_remote_class_cache_key",
                       "objc_getAssociatedObject(proc, &g_remote_selector_cache_key)",
                       "objc_getAssociatedObject(proc, &g_remote_class_cache_key)",
                       "if (cached.unsignedLongLongValue) return cached.unsignedLongLongValue",
                       "objc_setAssociatedObject(self, &g_remote_selector_cache_key, nil",
                       "objc_setAssociatedObject(self, &g_remote_class_cache_key, nil"):
    assert cache_contract in remote_call, cache_contract
need(swift(app, "application"), "CoreSetBackgroundAudio.shared.start()")
need(swift(main_scene_delegate, "scene"), "CoreSetBackgroundAudio.shared.start()")
need(swift(coordinator, "stopAudioAfterSceneTeardownIfReady"),
     "Self.retained.values.allSatisfy", "!$0.stopReceiptsPending",
     "!$0.host.hostedCleanupInFlight", "CoreSetBackgroundAudio.shared.stop()")
need(swift(coordinator, "stop"), "self.stopAudioAfterSceneTeardownIfReady()")
assert "toggleka()" not in app + settings and "keepAlive" not in app + settings
need(audio, "final class CoreSetBackgroundAudio", "static let shared", "private var player: AVAudioPlayer?",
     "private var watchdog: DispatchSourceTimer?", "private var backgroundTask: UIBackgroundTaskIdentifier",
     "private var recoveryEpoch: UInt64")
need(swift(audio, "start"), "timer.schedule", "repeating: .seconds(1)", "if !play() { recover")
need(swift(audio, "backgroundHeartbeatIfDue"), "applicationState == .background",
     "ProcessInfo.processInfo.systemUptime", "uptime - lastHeartbeatUptime >= 15",
     "playing=\\(isPlaying ? 1 : 0)", "backgroundTask == .invalid")
need(swift(audio, "recover"), "beginBackgroundTask()", "recoveryEpoch &+= 1",
     "[0.0, 0.2, 0.5, 1.0, 2.0, 4.0, 8.0, 16.0]", "self.endBackgroundTask()")
need(swift(audio, "play"), "setCategory(.playback", ".mixWithOthers", "setActive(true)",
     "try makeWave().write(to: url, options: .atomic)", "candidate.numberOfLoops = -1",
     "candidate.volume = 0.08", "candidate.isPlaying || candidate.play()")
need(swift(audio, "stop"), "recoveryEpoch &+= 1", "watchdog?.cancel()", "player?.stop()",
     "endBackgroundTask()", "setActive(false")
need(audio, "AVAudioSession.interruptionNotification", "AVAudioSession.mediaServicesWereResetNotification",
     "AVAudioSession.routeChangeNotification", "UIApplication.didEnterBackgroundNotification",
     "UIApplication.didBecomeActiveNotification", "UIApplication.willEnterForegroundNotification")
assert audio.count("AVAudioPlayer(contentsOf:") == 1 and "kaplayer" not in audio
need(launcher, "weak var coreSetRuntime: CoreSetRuntimeCoordinator?")
need(swift(launcher, "toggleMenu"), "guard let coreSetRuntime", "coreSetRuntime.toggleMenu()")
assert "CoreSetMenuViewController()" not in launcher and "present(menu" not in launcher
need(swift(launcher, "updateRuntimePresentation"), "menuRequestedVisible = menuVisible", "if !menuVisible { presentPendingNotices() }")
need(swift(launcher, "presentPendingNotices"), "!menuRequestedVisible")

# The production menu is one fixed 838x535 ImGui/Metal surface. The host owns
# scaling and the ImGui controller owns its semantic hit map; no UIKit control
# regions are exported to the cross-window input path.
need(coordinator, "host.contentOwnsLayout = false", "host.contentHitRegions = nil",
     "private lazy var menuSurface: CoreSetImGuiMenuViewController")
need(menu, "extension CoreSetMenuViewController: CoreSetImGuiMenuModel",
     "func imguiMenuSnapshot()", "func performImGuiMenuAction(")
layout = objc(host, "layoutSurfaces")
fixed_branch = re.search(r"\} else \{([\s\S]*?)\n    \}", layout).group(1)
need(fixed_branch, "_panel.bounds = CGRectMake(0, 0, 838, 535)",
     "_panel.transform = CGAffineTransformMakeScale(scale, scale)")
window = host.split("@implementation CoreSetMenuWindow")[1].split("@end")[0]
need(window, "controller.presentedViewController", "self.contentHitRegions()", "[region isDescendantOfView:self]",
     "ancestor.hidden || ancestor.alpha <= 0.01 || !ancestor.userInteractionEnabled", "[region convertPoint:point fromView:self]")
need(objc(host, "invalidateFrames"), "_lastConsumedSequence = 0")
submit = objc(host, "submitFrame")
need(submit, "consumeFrame:frame", "} else {", "host->_lastConsumedSequence = frame.sequence")
assert submit.index("consumeFrame:frame") < submit.index("host->_lastConsumedSequence = frame.sequence")
assert not re.search(r"smoba|UnityFramework|wzhud_|wzesp_", coordinator)
launch = swift(coordinator, "launchGame")
aim_consumer = (ROOT / "lara/views/app/CoreSetAimConsumer.swift").read_text(encoding="utf-8")
feature_state = (ROOT / "lara/views/app/CoreSetFeatureState.swift").read_text(encoding="utf-8")
need(coordinator, "aimConsumer = CoreSetAimConsumer(coordinator: self, battleProducer: battleProducer)")
need(aim_consumer, "CoreSetIsolatedWriteProbe", "battleProducer.copyAction(",
     "submit(authority: input", "result.committed", "cleanup.complete")
need(feature_state, "case basicAimScene")
need(launch, "axDeviceSupportStatus()", "init_offsets()", "offsets_init()", "manager.run", "prepareKernelOffsets")
for forbidden in ("foregroundInputProbeConfirmed", "foregroundProbeSourcesDetached",
                  "rejectForegroundProbe", "armForegroundInputProbe", ".milliseconds(120)"):
    assert forbidden not in launch + header + host, forbidden
assert launch.index("axDeviceSupportStatus()") < launch.index("gameLaunchPending = true") < launch.index("init_offsets()")
stop_body = objc(host, "stop")
need(stop_body, "[self invalidateFrames]",
     "_drawRegistered = NO; _iconRegistered = NO; _menuRegistered = NO;")
assert stop_body.index("_drawWindow.hidden = YES; _menuWindow.hidden = YES; _iconWindow.hidden = YES;") < stop_body.index("[CATransaction flush];")
assert stop_body.index("[CATransaction flush];") < stop_body.index("_drawWindow.rootViewController = nil; _menuWindow.rootViewController = nil;")
assert stop_body.index("_drawWindow.rootViewController = nil; _menuWindow.rootViewController = nil;") < stop_body.index("if (!_drawCleanupNeeded) _drawWindow = nil;")
need(start_host, "_drawWindow = [[CoreSetDrawWindow alloc] initWithWindowScene:scene]",
     "_menuWindow = [[CoreSetMenuWindow alloc] initWithWindowScene:scene]", "[self invalidateFrames]")
assert start_host.index("[self invalidateFrames]") < start_host.index("_drawWindow = [[CoreSetDrawWindow alloc]")
assert "ForegroundTouchCalibration" not in launch
assert launch.index("axDeviceSupportStatus()") < launch.index("init_offsets()") < launch.index("offsets_init()") < launch.index("manager.run") < launch.index("prepareKernelOffsets")
kernel_offsets = swift(coordinator, "prepareKernelOffsets")
need(kernel_offsets, "fetchkcache(action: action)",
     "fetched && !action.isCancellationRequested && dlkcache()",
     "manager.hasOffsets = validated", "prepareSpringBoardHosting", ".seconds(180)")
assert kernel_offsets.index("fetchkcache(action: action)") < kernel_offsets.index("fetched && !action.isCancellationRequested && dlkcache()") < kernel_offsets.index("manager.hasOffsets = validated") < kernel_offsets.index("guard validated else") < kernel_offsets.rindex("prepareSpringBoardHosting")
need(coordinator, 'rcinit(process: "SpringBoard"', "rebuildHostedWindows(process:")
remote = swift(coordinator, "rebuildHostedWindows")
need(remote, "host.localSurfacesReady", "host.attach(adapter)",
     "CoreSetRemoteHostingAdapter(remoteCall: process)", "verifyHostedWindows")
need(swift(coordinator, "verifyHostedWindows"), "confirmHostedReadbackAsync", ".milliseconds(1200)")
action_stop = swift(menu, "suspendActionConsumers")
need(action_stop, "stop(\\.aim)", "stop(\\.recoil)", "group.notify(queue: .main)")
need(swift(menu, "resumeActionConsumers"), "featureState.aim.resume()", "featureState.recoil.resume()")
assert "CoreSetHostedInputCalibration" not in host
attach = objc(host[host.index("@implementation CoreSetHUDHost {"):], "attachHostingAdapter")
need(attach, "_adapter = adapter", "registerAdapter:adapter menu:menu icon:icon draw:draw")
assert "alloc] initWithWindowScene" not in attach
transition = objc(host[host.index("@implementation CoreSetHUDHost {"):], "transitionToRemoteHostingAdapter")
need(transition, "unregisterAdapter:previousAdapter menu:menu icon:icon draw:draw", "host->_adapter = adapter",
     "registerAdapter:adapter menu:menu icon:icon draw:draw")
assert transition.index("unregisterAdapter:") < transition.index("registerAdapter:")
assert "alloc] initWithWindowScene" not in transition
need(swift(coordinator, "showHostedMenuAndOpenGame"),
     "requestMenuVisibility(true)", "guard confirmed else", "rollbackGameLaunch",
     "宿主菜单快照未确认，已取消打开游戏", "CoreSetGameTarget.openApplication")
exit_hud = swift(coordinator, "exitHostedHUD")
need(exit_hud, "returnToLocalPending = true", "if gameLaunchPending",
     "gameLaunchEpoch &+= 1", "gameLaunchPending = false",
     "pendingLaunchCompletion = nil", "pendingCompletion?(gameLaunchStatus)",
     "gameLaunchStatus = Self.userCancelledLaunchReason",
     "suspendGameConsumers", "stopMenuHostPresentation", "host.stopHostedAsync",
     "result.complete.boolValue", "host.installRemoteHostingAdapter(nil)")
assert exit_hud.index("returnToLocalPending = true") < exit_hud.index("pendingCompletion?(gameLaunchStatus)")
assert exit_hud.index("gameLaunchEpoch &+= 1") < exit_hud.index("stopMenuHostPresentation")
finish_launch = swift(coordinator, "finishGameLaunch")
need(finish_launch, "guard gameLaunchCurrent(epoch)", "let finishedCompletion = pendingLaunchCompletion",
     "pendingLaunchCompletion = nil", "(finishedCompletion ?? completion)(error)")
need(swift(coordinator, "launchGame"), "pendingLaunchCompletion = completion")
need(swift(coordinator, "stop"), "let pendingCompletion = pendingLaunchCompletion",
     "pendingLaunchCompletion = nil", "pendingCompletion?(Self.sceneEndedLaunchReason)")
need(swift(launcher, "launchApplication"),
     "error != CoreSetRuntimeCoordinator.userCancelledLaunchReason",
     "error != CoreSetRuntimeCoordinator.sceneEndedLaunchReason")
remote_adapter = (ROOT / "lara/overlay/CoreSetRemoteHostingAdapter.mm").read_text(encoding="utf-8")
remote_adapter_header = (ROOT / "lara/overlay/CoreSetRemoteHostingAdapter.h").read_text(encoding="utf-8")
need(remote_adapter_header,
     "- (nullable instancetype)initWithCoreHosting:(BOOL)coreHosting")
need(remote_adapter, "CALayerHost", "SBMainWorkspace", "mainWindowScene", "setContextId:",
     "kCoreSetCoreMenuLevel", "kCoreSetCoreIconLevel", "kCoreSetCoreDrawLevel", "RemoteCall",
     "doRemoteCallCheckedWithTimeout", '@"core-three-surface-sbs-or-remote-v6-hit-snapshot"',
     "SBSAccessibilityWindowHostingController", "registerWindowWithContextID:atLevel:",
     "unregisterWindowWithContextID:", "registerThreeSurfacesAsync",
     "kCoreSetCoreDrawLevel = 999998.0", "kCoreSetCoreMenuLevel = 999999.0",
     "kCoreSetCoreIconLevel = 1000000.0", "return YES;")
core_host = swift(coordinator, "prepareCoreHosting")
need(core_host, "CoreSetRemoteHostingAdapter(coreHosting: true)", "host.attach(adapter)",
     "verifyHostedWindows")
assert swift(coordinator, "launchGame").index("CoreSetRemoteHostingAdapter.isCoreHostingAvailable()") < swift(coordinator, "launchGame").index("manager.run")
open_game = swift(coordinator, "showHostedMenuAndOpenGame")
need(open_game, "requestMenuVisibility(true)", "guard confirmed else", "rollbackGameLaunch",
     "CoreSetGameTarget.openApplication")
assert open_game.index("guard confirmed else") < open_game.index("CoreSetGameTarget.openApplication")
assert "confirmHostedReadbackAsync" in open_game
assert "CoreSetGameTarget.openApplication" not in swift(launcher, "launchApplication")
need(swift(launcher, "launchApplication"), "coreSetRuntime.launchGame")
print("PASS: D1 project/owner/host contracts, Core three-surface SBS/RemoteCall registration; source only")
print("LIMIT: no Swift/ObjC/UIKit compile, cross-app physical touch or device lifecycle execution")
for name in paths:
    print(name + "=" + hashlib.sha256((ROOT / name).read_bytes()).hexdigest())
