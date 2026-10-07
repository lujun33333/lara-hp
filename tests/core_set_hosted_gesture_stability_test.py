"""Source contracts for the hosted gesture lifetime; no UIKit runtime claim."""

from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
menu = (root / "lara/views/app/CoreSetMenuViewController.swift").read_text(encoding="utf-8")
host = (root / "lara/overlay/CoreSetHUDHost.mm").read_text(encoding="utf-8")
owner = (root / "lara/views/app/CoreSetRuntimeCoordinator.swift").read_text(encoding="utf-8")
adapter = (root / "lara/overlay/CoreSetRemoteHostingAdapter.mm").read_text(encoding="utf-8")
radar_consumer = (root / "lara/views/app/CoreSetRadarConsumer.swift").read_text(encoding="utf-8")


def body(source: str, signature: str) -> str:
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    for position in range(opening + 1, len(source)):
        if source[position] == "{":
            depth += 1
        elif source[position] == "}":
            depth -= 1
            if depth == 0:
                return source[opening + 1 : position]
    raise AssertionError(f"unterminated function: {signature}")


performance = body(menu, "func updatePerformanceObservation(")
assert "refreshPerformanceLabels()" in performance
assert "rebuildMenu(" not in performance, "a 1.5-second sample must not cancel an active pointer"
labels = body(menu, "private func refreshPerformanceLabels()")
assert "performanceValueLabels[index].text = display" in labels
assert "rebuildMenu(" not in labels
home = body(menu, "func updateRuntimeObservations(")
assert "if hostedPointerID == nil { rebuildMenu() }" in home
assert "else { homeStatusNeedsRebuild = true }" in home

availability = body(menu, "func refreshConsumerAvailability()")
assert "if updateConsumerAvailability(), isViewLoaded { rebuildMenu() }" in availability
assert "updateConsumerAvailability()\n        if isViewLoaded { rebuildMenu() }" not in availability

frame = body(host, "- (void)submitFrame:")
assert "if (firstFrame) [host publishState]" in frame
assert "const BOOL firstFrame = host->_lastConsumedSequence == 0" in frame

rebuild = body(menu, "private func rebuildMenu(")
assert "pageContentOffsets[selectedPage] = content.contentOffset" in rebuild
assert "content.contentSize.height - content.bounds.height" in rebuild
assert "content.contentOffset = CGPoint(" in rebuild
page = body(menu, "@objc private func selectPage(")
assert "pageContentOffsets[selectedPage] = content.contentOffset" in page
assert "rebuildMenu(preservingCurrentOffset: false)" in page
scroll = body(menu, "func handleHostedControl(")
assert "if entry.action == .contentScroll { pageContentOffsets[selectedPage] = desired }" in scroll
assert "if phase == .began { hostedPointerID = identifier }" in scroll
assert "if homeStatusNeedsRebuild && hostedPointerID == nil" in scroll

end_gate = body(host, "- (void)handleHostedPointer:")
assert "![self hasHostedRegistrationReceipt]" in end_gate
assert "!self.crossApplicationHosted" not in end_gate
fresh = body(host, "- (BOOL)hasHostedRegistrationReceipt")
assert "_hostedReadbackGeneration == self.generation" in fresh
assert "[_adapter localSurfacesStillPublished]" in fresh
assert "age >= 0" not in fresh
assert "_hostedReadbackTimer" not in host
invalidate = body(host, "- (void)invalidateFrames")
assert "[self requestHostedReadback]" not in invalidate
assert "[self failClosedHostedInput]" in end_gate
assert "[self requestHostedReadback]" not in end_gate
readback = body(adapter[adapter.index("@implementation CoreSetRemoteHostingAdapter {"):],
                "- (void)observeBothSurfacesAsync:")
