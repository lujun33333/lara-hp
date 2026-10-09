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
        self.assertIn("refreshPeriodicObservations()", body(self.coordinator, "func publishStatus()"))
        self.assertIn("frameRateConsumer?.refreshSchedulerObservation()",
                      body(self.coordinator, "private func refreshPeriodicObservations()"))

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

    def test_current_home_actions_are_locally_bound_not_an_original_runtime_claim(self):
        sys.path.insert(0, str(ROOT / "tools"))
        from core_set_v17_home_producer_probe import probe_current_repository
        evidence = probe_current_repository(ROOT)
        self.assertEqual({point["id"] for point in evidence["points"]},
                         {f"v17-{point:03}" for point in (0, 1, 2, 3, 5, 6, 8, 9, 10)})
        bound = {point["id"] for point in evidence["points"] if point["producer_bound"]}
        self.assertEqual(bound, {"v17-000", "v17-002", "v17-003", "v17-005", "v17-006",
                                 "v17-008", "v17-009", "v17-010"})
        self.assertTrue(all(not point["original_runtime_receipt_verified"] for point in evidence["points"]))
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
        self.assertEqual(len(evidence["provider_scan"]["binding_calls"]), 2)
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
        self.assertIn("bound live local environment producer", points["v17-005"]["current_candidate"])
        self.assertIn("bound live local information producer", points["v17-006"]["current_candidate"])
        self.assertIn("running is not stage", points["v17-008"]["missing_same_meaning_interface"])
        self.assertIn("PAGE counters", points["v17-009"]["missing_same_meaning_interface"])
        self.assertIn("same units", points["v17-010"]["missing_same_meaning_interface"])
        self.assertIn("bound kernelcache transfer byte producer", points["v17-010"]["current_candidate"])
        self.assertIn("system OTA switch", points["v17-010"]["current_candidate"])
        self.assertEqual(points["v17-010"]["caller_evidence_keys"],
                         ["range_fetch", "kernel_cache_call", "local_copy", "ota_switch",
                          "observation_boundary", "live_home_producer"])

    def test_source_probe_refuses_changed_call_chain_and_counter_substitution(self):
        sys.path.insert(0, str(ROOT / "tools"))
        from core_set_v17_home_producer_probe import CURRENT_SOURCES, current_source_evidence
        sources = {owner: (ROOT / path).read_text(encoding="utf-8") for owner, path in CURRENT_SOURCES.items()}
        for owner, old, new in (
            ("coordinator", "let loaded = fetched && !action.isCancellationRequested && dlkcache()",
             "let loaded = fetched && dlkcache()"),
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
        self.assertEqual({point["id"] for point in evidence["points"] if point["producer_bound"]},
                         {"v17-000", "v17-002", "v17-003", "v17-005", "v17-006",
                          "v17-008", "v17-009", "v17-010"})


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
    bootstrap = evidence["cover_bootstrap"]
    assert bootstrap["configuration"] == {"enabled": "C+0x2f bool", "mode": "C+0x130 int32",
                                             "initialized": "C+0x1e9 bool"}
    assert [worker["callback_slot"] for worker in bootstrap["workers"]] == [
        "0x100c19ec8", "0x100c19ed0", "0x100c19ed8"]
    assert [worker["adapter"] for worker in bootstrap["workers"]] == [
        "0x1000e5288", "0x1000ec834", "0x1000e5288"]
    record = bootstrap["collector_record_abi"]
    assert record["stride"] == "0xa0"
    assert [field["range"] for field in record["fields"]] == [
        "0x00..0x17", "0x18..0x2f", "0x30", "0x31..0x33", "0x34..0x43",
        "0x44..0x53", "0x54..0x57", "0x58..0x67", "0x68..0x6f",
        "0x70..0x7f", "0x80..0x83", "0x84..0x93", "0x94..0x9f"]
    assert sum(field["size"] for field in record["fields"]) == 0xa0
    assert record["coverage"].startswith("all 0xa0 output-record bytes")
    assert "does not prove identity continuity" in record["coverage"]
    assert "record+0x58/+0x60" in record["ac_key"]
    assert "record+0x68" in record["b_key"]
    builder = bootstrap["spatial_builder_abi"]
    assert "0x9003 FLOAT3" in builder["vertex_buffer"]
    assert "0x5003 UINT3" in builder["index_buffer"]
    owner = bootstrap["collector_input_owner"]
    assert "global0x100c58778" in owner["lease"]
    assert "global0x100c58780" in owner["generation"]
    assert "A/B form" in owner["collector_base"]
    assert "no direct 64d04 edge" in owner["collector_base"]
    assert "e4200/e4288/e42fc" in owner["runtime_reads"]["A"]
    assert "ec3f0/ec478/ec4ec" in owner["runtime_reads"]["B"]
    assert "do not continuously carry one identity" in owner["runtime_reads"]["A"]
    assert "identity continuity into builder x21 is not proved" in owner["runtime_reads"]["B"]
    pair = owner["builder_pair_continuity"]
    assert "e4f84..e4fa0" in pair["A_call"] and "sp+0xa8" in pair["A_call"]
    assert "ec6a4..ec6cc" in pair["B_call"] and "sp+0x48" in pair["B_call"]
    assert "one 16-byte pair" in pair["pair_iteration"] and "ldp x0,x24" in pair["pair_iteration"]
    assert "source0 0x100 bytes" in pair["same_local_row"]
    assert "source1 0xd0 bytes" in pair["same_local_row"]
    assert "pair-to-local-row continuity" in pair["limit"]
    assert "does not identify" in pair["limit"]
    read_exact = "0x100064d04"
    for name in ("cover_collector_a", "cover_collector_b"):
        assert [edge["callee"] for edge in evidence["functions"][name]["calls"]].count(read_exact) == 3
    assert read_exact not in [edge["callee"] for edge in evidence["functions"]["cover_collector_c"]["calls"]]
    assert "d3b08" in owner["stop"]
    publication = bootstrap["callback_publication_abi"]
    assert "allocates three 0x100-byte owners" in publication["publisher"]
    assert "owner+0x10" in publication["owner_callback_slot"]
    assert "x19+0x40" in publication["owner_callback_slot"]
    assert "owner+0x50" in publication["owner_callback_slot"]
    assert "x0,x1" in publication["A"] and "x0" in publication["B"]
    assert bootstrap["proof_sites"]["stable_count"]["instructions"][0]["instruction"] == "add w9, w8, #1"
    assert bootstrap["proof_sites"]["worker_a_collect"]["instructions"][0]["instruction"] == "bl #0x1000e40f4"
    assert bootstrap["proof_sites"]["worker_b_collect"]["instructions"][0]["instruction"] == "bl #0x1000ec2f8"
    assert bootstrap["proof_sites"]["worker_c_collect"]["instructions"][0]["instruction"] == "bl #0x1000effec"
    assert bootstrap["proof_sites"]["worker_a_callback_load"]["instructions"][0]["instruction"] == "ldr x0, [x24, #0xec8]"
    assert bootstrap["proof_sites"]["worker_b_callback_load"]["instructions"][0]["instruction"] == "ldr x0, [x24, #0xed0]"
    assert bootstrap["proof_sites"]["worker_c_callback_load"]["instructions"][0]["instruction"] == "ldr x0, [x24, #0xed8]"
    assert bootstrap["proof_sites"]["callback_ac_key"]["instructions"][0]["instruction"] == "ldp x8, x1, [x0, #0x58]"
    assert bootstrap["proof_sites"]["callback_b_key"]["instructions"][0]["instruction"] == "ldr x0, [x0, #0x68]"
    assert bootstrap["proof_sites"]["owner_a_constructor"]["instructions"][0]["instruction"] == "bl #0x1000e10c8"
    assert bootstrap["proof_sites"]["owner_c_constructor"]["instructions"][0]["instruction"] == "bl #0x1000e10c8"
    assert bootstrap["proof_sites"]["owner_b_constructor"]["instructions"][0]["instruction"] == "bl #0x1000e11b0"
    assert bootstrap["proof_sites"]["owner_a_publish"]["instructions"][0]["instruction"] == "str x20, [x19, #0xec8]"
    assert bootstrap["proof_sites"]["owner_c_publish"]["instructions"][0]["instruction"] == "str x20, [x21, #0xed8]"
    assert bootstrap["proof_sites"]["owner_b_publish"]["instructions"][0]["instruction"] == "str x20, [x22, #0xed0]"
    assert bootstrap["proof_sites"]["owner_ac_base"]["instructions"][0]["instruction"] == "mov x19, x0"
    assert bootstrap["proof_sites"]["owner_ac_subobject_rebase"]["instructions"][0]["instruction"] == "stp q0, q0, [x19, #0x10]!"
    assert bootstrap["proof_sites"]["owner_b_base"]["instructions"][0]["instruction"] == "mov x19, x0"
    assert bootstrap["proof_sites"]["owner_b_subobject_rebase"]["instructions"][0]["instruction"] == "stp q0, q0, [x19, #0x10]!"
    assert bootstrap["proof_sites"]["owner_ac_callback_store"]["instructions"][0]["instruction"] == "str x1, [x19, #0x40]"
    assert bootstrap["proof_sites"]["owner_b_callback_store"]["instructions"][0]["instruction"] == "str x1, [x19, #0x40]"
    assert bootstrap["proof_sites"]["adapter_ac_callback_load"]["instructions"][0]["instruction"] == "ldr x8, [x19, #0x50]"
    assert bootstrap["proof_sites"]["adapter_b_callback_load"]["instructions"][0]["instruction"] == "ldr x8, [x19, #0x50]"
    for label, instruction in {
        "record_flag_copy": "strb w8, [sp, #0x280]",
        "record_payload_a_copy": "stur q0, [x28, #0x34]",
        "record_payload_b_copy": "stur q0, [x28, #0x44]",
        "record_key16_copy": "stur q0, [x28, #0x58]",
        "record_key64_copy": "str x8, [x9, #0x68]",
        "record_kind_copy": "str w8, [sp, #0x2d0]",
        "record_transform4_copy": "stur q0, [x28, #0x84]",
        "record_transform3_copy": "stur q0, [x28, #0x90]",
        "record_move_vectors": "ldr q0, [x1]",
        "record_copy_tail": "ldp q0, q1, [x1, #0x80]",
        "record_advance": "add x0, x8, #0xa0",
        "a_read_1": "bl #0x100064d04", "a_read_2": "bl #0x100064d04",
        "a_read_3": "bl #0x100064d04", "a_table_copy": "bl #0x1000e5638",
        "a_row_d0": "bl #0x1000e5638", "a_row_100": "bl #0x1000e5638",
        "b_read_1": "bl #0x100064d04", "b_read_2": "bl #0x100064d04",
        "b_read_3": "bl #0x100064d04", "b_table_copy": "bl #0x1000e5638",
        "a_builder_call": "bl #0x1000e60bc", "a_builder_pair": "ldp x0, x24, [x8]",
        "a_builder_source0_copy": "bl #0x1000e5638", "a_builder_source1_copy": "bl #0x1000e5638",
        "a_builder_row_select": "madd x21, x25, x9, x8",
        "b_builder_call": "bl #0x1000ed220", "b_builder_pair": "ldp x0, x24, [x8]",
        "b_builder_source0_copy": "bl #0x1000e5638", "b_builder_source1_copy": "bl #0x1000e5638",
        "b_builder_row_select": "madd x21, x25, x9, x8",
    }.items():
        assert bootstrap["proof_sites"][label]["instructions"][0]["instruction"] == instruction
    assert bootstrap["proof_sites"]["adapter_ac_stride"]["instructions"][0]["instruction"] == "add x20, x20, #0xa0"
    assert bootstrap["proof_sites"]["adapter_b_stride"]["instructions"][0]["instruction"] == "add x20, x20, #0xa0"
    assert bootstrap["proof_sites"]["adapter_ac_vertex_format"]["instructions"][0]["instruction"] == "mov w3, #0x9003"
    assert bootstrap["proof_sites"]["adapter_ac_index_format"]["instructions"][0]["instruction"] == "mov w3, #0x5003"
    assert bootstrap["proof_sites"]["adapter_b_vertex_format"]["instructions"][0]["instruction"] == "mov w3, #0x9003"
    assert bootstrap["proof_sites"]["adapter_b_index_format"]["instructions"][0]["instruction"] == "mov w3, #0x5003"
    assert bootstrap["proof_sites"]["input_lease_call"]["instructions"][0]["instruction"] == "bl #0x100064c7c"
    assert bootstrap["proof_sites"]["input_base_store"]["instructions"][0]["instruction"] == "str x8, [x9, #0x778]"
    assert bootstrap["proof_sites"]["input_update"]["instructions"][0]["instruction"] == "bl #0x1000d3eac"
    assert bootstrap["proof_sites"]["input_failure_stop"]["instructions"][0]["instruction"] == "bl #0x1000d3dd0"
    assert bootstrap["proof_sites"]["generation_xor"]["instructions"][0]["instruction"] == "eor x8, x9, x8"
    assert bootstrap["proof_sites"]["generation_store"]["instructions"][0]["instruction"] == "str x8, [x19]"
    assert bootstrap["proof_sites"]["query_wrapper_tail"]["instructions"][0]["instruction"] == "b #0x1000d3424"
    query = bootstrap["segment_query"]
    assert query["input"] == "six float32 arguments interpreted as two vec3 endpoints"
    assert query["result"].startswith("false when a slot is absent")
    assert "frame_draw bone-segment color selection" in query["owner_limit"]
    assert bootstrap["proof_sites"]["query_initialized_gate"]["instructions"][0]["instruction"] == "ldrb w8, [x8, #0x1e9]"
    assert bootstrap["proof_sites"]["query_frame_call"]["instructions"][0]["instruction"] == "bl #0x1000d33f4"
    assert bootstrap["proof_sites"]["query_store_by_bone"]["instructions"][0]["instruction"] == "strb w0, [x8, x23]"
    assert bootstrap["proof_sites"]["query_color_first_endpoint"]["instructions"][0]["instruction"] == "ldrb w8, [x8, x23]"
    assert bootstrap["proof_sites"]["query_color_second_endpoint"]["instructions"][0]["instruction"] == "ldrb w8, [x8, x24]"
    assert bootstrap["proof_sites"]["query_a"]["instructions"][0]["instruction"] == "bl #0x1000e0be8"
    assert bootstrap["proof_sites"]["query_b"]["instructions"][0]["instruction"] == "bl #0x1000e0cf0"
    assert bootstrap["proof_sites"]["query_c"]["instructions"][0]["instruction"] == "bl #0x1000e0be8"
    assert bootstrap["proof_sites"]["query_distance"]["instructions"][0]["instruction"] == "fsqrt s3, s3"
    assert bootstrap["proof_sites"]["query_hit_sentinel"]["instructions"][0]["instruction"] == "mov w8, #-1"
    assert "do not substitute a local LOS boolean" in bootstrap["unresolved"]
    assert "complete 0xa0 output layout" in bootstrap["unresolved"]
    assert "continuous identity" in bootstrap["unresolved"]
    assert "remain unproved" in bootstrap["unresolved"]
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
