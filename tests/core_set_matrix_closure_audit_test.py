"""Metadata/source safety audit only; no binary, process or target-memory access."""
from __future__ import annotations

from copy import deepcopy
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tests/fixtures"
MODELS = ("CoreSetActionCyclePlan.h", "CoreSetActionSelectionState.h", "CoreSetActionCompensationState.h", "CoreSetRecoilStateMachine.h")


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


def body(source, signature):
    begin = source.index("{", source.index(signature) + len(signature)); end = begin + 1; depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}"); end += 1
    return source[begin + 1:end - 1]


def require_matrix(menu, native, action):
    rows = [dict(zip(menu["columns"], row)) for row in menu["points"]]
    assert [row["id"] for row in rows] == [f"v17-{number:03}" for number in range(137)]
    assert [row["id"] for row in native["points"]] == [row["id"] for row in rows]
    assert not any(row["device_effect_verified"] for row in rows)
    assert not any(row["one_to_one_complete"] or row["original_runtime_receipt_verified"] for row in native["points"])
    assert menu["statistics"]["device_effect_verified_points"] == 0
    assert menu["statistics"]["original_action_consumer_missing_points"] == 29
    assert menu["statistics"]["alternative_aim_preview_points"] == 7
    assert all(not extra["counts_toward_v17_closure"] for extra in menu["current_ui_extensions"])
    assert [point["id"] for point in action["points"]] == [f"v17-{number:03}" for number in range(106, 137)]
    assert action["one_to_one_complete_count"] == 0
    component_keys = set(action["selection_route_history_evidence"]["closed_edges"]) | set(action["compensation_evidence"]["closed_edges"])
    assert len(component_keys) == 20
    action_points = {point["id"]: point for point in action["points"]}
    for point in action["points"]:
        closed = point["closed_reference_edges"]
        assert len(closed) == len(set(closed)) and set(closed) <= component_keys
        assert not point["one_to_one_complete"] and not point["original_runtime_receipt_verified"]
        assert len(point["next_exact_edges"]) == len(set(point["next_exact_edges"]))
    for point in native["points"][106:137]:
        match = action_points[point["id"]]
        assert point["component_evidence_key"] == match["evidence_key"]
        assert point["closed_reference_components"] == match["closed_reference_edges"]
        assert "beyond closed local component parity" in point["unresolved_stages"][0]
    gaps = [edge for point in action["points"] for edge in point["next_exact_edges"]]
    for group in ("selection_route_history_evidence", "compensation_evidence"):
        gaps += action[group]["remaining_edges"]
    # Remaining gaps must describe live provenance/receipt/restore, not list an
    # already closed numerical helper/component as an unimplemented algorithm.
    assert not any(re.search(r"\b(?:c4af8|c642c|c416c|c2d34|c571c)\b", gap) for gap in gaps)
    assert not any(key in gap for gap in gaps for key in component_keys)
    counts = action["closure_counts"]
    assert counts["mapped_points"] == 31 and counts["original_effect_points"] == 0
    assert counts["shared_reference_component_classes"] == len(component_keys)
    assert counts["per_point_unresolved_requirement_entries"] == sum(len(p["next_exact_edges"]) for p in action["points"]) == 113
    assert counts["unique_unresolved_requirements"] == len({e for p in action["points"] for e in p["next_exact_edges"]}) == 6
    assert "NOT point-specific" in counts["scope"]
    anchor = action["aim_anchor_producer_evidence"]
    assert "same first-bone world point" in anchor["semantics"]
    assert action_points["v17-107"]["closed_producer_edges"] == ["profile-first-bone-to-candidate-1e0-and-1ec"]
    assert not any("anchor1e0/1ec actual producers" in edge for edge in gaps)
    knocked = action["knocked_flag_producer_evidence"]
    assert "HasLastBreath status" in knocked["semantics"]
    assert action_points["v17-114"]["closed_producer_edges"] == ["has-last-breath-or-state-bit19-to-candidate-flag14"]
    assert not any("pawn-state bit19 producer" in edge for edge in gaps)
    assert not action["compensation_evidence"]["write_ready"]
    assert not action["compensation_evidence"]["target_effect_restored"]
    assert not action["cleanup_contract"]["production_restoration_verifier_installed"]
    assert "not invocation-count or thread-exclusion proof" in action["compensation_evidence"]["closed_edges"]["single_worker_sink"]


def require_recoil_source(source):
    assert not re.fullmatch(r"\s*\[\]\s*", body(source, "var supportedFields:"))
    assert body(source, "var supportedFields:").count(".recoil") >= 6
    assert "supportedFields" in body(source, "var configurableFields:")
    apply = body(source, "func apply(")
    assert "actionConsumer.applyRecoil" in apply
    assert "writeControllerAction" not in source and "initWithRequestAuthority" not in source
    assert "CoreSetAimConsumer" in source
    stop = body(source, "func stop(")
    assert "actionConsumer.stopRecoil" in stop


def require_aim_source(source):
    assert not re.fullmatch(r"\s*\[\]\s*", body(source, "var supportedFields:"))
    assert "CoreSetIsolatedWriteProbe" in source
    assert "persistentActionWorker" in source
    submit = body(source, "private func submitMergedAction(")
    assert "let cleanup = probe.stop()" not in submit
    assert "includeBattleInputs: true" in source
    assert "result.committed" in source and "cleanup.complete" in source
    assert "cleanup.targetEffectsAbandoned" in source and "unrestoredActionEffects" in source
    assert ".applied(observed: request.desired)" in source
    stop = body(source, "func stop(")
    assert "timer?.cancel()" in stop and "pendingProbes" in stop
    assert ".stoppedWithoutRestoration" in stop


