"""Kernel-mapped fallback contracts; source-only, no device-success claim."""

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
        cls.vm = read("lara/kexploit/TaskRop/vm.m")
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

    def test_page_alias_is_structurally_readonly_and_immediately_released(self) -> None:
        read_at = body(self.source, "- (BOOL)readAt:")
        for gate in ("identityValidLocked", "CSKernelMappedReadLock",
                     "vmmapremotepagereadonly(_kernelVMMap, pageAddress)",
                     "memcpy((uint8_t *)scratch.mutableBytes + completed",
                     "CSReleaseMappedPage(&mapping)", "completed == length",
                     "memcpy(destination, scratch.bytes, length)"):
            self.assertIn(gate, read_at)
        readonly = body(self.vm, "struct vmshmem vmmapremotepagereadonly(")
        self.assertIn("vmcreateshmemwithobjprotection(&before, VM_PROT_READ)", readonly)
        self.assertIn("vmmapfindentry(vmmap, address)", readonly)
        self.assertGreaterEqual(readonly.count("vmgetptratentry(entryaddr, address)"), 3)
        self.assertIn("before.address != confirm.address", readonly)
        self.assertIn("before.address != after.address", readonly)
        self.assertIn("shmem.used = false", readonly)
        create = body(self.vm, "static struct vmshmem vmcreateshmemwithobjprotection(")
        self.assertIn("entryProtection = requestedProtection == VM_PROT_READ", create)
        self.assertIn("entryProtection, &memobj", create)
        self.assertIn("curprot = requestedProtection", create)
        self.assertIn("maxprot = requestedProtection", create)
        release = body(self.source, "static BOOL CSReleaseMappedPage(")
        self.assertIn("mach_vm_deallocate", release)
        self.assertIn("mach_port_deallocate", release)
        self.assertLess(read_at.index("memcpy((uint8_t *)scratch.mutableBytes + completed"),
                        read_at.index("CSReleaseMappedPage(&mapping)"))

    def test_identity_binds_proc_pid_task_and_vm_map(self) -> None:
        identity = body(self.source, "- (BOOL)identityValidLocked")
        for gate in ("_kernelProcess", "off_proc_p_pid",
                     "taskbyproc(_kernelProcess) == _kernelTask",
                     "task_get_vm_map(_kernelTask) == _kernelVMMap"):
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

    def test_indirect_kernel_metadata_write_requires_known_build_profile(self) -> None:
        prerequisites = body(self.source, "static BOOL CSKernelMappedReadPrerequisites(")
        self.assertIn("[CoreSetKernelReadProfile matchesCurrentKernel]", prerequisites)
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
        get_object = body(self.vm, "static struct vmobj vmgetptratentry(")
        for gate in ("entry.is_sub_map", "entry.vme_kernel_object",
                     "entry.protection & VM_PROT_READ", "entry.vme_object_or_delta == 0",
                     "ds_address_usable(vmeobj)", "refcount == 0"):
            self.assertIn(gate, get_object)
        # The alias helper still performs kernel metadata writes internally;
        # the contract is exact-profile-gated and never claims strict zero-write.
        self.assertIn("ds_kwrite32", self.vm)
        self.assertIn("ds_kwritezoneelement", self.vm)

    def test_session_prefers_task_port_then_uses_bounded_fallback(self) -> None:
        connect = body(self.session, "- (BOOL)connect")
        self.assertLess(connect.index("CSAcquireTaskForPID(pid)"),
                        connect.index("initWithKernelProcess:candidate.kernelProc"))
        for gate in ("findImageWithUUID:CSUUID", "CSResolveKernelTarget(true)",
                     "[transport identityValid]", '@"kernel-mapped-read"',
                     "kernel-mapped-read-cleanup-pending"):
            self.assertIn(gate, connect)
        read_at = body(self.session, "- (BOOL)readAt:")
        self.assertIn("to:scratch.mutableBytes", read_at)
        self.assertEqual(read_at.count("memcpy(destination, scratch.bytes, length)"), 1)

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
