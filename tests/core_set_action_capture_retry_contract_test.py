import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "lara/views/app/CoreSetAimConsumer.swift").read_text(encoding="utf-8")
SNAPSHOT_H = (ROOT / "lara/overlay/CoreSetPlayerSnapshot.h").read_text(encoding="utf-8")
SNAPSHOT_MM = (ROOT / "lara/overlay/CoreSetPlayerSnapshot.mm").read_text(encoding="utf-8")


def section(start: str, end: str) -> str:
    begin = SOURCE.index(start)
    finish = SOURCE.index(end, begin)
    return SOURCE[begin:finish]


class ActionCaptureRetryContractTest(unittest.TestCase):
    def test_transient_aim_sample_loss_keeps_request_live(self):
        tick = section("private func tick(_ request:", "private func publish(_ text:")
        self.assertIn("noteCaptureFailure(capture.failure, lane: \"aim\"", tick)
        self.assertIn("let failedAt = CACurrentMediaTime()", tick)
        self.assertIn("deferBattleCapture(now: failedAt)", tick)
        self.assertNotIn("战斗采样失效或请求撤销", tick)
        self.assertNotIn("fail(request, capture.failure", tick)

    def test_transient_recoil_sample_loss_keeps_request_live(self):
        tick = section("private func tickRecoilOnly", "private func runRecoilFallback")
        self.assertIn("noteCaptureFailure(capture.failure, lane: \"recoil\"", tick)
        self.assertIn("let failedAt = CACurrentMediaTime()", tick)
        self.assertIn("deferBattleCapture(now: failedAt)", tick)
        self.assertNotIn("压枪战斗采样失效或请求已撤销", tick)

    def test_retry_is_bounded_and_diagnostics_are_throttled(self):
        self.assertIn("nextBattleCaptureAt = now + 0.15", SOURCE)
        self.assertIn("now - lastAimCaptureFailureLogAt >= 3", SOURCE)
        self.assertIn("now - lastRecoilCaptureFailureLogAt >= 3", SOURCE)
        self.assertIn("stage=retry terminal=0", SOURCE)

    def test_recoil_does_not_request_unused_bones(self):
        recoil = section("private func tickRecoilOnly", "private func runRecoilFallback")
        self.assertIn("includeBones: false,", recoil)
        self.assertIn("includeBots: false, targetActor: 0", recoil)
        self.assertIn("includeBones && includeBots", SOURCE)
        self.assertIn("playerBones: demand.playerBones", SOURCE)
        self.assertIn("botBones: demand.botBones", SOURCE)

    def test_heavy_roster_is_followed_by_fast_action_refresh(self):
        self.assertIn("refreshActionForSnapshot", SNAPSHOT_H)
        self.assertIn("refreshAction(for: roster", SOURCE)
        self.assertIn("rosterPublication = ActionRosterPublication", SOURCE)
        self.assertIn("targetActor: refreshTarget", SOURCE)
        self.assertIn("targetActor: 0", SOURCE)
        self.assertIn("actorArrayScan=0", SNAPSHOT_MM)

    def test_heavy_capture_is_confined_to_independent_producer(self):
        producer = section("private func produceRoster()", "private func publishedRoster")
        action = section("private func captureAction", "private func shouldAttemptBattleCapture")
        self.assertIn('DispatchQueue(label: "coreset.basic.aim.roster"', SOURCE)
        self.assertIn("private var rosterSession = CoreSetReadSession()", SOURCE)
        self.assertIn("CoreSetPlayerCollector.capture(rosterSession", producer)
        self.assertIn("includeBattleInputs: false", producer)
        self.assertNotIn("CoreSetPlayerCollector.capture", action)
        self.assertIn("rosterLock.lock()", SOURCE)
        self.assertIn("let snapshot: CoreSetPlayerSnapshot", SOURCE)

    def test_stop_drains_both_action_and_roster_sessions(self):
        self.assertIn("private func drainRosterProducer() -> Bool", SOURCE)
        self.assertGreaterEqual(SOURCE.count("let rosterClean = self.drainRosterProducer()"), 2)
        self.assertIn("let rosterClean = drainRosterProducer()", SOURCE)
        self.assertIn("rosterClean && self.pendingProbes.isEmpty", SOURCE)
        self.assertIn("rosterClean && pendingProbes.isEmpty", SOURCE)

    def test_action_session_owns_inputs_generation_and_lock_policy(self):
        self.assertNotIn("!source.battleInputsPresent", SNAPSHOT_MM)
        self.assertIn("snapshot.sessionGeneration = generation", SNAPSHOT_MM)
        self.assertIn("snapshot.battleInputsPresent = YES", SNAPSHOT_MM)
        aim = section("private func tick(_ request:", "private func publish(_ text:")
        self.assertIn("request.desired.lockSameTarget == true ? selectedActor : 0", aim)
        self.assertIn("targetActor: refreshTarget", aim)

    def test_fast_target_path_refreshes_current_inputs_geometry_and_identity(self):
        for token in (
            'CSLastCaptureDiagnostic = targetActor ? "action-refresh-target"',
            "CSReadCorePlayerState(session, generation, oldMark.actorAddress",
            "CSRefreshActionBone(session, generation, base",
            'CSLastCaptureDiagnostic = "action-refresh-inputs-final"',
            "controller + 0x620", "controller + 0x828",
            'CSLastCaptureDiagnostic = "action-refresh-identity-final"',
            "finalWorld != world", "finalController != controller", "finalLocal != local",
        ):
            self.assertIn(token, SNAPSHOT_MM)

    def test_long_capture_rechecks_request_identity_before_consuming_snapshot(self):
        aim = section("private func tick(_ request:", "private func publish(_ text:")
        recoil = section("private func tickRecoilOnly", "private func runRecoilFallback")
        self.assertGreaterEqual(aim.count("isLive(request.token, host: hostGeneration)"), 2)
        self.assertGreaterEqual(recoil.count("isLive(recoilRequest.token, host: hostGeneration)"), 2)


if __name__ == "__main__":
    unittest.main()
