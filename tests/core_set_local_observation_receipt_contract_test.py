"""Local observation source/negative contracts; not native UIKit/Metal execution."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def body(source, signature):
    begin = source.index("{", source.index(signature) + len(signature)); end = begin + 1; depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}"); end += 1
    return source[begin + 1:end - 1]


def require_palette_receipt(source):
    apply = body(source, "func apply(_ request:")
    assert "let generation = host.generation" in apply
    assert "matches(request.desired, generation: generation)" in apply
    assert "appliedToken = request.token" in apply
    match = body(source, "private func matches(")
    assert "host.generation == generation" in match and "host.floatingControlReady" in match
    assert "zip(observed, expected)" in match and "host.panelVisible == state.menuVisible" in match


class LocalObservationReceiptContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        read = lambda path: (ROOT / path).read_text(encoding="utf-8")
        cls.coordinator = read("lara/views/app/CoreSetRuntimeCoordinator.swift")
        cls.host_consumer = cls.coordinator.split("private final class CoreSetLocalHostConsumer", 1)[1]
        cls.menu = read("lara/views/app/CoreSetMenuViewController.swift")
        cls.state = read("lara/views/app/CoreSetFeatureState.swift")
        cls.home = read("lara/views/app/CoreSetHomeTelemetrySource.swift")
        cls.host = read("lara/overlay/CoreSetHUDHost.mm")
        cls.metal = read("lara/overlay/CoreSetMetalRenderAdapter.mm")
        cls.window = read("lara/overlay/CoreSetPresentationCadence.h")

    def test_real_palette_float_bits_and_exact_live_owner(self):
        require_palette_receipt(self.host_consumer)
        colors = body(self.host_consumer, "private func colors(")
        self.assertIn("palette.referenceColors", colors)
        self.assertNotIn("/ 255", colors)
        observe = body(self.host, "- (NSArray<UIColor *> *)observedFloatingColors")
        for gate in ("self.floatingControlReady", "_floatingGradient.colors"):
            self.assertIn(gate, observe)

    def test_palette_negative_generation_and_model_only_mutants(self):
        for marker in ("host.generation == generation", "host.floatingControlReady", "matches(request.desired, generation: generation)"):
            with self.assertRaises(AssertionError):
                require_palette_receipt(self.host_consumer.replace(marker, "true"))

    def test_palette_pending_receipts_and_stop_obligation(self):
        self.assertIn("let hostedSource = interactionControlIdentifier", body(self.menu, "func applyHostSettings(completion: @escaping (Bool) -> Void = { _ in })"))
        current = body(self.menu, "func menuHostRequestIsCurrent(")
        self.assertIn("lastHostAppliedToken == token", current)
        inspect = body(self.menu, "func menuHostObservationMayBeRefreshed(")
        self.assertIn("pendingApply == nil", inspect); self.assertIn("pendingStop == nil", inspect)
        refresh = body(self.host_consumer, "func refreshObservation(")
        self.assertIn("canInspect(token)", refresh)
        invalidation = body(self.state, "func invalidateHostPresentationObservation(")
        self.assertLess(invalidation.index("actual = nil"), invalidation.index("guard pendingStop == nil"))
        self.assertNotIn("mayHaveEffects = false", invalidation)
        self.assertNotIn("restoration =", invalidation)
        stop = body(self.host_consumer, "func stop(")
        self.assertIn("!host.floatingControlReady", stop)
        self.assertIn("host.observedFloatingColors.isEmpty", stop)
        self.assertIn("persisted-palette-retained=1", stop)

    def test_actual_present_timestamps_not_requested_or_completed_time(self):
        render = body(self.metal, "- (void)drawInMTKView:")
        self.assertIn("addPresentedHandler", render)
        self.assertIn("drawableValue.presentedTime", render)
        self.assertIn("accept(presentationEpoch, presented, CACurrentMediaTime())", render)
        self.assertLess(render.index("addPresentedHandler"), render.index("[buffer presentDrawable:"))
        observation = body(self.metal, "- (CoreSetPresentationCadenceSample)observedPresentationCadence")
        self.assertNotIn("preferredFramesPerSecond", observation)
        self.assertIn("_presentationCadence.observe", observation)
        for gate in ("epoch != epoch_", "presented <= 0", "now - presented > .5", "presented <= times_[count_ - 1]"):
            self.assertIn(gate, self.window)

    def test_present_window_lifecycle_and_host_identity(self):
        for signature in ("- (void)clear", "- (void)setVisible:", "- (BOOL)setPreferredRenderFPS:"):
            self.assertIn("_presentationCadence.reset()", body(self.metal, signature))
        observe = body(self.coordinator, "var presentedFrameObservation:")
        for gate in ("sample.valid", "host.generation == generation", "host.renderGeneration == renderGeneration"):
            self.assertIn(gate, observe)
        self.assertIn("requested-fps-input=0", self.menu)
        self.assertNotIn(".applied(", body(self.menu, "func updatePresentedFrameObservation("))

    def test_home_real_sources_and_missing_original_fields(self):
        runtime = body(self.home.split("final class CoreSetLaraHomeRuntimeObservationProvider", 1)[1], "func readObservation(hostGeneration:")
        for source in ("ds_is_ready()", "laramgr.shared", "manager.dsrunning", "manager.dsready", "manager.dsfailed"):
            self.assertIn(source, runtime)
        capture = body(self.home, "func capture(")
        for forbidden in ("targetReadReady ?", "nativeReady ?", 'stage = manager.dsrunning'):
            self.assertNotIn(forbidden, capture)
        for missing in ("v17-005", "v17-006", "v17-008", "v17-009", "v17-010"):
            self.assertIn(missing, capture)
        self.assertIn("protocol CoreSetHomeReferenceObservationProvider: AnyObject", self.home)
        self.assertIn("completedPages: nil, totalPages: nil", capture)
        self.assertIn("downloadedBytes: nil, totalBytes: nil", capture)

    def test_home_epoch_sequence_generation_and_stop(self):
        capture = body(self.home, "func capture(")
        for gate in ("identity.observerEpoch == provider.observerEpoch", "identity.hostGeneration == hostGeneration",
                     "identity.sequence > $0.sequence", "age >= 0", "age <= 5",
                     "value.currentGeneration == referenceGenerations[field]",
                     "value.nativeSequence >= (referenceNativeSequences[field] ?? 0)"):
            self.assertIn(gate, capture)
        menu = body(self.menu, "func updateRuntimeObservations(")
        self.assertIn("identity.hostGeneration == expectedHostGeneration", menu)
        self.assertIn("identity.sequence > (old?.sequence ?? 0)", menu)
        self.assertIn("referenceProvider = nil", body(self.home, "func stopObservations()"))
        self.assertIn("referenceProvider?.stopObservation()", body(self.home, "func stopObservations()"))
        self.assertIn("observation-owner-stopped", body(self.home, "func recordProducerProbeEvent("))
        stop = body(self.coordinator, "func stop()")
        self.assertIn("observationTimer?.cancel()", stop)
        self.assertIn("homeTelemetry.stopObservations()", stop)


if __name__ == "__main__":
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(LocalObservationReceiptContract))
    if not result.wasSuccessful(): raise SystemExit(1)
    print("LIMIT: source contracts only; no Swift/UIKit/Metal execution or device receipt")