def require_retained_effect_obligation(state, ledger):
    invalidation = body(state, "mutating func invalidateReadFrameObservation(")
    assert invalidation.index("actual = nil") < invalidation.index("guard pendingStop == nil")
    assert "mayHaveEffects = false" not in invalidation and "restoration = .notNeeded" not in invalidation
    rejected = body(state, "mutating func receive(").split("case .notApplied(let reason):", 1)[1].split("case .unavailable", 1)[0]
    assert "actual == nil && !effectsBeforePendingApply" in rejected
    prior_effect = rejected.split("} else {", 1)[1]
    assert "mayHaveEffects = false" not in prior_effect and "restoration = .notNeeded" not in prior_effect
    verify = body(ledger, "bool acknowledgeVerifiedRestoration(")
    for marker in ("receipt.attemptEpoch != attemptEpoch_", "!receipt.producerStopped", "!receipt.writerDrained",
                   "!receipt.identityStable", "!receipt.independentReadback", "!receipt.allOwnedRangesMatchBaseline", "!independentVerifier(receipt)"):
        assert marker in verify
    complete = body(ledger, "bool cleanupComplete(")
    assert "noInFlight && !unresolved_" in complete


class MatrixClosureAudit(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.menu = json.loads((FIXTURES / "core_set_v17_menu_point_map.json").read_text(encoding="utf-8"))
        cls.native = json.loads((FIXTURES / "core_set_v17_native_point_chain_map.json").read_text(encoding="utf-8"))
        cls.action = json.loads((FIXTURES / "core_set_v17_action_cycle_evidence.json").read_text(encoding="utf-8"))
        cls.state = read("lara/views/app/CoreSetFeatureState.swift")
        cls.ledger = read("lara/overlay/CoreSetActionEffectLedger.h")

    def test_137_and_31_counts_linked_without_component_effect_promotion(self):
        require_matrix(self.menu, self.native, self.action)

    def test_negative_promoted_duplicate_and_unresolved_component_matrices(self):
        changes = [lambda m, n, a: a["points"][0].update(one_to_one_complete=True),
                   lambda m, n, a: a["points"][0]["closed_reference_edges"].append("geometry_full"),
                   lambda m, n, a: a["points"][0]["next_exact_edges"].append("c4af8 prediction algorithm not implemented"),
                   lambda m, n, a: a["closure_counts"].update(original_effect_points=20),
                   lambda m, n, a: n["points"][106].update(component_evidence_key="action-cycle/v17-107"),
                   lambda m, n, a: m["current_ui_extensions"][0].update(counts_toward_v17_closure=True)]
        for change in changes:
            menu, native, action = deepcopy(self.menu), deepcopy(self.native), deepcopy(self.action)
            change(menu, native, action)
            with self.assertRaises(AssertionError): require_matrix(menu, native, action)

    def test_aim_and_recoil_use_one_checked_shared_action_owner(self):
        require_aim_source(read("lara/views/app/CoreSetAimConsumer.swift"))
        require_recoil_source(read("lara/views/app/CoreSetRecoilConsumer.swift"))

    def test_negative_missing_aim_writer_and_forgiven_stop_source_mutants(self):
        source = read("lara/views/app/CoreSetAimConsumer.swift")
        for altered in (source.replace("CoreSetIsolatedWriteProbe", "RemovedAimProbe"),
                        source.replace(".stoppedWithoutRestoration", ".restored"),
                        source.replace("includeBattleInputs: true", "includeBattleInputs: false")):
            with self.assertRaises(AssertionError): require_aim_source(altered)

    def test_local_models_have_no_receipt_or_effect_ledger_authority(self):
        for name in MODELS:
            source = read(f"lara/overlay/{name}")
            for forbidden in ("ActionEffectLedger", "acknowledgeVerifiedRestoration", "CoreSetApplyOutcome", ".applied(", ".restored", "_effects"):
                self.assertNotIn(forbidden, source)
        post = read("lara/overlay/CoreSetActionCompensationState.h")
        self.assertIn("ownerToken", post); self.assertIn("not a counter", post)
        self.assertIn("Invalid input clears only this Core-local model", post)
        self.assertIn("zero draft is NOT target restoration", post)

    def test_local_invalidation_and_ledger_keep_stop_restore_obligation(self):
        require_retained_effect_obligation(self.state, self.ledger)

    def test_negative_reset_and_independent_receipt_source_mutants(self):
        for state, ledger in (
            (self.state.replace("observationInvalidationReason = reason", "mayHaveEffects = false; observationInvalidationReason = reason"), self.ledger),
            (self.state, self.ledger.replace("!independentVerifier(receipt)", "false")),
            (self.state, self.ledger.replace("noInFlight && !unresolved_", "noInFlight"))):
            with self.assertRaises(AssertionError): require_retained_effect_obligation(state, ledger)


if __name__ == "__main__":
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(MatrixClosureAudit))
    if not result.wasSuccessful(): raise SystemExit(1)
    print("PASS: 137/31 metadata closure audit; 20 shared reference classes, original effects=0; no target access")
