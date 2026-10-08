"""Home diagnostic / scheduler source contracts plus optional original byte replay.

No Swift/UIKit execution. Probe replays the external IPA in memory and never
executes it. Negative controls mutate strings/dicts only, not repository files.
"""
from __future__ import annotations

import argparse
import hashlib
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

    def test_progress_requires_typed_owner_and_keeps_local_equivalent_scope(self):
        capture = body(self.telemetry, "func capture(")
        self.assertIn("completedPages: nil, totalPages: nil", capture)
        self.assertIn("downloadedBytes: nil, totalBytes: nil", capture)
        self.assertIn("value.snapshot.pageProgressState", capture)
        self.assertIn("value.snapshot.firmwareState", capture)
        self.assertIn('state.stage == "local-kernelcache-copy"', capture)
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
        gaps = matrix["original_observation_producer_gaps"]
        self.assertTrue(gaps["v17-009"]["local_equivalent_producer_available"])
        self.assertTrue(gaps["v17-010"]["local_equivalent_producer_available"])
        self.assertFalse(gaps["v17-009"]["original_producer_available"])
        self.assertFalse(gaps["v17-010"]["original_producer_available"])
        current = matrix["reference"]["home_current_caller_probe"]
        self.assertEqual(current["points"], [f"v17-{point:03}" for point in (0, 1, 2, 3, 5, 6, 8, 9, 10)])
        self.assertFalse(current["original_runtime_receipt_verified"])
        self.assertFalse(current["device_effect_verified"])
        for point in current["points"]:
            requirement = (matrix["downstream_requirements"] | matrix["original_observation_producer_gaps"])[point]
            self.assertTrue(requirement["current_caller_evidence"].startswith("home_current_caller_probe:") or
                            requirement["current_caller_evidence"].startswith("configureHome"))

    def test_current_callers_are_source_bound_not_an_external_library_claim(self):
        sys.path.insert(0, str(ROOT / "tools"))
        from core_set_v17_home_producer_probe import probe_current_repository
        evidence = probe_current_repository(ROOT)
        self.assertEqual({point["id"] for point in evidence["points"]},
                         {f"v17-{point:03}" for point in (0, 1, 2, 3, 5, 6, 8, 9, 10)})
        self.assertTrue(all(not point["producer_bound"] and not point["original_runtime_receipt_verified"]
                            for point in evidence["points"]))
        for source in evidence["source_manifest"]:
            current = (ROOT / source["source"]).read_text(encoding="utf-8")
            self.assertEqual(source["sha256_utf8_text"], hashlib.sha256(current.encode("utf-8")).hexdigest())
        for sites in evidence["caller_evidence"].values():
            for site in sites:
                lines = (ROOT / site["source"]).read_text(encoding="utf-8").splitlines()
                for line in site["lines"]:
                    self.assertIn(site["anchor"], lines[line - 1])
        self.assertEqual([hit["class"] for hit in evidence["provider_scan"]["conformers"]],
                         ["CoreSetHomeRuntimeProducer"])
        self.assertEqual(evidence["provider_scan"]["binding_calls"], [])
        self.assertEqual(evidence["provider_scan"]["home_consumer_bindings"], [])
        self.assertIn("homeTelemetry.bindReferenceObservationProvider(homeProducer)", self.coordinator)
        self.assertIn("NOT proof of absent internal functionality", evidence["external_partial"]["limit"])

    def test_current_quantities_remain_distinct_from_original_home_fields(self):
        sys.path.insert(0, str(ROOT / "tools"))
        from core_set_v17_home_producer_probe import probe_current_repository
        evidence = probe_current_repository(ROOT)
        points = {point["id"]: point for point in evidence["points"]}
        self.assertIn("20s stagnant counter", points["v17-002"]["missing_same_meaning_interface"])
        self.assertIn("609a8 tuple", points["v17-003"]["missing_same_meaning_interface"])
        self.assertIn("native-ready", points["v17-005"]["current_candidate"])
        self.assertIn("hasOffsets", points["v17-006"]["current_candidate"])
        self.assertIn("running is not stage", points["v17-008"]["missing_same_meaning_interface"])
        self.assertIn("PAGE counters", points["v17-009"]["missing_same_meaning_interface"])
        self.assertIn("same units", points["v17-010"]["missing_same_meaning_interface"])
        self.assertIn("decompressed length", points["v17-010"]["current_candidate"])
        self.assertIn("system OTA switch", points["v17-010"]["current_candidate"])
        self.assertEqual(points["v17-010"]["caller_evidence_keys"],
                         ["range_fetch", "kernel_cache_call", "local_copy", "ota_switch", "observation_boundary"])

    def test_source_probe_refuses_changed_call_chain_and_counter_substitution(self):
        sys.path.insert(0, str(ROOT / "tools"))
        from core_set_v17_home_producer_probe import CURRENT_SOURCES, current_source_evidence
        sources = {owner: (ROOT / path).read_text(encoding="utf-8") for owner, path in CURRENT_SOURCES.items()}
        for owner, old, new in (
            ("coordinator", "let loaded = fetched && dlkcache()", "let loaded = dlkcache()"),
            ("telemetry", "completedPages: nil, totalPages: nil", "completedPages: UInt64(progress), totalPages: 100"),
            ("telemetry", "downloadedBytes: nil, totalBytes: nil", "downloadedBytes: copiedBytes, totalBytes: copiedTotal"),
            ("partial", "[zip getFileForPath:entry error:&error]", "[zip fakeProgress]"),
            ("ota", "uint64_t remaining = outData.length;", "uint64_t remaining = firmwareBytes;")):
            mutated = sources | {owner: sources[owner].replace(old, new)}
            with self.assertRaises(ValueError, msg=owner + "/" + old):
                current_source_evidence(mutated, {}, False)

    def test_new_provider_candidate_never_automatically_claims_original_effect(self):
        sys.path.insert(0, str(ROOT / "tools"))
        from core_set_v17_home_producer_probe import CURRENT_SOURCES, current_source_evidence
        sources = {owner: (ROOT / path).read_text(encoding="utf-8") for owner, path in CURRENT_SOURCES.items()}
        candidate = """final class Candidate: NSObject, CoreSetHomeReferenceObservationProvider {
            func bindHomeReferenceObservationProvider(_ p: Provider) {}
            func start() { coordinator.bindHomeReferenceObservationProvider(self)
                menu.bindGameConsumer(self, to: \\.home) }
        }"""
        evidence = current_source_evidence(sources, {"candidate.swift": candidate}, False)
        scan = evidence["provider_scan"]
        self.assertEqual([hit["class"] for hit in scan["conformers"]], ["Candidate"])
        self.assertEqual(len(scan["binding_calls"]), 1)
        self.assertEqual(len(scan["home_consumer_bindings"]), 1)
        self.assertTrue(all(not point["producer_bound"] for point in evidence["points"]))


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
    lifecycle = evidence["action_lifecycle"]
    assert lifecycle["v17-002"]["watchdog_block"] == "0x100006938"
    assert core.proof_window(0x1000050d8, 4)["instructions"][0]["instruction"] == "add x16, x16, #0x938"
    assert core.proof_window(0x100005184, 4)["instructions"][0]["instruction"] == "add x16, x16, #0x3a4"
    assert core.bindings[0x100b8cd30] == "_bzero"
    assert core.bindings[0x100b8d0c8] == "_memcpy"
    assert core.proof_window(0x10000696c, 4)["instructions"][0]["instruction"] == "ldapr x0, [x8]"
    assert core.proof_window(0x100006974, 4)["instructions"][0]["instruction"] == "cmp x0, x8"
    assert core.proof_window(0x100006978, 4)["instructions"][0]["instruction"] == "b.ne #0x100006ac4"
    assert core.proof_window(0x100006994, 4)["instructions"][0]["instruction"] == "mov x8, #0x406e000000000000"
    assert core.proof_window(0x1000069f4, 4)["instructions"][0]["instruction"] == "fmov d1, #20.00000000"
    for edge in lifecycle["v17-003"]["typed_edges"]:
        assert core.proof_window(int(edge["site"], 16), 4)["instructions"][0]["instruction"] == "bl #" + edge["callee"]
        assert edge["callee"] in {function["entry"] for function in evidence["functions"].values()}
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
