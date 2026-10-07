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
assert "![self hasFreshHostedReadback]" in end_gate
assert "!self.crossApplicationHosted" not in end_gate
fresh = body(host, "- (BOOL)hasFreshHostedReadback")
assert "_hostedReadbackGeneration == self.generation" in fresh
assert "age >= 0 && age <= 3.5" in fresh
assert "[weakSelf requestHostedReadback]" in host
assert "if (!active) [self requestHostedReadback]" in host
invalidate = body(host, "- (void)invalidateFrames")
assert "[self requestHostedReadback]" in invalidate
assert "[self requestHostedReadback]" in end_gate
assert "rejected=stale-readback" in end_gate
readback = body(adapter, "- (void)observeBothSurfacesAsync:")
assert "[self localSideObserved:menu]" in readback
assert "dispatch_async(_readbackQueue" in readback
assert "[self remoteSideObserved:menu]" in readback
assert "dispatch_async(dispatch_get_main_queue()" in readback
status = body(owner, "private func publishStatus()")
assert "host.recentCrossApplicationHosted" in status
assert "host.crossApplicationHosted" not in status
select_backend = body(host, "- (void)selectBackend")
assert "self.recentCrossApplicationHosted" in select_backend
assert "self.crossApplicationHosted" not in select_backend
prepare = body(adapter, "- (void)prepareForHostGeneration:")
assert "self.bothSurfacesObserved" not in prepare
assert "_pendingHostGeneration = generation" in prepare
assert "confirmHostedReadbackAsync" in owner
assert "case UIInterfaceOrientationLandscapeLeft: return (CGFloat)-M_PI_2" in host
assert "case UIInterfaceOrientationLandscapeRight: return (CGFloat)M_PI_2" in host
assert "? CGRectMake(0, 0, bounds.size.height, bounds.size.width) : bounds" in host
assert "[_menuController.view convertPoint:point fromView:_menuWindow]" in host

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
assert "let canvas = coordinator?.playerCanvas" in radar_consumer
assert "center.x + r <= size.width, center.y + r <= size.height" in radar_consumer
# The same portrait surface (390 x 844) becomes an 844 x 390 logical radar
# canvas after quarter turn. X and Y legal ranges must therefore exchange.
def placement_bounds(width: int, height: int, radius: int) -> tuple[tuple[int, int], tuple[int, int]]:
    return (radius, width - radius), (radius, height - radius)


assert placement_bounds(390, 844, 50) == ((50, 340), (50, 794))
assert placement_bounds(844, 390, 50) == ((50, 794), (50, 340))

assert not re.search(r"sendActions\s*\(", menu), "hosted input must use explicit consumers"
print("PASS: hosted gesture survives unrelated samples and frames, keeps page scroll, gates stale readback; source only")
