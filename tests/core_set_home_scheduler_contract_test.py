"""Home diagnostic / scheduler source contracts plus optional original byte replay.

No Swift/UIKit execution. Probe replays the external IPA in memory and never
executes it. Negative controls mutate strings/dicts only, not repository files.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]


def body(source, anchor):
    start = source.index("{", source.index(anchor))
    depth = 1
    end = start + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start + 1:end - 1]


def scheduler_contract(source):
    apply = body(source, "func apply(")
    assert "observed.hostGeneration == before.hostGeneration" in apply
    assert "observed.preferredFramesPerSecond == value" in apply
    assert apply.index("coordinator?.applyFrameRate(value)") < apply.index(".applied(observed:")
    refresh = body(source, "func refreshSchedulerObservation()")
    for gate in ("channel.pendingApply == nil", "channel.pendingStop == nil", "channel.generation == token.generation"):
        assert gate in refresh
    assert refresh.index("current != expected") < refresh.index("invalidateFrameRateObservation(reason:")
    assert "measured-presentation-fps=0" in source


class HomeSchedulerContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.frame = (ROOT / "lara/views/app/CoreSetFrameRateConsumer.swift").read_text(encoding="utf-8")
        cls.state = (ROOT / "lara/views/app/CoreSetFeatureState.swift").read_text(encoding="utf-8")
        cls.menu = (ROOT / "lara/views/app/CoreSetMenuViewController.swift").read_text(encoding="utf-8")
        cls.coordinator = (ROOT / "lara/views/app/CoreSetRuntimeCoordinator.swift").read_text(encoding="utf-8")
        cls.telemetry = (ROOT / "lara/views/app/CoreSetHomeTelemetrySource.swift").read_text(encoding="utf-8")

    def test_exact_active_metal_readback_and_generation(self):
        scheduler_contract(self.frame)
        observation = body(self.coordinator, "var frameRateObservation:")
        for gate in ("host.renderFPSControlReady", "host.activeBackend == CoreSetHUDBackendMetal",
                     "host.generation == generation", "host.observedRenderFPS()"):
            self.assertIn(gate, observation)
        self.assertIn("frameRateConsumer?.refreshSchedulerObservation()", body(self.coordinator, "func publishStatus()"))

    def test_scheduler_invalidation_does_not_forgive_stop(self):
        invalidate = body(self.state, "func invalidateSchedulerObservation(reason:")
        self.assertLess(invalidate.index("actual = nil"), invalidate.index("guard pendingStop == nil"))
        self.assertLess(invalidate.index("guard pendingStop == nil"), invalidate.index("generation = UUID()"))
        self.assertNotIn("mayHaveEffects = false", invalidate)
        self.assertNotIn("restoration =", invalidate)
        stop = body(self.frame, "func stop(")
        self.assertLess(stop.index("restoreFrameRate() == true"), stop.index(".restored"))
        self.assertIn(".failed(reason:", stop)

    def test_mutations_cannot_drop_generation_or_pending_stop(self):
        for marker in ("observed.hostGeneration == before.hostGeneration", "channel.pendingStop == nil"):
            with self.assertRaises(AssertionError):
                scheduler_contract(self.frame.replace(marker, "true"))

    def test_real_adapter_property_not_cached_requested_or_measured_rate(self):
        adapter = (ROOT / "lara/overlay/CoreSetMetalRenderAdapter.mm").read_text(encoding="utf-8")
        observe = body(adapter, "- (NSInteger)observedRenderFPS")
        self.assertIn("return _metalView.preferredFramesPerSecond", observe)
        self.assertNotIn("return _requestedFPS", observe)
        self.assertIn("_lastDrawSucceeded", observe)
        self.assertIn("Metal调度器参数回读；非实测呈现FPS", self.menu)

    def test_six_home_points_have_typed_diagnostic_boundary_only(self):
        for number in (0, 1, 2, 3, 9, 10):
            self.assertRegex(self.telemetry, rf"\b\w+ = {number}\b")
        record = body(self.telemetry, "func recordProducerProbeEvent(")
        for field in ("producerEpoch", "requestID", "sequence", "observedAt", "requestedOption", "observedStatus",
                      "nativeGeneration", "inFlight", "ready", "completedCount", "totalCount", "errorCode"):
            self.assertIn(field, record)
        self.assertIn("confirmed=0 scope=diagnostic-only v17-effect-verified=0", record)
        self.assertNotIn("updateDesired", record)
        self.assertNotIn(".applied(", record)
        self.assertNotIn("snapshot", record)
        self.assertIn("homeTelemetry.recordProducerProbeEvent(event)", self.coordinator)

    def test_probe_rejects_stale_sequence_bad_counts_and_false_completion(self):
        record = body(self.telemetry, "func recordProducerProbeEvent(")
        for gate in ("age >= 0", "age <= 5", "event.sequence > previous.sequence", "event.phase.canFollow(previous.phase)",
                     "total > 0", "completed <= total", "new < old", "new != old",
                     "event.errorCode == nil", "completed == event.totalCount"):
            self.assertIn(gate, record)
        phases = body(self.telemetry, "func canFollow(")
        self.assertIn("case .stopped, .refused: return false", phases)
        self.assertIn("case .stopping: return [.stopped, .stopFailed].contains(self)", phases)
        self.assertIn("case .stopFailed: return self == .stopping", phases)
        for reason in ("stale-or-future-observation", "invalid-option-for-point", "invalid-count-pair-or-unit-scope",
                       "failure-without-error-code", "completed-without-exact-total", "stale-sequence-or-invalid-transition",
                       "count-regressed", "denominator-changed", "new-request-must-start-requested-or-refused"):
            self.assertIn(reason, record)
        self.assertIn("native-generation-changed-within-request", record)
        self.assertIn("requested-option-changed-within-request", record)
        self.assertIn("event.point == .firmwareProgress", record)
        self.assertIn("[.cancelled, .stopping, .stopped].contains(event.phase)", record)
        self.assertIn("old < UInt64.max && new == old + 1", record)

    def test_home_refusals_preserve_option_and_no_action_execution(self):
        refuse = body(self.menu, "func explainUnavailable(")
        self.assertIn("onHomeProbeRefusal?(point", refuse)
        self.assertNotIn("updateDesired", refuse)
        self.assertNotIn(".run(", refuse)
        self.assertIn("info.tag = child.tag", self.menu)
        self.assertIn("core-set.0.v17-001.option", self.menu)
        self.assertIn("core-set.0.v17-000.option", self.menu)

    def test_progress_never_substitutes_dark_sword_or_file_copy(self):
        capture = body(self.telemetry, "func capture(")
        self.assertIn("completedPages: nil, totalPages: nil", capture)
        self.assertIn("downloadedBytes: nil, totalBytes: nil", capture)
        self.assertIn("producer=unbound confirmed=0 required=%@ scope=reference-contract", capture)
        self.assertNotIn("fetchkcache", capture)
        provider = body(self.telemetry.split("final class CoreSetLaraHomeRuntimeObservationProvider", 1)[1], "func readObservation(hostGeneration:")
        self.assertIn("running && progress.isFinite", provider)
        self.assertIn("let kernelProgress = runtime.kernelProgress", capture)

    def test_137_matrix_links_executable_home_probe_without_closure_credit(self):
        matrix = json.loads((ROOT / "tests/fixtures/core_set_v17_menu_point_map.json").read_text(encoding="utf-8"))
        probe = matrix["reference"]["home_producer_probe"]
        self.assertEqual(probe["points"], ["v17-000", "v17-001", "v17-002", "v17-003", "v17-009", "v17-010", "v17-029"])
        self.assertFalse(probe["original_runtime_receipt_verified"])
        self.assertTrue((ROOT / probe["tool"]).is_file())
        self.assertIn("same host generation", matrix["contracts"]["frame_rate"]["receipt"])
        self.assertIn("not measured", matrix["contracts"]["frame_rate"]["scope"])
        self.assertFalse(matrix["missing_observation_producers"]["v17-009"]["producer_available"])
        self.assertFalse(matrix["missing_observation_producers"]["v17-010"]["producer_available"])


def replay(path):
    sys.path.insert(0, str(ROOT / "tools"))
    from core_set_v17_function_chain_probe import CoreImage
    from core_set_v17_home_producer_probe import probe
    core = CoreImage(path)
    evidence = probe(core)
    assert evidence["point_ids"] == [f"v17-{point:03}" for point in range(11)]
    assert not evidence["original_runtime_verified"]
    names = {(method["class"], method["owner"], method["selector"]): method["implementation"]
             for method in evidence["objc_methods"]}
    assert names[("QXA107", "class", "qx327")] == "0x100009da8"
    assert names[("QXA107", "instance", "qx307:")] == "0x100009f68"
    assert names[("QXA105", "instance", "qx307:")] != names[("QXA107", "instance", "qx307:")]
    assert evidence["firmware_class_reference"]["class"] == "QXA107"
    provider_edges = {edge["stub"]: edge for edge in evidence["provider_selector_edges"]}
    download = provider_edges["0x10072c640"]
    assert download["selector"] == "qm571:fromURL:productType:buildVersion:boardConfig:client:generation:progress:error:"
    assert [site["address"] for site in download["direct_call_sites"]] == ["0x10000ff24"]
    assert len(provider_edges["0x10072c4a0"]["direct_call_sites"]) == 22
    for edge in provider_edges.values():
        for site in edge["direct_call_sites"]:
            word = site["instructions"][0]
            assert word["instruction"] == "bl #" + edge["stub"]
            assert core.raw(int(site["address"], 16), 4).hex() == word["bytes"]
    assert evidence["functions"]["firmware_workflow_block"]["entry"] == "0x10000f8f0"
    assert "digest only" in evidence["progress_sources"]["v17-010"]["next_capture"]
    assert evidence["status_semantics"]["v17-004"]["strings"] == ["未初始化", "初始化中", "初始化成功", "初始化失败", "初始化超时"]
    assert evidence["status_semantics"]["v17-005"]["strings"][:4] == ["正在联网适配", "环境已就绪", "环境适配失败", "等待授权后适配"]
    assert evidence["status_semantics"]["v17-007"]["strings"] == ["等待内核成功利用", "已开启全局悬浮"]
    assert "running alone is NOT" in evidence["status_semantics"]["v17-008"]["current"]
    selectors = {stub["stub"]: stub["selector"] for stub in evidence["selector_stubs"]}
    assert selectors == {"0x10072ce60": "qx327", "0x10072cda0": "qx307:",
                         "0x100729e80": "generation", "0x10072f780": "setGeneration:",
                         "0x10072ba80": "otaTotalBytes", "0x1007324e0": "snapshotBytes"}
    cover = evidence["functions"]["cover_update"]
    assert cover["first_return_site"] == "0x1000d3f24"
    assert [edge["site"] for edge in cover["calls_after_first_return_not_presumed_reachable"]] == [
        "0x1000d3f28", "0x1000d3f2c", "0x1000d3f30"]
    for function in evidence["functions"].values():
        assert not function["truncated"]
    for window in evidence["proof_windows"]:
        for instruction in window["instructions"]:
            assert core.raw(int(instruction["address"], 16), 4).hex() == instruction["bytes"]
    assert core.proof_window(0x10002fd60, 4)["instructions"][0]["instruction"] == "ldapr x9, [x8]"
    assert core.proof_window(0x10002fd6c, 4)["instructions"][0]["instruction"] == "ldapr x8, [x8]"
    assert core.proof_window(0x100033bf4, 4)["instructions"][0]["instruction"] == "stlr x9, [x8]"
    globals_seen = {candidate["global"] for candidate in evidence["global_reference_candidates"]}
    assert {"0x100c5839c", "0x100c583a0", "0x100c5829f", "0x100c20288", "0x100c20290"} <= globals_seen
    print(f"REPLAY: {len(evidence['functions'])} home roots, {len(evidence['proof_windows']) * 4} instruction words, "
          f"{len(evidence['global_reference_candidates'])} global reference candidates; original runtime closure=0")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--reference-ipa", type=Path)
    arguments = parser.parse_args()
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(HomeSchedulerContract)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if not result.wasSuccessful():
        raise SystemExit(1)
    if arguments.reference_ipa:
        replay(arguments.reference_ipa)
    else:
        print("SKIP: original sample replay needs --reference-ipa")
    print("LIMIT: source contracts/static replay only; no Swift/UIKit build, native action execution or device FPS measurement")