assert "[self localSideObserved:menu]" in readback
assert "dispatch_async(_readbackQueue" in readback
assert "[self remoteSideObserved:menu]" in readback
assert "dispatch_async(dispatch_get_main_queue()" in readback
status = body(owner, "private func publishStatus()")
assert "host.hostedRegistrationReceipt" in status
assert "host.crossApplicationHosted" not in status
select_backend = body(host, "- (void)selectBackend")
assert "self.hostedRegistrationReceipt" in select_backend
assert "self.crossApplicationHosted" not in select_backend
remote_adapter = adapter[adapter.index("@implementation CoreSetRemoteHostingAdapter {"):]
prepare = body(remote_adapter, "- (void)prepareForHostGeneration:")
assert "self.bothSurfacesObserved" not in prepare
assert "self.localSurfacesStillPublished" in prepare
assert "age <= 3.5" not in prepare
assert "_pendingHostGeneration = generation" in prepare
assert "confirmHostedReadbackAsync" in owner
assert "case UIInterfaceOrientationLandscapeLeft: return (CGFloat)-M_PI_2" in host
assert "case UIInterfaceOrientationLandscapeRight: return (CGFloat)M_PI_2" in host
assert "? CGRectMake(0, 0, bounds.size.height, bounds.size.width) : bounds" in host
assert "menuWindowPointFromFixedSurface" in host
assert "fromCoordinateSpace:_menuWindow.windowScene.screen.fixedCoordinateSpace" in host
orientation = body(host, "- (void)applyHostedOrientation:")
assert "[self invalidateFrames]" not in orientation
assert "[_layers clear]; [_metal clear]" in orientation
assert "[CATransaction flush]" in orientation
geometry = body(owner, "func invalidateGeometry()")
assert "nextSequence =" not in geometry
assert "!CGSizeEqualToSize(frame.canvasSize, host.logicalCanvasSize)" in host
assert "+ (BOOL)_isSystemWindow { return YES; }" in host
assert "- (BOOL)_ignoresHitTest { return self.backgroundPassThrough; }" in host
assert "_menuWindow.userInteractionEnabled = YES" in host
assert "CGRectInset(" in body(host, "- (void)layoutSurfaces")
ax_callback = body(host[host.index("@implementation CoreSetHUDHost {") :],
                   "- (void)receiveHostedHIDEvent:")
for reason in ("hand-missing", "paths-missing", "exception"):
    assert f'CoreSetLogAXDrop("{reason}"' in ax_callback
assert "reason=factory-nil count=%llu eventType=%u children=%ld digitizerChildren=%llu" in ax_callback
assert "IOHIDEventGetChildren" in host and "ax-child-recover" in ax_callback
assert 'stage=ax-drop reason=%s count=%llu' in host
assert not re.search(r"NSLog\([^;]*point\.[xy]", ax_callback, re.S)
assert "[self invalidatePendingTouchActions]" in ax_callback
assert "_pendingTouchActions.enqueue" in ax_callback
assert "_pendingTouchSerialQueue" in ax_callback


def check_pending_invalidation(source: str) -> None:
    invalidation = body(source, "- (void)invalidatePendingTouchActions")
    assert invalidation.index("_pendingTouchGeneration.fetch_add(1)") < invalidation.index(
        "dispatch_async(_pendingTouchSerialQueue"
    )
    assert invalidation.index("_pendingTouchActions.reset(next)") < invalidation.index(
        "dispatch_async(dispatch_get_main_queue()"
    ) < invalidation.index("[current resetHostedPointer]")
    assert invalidation.index("next != host->_pendingTouchGeneration.load()") < invalidation.index(
        "_pendingTouchActions.reset(next)"
    )
    assert "next == current->_pendingTouchGeneration.load()" in invalidation
    callback = body(source[source.index("@implementation CoreSetHUDHost {"):],
                    "- (void)receiveHostedHIDEvent:")
    assert "^{ [self resetHostedPointer]; }" not in callback


implementation = host[host.index("@implementation CoreSetHUDHost {"):]
check_pending_invalidation(implementation)
for missing_gate in ("next == current->_pendingTouchGeneration.load()",
                     "next != host->_pendingTouchGeneration.load()",
                     "_pendingTouchActions.reset(next)"):
    try:
        check_pending_invalidation(implementation.replace(missing_gate, "REMOVED_GATE"))
    except (AssertionError, ValueError):
        pass
    else:
        raise AssertionError("pending cancellation negative control accepted: " + missing_gate)

drain = body(implementation, "- (void)drainPendingTouchActionsOnQueue")
assert "if (expired && generation == host->_pendingTouchGeneration.load())" in drain
assert drain.index("if (expired && generation == host->_pendingTouchGeneration.load())") < drain.index(
    "host->_pendingTouchActions.discardAll()"
)

assert "CoreSetHostedInputCalibration" not in host
assert "IOHIDEventGetTimeStamp" not in host
assert "BKSHIDEventRegisterEventCallback" in body(
    host[host.index("@implementation CoreSetHUDHost {"):], "- (BOOL)startInputMonitor")
monitor = body(host[host.index("@implementation CoreSetHUDHost {"):],
               "- (BOOL)startInputMonitor")
