"""Current action planner, read-only probe and exact reference differential.

Compile core_set_action_cycle_plan_test.cpp separately, then pass --planner-exe.
Only that workspace-owned test executable is run; neither game image is run.
All negative cases mutate memory, and this script writes no evidence files.
Tested MSVC flags: /nologo /utf-8 /W4 /WX /EHsc /std:c++20 /fp:strict.
Use /Fe:tests/.action-cycle-build/core_set_action_cycle_plan_test.exe and the
same-directory /Fo:core_set_action_cycle_plan_test.obj in a precreated directory.
The temporary exe/obj are not deliverables and should be removed after testing.
"""

from __future__ import annotations

import argparse
from copy import deepcopy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
ARGUMENTS = None


class ActionCycleContractTests(unittest.TestCase):
    def test_pure_plan_does_not_select_or_authorize_target_write(self):
        source = (ROOT / "lara/overlay/CoreSetActionCyclePlan.h").read_text(encoding="utf-8")
        for marker in ("class ActionTriggerLatch", "monotonicSeconds + 0.25",
                       "monotonicSeconds < deadline_", "allNinePresent",
                       "verticalEnabledW28 & 1", "storedContinueWhenNotFiring",
                       "oldPitch + delta.pitch", "oldYaw + delta.yaw",
                       "selectsWriteSlot = false", "restoresTargetState = false",
                       "ControlRotationWriteGate::shape"):
            self.assertIn(marker, source)
        self.assertEqual(source.count("writeReady = false"), 3)
        self.assertNotIn(".transact(", source)
        self.assertNotIn("remoteRead", source)

    def test_probe_is_current_capture_only_and_no_target_effect(self):
        source = (ROOT / "lara/views/app/CoreSetActionReadOnlyProbe.swift").read_text(encoding="utf-8")
        for marker in ("now - lastAttempt >= 30", "!stopped, !inFlight",
                       "includeBattleInputs: true", "canvas=synthetic-unit",
                       "self.session.readFailureSequence != failuresBefore",
                       "snapshot.sessionGeneration == self.session.generation",
                       "snapshot.processID == self.session.processID",
                       "snapshot.imageBase == self.session.imageBase",
                       "age >= 0, age <= 0.5", "stillCurrent",
                       "originalEffectConfirmed=0", "writeReady=0"):
            self.assertIn(marker, source)
        for forbidden in ("writeControllerAction", "submitLane", "clearLane", "RemoteCall", "ds_kwrite"):
            self.assertNotIn(forbidden, source)

    def test_stop_acknowledges_serial_probe_and_writer_cleanup(self):
        probe = (ROOT / "lara/views/app/CoreSetActionReadOnlyProbe.swift").read_text(encoding="utf-8")
        self.assertIn("let complete = !self.inFlight && self.cleanupConfirmed", probe)
        self.assertIn("stopped = true", probe)
        self.assertIn("self.session.disconnect()", probe)
        aim = (ROOT / "lara/views/app/CoreSetAimConsumer.swift").read_text(encoding="utf-8")
        for marker in ("CoreSetIsolatedWriteProbe", "persistentActionWorker", "pendingProbes",
                       "cleanup.targetEffectsAbandoned", "unrestoredActionEffects",
                       ".stoppedWithoutRestoration", ".appliedWithoutRestoration(observed:",
                       ".applied(observed:"):
            self.assertIn(marker, aim)
        state = (ROOT / "lara/views/app/CoreSetFeatureState.swift").read_text(encoding="utf-8")
        self.assertIn("case .appliedWithoutRestoration(let observed):", state)
        self.assertIn("restoration = .abandoned", state)
        recoil = (ROOT / "lara/views/app/CoreSetRecoilConsumer.swift").read_text(encoding="utf-8")
        for marker in ("CoreSetAimConsumer", "actionConsumer.applyRecoil",
                       "actionConsumer.stopRecoil", "shutdownWriteSession() -> Bool { true }"):
            self.assertIn(marker, recoil)
        for marker in ("tickRecoilOnly", "submitMergedAction", "recoilDynamics.reset()",
                       "retireActionWorker()",
                       "drainPendingActionWorkers()"):
            self.assertIn(marker, aim)

    def test_writer_attempt_uses_explicit_no_restore_disposition(self):
        header = (ROOT / "lara/overlay/CoreSetTargetWriteSession.h").read_text(encoding="utf-8")
        source = (ROOT / "lara/overlay/CoreSetTargetWriteSession.mm").read_text(encoding="utf-8")
        ledger = (ROOT / "lara/overlay/CoreSetActionEffectLedger.h").read_text(encoding="utf-8")
        self.assertIn("BOOL targetEffectsResolved", header)
        self.assertIn("BOOL targetEffectsAbandoned", header)
        self.assertIn("noInFlight && targetEffectsResolved", source)
        self.assertIn("targetEffectsResolved:NO targetEffectsAbandoned:NO", source)
        self.assertLess(source.index("_effects.markWriteAttempt()"),
                        source.index("return [_backend writeControllerSlot:"))
        for marker in ("_effects.abandonWithoutRestoration()",
                       "_effects.targetEffectsAbandoned()",
                       "generationAdvanced:advanced && readAdvanced",
                       "noInFlight:drained && backendClean"):
            self.assertIn(marker, source)
        self.assertIn("pending_ = false", gate := (ROOT / "lara/overlay/CoreSetTargetWriteContract.h").read_text(encoding="utf-8"))
        self.assertIn("Target-effect uncertainty is retained", gate)
        self.assertNotIn("_pendingCleanup = _pendingCleanup ||", source)
        self.assertIn("readCleanup = _ownsReadSession ? [_readSession disconnect] : nil", source)
        for marker in ("receipt.attemptEpoch != attemptEpoch_", "receipt.producerStopped",
                       "receipt.writerDrained", "receipt.identityStable",
                       "receipt.independentReadback", "receipt.allOwnedRangesMatchBaseline",
                       "independentVerifier(receipt)", "&& !unresolved_",
                       "bool abandonWithoutRestoration()", "bool targetEffectsAbandoned() const"):
            self.assertIn(marker, ledger)

    def test_mapped_alias_cleanup_can_retire_a_failed_worker(self):
        source = (ROOT / "lara/overlay/CoreSetMappedPageWriteBackend.mm").read_text(encoding="utf-8")
        disconnect = source.split("- (BOOL)disconnect", 1)[1]
        self.assertIn("_pendingCleanup = !released", disconnect)
        self.assertIn("if (released) _mappingCount = 0", disconnect)
        self.assertIn("return released", disconnect)

    def test_aim_and_recoil_share_one_serial_timer_and_coalesce_ui_status(self):
        aim = (ROOT / "lara/views/app/CoreSetAimConsumer.swift").read_text(encoding="utf-8")
        apply = aim.split("func apply(_ request: CoreSetApplyRequest<State>,", 1)[1].split(
            "private func recoilConfiguration", 1)[0]
        self.assertLess(apply.index("worker.async"), apply.index("self.invalidateHost()"))
        self.assertLess(apply.index("self.invalidateHost()"), apply.index("self.liveToken = request.token"))
        self.assertNotIn("recoilTimer", aim)
        self.assertIn("replaceActionTimerWithRecoil", aim)
        self.assertEqual(aim.count("private var timer: DispatchSourceTimer?"), 1)
        publish = aim.split("private func publish(_ text: String)", 1)[1].split(
            "private func fail(", 1)[0]
        self.assertIn("pendingStatusText = text", publish)
        self.assertIn("guard !statusPublishScheduled else { return }", publish)
        self.assertIn("0.25", publish)
        self.assertIn("let requestID = self.liveToken?.requestID", publish)
        self.assertIn("self.actionWorkerLive(requestID, host: hostGeneration", publish)

    def test_31_point_fixture_never_promotes_component_parity_to_original_effect(self):
        evidence = json.loads((ROOT / "tests/fixtures/core_set_v17_action_cycle_evidence.json").read_text(encoding="utf-8"))
        self.assertEqual([point["id"] for point in evidence["points"]],
                         [f"v17-{number:03}" for number in range(106, 137)])
        self.assertEqual(evidence["point_count"], 31)
        self.assertEqual(evidence["one_to_one_complete_count"], 0)
        self.assertEqual([point["id"] for point in evidence["points"] if point["current_alternative_preview"]],
                         ["v17-108", "v17-110", "v17-111", "v17-112", "v17-113", "v17-115", "v17-117"])
        for point in evidence["points"]:
            self.assertFalse(point["one_to_one_complete"])
            self.assertFalse(point["original_runtime_receipt_verified"])
            self.assertEqual(point["evidence_key"], "action-cycle/" + point["id"])
            self.assertGreaterEqual(len(point["next_exact_edges"]), 2)
            self.assertIn("merge_slot", point["closed_reference_edges"])
            for storage in point["core_self_storage"]:
                self.assertEqual(storage["owner"], "Core-self-configuration")
        self.assertFalse(evidence["cleanup_contract"]["production_restoration_verifier_installed"])

    def test_31_point_fixture_exact_core_and_target_replay(self):
        if not ARGUMENTS.reference_ipa or not ARGUMENTS.target_ipa:
            self.skipTest("exact reference + target IPA required")
        evidence = json.loads((ROOT / "tests/fixtures/core_set_v17_action_cycle_evidence.json").read_text(encoding="utf-8"))
        native = json.loads((ROOT / "tests/fixtures/core_set_v17_native_point_chain_map.json").read_text(encoding="utf-8"))
        probe = load_probe()
        actual = probe.action_evidence(probe.CoreImage(ARGUMENTS.reference_ipa), native,
                                       probe.target_evidence(ARGUMENTS.target_ipa))
        self.assertEqual(actual, evidence)
        self.assertEqual(len(actual["reference_windows"]), 13)
        self.assertEqual(sum(len(window["instructions"]) for window in actual["reference_windows"]), 505)
        print("PASS: 31-point action fixture exact Core/target replay; partial components only")

    def test_compiled_cleanup_no_write_attempt_and_verified_receipt(self):
        if not ARGUMENTS.reference_ipa or not ARGUMENTS.planner_exe:
            self.skipTest("reference IPA + compiled planner executable required")
        _probe, _core, planner = load_differential()
        self.assertEqual(planner["cleanup"], [
            {"case": "no-write-resource-clean", "complete": True},
            {"case": "write-attempt-no-restore", "complete": False},
            {"case": "explicit-synthetic-restoration-receipt", "complete": True},
        ])

    def test_compiled_planner_matches_original_micro_cfg(self):
        if not ARGUMENTS.reference_ipa or not ARGUMENTS.planner_exe:
            self.skipTest("reference IPA + compiled planner executable required")
        probe, core, planner = load_differential()
        result = probe.differential(core, planner)
        self.assertEqual(result["cases"], {"trigger": 24, "scene": 12, "post_flag": 16, "draft": 8})
        self.assertEqual(result["checked_write_executions"], 0)
        print("PASS: compiled C++ planner vs original ARM64 micro-CFG: 60 cases; write sink never executed")

    def test_negative_trigger_and_post_policy_not_conflated_with_fire(self):
        if not ARGUMENTS.reference_ipa or not ARGUMENTS.planner_exe:
            self.skipTest("reference IPA + compiled planner executable required")
        probe, core, planner = load_differential()
        for change in (lambda p: p["trigger"][17].update(active=0),
                       lambda p: p["post_flag"][5].update(flag=1),
                       lambda p: p["draft"][5].update(offset=0x620),
                       lambda p: p["scene"][0]["effective"].__setitem__(0, 75)):
            altered = deepcopy(planner)
            change(altered)
            with self.assertRaises(AssertionError):
                probe.differential(core, altered)

    def test_target_slot_owner_type_and_lifecycle_windows(self):
        if not ARGUMENTS.target_ipa:
            self.skipTest("exact target IPA required")
        probe = load_probe()
        result = probe.target_evidence(ARGUMENTS.target_ipa)
        self.assertEqual(result["vtable_slots"]["0xee0"], "0x107cfd600")
        self.assertEqual(result["vtable_slots"]["0xee8"], "0x107cfd69c")
        self.assertEqual(result["vtable_slots"]["0xe10"], "0x104ce7800")
        print("PASS: target build15915 image hash/UUID, Rotator property layout and specific STExtra input/update/reset windows")


