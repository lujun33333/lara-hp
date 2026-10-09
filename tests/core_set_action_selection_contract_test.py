"""Exact original selector/state edges; no device action or target writer activation."""
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


def inputs():
    global CACHED
    if CACHED is not None: return CACHED
    expected = ROOT / "tests/.action-cycle-build/core_set_action_selection_state_test.exe"
    if ARGS.planner_exe.resolve() != expected.resolve():
        raise ValueError("only the workspace-owned separately compiled C++ selection test is permitted")
    planner = json.loads(subprocess.run([str(expected)], capture_output=True, text=True,
                                        check=True, timeout=20).stdout)
    sys.path.insert(0, str(ROOT / "tools"))
    import core_set_action_cycle_probe as original
    import core_set_action_selection_probe as selection
    CACHED = selection, original.CoreImage(ARGS.reference_ipa), planner
    return CACHED


class SelectionContracts(unittest.TestCase):
    def test_source_never_claims_upstream_path_or_write_authority(self):
        source = (ROOT / "lara/overlay/CoreSetActionSelectionState.h").read_text(encoding="utf-8")
        self.assertEqual(source.count("writeReady = false"), 5)
        self.assertIn("authorizesUpstreamPath = false", source)
        self.assertIn("Core-local record fields, NEVER target game-object offsets", source)
        for forbidden in (".transact(", "writeControllerAction", "RemoteCall", "ds_kwrite"):
            self.assertNotIn(forbidden, source)
        for marker in ("pixels <= radius", "pixels < bestPixels", "elapsed >= 50000001",
                       "now <= state.previousNanoseconds", "state.targetKey != key",
                       "state.confirmationCount = 0", "pauseMilliseconds) / 1000.0"):
            self.assertIn(marker, source)

    def test_runtime_controller_probe_is_typed_read_only_and_non_authoritative(self):
        header = (ROOT / "lara/overlay/CoreSetActionInputReadContract.h").read_text(encoding="utf-8")
        runtime = (ROOT / "lara/overlay/CoreSetTargetWriteSession.mm").read_text(encoding="utf-8")
        readonly = runtime.split("@implementation CoreSetActionInputObservation", 1)[1].split("@end", 1)[0]
        swift = (ROOT / "lara/views/app/CoreSetActionReadOnlyProbe.swift").read_text(encoding="utf-8")
        for marker in ("lease.uuid != ControlRotationWriteGate::kUUID", "time - lease.snapshotCompletedSeconds <= 0.5",
                       "completed < started", "partialInput", "partialControl", "std::isfinite(input[0])",
                       "std::memcmp(control.data(), lease.capturedControl.data()", "writeReady = false"):
            self.assertIn(marker, header)
        self.assertEqual(header.count("!identity(lease)"), 3)
        for marker in ("session.ready", "session.generation == current.generation",
                       "snapshot.sessionGeneration == current.generation", "length != 8", "readAt:address"):
            self.assertIn(marker, readonly)
        for forbidden in ("writeControllerSlot", "transact(", "RemoteCall", "ds_kwrite", "_authority", "_backend"):
            self.assertNotIn(forbidden, readonly)
            self.assertNotIn(forbidden, header)
        for marker in ("CoreSetActionInputObservation.capture", "inputStillCurrent",
                       "fingerprintScope=diagnostic-fnv1a64-not-authority", "objectLifetimeAtomic=0",
                       "slotRoute=unissued", "controlBeforeFingerprint", "controlAfterFingerprint",
                       "let inputFailuresBefore = self.session.readFailureSequence",
                       "self.session.readFailureSequence != inputFailuresBefore"):
            self.assertIn(marker, swift)

    def test_compiled_typed_read_contract_positive_and_negative_cases(self):
        if not ARGS.read_contract_exe:
            self.skipTest("separately compiled workspace-owned read contract executable required")
        expected = ROOT / "tests/.action-cycle-build/core_set_action_input_read_contract_test.exe"
        if ARGS.read_contract_exe.resolve() != expected.resolve():
            raise ValueError("unexpected read contract executable")
        output = subprocess.run([str(expected)], capture_output=True, text=True, check=True, timeout=20).stdout
        self.assertIn("old-generation/profile/nonfinite/freshness/identity/control-change", output)
        self.assertIn("writerCalls=0", output)
        print(output.strip())

    def test_compiled_original_selector_history_takeover_and_slot_edges(self):
        if not ARGS.reference_ipa or not ARGS.planner_exe:
            self.skipTest("exact reference IPA + separately compiled C++ executable required")
        probe, core, planner = inputs()
        result = probe.differential(core, planner)
        self.assertEqual(result["cases"], {"actor_gate": 64, "point": 6, "rank": 8,
                                           "clock": 8, "route": 6, "takeover": 16, "recoil": 40, "motion": 8})
        self.assertEqual(result["checked_write_executions"], 0)
        print("PASS: 156 compiled C++ vs original ARM64 selector/state cases; write sink executions=0")

    def test_eight_negative_component_mutations_are_rejected(self):
        if not ARGS.reference_ipa or not ARGS.planner_exe:
            self.skipTest("exact reference IPA + separately compiled C++ executable required")
        probe, core, planner = inputs()
        mutations = [lambda p: p["actor_gate"][0].update(eligible=1),
                     lambda p: p["point"][0]["value"].__setitem__(2, 93),
                     lambda p: p["rank"][1].update(updated=0),
                     lambda p: p["clock"][0].update(eligible=1),
                     lambda p: p["route"][2].update(slot=1),
                     lambda p: p["takeover"][7].update(newDeadline=0),
                     lambda p: p["recoil"][8]["result"].__setitem__(5, 0),
                     lambda p: p["motion"][1]["after"].__setitem__(10, 0)]
        for mutation in mutations:
            altered = deepcopy(planner); mutation(altered)
            with self.assertRaises(AssertionError): probe.differential(core, altered)

    def test_fixture_has_closed_reference_edges_and_fewer_unresolved_edges(self):
        evidence = json.loads((ROOT / "tests/fixtures/core_set_v17_action_cycle_evidence.json").read_text(encoding="utf-8"))
        self.assertEqual(evidence["schema_version"], 3)
        self.assertEqual(sum(len(point["next_exact_edges"]) for point in evidence["points"]), 82)
        edges = evidence["selection_route_history_evidence"]
        self.assertEqual(len(edges["closed_edges"]), 10)
        self.assertFalse(edges["write_ready"])
        self.assertFalse(edges["original_device_effect_verified"])
        self.assertEqual(edges["whole_text_direct_branch_to_merge"], ["0x1000c3918", "0x1000c3990"])

    def test_original_static_edges_replay_including_whole_text_branches(self):
        if not ARGS.reference_ipa:
            self.skipTest("exact reference IPA required")
        sys.path.insert(0, str(ROOT / "tools"))
        import core_set_action_cycle_probe as original
        import core_set_action_selection_probe as selection
        evidence = json.loads((ROOT / "tests/fixtures/core_set_v17_action_cycle_evidence.json").read_text(encoding="utf-8"))
        result = selection.static_edges(original.CoreImage(ARGS.reference_ipa))
        self.assertEqual(result, evidence["selection_route_history_evidence"])
        self.assertEqual(sum(len(window["instructions"]) for window in result["reference_windows"]), 1157)
        print("PASS: exact 1157 new original instruction words, three merge edges + whole-text direct-branch scan")


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser()
    parser.add_argument("--reference-ipa", type=Path)
    parser.add_argument("--planner-exe", type=Path)
    parser.add_argument("--read-contract-exe", type=Path)
    ARGS = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(SelectionContracts))
    if not result.wasSuccessful(): raise SystemExit(1)
    print("LIMIT: offline exact-edge parity only; no current-game candidate authority or concurrent effect receipt")