assert "if (create && reg && schedule)" in monitor
assert "&& canUnschedule" not in monitor
assert "gCoreSetDormantHIDClient" in monitor
assert 'provider=%s type=%u' in ax_callback
assert 'vendor=%llu digitizer=%llu other=%llu' in ax_callback
assert 'cleanupCapable=%d' in ax_callback
active = body(host, "- (void)setApplicationActive:")
assert "[self disarmHostedInput]" not in active
assert "[self invalidateFrames]" in active
assert "[self setPanelVisible:NO]" not in active, "WZ preserves panel visibility across app switch"
toggle = body(host, "- (void)togglePanel")
assert "reason=remote-UIKit-panel-toggle" not in toggle
assert "[self togglePanelFromHostedPointer]" in toggle
assert "source=UIKit control=host.floating" in toggle
assert "usesDirectSourceInteraction" not in body(host, "- (void)dragFloating:")
assert "source=UIKit control=host.floating phase=%ld" in body(host, "- (void)dragFloating:")
assert "stage=dispatch source=HID control=%@" in end_gate
assert "[self togglePanelFromHostedPointer]" in end_gate
assert "[self disarmHostedInput]" in body(host, "- (CoreSetHUDStopResult)stop") or \
       "[self disarmHostedInput]" in body(host, "- (void)stopHostedAsync:")
assert ax_callback.index("if (paths.count != 1)") < ax_callback.index("_pendingTouchActions.enqueue")
assert ax_callback.index('CoreSetLogAXDrop("phase-missing"') < ax_callback.index("_pendingTouchActions.enqueue")
assert "CoreSetDrawWindow" in host and "CoreSetMenuWindow" in host
assert "CoreSetMirroredMenuWindow" not in host
assert "foregroundTouchCalibrationReady" not in host
forced_readback = body(host, "- (void)confirmHostedReadbackAsync:")
assert "[self requestHostedReadback]" in forced_readback
assert "if ([self hasFreshHostedReadback]) { completion(YES)" not in forced_readback
assert "host.renderGeneration" in owner
assert "self.renderGeneration = CoreSetHUDNextGeneration(self.renderGeneration)" in orientation
assert "_lastSequence = 0; _lastConsumedSequence = 0" in orientation
assert "host.setApplicationActive(true)" in body(owner, "func activate()")
assert "host.stopHostedAsync" not in body(owner, "func activate()")
assert "host.stopHostedAsync" in body(owner, "private func rollbackGameLaunch(")
assert "host.stop()" not in body(owner, "private func rollbackGameLaunch(")
assert "unregisterBothSurfacesAsync" in adapter
assert "dispatch_async(_readbackQueue" in body(remote_adapter, "- (void)unregisterBothSurfacesAsync:")
registration = body(remote_adapter, "- (void)registerBothSurfacesAsync:")
assert registration.index("menuWindow.bounds") < registration.index("dispatch_async(_readbackQueue")
assert registration.index("drawWindow.bounds") < registration.index("dispatch_async(_readbackQueue")
assert registration.index('NSSelectorFromString(@"_contextId")') < registration.index("dispatch_async(_readbackQueue")
remote_work = registration[registration.index("dispatch_async(_readbackQueue"):]
assert "source.bounds" not in remote_work and 'NSSelectorFromString(@"_contextId")' not in remote_work
create_side = body(adapter, "- (BOOL)createSide:")
assert "side.sourceFrame" in create_side and "side.source.bounds" not in create_side
assert "[self remoteSideObserved:side]" in create_side and "[self localSideObserved:side]" not in create_side
assert "@synchronized" not in body(adapter, "- (BOOL)cleanupPending")
assert "@synchronized" not in body(adapter, "- (NSString *)hostingDiagnosticSnapshot")
stop_host = body(host, "- (CoreSetHUDStopResult)stop")
assert "[self stopHostedAsync:" in stop_host and "unregisterWindow:" not in stop_host
assert "host.stopHostedAsync" in body(owner, "func stop()")
launch = body(owner, "func launchGame(")
assert "foregroundInputProbeConfirmed" not in launch
open_game = body(owner, "private func showHostedMenuAndOpenGame(")
assert "let inputArmed = self.host.armHostedInput()" in open_game
assert "guard self.host.armHostedInput()" not in open_game
exit_hud = body(owner, "private func exitHostedHUD()")
for gate in ("suspendGameConsumers", "suspendMenuHostConsumer", "host.cleanupPending",
             "installRemoteHostingAdapter(nil)", "remoteCleanupFailed = true"):
    assert gate in exit_hud
