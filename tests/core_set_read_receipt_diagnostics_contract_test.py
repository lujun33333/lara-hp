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
        self.assertIn("imageAt:_base task:_task", body(self.session, "- (BOOL)identityStillValid:"))

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
                self.assertIn("snapshot-validation-or-identity-failed transport-errors=0", capture)
                self.assertIn("snapshot-stale stage=capture", capture)
                self.assertIn("captureAge >= 0, captureAge <= 0.5", capture)
        preview = read("lara/views/app/CoreSetAimPreviewConsumer.swift")
        self.assertIn("self.session.readFailureSequence != failureSequence", body(preview, "func capture("))
        material = body(self.consumers["Material"], "private func capture()")
        self.assertLess(material.index("CoreSetMaterialCollector.capture("),
                        material.index("let capturedAt = snapshot?.captureCompletedMonotonicSeconds"))

    def test_periodic_failure_invalidates_only_after_exact_clear_receipt(self) -> None:
        for name, source in self.consumers.items():
            with self.subTest(consumer=name):
                require_exact_invalidation(source)
                clear = body(source, "private func clearStaleLane")
                self.assertIn("recordInvalidation && pendingApply == nil && pendingStop == nil", clear)
                self.assertIn("refresh?.invalidate(); refresh = nil", clear)
                receipt = body(source, "func consumed(")
                self.assertIn("expectedCapturedAt.map", receipt)
                self.assertIn("CACurrentMediaTime() - $0 <= 0.5", receipt)
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
        for name in ("Aim", "Recoil"):
            source = read(f"lara/views/app/CoreSet{name}Consumer.swift")
            apply = body(source, "func apply(")
            self.assertIn("audited-writer-or-receipt-unavailable", apply)
            self.assertIn("committed=0", apply)
            self.assertIn(".notApplied(reason:", apply)
            self.assertNotIn("writeControllerAction", source)
            self.assertNotIn(".applied(observed:", apply)
            self.assertRegex(body(source, "var supportedFields:"), r"^\s*\[\]\s*$")
        writer = read("lara/overlay/CoreSetTargetWriteSession.mm")
        self.assertIn("initWithRequestAuthority:nil", writer)
        self.assertIn("active-request-snapshot-authority-unavailable", writer)


if __name__ == "__main__":
    unittest.main(verbosity=2)
