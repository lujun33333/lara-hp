"""Source contracts for the live local home producers; no device/network execution."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


def require_owner_contract(telemetry, producer):
    for marker in (
        "[CoreSetHomeObservationField: CoreSetHomeReferenceFieldObservation]",
        "value.currentGeneration == referenceGenerations[field]",
        "value.publishGenerationRaw == UInt64.max",
        "value.nativeSequence >= (referenceNativeSequences[field] ?? 0)",
        "new >= old",
        "oldTotal == newTotal",
        "referenceProvider?.stopObservation()",
    ):
        assert marker in telemetry
    for marker in (
        "final class CoreSetHomeRuntimeProducer: CoreSetHomeReferenceObservationProvider",
        "originalRuntimeReceipt: false",
        "localEquivalent: true",
        '"local-kernelcache-copy"',
        "func stopObservation() -> Bool",
    ):
        assert marker in producer


def owner_methods(source):
    for match in re.finditer(r"\bfunc (\w+)\([^\n]*", source):
        opening = source.find("{", match.start())
        if opening < 0:
            continue
        depth = 0
        for position in range(opening, len(source)):
            if source[position] == "{":
                depth += 1
            elif source[position] == "}":
                depth -= 1
                if depth == 0:
                    yield match.group(1), source[opening:position + 1]
                    break


class HomeRuntimeProducerContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        read = lambda p: (ROOT / p).read_text(encoding="utf-8")
        cls.telemetry = read("lara/views/app/CoreSetHomeTelemetrySource.swift")
        cls.producer = read("lara/views/app/CoreSetHomeRuntimeProducer.swift")
        cls.coordinator = read("lara/views/app/CoreSetRuntimeCoordinator.swift")
        cls.manager = read("lara/classes/laramgr.swift")
        cls.header = read("lara/kexploit/darksword.h")
        cls.dark = read("lara/kexploit/darksword.m")
        cls.fetch = read("lara/funcs/fetchkcache.swift")
        cls.menu = read("lara/views/app/CoreSetMenuViewController.swift")

    def test_per_owner_identity_generation_sequence_and_detach(self):
        require_owner_contract(self.telemetry, self.producer)
        self.assertIn("homeTelemetry.bindReferenceObservationProvider(homeProducer)", self.coordinator)
        self.assertIn("homeTelemetry.stopObservations()", self.coordinator)
        self.assertIn('producer=%@ confirmed=0 original-runtime-receipt=0', self.telemetry)
        self.assertIn('localAction ? "local-action-bound"', self.telemetry)
        self.assertIn('"local-equivalent-bound" : "original-action-unbound"', self.telemetry)
        self.assertNotIn('producer=unbound confirmed=0', self.telemetry)

    def test_negative_mutants_drop_required_owner_gates(self):
        for source_name, source, marker in (
            ("telemetry", self.telemetry, "value.currentGeneration == referenceGenerations[field]"),
            ("telemetry", self.telemetry, "value.publishGenerationRaw == UInt64.max"),
            ("telemetry", self.telemetry, "oldTotal == newTotal"),
            ("producer", self.producer, "originalRuntimeReceipt: false"),
            ("producer", self.producer, "func stopObservation() -> Bool"),
        ):
            mutated = source.replace(marker, "REMOVED", 1)
            with self.assertRaises(AssertionError, msg=source_name + "/" + marker):
                require_owner_contract(mutated if source_name == "telemetry" else self.telemetry,
                                       mutated if source_name == "producer" else self.producer)

    def test_darksword_stage_and_page_callbacks_are_real_loop_events(self):
        for marker in ("ds_stage_event_callback_t", "ds_page_event_callback_t"):
            self.assertIn(marker, self.header)
            self.assertIn(marker, self.dark)
        for marker in ("ds_set_stage_event_callback", "ds_set_page_event_callback"):
            self.assertIn(marker, self.header)
            self.assertIn(marker, self.dark)
            self.assertIn(marker, self.manager)
        for marker in ("ds_page_begin(n_of_search_mappings * pages_per_search_mapping)",
                       "ds_page_update(s * pages_per_search_mapping + current_page + 1)",
                       "ds_page_begin(search_mapping_size / PAGE_SZ)",
                       "ds_page_finish(success, success ? 0 : -1)",
                       'ds_stage_event("正在遍历内核结构", 1, 0)'):
            self.assertIn(marker, self.dark)
        self.assertIn("completed >= (old?.completedPages ?? 0)", self.manager)
        self.assertIn("total == (old?.totalPages ?? total)", self.manager)

    def test_kernelcache_progress_uses_fstat_and_actual_written_bytes(self):
        for marker in ("fstat(src, &sourceStat)", "expectedBytes = UInt64(sourceStat.st_size)",
                       "transferOwner.begin(totalBytes: expectedBytes, action: action)",
                       "UInt64(totalBytes + written)", "UInt64(totalBytes) != expectedBytes",
                       "transferOwner.complete(action: action)"):
            self.assertIn(marker, self.fetch)
        self.assertNotIn('stage = "ota-download"', self.fetch)
        self.assertIn("本机 kernelcache 复制进度（Core 同位本地等价）", self.menu)

    def test_information_is_actual_offset_lifecycle_but_not_original_receipt(self):
        for marker in ("CoreSetKernelInformationOwner.shared.beginResolve(action: action)",
                       "CoreSetKernelInformationOwner.shared.didResolveArtifact(action: action)",
                       "CoreSetKernelInformationOwner.shared.completeValidation(action: action)",
                       "CoreSetKernelInformationOwner.shared.failValidation"):
            self.assertIn(marker, self.coordinator)
        for marker in ("kernelcache 已读取，正在验证偏移", "本机内核偏移已验证",
                       "CoreSetHomeInformationState", "localEquivalent: true"):
            self.assertIn(marker, self.producer)

    def test_environment_uses_core_v17_support_constants_and_firmware_owner(self):
        for marker in ("hw.cpufamily", "0xab345f09", "0x01d7a72b", "0x1d5a87e8",
                       "0x92fb37c8", "0x462504d2", "version.majorVersion == 17",
                       "version.majorVersion == 18", "version.majorVersion == 26",
                       "let firmware = CoreSetKernelCacheTransferOwner.shared.snapshot()"):
            self.assertIn(marker, self.producer)
        self.assertIn("manager.hasOffsets && information.status == 2", self.producer)
        self.assertIn("firmware.phase == 6 || information.status == 3", self.producer)
        self.assertNotIn("axDeviceSupportStatus()", self.producer)

    def test_home_actions_are_bound_to_live_local_owners(self):
        for marker in ("menu.onHomeAction =", "performHomeKernelAction",
                       "performHomeInformationAction", "recordHomeAction"):
            self.assertIn(marker, self.coordinator)
        for marker in ("startHomeKernelAction", "startHomeInformationAction",
                       ".homeKernelAction", ".homeInformationAction"):
            self.assertIn(marker, self.menu)

    def test_one_local_action_identity_flows_to_its_fields_and_receipts(self):
        for marker in ("final class CoreSetLocalHomeAction", "let requestID = UUID()",
                       "let generation: UInt64", "func nextSequence() -> UInt64",
                       "action.nextStamp()", "originalRuntimeReceipt: false"):
            self.assertIn(marker, self.producer)
        for marker in ("requestID: action.requestID", "nativeGeneration: action.generation",
                       "manager.run(action: action)", "fetchkcache(action: action)",
                       "CoreSetKernelInformationOwner.shared.beginResolve(action: action)",
                       "CoreSetKernelInformationOwner.shared.completeValidation(action: action)"):
            self.assertIn(marker, self.coordinator)
        for marker in ("actionRequestID: action.requestID",
                       "actionGeneration: action.generation",
                       "actionSequence: action.nextSequence()"):
            self.assertIn(marker, self.manager)
        for marker in ("requestID: stage.actionRequestID", "generation: stage.actionGeneration",
                       "nativeSequence: stage.actionSequence", "requestID: page.actionRequestID",
                       "generation: page.actionGeneration", "nativeSequence: page.actionSequence"):
            self.assertIn(marker, self.producer)
        self.assertNotIn("darkSwordRequests", self.producer)

    def test_stop_and_cancellation_are_fail_closed(self):
        for marker in ("action.requestCancellation()", "phase: .stopping",
                       "phase: .stopFailed", "errorCode: -2"):
            self.assertIn(marker, self.coordinator)
        for marker in ("CoreSetKernelInformationOwner.shared.cancelRequested(action: action)",
                       "CoreSetKernelCacheTransferOwner.shared.cancelRequested(action: action)",
                       "CoreSetKernelInformationOwner.shared.stoppedAfterCancellation(action: action)"):
            self.assertIn(marker, self.coordinator)
        for marker in ("if action.isCancellationRequested { return false }",
                       "transferOwner.stoppedAfterCancellation(action: action)",
                       "unlink(outpath)"):
            self.assertIn(marker, self.fetch)
        self.assertIn("本机 kernelcache 复制进度（Core 同位本地等价）", self.menu)
        self.assertNotIn('stage = "ota-download"', self.producer)
        self.assertIn("[.completed, .failed, .stopped, .stopFailed].contains(phase)",
                      self.coordinator)

    def test_owner_lock_never_nests_action_lock(self):
        checked = 0
        for name, body in owner_methods(self.producer):
            if name not in {"begin", "advance", "complete", "fail", "cancelRequested",
                            "stoppedAfterCancellation", "beginResolve", "didResolveArtifact",
                            "completeValidation", "failValidation", "publishCachedValidation"}:
                continue
            self.assertIn("let stamp = action.nextStamp()", body, name)
            self.assertLess(body.index("let stamp = action.nextStamp()"),
                            body.index("lock.lock()"), name)
            locked = body[body.index("lock.lock()"):]
            self.assertNotIn("action.nextSequence()", locked, name)
            self.assertNotIn("action.isCancellationRequested", locked, name)
            checked += 1
        self.assertEqual(checked, 13)


if __name__ == "__main__":
    unittest.main()
