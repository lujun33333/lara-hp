"""Source contracts for the live local home producers; no device/network execution."""
from pathlib import Path
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
                       "transferOwner.begin(totalBytes: expectedBytes)",
                       "UInt64(totalBytes + written)", "UInt64(totalBytes) != expectedBytes",
                       "transferOwner.complete()"):
            self.assertIn(marker, self.fetch)
        self.assertNotIn('stage = "ota-download"', self.fetch)
        self.assertIn("本机 kernelcache 复制进度（Core 同位本地等价）", self.menu)

    def test_information_is_actual_offset_lifecycle_but_not_original_receipt(self):
        for marker in ("CoreSetKernelInformationOwner.shared.beginResolve()",
                       "CoreSetKernelInformationOwner.shared.didResolveArtifact()",
                       "CoreSetKernelInformationOwner.shared.completeValidation()",
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
        self.assertNotIn("axDeviceSupportStatus()", self.producer)


if __name__ == "__main__":
    unittest.main()
