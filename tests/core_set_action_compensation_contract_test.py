"""Reference compensation/owner CFG contracts, never target writer activation."""
from __future__ import annotations

import argparse
from copy import deepcopy
import json
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
ARGS = None
CACHED = None
COUNTS = {"prediction": 10, "angular": 8, "residual": 40, "compensation": 48, "post": 80, "caller_merge": 12, "geometry": 80, "feedback": 32}


def inputs():
    global CACHED
    if CACHED is not None: return CACHED
    expected = ROOT / "tests/.action-cycle-build/core_set_action_compensation_state_test.exe"
    if ARGS.planner_exe.resolve() != expected.resolve(): raise ValueError("only workspace-owned compiled model executable allowed")
    model = json.loads(subprocess.run([str(expected)], capture_output=True, text=True, check=True, timeout=20).stdout)
    sys.path.insert(0, str(ROOT / "tools"))
    import core_set_action_cycle_probe as original
    import core_set_action_compensation_probe as compensation
    CACHED = compensation, original.CoreImage(ARGS.reference_ipa), model
    return CACHED


class CompensationContracts(unittest.TestCase):
    def test_source_has_no_authority_or_target_write(self):
        source = (ROOT / "lara/overlay/CoreSetActionCompensationState.h").read_text(encoding="utf-8")
        self.assertEqual(source.count("writeReady = false"), 5)
        for forbidden in ("RemoteCall", "ds_kwrite", ".transact(", "writeControllerAction", "writeControllerSlot"):
            self.assertNotIn(forbidden, source)
        for marker in ("No target owner", "No reset here can resolve a prior target-memory effect",
                       "ownerToken", "not a counter", "quietFrameLimit", "continueLocalTail",
                       "referenceActionGeometry", "referenceActionRecoilCallerMerge"):
            self.assertIn(marker, source)
        # Post record owner is a checked pointer. Only ReadSession has a read
        # generation; do not conflate that with this original native record.
        post = source.split("struct ActionPostRecord", 1)[1].split("inline float referenceActionRecoilCallerMerge", 1)[0]
        self.assertNotIn("uint64_t generation", post)

    def test_compiled_310_cases_match_original_full_geometry_post_and_components(self):
        if not ARGS.reference_ipa or not ARGS.planner_exe: self.skipTest("exact IPA and separately compiled C++ test required")
        probe, core, model = inputs()
        result = probe.differential(core, model)
        self.assertEqual(result["case_counts"], COUNTS)
        self.assertEqual(result["checked_write_executions"], 0)
        self.assertFalse(result["write_ready"])
        print("PASS: 310 current compiled C++ vs original ARM64 cases; no writer executions")

    def test_eight_component_negative_mutations_rejected(self):
        if not ARGS.reference_ipa or not ARGS.planner_exe: self.skipTest("exact IPA and separately compiled C++ test required")
        probe, core, model = inputs()
        mutations = [lambda p: p["prediction"][0].update(gain=1),
                     lambda p: p["angular"][0]["value"].__setitem__(0, 0),
                     lambda p: p["residual"][0].update(afterPresent=1),
                     lambda p: p["compensation"][0]["delta"].__setitem__(0, 0),
                     lambda p: p["post"][0].update(phaseCode=99),
                     lambda p: p["caller_merge"][0].update(result=0),
                     lambda p: p["geometry"][0]["flags"].__setitem__(1, 0),
                     lambda p: p["feedback"][0].update(value=0)]
        for mutation in mutations:
            altered = deepcopy(model); mutation(altered)
            with self.assertRaises(AssertionError): probe.differential(core, altered)

    def test_fixture_keeps_target_authority_receipt_and_restore_open(self):
        evidence = json.loads((ROOT / "tests/fixtures/core_set_v17_action_cycle_evidence.json").read_text(encoding="utf-8"))
        self.assertEqual(evidence["schema_version"], 3)
        self.assertEqual(len(evidence["points"]), 31)
        self.assertEqual(sum(len(p["next_exact_edges"]) for p in evidence["points"]), 113)
        self.assertEqual(evidence["one_to_one_complete_count"], 0)
        components = evidence["compensation_evidence"]
        self.assertEqual(components["case_counts"], COUNTS)
        self.assertEqual(len(components["closed_edges"]), 10)
        self.assertFalse(components["write_ready"])
        self.assertFalse(components["target_effect_restored"])
        for point in evidence["points"]:
            self.assertFalse(point["one_to_one_complete"])
            self.assertFalse(point["original_runtime_receipt_verified"])
            self.assertTrue(any("game-thread concurrency" in edge for edge in point["next_exact_edges"]))
            self.assertTrue(any("effects restored" in edge for edge in point["next_exact_edges"]))

    def test_aim_and_recoil_share_reference_geometry_state_and_writer(self):
        aim = (ROOT / "lara/views/app/CoreSetAimConsumer.swift").read_text(encoding="utf-8")
        self.assertIn("CoreSetIsolatedWriteProbe", aim)
        self.assertIn("result.committed", aim)
        self.assertIn(".applied(observed:", aim)
        recoil = (ROOT / "lara/views/app/CoreSetRecoilConsumer.swift").read_text(encoding="utf-8")
        self.assertIn("CoreSetAimConsumer", recoil)
        self.assertIn("actionConsumer.applyRecoil", recoil)
        self.assertNotIn("supportedFields: Set<CoreSetField> { [] }", recoil)
        for marker in ("CoreSetV17RecoilDynamics", "submitMergedAction", "actionSlot(snapshot:",
                       "routeDynamics.slot(firingSample:", "tickRecoilOnly"):
            self.assertIn(marker, aim)
        bridge = (ROOT / "lara/overlay/CoreSetIsolatedWriteProbe.mm").read_text(encoding="utf-8")
        self.assertIn('CoreSetActionCompensationState.h', bridge)
        self.assertIn("referenceActionCandidateMotion", bridge)
        self.assertIn("referenceActionGeometry", bridge)
        self.assertIn("planActionScene", bridge)
        self.assertIn("aimSceneCompensationValues", bridge)
        self.assertIn("referenceActionRecoilPostTuning", bridge)
        self.assertNotIn("basicAimDynamicStep(", bridge)

    def test_local_numerical_bytes_calls_constants_and_feedback_replay(self):
        if not ARGS.reference_ipa: self.skipTest("exact reference IPA required")
        sys.path.insert(0, str(ROOT / "tools"))
        import core_set_action_cycle_probe as original
        import core_set_action_compensation_probe as compensation
        core = original.CoreImage(ARGS.reference_ipa)
        result = compensation.static_edges(core)
        evidence = json.loads((ROOT / "tests/fixtures/core_set_v17_action_cycle_evidence.json").read_text(encoding="utf-8"))
        self.assertEqual(result, evidence["compensation_evidence"])
        self.assertIn("only c2f4c", result["closed_edges"]["single_worker_sink"])
        self.assertIn("not invocation-count or thread-exclusion proof", result["closed_edges"]["single_worker_sink"])
        self.assertIn("no inverse target write", result["closed_edges"]["stop_post_state_local"])
        print("PASS: local compensation/post/feedback byte windows and existing direct caller scan")

    def test_fixture_replay_uses_retained_target_metadata_not_target_ipa(self):
        if not ARGS.reference_ipa: self.skipTest("exact reference IPA required")
        sys.path.insert(0, str(ROOT / "tools"))
        import core_set_action_cycle_probe as original
        evidence = json.loads((ROOT / "tests/fixtures/core_set_v17_action_cycle_evidence.json").read_text(encoding="utf-8"))
        native = json.loads((ROOT / "tests/fixtures/core_set_v17_native_point_chain_map.json").read_text(encoding="utf-8"))
        # Only saved metadata is passed through; this deliberately does not
        # open the target IPA, resolve an object or acquire a process session.
        result = original.action_evidence(original.CoreImage(ARGS.reference_ipa), native, evidence["target_static_evidence"])
        self.assertEqual(result, evidence)
        self.assertEqual(result["target_static_evidence"], evidence["target_static_evidence"])
        print("PASS: 31-point local fixture replay; prior target-static metadata only, no target IPA read")


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser()
    parser.add_argument("--reference-ipa", type=Path)
    parser.add_argument("--planner-exe", type=Path)
    ARGS = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(CompensationContracts))
    if not result.wasSuccessful(): raise SystemExit(1)
    print("LIMIT: exact Core-self components only; no live target owner authority or restore receipt")
