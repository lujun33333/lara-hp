"""Existing task-read permission boundary and failure-buffer contracts.

Source checks cover Objective-C session gates; the companion C++ test executes
the exact bounded-clear helper from CoreSetReadSession.h. No device claim.
"""

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


def body(source: str, signature: str) -> str:
    opening = source.index("{", source.index(signature))
    depth = 1
    for position in range(opening + 1, len(source)):
        depth += (source[position] == "{") - (source[position] == "}")
        if depth == 0:
            return source[opening + 1:position]
    raise AssertionError("unterminated body: " + signature)


def require_read_contract(source: str, header: str) -> None:
    read = body(source, "- (BOOL)readAt:")
    clear = read.index("coreset_read_contract::clearDestination(destination, length)")
    for gate in ("if (!writableSpan || address == 0", "generation != _generation",
                 "identityStillValid:NO", "NSMutableData *scratch"):
        assert clear < read.index(gate), gate
    assert read.count("memcpy(destination, scratch.bytes, length)") == 1
    commit = read.index("memcpy(destination, scratch.bytes, length)")
    for gate in ("kr != KERN_SUCCESS", "done != length", "!identityValid"):
        assert read.index(gate) < commit, gate
    assert read.count("identityStillValid:NO") == 2
    assert "generation == _generation" in read
    assert "(mach_vm_address_t)(uintptr_t)scratch.mutableBytes" in read
    assert "(mach_vm_address_t)(uintptr_t)destination" not in read
    assert read.index("*completedBytes = 0") < clear
    helper = body(header, "inline bool clearDestination(")
    assert helper.index("length > maximumLength") < helper.index("memset(destination, 0, length)")
    assert "!destination || length == 0" in helper
    assert "maximumLength = 0x10000" in header


def require_cleanup_contract(source: str) -> None:
    cleanup = body(source, "- (CoreSetReadCleanupResult *)disconnect")
    for gate in ("if (released) _task = MACH_PORT_NULL",
                 "released = releaseResult == KERN_SUCCESS",
                 "transportReleased = [_kernelTransport disconnect]",
                 "BOOL advanced = resourcesReleased && _generation != UINT64_MAX",
                 "if (advanced) ++_generation"):
        assert gate in cleanup, gate
    assert "transportReleased:transportReleased" in cleanup
    assert "generationAdvanced:advanced" in cleanup


def require_permission_boundary(source: str) -> None:
    assert 'dlsym(RTLD_DEFAULT, "task_read_for_pid")' in source
    assert 'dlsym(RTLD_DEFAULT, "task_for_pid")' in source
    assert 'dlsym(RTLD_DEFAULT, "processor_set_tasks")' in source
    assert "procbyname(CSProcessName)" in source
    read = body(source, "- (BOOL)readAt:")
    assert not re.search(r"\b(?:task_for_pid|remoteRead|vmmapremotepage|ds_kread\w*|ds_kwrite\w*)\s*\(", read)
    assert not re.search(r"\b(?:remoteRead|vmmapremotepage|ds_kwrite\w*)\s*\(", source)
    assert not re.search(r"(?:RemoteCall\s*\*|doRemoteCall|ReadTransportProvider|objc_msgSend)", source)
    assert not re.search(r"(?:mach_vm_write|VM_PROT_WRITE|initWithProcess:)", source)


class ReadFailureZeroContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = (ROOT / "lara/overlay/CoreSetReadSession.mm").read_text(encoding="utf-8")
        cls.header = (ROOT / "lara/overlay/CoreSetReadSession.h").read_text(encoding="utf-8")
        cls.kernel_transport = (ROOT / "lara/overlay/CoreSetKernelMappedReadTransport.mm").read_text(encoding="utf-8")
        cls.kernel_profile = (ROOT / "lara/overlay/CoreSetKernelReadProfile.mm").read_text(encoding="utf-8")

    def test_all_bounded_failure_paths_clear_before_read_gates(self) -> None:
        require_read_contract(self.source, self.header)

    def test_old_generation_identity_partial_and_direct_destination_are_rejected(self) -> None:
        for gate in ("coreset_read_contract::clearDestination(destination, length)",
                     "generation != _generation", "generation == _generation",
                     "done != length", "!identityValid", "kr != KERN_SUCCESS"):
            with self.subTest(gate=gate), self.assertRaises((AssertionError, ValueError)):
                require_read_contract(self.source.replace(gate, "REMOVED_GATE"), self.header)
        broken = self.source.replace("(mach_vm_address_t)(uintptr_t)scratch.mutableBytes",
                                     "(mach_vm_address_t)(uintptr_t)destination")
        with self.assertRaises(AssertionError):
            require_read_contract(broken, self.header)

    def test_invalid_span_cannot_trigger_unbounded_clear(self) -> None:
        for gate in ("length > maximumLength", "!destination || length == 0"):
            with self.subTest(gate=gate), self.assertRaises((AssertionError, ValueError)):
                require_read_contract(self.source, self.header.replace(gate, "REMOVED_GATE"))

    def test_cleanup_retains_failed_port_and_never_wraps_generation(self) -> None:
        require_cleanup_contract(self.source)
        cleanup = body(self.source, "- (CoreSetReadCleanupResult *)disconnect")
        self.assertIn("if (released) _task = MACH_PORT_NULL", cleanup)
        self.assertIn("releaseResult = mach_port_deallocate(mach_task_self(), _task)", cleanup)
        self.assertIn("released = releaseResult == KERN_SUCCESS", cleanup)
        self.assertIn("BOOL advanced = resourcesReleased && _generation != UINT64_MAX", cleanup)
        self.assertIn("if (advanced) ++_generation", cleanup)
        self.assertIn("transportReleased:transportReleased", cleanup)
        for marker in ("task-port-release-failed", "read-transport-release-failed",
                       "generation-exhausted", "retainedPort=%d", "retainedTransport=%d",
                       "previousGeneration=%llu sessionGeneration=%llu kr=0x%x",
                       "stage=cleanup", "now - _lastCleanupLogTime >= 30.0"):
            self.assertIn(marker, cleanup)
        self.assertIn("lastCleanupDiagnostic", self.header)

    def test_failed_cleanup_or_saturated_generation_cannot_claim_success(self) -> None:
        for gate in ("if (released) _task = MACH_PORT_NULL",
                     "released = releaseResult == KERN_SUCCESS",
                     "resourcesReleased && _generation != UINT64_MAX", "if (advanced) ++_generation"):
            with self.subTest(gate=gate), self.assertRaises(AssertionError):
                require_cleanup_contract(self.source.replace(gate, "REMOVED_GATE"))

    def test_transport_permissions_are_unchanged(self) -> None:
        require_permission_boundary(self.source)
        self.assertIn("private", self.header)
        self.assertIn("kernel-mapped read transport", self.header)
        self.assertIn("no mapped", self.header)
        self.assertIn("target-write API", self.header)
        for forbidden in ("ds_kwrite", "mach_vm_write", "VM_PROT_WRITE", "RemoteCall"):
            self.assertNotIn(forbidden, self.kernel_transport)
        self.assertIn("CoreSetKernelReadProfile matchesCurrentKernel", self.kernel_transport)
        for exact in ("23A341", "iPhone17,2", "xnu-12377.2.8~1",
                      "off_task_itk_space == 0x310", "off_ipc_port_ip_kobject == 0x50",
                      "kernel_base == sPinnedKernelBase", "kernel-uuid-changed"):
            self.assertIn(exact, self.kernel_profile)

    def test_write_or_broker_symbols_are_rejected(self) -> None:
        for forbidden in ("mach_vm_write", "VM_PROT_WRITE", "RemoteCall *broker",
                          "remoteRead(address)"):
            with self.subTest(symbol=forbidden), self.assertRaises(AssertionError):
                require_permission_boundary(self.source + "\n" + forbidden)


if __name__ == "__main__":
    unittest.main(verbosity=2)
