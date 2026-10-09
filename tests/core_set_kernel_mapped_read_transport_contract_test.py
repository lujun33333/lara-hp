"""SPTM page-table fallback contracts; source-only, no device-success claim."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def body(source: str, signature: str) -> str:
    opening = source.index("{", source.index(signature))
    depth = 1
    for position in range(opening + 1, len(source)):
        depth += (source[position] == "{") - (source[position] == "}")
        if depth == 0:
            return source[opening + 1:position]
    raise AssertionError("unterminated body: " + signature)


class KernelMappedReadTransportContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.header = read("lara/overlay/CoreSetKernelMappedReadTransport.h")
        cls.source = read("lara/overlay/CoreSetKernelMappedReadTransport.mm")
        cls.profile = read("lara/overlay/CoreSetKernelReadProfile.mm")
        cls.darksword = read("lara/kexploit/darksword.m")
        cls.session = read("lara/overlay/CoreSetReadSession.mm")

    def test_transport_exposes_read_and_cleanup_only(self) -> None:
        for exposed in ("identityValid", "findImageWithUUID", "imageAt:",
                        "readAt:", "disconnect"):
            self.assertIn(exposed, self.header)
        for forbidden in ("writeAt", "remoteCall", "mappedAddress", "localAddress",
                          "RemoteCall", "mach_vm_write", "ds_kwrite", "VM_PROT_WRITE"):
            self.assertNotIn(forbidden, self.header)
        for forbidden_property in ("kernelProcess;", "kernelTask;", "kernelVMMap;"):
            self.assertNotIn(forbidden_property, self.header)
        for forbidden in ("RemoteCall", "mach_vm_write", "ds_kwrite", "VM_PROT_WRITE"):
            self.assertNotIn(forbidden, self.source)

    def test_sptm_page_table_walk_is_checked_and_readonly(self) -> None:
        read_at = body(self.source, "- (BOOL)readAt:")
        for gate in ("identityValidLocked", "CSKernelMappedReadLock",
                     "physicalAddressForUserAddressLocked:current",
                     "kernelVirtualForPhysicalLocked:physical",
                     "ds_kreadbuf_checked(kernelAddress",
                     "page-table-mapping-changed-during-read", "completed == length",
                     "memcpy(destination, scratch.bytes, length)"):
            self.assertIn(gate, read_at)
        self.assertNotIn("vmmapremotepagereadonly", self.source)
        translate = body(self.source, "- (uint64_t)physicalAddressForUserAddressLocked:")
        for gate in ("coreset_arm_tt_l1_index_mask", "CSArmTTEValid",
                     "CSArmTTETableMask", "CSArmTTEPhysicalMask",
                     "_targetTTEPIsPhysical", "readPhysical64Locked"):
            self.assertIn(gate, translate)
        checked = body(self.darksword, "bool ds_kreadbuf_checked(")
        self.assertIn("early_kread(addr + off, &val, chunk)", checked)
        self.assertNotIn("early_kread64", checked)

    def test_identity_binds_proc_pid_task_vm_map_pmap_and_ttep(self) -> None:
        identity = body(self.source, "- (BOOL)identityValidLocked")
        for gate in ("_kernelProcess", "off_proc_p_pid",
                     "taskbyproc(_kernelProcess) == _kernelTask",
                     "task_get_vm_map(_kernelTask) == _kernelVMMap",
                     "currentPmap == _kernelPmap", "currentTTEP == _targetTTEP"):
            self.assertIn(gate, identity)
        find_image = body(self.source, "- (uint64_t)findImageWithUUID:")
        for gate in ("count > 8192", "start <= previousStart", "end <= start",
                     "next == entry", "imageAt:start matchesUUID:uuid",
                     "mapped-read-identity-changed-during-vm-map-walk",
                     "targetEntry.is_sub_map", "targetEntry.vme_kernel_object",
                     "VM_PROT_READ | VM_PROT_EXECUTE"):
            self.assertIn(gate, find_image)
        image = body(self.source, "- (BOOL)imageAt:")
        for gate in ("MH_EXECUTE", "LC_UUID", "memcmp(value->uuid, uuid, 16) == 0"):
            self.assertIn(gate, image)

    def test_page_table_values_require_known_build_profile(self) -> None:
        prerequisites = body(self.source, "static BOOL CSKernelMappedReadPrerequisites(")
        self.assertIn("[CoreSetKernelReadProfile matchesCurrentKernel]", prerequisites)
        for exact in ("coreset_vm_map_pmap_offset == 0x40",
                      "coreset_arm_tt_l1_index_mask == 0x0000007000000000ULL",
                      "coreset_libsptm_n_papt_ranges_offset != 0",
                      "coreset_libsptm_papt_ranges_offset != 0"):
            self.assertIn(exact, prerequisites)
        for exact in ("23A341", "iPhone17,2", "xnu-12377.2.8~1",
                      "off_proc_p_pid == 0x60", "off_task_itk_space == 0x310",
                      "off_ipc_space_is_table == 0x48", "sizeof_ipc_entry == 0x18",
                      "off_ipc_entry_ie_object == 0", "off_ipc_port_ip_kobject == 0x50",
                      "off_vm_map_entry_vme_object_or_delta == 0x3c",
                      "off_vm_map_entry_vme_alias == 0x40",
                      "off_vm_object_ref_count == 0x28",
                      "kernel-uuid-unavailable-or-unstable", "kernel-uuid-changed",
                      "kernel_base == sPinnedKernelBase"):
            self.assertIn(exact, self.profile)
        for forbidden in ("ds_kwrite", "vmmapremotepage", "mach_vm_write"):
            self.assertNotIn(forbidden, self.source)

    def test_session_prefers_task_port_then_uses_bounded_fallback(self) -> None:
        connect = body(self.session, "- (BOOL)connect")
        self.assertLess(connect.index("CSAcquireTaskForPID(pid)"),
                        connect.index("initWithKernelProcess:candidate.kernelProc"))
        for gate in ("findImageWithUUID:CSUUID", "CSResolveKernelTarget(true)",
                     "[transport identityValid]", '@"kernel-page-table-read"'):
            self.assertIn(gate, connect)
        read_at = body(self.session, "- (BOOL)readAt:")
        self.assertIn("to:scratch.mutableBytes", read_at)
        self.assertEqual(read_at.count("memcpy(destination, scratch.bytes, length)"), 1)

    def test_mapped_read_failure_reports_transport_reason(self) -> None:
        diagnostic = body(self.session, "- (void)recordReadFailure:")
        self.assertIn('[kind isEqualToString:@"read-partial-or-kern-failure"]', diagnostic)
        self.assertIn('_kernelTransport.lastError', diagnostic)
        self.assertIn('mappedTransport=%@', diagnostic)
        read_at = body(self.session, "- (BOOL)readAt:")
        self.assertIn('mapped ? KERN_SUCCESS : KERN_FAILURE', read_at)
        self.assertIn('recordReadFailure:identityValid ? @"read-partial-or-kern-failure"', read_at)

    def test_cleanup_failure_retains_transport_and_blocks_generation(self) -> None:
        cleanup = body(self.session, "- (CoreSetReadCleanupResult *)disconnect")
        for gate in ("transportReleased = [_kernelTransport disconnect]",
                     "if (transportReleased) _kernelTransport = nil",
                     "resourcesReleased = released && transportReleased",
                     "BOOL advanced = resourcesReleased && _generation != UINT64_MAX",
                     "read-transport-release-failed", "retainedTransport=%d"):
            self.assertIn(gate, cleanup)
        result = body(self.session, "- (instancetype)initWithTaskPortReleased:")
        self.assertIn("taskPortReleased && transportReleased && generationAdvanced", result)
        connect = body(self.session, "- (BOOL)connect")
        self.assertIn("!cleanup.complete", connect)
        self.assertLess(connect.index("!cleanup.complete"), connect.index("proc_listallpids"))
        with self.assertRaises(AssertionError):
            self.assertIn("!cleanup.complete", connect.replace("!cleanup.complete", "!cleanup.taskPortReleased"))

    def test_all_cleanup_consumers_require_complete(self) -> None:
        for relative, signature in (
            ("lara/views/app/CoreSetPlayerConsumer.swift", "func shutdownReadSession()"),
            ("lara/views/app/CoreSetMaterialConsumer.swift", "func shutdownReadSession()"),
            ("lara/views/app/CoreSetRadarConsumer.swift", "func shutdownReadSession()"),
            ("lara/views/app/CoreSetAimPreviewConsumer.swift", "func shutdown()"),
        ):
            shutdown = body(read(relative), signature)
            self.assertIn("cleanup.complete", shutdown, relative)
            self.assertNotIn("cleanup.taskPortReleased && cleanup.generationAdvanced", shutdown)
        probe = read("lara/views/app/CoreSetActionReadOnlyProbe.swift")
        self.assertEqual(probe.count("cleanup.complete"), 2)
        self.assertNotIn("cleanup.taskPortReleased && cleanup.generationAdvanced", probe)
        writer = read("lara/overlay/CoreSetTargetWriteSession.mm")
        disconnect = body(writer, "- (CoreSetTargetWriteCleanupResult *)disconnect")
        self.assertIn("!readCleanup.complete", disconnect)
        self.assertNotIn("!readCleanup.taskPortReleased ||", disconnect)


if __name__ == "__main__":
    unittest.main(verbosity=2)