def load_probe():
    sys.path.insert(0, str(ROOT / "tools"))
    specification = importlib.util.spec_from_file_location("action_cycle_probe", ROOT / "tools/core_set_action_cycle_probe.py")
    probe = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(probe)
    return probe


DIFFERENTIAL = None


def load_differential():
    global DIFFERENTIAL
    if DIFFERENTIAL is not None:
        return DIFFERENTIAL
    executable = ARGUMENTS.planner_exe.resolve()
    expected = (ROOT / "tests/.action-cycle-build/core_set_action_cycle_plan_test.exe").resolve()
    if executable != expected:
        raise ValueError("only the separately compiled workspace-owned action test executable is allowed")
    output = subprocess.run([str(executable)], check=True, capture_output=True, text=True, timeout=20).stdout
    planner = json.loads(output)
    assert planner["scope"] == "pure-planner-and-fake-memory-contract; no target writes"
    probe = load_probe()
    core = probe.CoreImage(ARGUMENTS.reference_ipa)
    DIFFERENTIAL = (probe, core, planner)
    return DIFFERENTIAL


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser()
    parser.add_argument("--reference-ipa", type=Path)
    parser.add_argument("--target-ipa", type=Path)
    parser.add_argument("--planner-exe", type=Path)
    ARGUMENTS = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(ActionCycleContractTests))
    if not result.wasSuccessful():
        raise SystemExit(1)
    print("LIMIT: pure/offline and source contracts only; no Swift/iOS compilation or target/game action receipt")
