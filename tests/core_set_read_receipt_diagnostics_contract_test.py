"""Read identity, capture attribution and observed lane invalidation contracts.

These tests inspect production source. They do not prove a device task port,
UIKit rendering, an atomic engine snapshot or any gameplay write.
"""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def body(source: str, signature: str) -> str:
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    for position in range(opening + 1, len(source)):
        depth += (source[position] == "{") - (source[position] == "}")
        if depth == 0:
            return source[opening + 1:position]
    raise AssertionError(f"unterminated body: {signature}")


def require_exact_invalidation(source: str) -> None:
    consumed = body(source, "func consumed(")
    invalidation = consumed[:consumed.index("if let stop =")]
    for identity in ("receipt.requestToken == invalidation.token", "receipt.snapshotID == invalidation.snapshot",
                     "receipt.hostGeneration == invalidation.generation", "receipt.configRevision == invalidation.revision",
                     "activeToken == invalidation.token", "pendingApply == nil", "pendingStop == nil"):
        assert identity in invalidation, f"missing invalidation boundary: {identity}"
    assert "invalidateReadFrameObservation(capability," in invalidation
    assert "invalidateReadFrameObservation" not in body(source, "private func clearStaleLane")


def require_empty_frame_recovery(source: str, signature: str, composer: str) -> None:
    publish = body(source, signature)
    assert "coordinator?.submitLane(" in publish, "complete empty snapshots must enter normal composition"
    assert "coordinator?.clearLane(" not in publish, "empty snapshots must not install a stop barrier"
    assert "invalidateReadFrameObservation" not in publish, "an empty observation must not revoke actual"
    frame = body(composer, "func makeFrame(")
    assert "input.configRevision >= previous.configRevision" in frame
    assert "input.snapshotID != previous.snapshotID" in frame
    assert "stoppedAtRevision[input.lane] = input.configRevision" not in frame
    assert "stoppedAtRevision[input.lane] = input.configRevision" in body(composer, "func makeClearFrame(")


class ReadReceiptDiagnosticsContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.session = read("lara/overlay/CoreSetReadSession.mm")
        cls.kernel_transport = read("lara/overlay/CoreSetKernelMappedReadTransport.mm")
        cls.consumers = {name: read(f"lara/views/app/CoreSet{name}Consumer.swift")
                         for name in ("Player", "Material", "Radar")}

    def test_identity_loss_clears_old_ready_diagnostic(self) -> None:
        ready = body(self.session, "- (BOOL)ready")
        self.assertLess(ready.index("[self disconnect]"), ready.index('"identity-lost stage=ready"'))
        self.assertIn("ready:NO", ready)
        read_at = body(self.session, "- (BOOL)readAt:")
        self.assertIn("identity-lost stage=read-before", read_at)
        self.assertIn("identity-lost stage=read-after", read_at)
        cleanup = body(self.session, "- (CoreSetReadCleanupResult *)disconnect")
        self.assertIn('_lastConnectDiagnostic = @"disconnected"', cleanup)
        self.assertIn('_lastReadDiagnostic = @"no-read-failure session-disconnected"', cleanup)
        self.assertIn("_lastLoggedReadFailureKind = nil", cleanup)
        self.assertNotIn("_readFailureSequence =", cleanup)
        self.assertIn("if (hadIdentity)", cleanup)

    def test_kernel_pid_fallback_keeps_exact_uuid_as_identity_authority(self) -> None:
        connect = body(self.session, "- (BOOL)connect")
        self.assertIn("candidate.kernelProc == 0", connect)
        self.assertIn('@"kernel-proc+mach-uuid"', connect)
        self.assertIn("findImageInTask:task", connect)
        self.assertIn("findImageWithUUID:CSUUID", connect)
        identity = body(self.session, "- (BOOL)identityStillValid:")
        self.assertIn("imageAt:_base task:_task", identity)
        self.assertIn("imageAt:_base matchesUUID:CSUUID", identity)

    def test_read_errors_have_current_generation_range_and_no_payload(self) -> None:
        diagnostic = body(self.session, "- (void)recordReadFailure:")
        for marker in ("++_readFailureSequence", "captureGeneration=%llu", "sessionGeneration=%llu",
                       "address=0x%llx length=%zu completed=%zu", "stage=read", "_lastReadFailureLogTime >= 30.0"):
            self.assertIn(marker, diagnostic)
        self.assertNotRegex(diagnostic, r"(?:scratch|destination|buffer)\.(?:bytes|description)")
        read_at = body(self.session, "- (BOOL)readAt:")
        for failure in ("read-arguments-invalid", "read-generation-stale", "read-identity-unavailable",
                        "read-allocation-failed", "read-partial-or-kern-failure", "read-identity-changed"):
            self.assertIn(failure, read_at)
        self.assertLess(read_at.index("done != length"), read_at.index("memcpy(destination, scratch.bytes, length)"))
        self.assertIn("Never expose a partially filled destination", read_at)

    def test_capture_only_attributes_errors_from_its_own_worker_period(self) -> None:
        for name, source in self.consumers.items():
            with self.subTest(consumer=name):
                capture = body(source, "private func capture()")
                before = capture.index("let failureSequence = self.session.readFailureSequence")
                collect = capture.index("Collector.capture(")
                after = capture.index("self.session.readFailureSequence != failureSequence")
                self.assertLess(before, collect)
                self.assertLess(collect, after)
                if name in ("Player", "Radar"):
                    self.assertIn("CoreSetPlayerCollector.lastCaptureDiagnostic()", capture)
                else:
                    self.assertIn("snapshot-validation-or-identity-failed", capture)
                self.assertIn("transport-errors=0", capture)
                self.assertIn("snapshot-stale stage=capture", capture)
                self.assertIn("captureAge >= 0, captureAge <= 0.5", capture)
                if name in ("Player", "Radar"):
                    self.assertIn("captureCompletedMonotonicSeconds", capture)
                    self.assertNotIn("captureStartedMonotonicSeconds", capture)
        preview = read("lara/views/app/CoreSetAimPreviewConsumer.swift")
        preview_capture = body(preview, "func capture(")
        self.assertNotIn("CoreSetPlayerCollector.capture", preview_capture)
        self.assertNotIn("CoreSetReadSession", preview)
        self.assertIn("store.latest()", preview_capture)
        self.assertIn("captureCompletedMonotonicSeconds", preview)
        self.assertIn("maximumRecordAge", preview)
        material = body(self.consumers["Material"], "private func capture()")
        self.assertLess(material.index("CoreSetMaterialCollector.capture("),
                        material.index("let capturedAt = snapshot?.captureCompletedMonotonicSeconds"))

    def test_player_capture_diagnostic_covers_roots_stability_and_success(self) -> None:
        header = read("lara/overlay/CoreSetPlayerSnapshot.h")
        collector = read("lara/overlay/CoreSetPlayerSnapshot.mm")
        self.assertIn("+ (NSString *)lastCaptureDiagnostic", header)
        self.assertIn("captureStartedMonotonicSeconds", header)
        stages = (
            "request-validation", "identity-initial", "root-world",
            "root-world-netdriver", "root-netdriver-serverconnection",
            "root-connection-playercontroller", "root-controller-camera-manager",
            "root-controller-local-character", "local-team", "root-level",
            "root-actor-array-core17-primary-or-level-fallback",
            "camera-candidate", "local-position", "actor-scan",
            "stability-roots", "stability-actor-membership", "stability-final-projection-roots",
            "stability-player-actors",
            "stability-count-actors", "stability-grenades", "stability-bones",
            "stability-battle-inputs", "stability-final-reprojection", "identity-final", "ready",
        )
        positions = []
        for stage in stages:
            token = f'CSLastCaptureDiagnostic = "{stage}"'
            self.assertIn(token, collector)
            positions.append(collector.index(token))
        self.assertEqual(positions, sorted(positions))
        self.assertIn("static thread_local std::string CSLastCaptureDiagnostic", collector)
        self.assertIn("snapshot.captureStartedMonotonicSeconds = captureStartedAt", collector)
        self.assertIn("snapshot.captureCompletedMonotonicSeconds = captureCompletedAt", collector)
        self.assertIn("freshnessBasis=final-reprojected", collector)
        self.assertIn("displayFields=final-reprojected", collector)
        self.assertNotIn("finalReprojectionAge > 0.45", collector)
        self.assertNotIn("final-reprojection-stale age=", collector)
        self.assertIn("This is roster production, not presentation", collector)
        for final_identity in ("finalWorld != world", "finalLevel != level",
                               "finalController != controller", "finalLocal != local",
                               "finalManager != manager"):
            self.assertIn(final_identity, collector)
        for counter in ("speedMatched=%lu", "enemyTeam=%lu", "stateBit20Clear=%lu",
                        "lifecyclePass=%lu", "healthPass=%lu", "rootValid=%lu",
                        "meshValid=%lu", "coreAccepted=%lu", "producedPlayers=%lu",
                        "producedBots=%lu"):
            self.assertIn(counter, collector)
        self.assertNotIn("captureBudgetExceeded", collector)
        self.assertNotIn("capture-budget-exceeded", collector)
        self.assertLess(collector.index('CSLastCaptureDiagnostic = "request-validation"'),
                        collector.index('CSLastCaptureDiagnostic = "ready"'))

    def test_player_matches_core_continuous_retry_and_exact_controller_hops(self) -> None:
        player = self.consumers["Player"]
        collector = read("lara/overlay/CoreSetPlayerSnapshot.mm")
        apply = body(player, "func apply(")
        self.assertLess(apply.index("armCaptureLoop()"), apply.index("tick()"))
        self.assertIn("completion(request.token, .applied(observed: settings))", apply)
        self.assertNotIn("pendingApply = (request.token, completion)", apply)
        self.assertLess(apply.index("completion(request.token, .applied(observed: settings))"),
                        apply.index("armCaptureLoop()"))
        self.assertIn("player-loop contract=latest-snapshot-v10", player)
        self.assertIn("presentationInterval=0.016 presentationClock=dispatch-source", player)
        self.assertIn("rosterRetry=0.15 rosterRefresh=1.0", player)
        self.assertIn("firstFrame=current-camera-reprojection geometry=independent-camera-root-reprojection", player)
        self.assertIn("presentation=current-camera-cached-world-reprojection", player)
        self.assertIn("configurationApply=immediate renderEvidence=separate", player)
        loop = body(player, "private func armCaptureLoop()")
        self.assertIn("withTimeInterval: 0.15, repeats: true", loop)
        retry = body(player, "private func retryCapture(")
        for gate in ("guard activeSessionMatches", "captureFailureStartedAt",
                     ">= 0.5", "recordInvalidation: false", "preserveRefresh: true",
                     "armCaptureLoop()"):
            self.assertIn(gate, retry)
        expiry = body(player, "private func expireGeometryIfNeeded()")
        for gate in ("CACurrentMediaTime()", "now - since >= 0.5",
                     "now - freshest >= 0.5", "commands: []", "geometryExpired = true"):
            self.assertIn(gate, expiry)
        geometry = body(player, "private func refreshGeometry()")
        for gate in ("geometryInFlight", "CoreSetPlayerCollector.refreshGeometry",
                     "currentGeometry ?? currentRoster", "snapshotID == rosterID", "submitGeometry"):
            self.assertIn(gate, geometry)
        presentation_loop = body(player, "private func armPresentationLoop()")
        for gate in ("DispatchSource.makeTimerSource(queue: presentationWorker)",
                     "repeating: .milliseconds(16)", "leeway: .milliseconds(2)",
                     "enqueuePresentationTick()", "timer.resume()"):
            self.assertIn(gate, presentation_loop)
        self.assertNotIn("Timer.scheduledTimer", presentation_loop)
        enqueue_tick = body(player, "private func enqueuePresentationTick()")
        for gate in ("presentationTickLock.lock()", "!presentationTickQueued",
                     "presentationTickQueued = true", "DispatchQueue.main.async",
                     "presentationTickQueued = false", "refreshPresentation()"):
            self.assertIn(gate, enqueue_tick)
        presentation = body(player, "private func refreshPresentation()")
        for gate in ("presentationInFlight", "!awaitingReceipt",
                     "CoreSetPlayerCollector.reprojectPresentation",
                     "presentationSession", "snapshotID == geometryID", "submitGeometry"):
            self.assertIn(gate, presentation)
        self.assertIn("presentation-reprojection", collector)
        self.assertIn("camera=current cameraOffset=0x%llx actorRoots=cached screenPoints=reprojected", collector)
        native_start = collector.index(
            "+ (CoreSetPlayerSnapshot *)reprojectPresentationForSnapshot:")
        native_end = collector.index(
            "+ (CoreSetPlayerSnapshot *)refreshActionForSnapshot:", native_start)
        native_presentation = collector[native_start:native_end]
        for required in ("base + CSWorldSlot", "rosterCameraManagerAddress",
                         "CSCameraValid(candidate)", "cameraOffset = offset",
                         "oldMark.actorWorldPosition",
                         "CSRefreshPlayerMark"):
            self.assertIn(required, native_presentation)
        for forbidden in ("CSReadCorePlayerState", "CSPosition(session", "actorAddress +"):
            self.assertNotIn(forbidden, native_presentation)
        capture = body(player, "private func capture()")
        self.assertIn("self.retryCapture(failureReason, token: token)", capture)
        failed_capture = capture[capture.index("guard let snapshot,"):capture.index("self.lastCaptureFailure = nil")]
        self.assertNotIn("pendingApply = nil", failed_capture)
        self.assertIn("self.currentRoster = snapshot", capture)
        self.assertIn("self.refreshPresentation()", capture)
        self.assertNotIn("self.submitGeometry(snapshot", capture)
        tick = body(player, "private func tick()")
        self.assertIn("currentRoster == nil ? 0.15 : 1.0", tick)
        self.assertIn("CACurrentMediaTime() - lastFullCaptureAttemptEndedAt", tick)
        capture = body(player, "private func capture()")
        self.assertIn("lastFullCaptureAttemptEndedAt = CACurrentMediaTime()", capture)
        submit = body(player, "private func submitGeometry(")
        self.assertIn("guard !awaitingReceipt else { return }", submit)
        self.assertIn("awaitingReceipt = true", submit)
        receipt = body(player, "func consumed(")
        self.assertGreaterEqual(receipt.count("awaitingReceipt = false"), 2)
        self.assertIn("retryCapture(reason, token: pending.0)", receipt)
        identity = body(player, "private var expectedReadIdentityMatches:")
        self.assertIn("matches(session) || matches(geometrySession) || matches(presentationSession)", identity)
        shutdown = body(player, "func shutdownReadSession()")
        for reset in ("refresh?.invalidate(); refresh = nil", "awaitingReceipt = false",
                      "awaitingReceiptSince = nil", "activeSessionGeneration = nil",
                      "captureFailureStartedAt = nil"):
            self.assertIn(reset, shutdown)
        self.assertIn("presentationTimer?.cancel(); presentationTimer = nil", shutdown)
        self.assertIn("presentationSession.disconnect()", shutdown)
        cadence = body(player, "private func recordPresentationCadenceIfNeeded()")
        for gate in ("presentation-reprojection", "presentationReceiptCount += 1",
                     "elapsed >= 2", "effectiveFPS=%.2f", "receipt=local-renderer"):
            self.assertIn(gate, cadence)
        ordered = [collector.index(f'CSLastCaptureDiagnostic = "{stage}"') for stage in (
            "root-world-netdriver", "root-netdriver-serverconnection",
            "root-connection-playercontroller", "root-controller-camera-manager",
            "root-controller-local-character")]
        self.assertEqual(ordered, sorted(ordered))
        capture_root = collector.index('CSLastCaptureDiagnostic = "root-world-netdriver"')
        self.assertLess(collector.index("controller + 0x680, &manager", capture_root),
                        collector.index("controller + 0x3540, &local", capture_root))
        self.assertLess(collector.index('CSLastCaptureDiagnostic = "root-world-netdriver"'),
                        collector.index('CSLastCaptureDiagnostic = "root-level"'))

    def test_periodic_failure_invalidates_only_after_exact_clear_receipt(self) -> None:
        for name, source in self.consumers.items():
            with self.subTest(consumer=name):
                require_exact_invalidation(source)
                clear = body(source, "private func clearStaleLane")
                self.assertIn("recordInvalidation && pendingApply == nil && pendingStop == nil", clear)
                self.assertIn("refresh?.invalidate(); refresh = nil", clear)
                receipt = body(source, "func consumed(")
                expected = "expectedCapturedAt.map" if name == "Material" else "expectedCompletedAt.map"
                self.assertIn(expected, receipt)
                self.assertIn("CACurrentMediaTime() - $0 <= 0.5", receipt)
                if name == "Player":
                    self.assertIn("recordInvalidation: false", body(source, "private func retryCapture("))
                else:
                    self.assertIn("recordInvalidation: false", receipt)
                self.assertIn("snapshot-stale stage=receipt", receipt)
        radar = body(self.consumers["Radar"], "func consumed(")
        self.assertIn("guard invalidationLanes == ownedLanes else { return }", radar)
        clear = body(self.consumers["Radar"], "private func clearStaleLanes")
        self.assertEqual(clear.count("snapshotID: id"), 2)
        broken = self.consumers["Player"].replace("receipt.snapshotID == invalidation.snapshot", "true", 1)
        with self.assertRaisesRegex(AssertionError, "snapshotID"):
            require_exact_invalidation(broken)

    def test_empty_then_nonempty_same_revision_keeps_both_lanes_live(self) -> None:
        composer = read("lara/views/app/CoreSetRuntimeCoordinator.swift")
        for name, signature in (("Material", "private func submit("), ("Radar", "private func publish(")):
            with self.subTest(consumer=name):
                source = self.consumers[name]
                # Normal composition allows an empty snapshot followed by a
                # different snapshot ID at the same configuration revision.
                require_empty_frame_recovery(source, signature, composer)
                self.assertIn("coordinator?.clearLane(", body(source, "private func clearStaleLane"))
                self.assertIn("coordinator?.clearLane(", body(source, "func stop("))
                # Reintroducing the old empty->clear route must fail this
                # positive contract for both producers, even with valid IDs.
                broken = source.replace("let accepted = coordinator?.submitLane(input)",
                                        "let accepted = commands.isEmpty ? coordinator?.clearLane(input) : coordinator?.submitLane(input)", 1) \
                    if name == "Material" else source.replace(
                        "return coordinator?.submitLane(CoreSetLaneSubmission(lane: lane,",
                        "if commands.isEmpty { return coordinator?.clearLane(lane) == true }\n        return coordinator?.submitLane(CoreSetLaneSubmission(lane: lane,", 1)
                with self.assertRaisesRegex(AssertionError, "stop barrier"):
                    require_empty_frame_recovery(broken, signature, composer)

    def test_transport_and_writers_keep_the_audited_boundary(self) -> None:
        self.assertIn('dlsym(RTLD_DEFAULT, "task_read_for_pid")', self.session)
        self.assertIn('dlsym(RTLD_DEFAULT, "task_for_pid")', self.session)
        self.assertIn('dlsym(RTLD_DEFAULT, "processor_set_tasks")', self.session)
        self.assertIn("procbyname(CSProcessName)", self.session)
        read_at = body(self.session, "- (BOOL)readAt:")
        self.assertNotRegex(read_at, r"\b(?:task_for_pid|remoteRead|vmmapremotepage|ds_kread\w*)\s*\(")
        self.assertNotIn("mach_vm_write", self.session)
        self.assertIn("physicalAddressForUserAddressLocked:current", self.kernel_transport)
        self.assertIn("ds_kreadbuf_checked(kernelAddress", self.kernel_transport)
        self.assertNotIn("vmmapremotepagereadonly", self.kernel_transport)
        for forbidden in ("ds_kwrite", "mach_vm_write", "VM_PROT_WRITE", "RemoteCall"):
            self.assertNotIn(forbidden, self.kernel_transport)
        aim = read("lara/views/app/CoreSetAimConsumer.swift")
        self.assertIn("CoreSetIsolatedWriteProbe", aim)
        self.assertIn("result.committed", aim)
        self.assertIn("cleanup.complete", aim)
        self.assertIn(".applied(observed:", aim)
        self.assertNotRegex(body(aim, "var supportedFields:"), r"^\s*\[\]\s*$")
        recoil = read("lara/views/app/CoreSetRecoilConsumer.swift")
        recoil_apply = body(recoil, "func apply(")
        self.assertIn("actionConsumer.applyRecoil", recoil_apply)
        self.assertIn(".unavailable(reason:", recoil_apply)
        self.assertNotIn("writeControllerAction", recoil)
        self.assertNotIn(".applied(observed:", recoil_apply)
        self.assertNotRegex(body(recoil, "var supportedFields:"), r"^\s*\[\]\s*$")
        writer = read("lara/overlay/CoreSetTargetWriteSession.mm")
        self.assertIn("initWithRequestAuthority:nil", writer)
        self.assertIn("active-request-snapshot-authority-unavailable", writer)


if __name__ == "__main__":
    unittest.main(verbosity=2)