assert "case .exitHUD" in menu and "onExitHUD()" in menu
release = body(owner, "private func releaseStoppedOwnerIfReady()")
assert "stopChannelsConfirmed" in release and "stopWindowsConfirmed" in release
assert "Self.retained.removeValue" in release

radar = body(menu, "private func refreshRadarRangeRows()")
assert "featureState.radar.desired.placement.canvas" in radar
assert "radarRangeCanvas != canvas" in radar
assert "hostedMenuRevision &+= 1" in radar
sync_radar = body(menu, "func syncRadarCanvas(")
assert "featureState.radar.updateDesired { $0.placement.refreshCanvas(canvas) }" in sync_radar
assert "self.featureState.radar.actual != self.featureState.radar.desired" in sync_radar
assert "self.applyGame(\\.radar)" in sync_radar
host_changed = body(owner, "private func hostChanged()")
assert "if let canvas = playerCanvas { menu.syncRadarCanvas(canvas.size) }" in host_changed
assert "frameComposer.invalidateGeometry()" in host_changed
assert "let canvas = coordinator?.playerCanvas" in radar_consumer
assert "center.x + r <= size.width, center.y + r <= size.height" in radar_consumer
# The same portrait surface (390 x 844) becomes an 844 x 390 logical radar
# canvas after quarter turn. X and Y legal ranges must therefore exchange.
def placement_bounds(width: int, height: int, radius: int) -> tuple[tuple[int, int], tuple[int, int]]:
    return (radius, width - radius), (radius, height - radius)


assert placement_bounds(390, 844, 50) == ((50, 340), (50, 794))
assert placement_bounds(844, 390, 50) == ((50, 794), (50, 340))

assert not re.search(r"sendActions\s*\(", menu), "hosted input must use explicit consumers"


