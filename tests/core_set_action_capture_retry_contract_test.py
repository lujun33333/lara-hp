import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AIM = (ROOT / "lara/views/app/CoreSetAimConsumer.swift").read_text(encoding="utf-8")
COORDINATOR = (ROOT / "lara/views/app/CoreSetRuntimeCoordinator.swift").read_text(encoding="utf-8")
SNAPSHOT_MM = (ROOT / "lara/overlay/CoreSetPlayerSnapshot.mm").read_text(encoding="utf-8")


def section(source: str, start: str, end: str) -> str:
    begin = source.index(start)
    return source[begin:source.index(end, begin)]


class ActionCaptureRetryContractTest(unittest.TestCase):
    def test_transient_action_publication_loss_keeps_request_live(self):
        aim = section(AIM, "private func tick(_ request:", "private func publish(_ text:")
        recoil = section(AIM, "private func tickRecoilOnly", "private func runRecoilFallback")
        for body, lane in ((aim, "aim"), (recoil, "recoil")):
            self.assertIn('noteCaptureFailure("battle-publication-waiting", lane: "' + lane + '"', body)
            self.assertIn("deferBattleCapture(now: failedAt)", body)
            self.assertNotIn("fail(request, capture", body)

    def test_retry_and_diagnostic_cadence_are_bounded(self):
        self.assertIn("nextBattleCaptureAt = now + 0.15", AIM)
        self.assertIn("now - lastAimCaptureFailureLogAt >= 3", AIM)
        self.assertIn("now - lastRecoilCaptureFailureLogAt >= 3", AIM)
        self.assertIn("stage=retry terminal=0", AIM)

    def test_one_union_producer_owns_full_capture(self):
        producer = section(COORDINATOR, "final class CoreSetBattleProducer", "final class CoreSetRuntimeCoordinator")
        self.assertIn('DispatchQueue(label: "coreset.battle.producer"', producer)
        self.assertIn("private let session = CoreSetReadSession()", producer)
        self.assertIn("CoreSetPlayerCollector.capture(session", producer)
        self.assertIn("playerBones: aim != nil || display?.playerBones == true", producer)
        self.assertIn("includeBattleInputs: actionPrimary != nil", producer)
        self.assertIn("candidateStore.publishCandidateKey(", producer)
        self.assertNotIn("CoreSetPlayerCollector.capture", AIM)

    def test_action_consumer_gets_compact_candidate_and_input_only(self):
        self.assertIn("battleProducer.copyAction(", AIM)
        self.assertIn("dynamics.plan(candidate: candidate, input: input", AIM)
        self.assertIn("recoilDynamics.plan(input: input", AIM)
        self.assertNotIn("snapshot: CoreSetPlayerSnapshot", AIM)

    def test_prior_key_is_owned_by_publication_store(self):
        self.assertIn("publishMissing(forSessionGeneration:", COORDINATOR)
        self.assertIn("capturedAt - _capturedAt > 0.075000001", SNAPSHOT_MM)
        self.assertIn("previousActor: candidateStore.copyRecord()?.raw.candidateKey ?? 0", COORDINATOR)

    def test_stop_releases_demands_without_disconnect_of_shared_session(self):
        self.assertIn("battleProducer.releaseAim(requestID:", AIM)
        self.assertIn("battleProducer.releaseRecoil(requestID:", AIM)
        self.assertNotIn("session.disconnect()", AIM)
        self.assertNotIn("rosterSession", AIM)

    def test_route_authority_is_not_inferred_from_fire(self):
        self.assertIn("guard input.routeAuthorityResolved", AIM)
        self.assertIn("switch input.resolvedActionSlotRaw", AIM)
        self.assertIn("拒绝用 firing 字节猜测 +0x620/+0x828", AIM)
        self.assertNotIn("routeDynamics.slot(firingSample:", AIM)


if __name__ == "__main__":
    unittest.main()