def check_hosted_input_diagnostics(source: str) -> None:
    implementation = source[source.index("@implementation CoreSetHUDHost {"):]
    logger = body(source, "static void CoreSetLogInputStage(")
    assert "counter->fetch_add(1)" in logger
    assert "if (CoreSetInputLogDue(count))" in logger
    assert "phase=%ld control=%@ result=%ld" in logger
    assert "point.x" not in logger and "point.y" not in logger
    assert "count == 1 || count % 64 == 0" in body(source, "static BOOL CoreSetInputLogDue(")
    callback = body(implementation, "- (void)receiveHostedHIDEvent:")
    assert "stage=event count=%llu provider=%s" in callback
    assert "typeKnown=%d" in callback and "eventType != UINT32_MAX" in callback
    assert "const uint32_t eventType = _hidEventGetType" in callback
    assert "(!_bkInputRegistered && _hidEventGetType)" not in callback
    assert "stage=wrapper count=%llu provider=%s" in callback
    assert "rootAX=%d rootHand=%d" in callback
    assert "selectedDepth=%lu selectedType=%u maxDepth=%lu truncated=%d" in callback
    assert "constexpr NSUInteger nodeLimit = 64, depthLimit = 4" in callback
    assert "const CFIndex boundedCount = MIN(count, (CFIndex)nodeLimit)" in callback
    assert "nodes[visited].event == child" in callback
    assert "if (node.depth >= depthLimit && count > 0)" in callback
    assert "if (nodeCount == nodeLimit)" in callback
    for reason in ("wrapper-scan-limit", "wrapper-multiple-pointers"):
        assert f'CoreSetLogAXDrop("{reason}"' in callback
    assert callback.index("if (candidatePointers.count > 1)") < callback.index(
        "_pendingTouchActions.enqueue"
    )
    assert "IOHIDEventGetParent" not in source and "IOHIDEventGetTypeID" not in source
    assert "_inputCounts.parseDropped.fetch_add(1)" in callback
    for reason in ("paths-empty", "multiple-paths", "reserved-pointer", "phase-missing",
                   "nonfinite-point", "physical-cancel"):
        assert f'CoreSetLogAXDrop("{reason}"' in callback
    assert 'CoreSetLogInputStage("queue"' in callback
    assert "accepted ? &host->_inputCounts.queued : &host->_inputCounts.queueDropped" in callback
    assert "queueGeneration == current->_pendingTouchGeneration.load()" in callback
    expiry_reset = callback.index("if (result == coreset_pending_touch::EnqueueResult::AppendedAfterDroppingLifecycle)")
    assert expiry_reset < callback.index("[current resetHostedPointer]", expiry_reset) < callback.index(
        "[host drainPendingTouchActionsOnQueue]", expiry_reset
    )
    drain = body(implementation, "- (void)drainPendingTouchActionsOnQueue")
    assert 'CoreSetLogInputStage("delivery", "main-action"' in drain
    assert 'CoreSetLogInputStage("delivery", reason' in drain
    pointer = body(implementation, "- (void)handleHostedPointer:")
    for reason in ("host-not-interactive", "readback-pending", "source-context-unavailable",
                   "control-changed-at-end"):
        assert f'CoreSetLogInputStage("hit", "{reason}"' in pointer
    assert 'CoreSetLogInputStage("hit", missReason' in pointer
    hit_test = body(implementation, "- (NSString *)hostedControlIDAtSurfacePoint:")
    for reason in ("no-eligible-control", "outside-fixed-surface", "modal-presented",
                   "panel-hidden-or-consumer-unavailable"):
        assert f'"{reason}"' in hit_test
    coordinate = body(implementation, "- (CGPoint)menuWindowPointFromFixedSurface:")
    assert "stage=coordinate count=%llu generation=%llu mapping=screen-fixed" in coordinate
    assert "if (CoreSetInputLogDue(count))" in coordinate
    assert "fixedInside=%d sceneInside=%d nativeInside=%d unitRange=%d menuInside=%d" in coordinate
    assert "fromCoordinateSpace:_menuWindow.windowScene.screen.fixedCoordinateSpace" in coordinate
    assert 'CoreSetLogInputStage("hit", "control-matched"' in pointer
    assert pointer.index('CoreSetLogInputStage("hit", "control-matched"') < pointer.index(
        "(void)[self dispatchHostedMenuControl:identifier"
    )
    assert "if (CoreSetInputLogDue(dispatchCount))" in pointer
    assert pointer.index("action=begin generation=%llu") < pointer.index(
        "dispatched = [self dispatchHostedMenuControl:identifier"
    )
    consumer_callback = body(implementation, "- (BOOL)dispatchHostedMenuControl:")
    assert consumer_callback.index("const uint64_t generation = self.generation") < consumer_callback.index(
        "handleHostedControlID:"
    )
    assert consumer_callback.index("handleHostedControlID:") < consumer_callback.index(
        'CoreSetLogInputStage("callback", "menu-return"'
    )
    assert "return handled" in consumer_callback
    arm = body(implementation, "- (BOOL)armHostedInput")
    assert 'CoreSetLogInputStage("source"' in arm
    readback = body(implementation, "- (void)requestHostedReadback")
    assert "if (CoreSetInputLogDue(readbackCount))" in readback
    assert 'CoreSetLogInputStage("readback", "stale-epoch"' in readback
    assert "stage=readback observed=%d" in readback
    snapshot = body(implementation, "- (NSString *)hostingDiagnosticSnapshot")
    for counter in ("event", "wrapper", "wrapperIncomplete", "parsed", "parseDropped", "queued", "queueDropped", "delivered",
                    "deliveryDropped", "coordinate", "coordinateDropped", "hit", "hitDropped", "dispatched", "callback",
                    "callbackHandled", "readback", "readbackDropped"):
        assert f"{counter}=%llu" in snapshot
    monitor = body(implementation, "- (BOOL)startInputMonitor")
    assert "stage=source-api count=%llu callbackABI=WZ-IOHIDEventRef" in monitor
    assert "[axClass methodSignatureForSelector:factory]" in monitor
    assert "eventArgument=%s streamArgument=%s returnArgument=%s" in monitor
    assert monitor.index("if (registerBK)") < monitor.index("if (create && reg && schedule)")
    assert "WZ's install_hid_monitor_main tries IOHID first and BKSHID as fallback" in monitor


check_hosted_input_diagnostics(host)
for required in ('CoreSetLogInputStage("queue"', 'CoreSetLogInputStage("delivery", "main-action"',
                 'CoreSetLogInputStage("hit", "control-matched"',
                 'CoreSetLogInputStage("callback", "menu-return"',
                 "if (CoreSetInputLogDue(readbackCount))",
                 "if (candidatePointers.count > 1)", "nodes[visited].event == child",
                 "queueGeneration == current->_pendingTouchGeneration.load()"):
    try:
        check_hosted_input_diagnostics(host.replace(required, "REMOVED_DIAGNOSTIC"))
    except (AssertionError, ValueError):
        pass
    else:
        raise AssertionError("input diagnostics negative control accepted: " + required)

print("PASS: hosted gesture survives unrelated samples and frames, keeps page scroll, gates stale readback; source only")
print("PASS: source/event/AX/queue/delivery/hit/dispatch/callback/readback counters and throttled diagnostics; source only")
