"""Core trigger inputs match target fields, but no battle consumer is claimed."""

from hashlib import sha256
from pathlib import Path
import zipfile
from core_set_basic_aim_contract import check_basic_aim_contract


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "源码 - 和平"
BASE = 0x100000000


def gate(core: bytes, target: bytes, report: str, coordinator: str, menu: str,
         read_session: str, writer: str, backend: str, profile: str, aim: str) -> None:
    for va, opcode in {0x1000C2054: "1501178b", 0x1000C220C: "1501178b",
                       0x1000C22B4: "094f41b9", 0x1000C22E8: "00106a1e",
                       0x1000C2F4C: "e30a0094", 0x1000C5B64: "5571fe97",
                       0x1000623F0: "6c3fff97", 0x100062494: "6d030094",
                       0x1000624B4: "8b0e1b94"}.items():
        assert core[va - BASE:va - BASE + 4] == bytes.fromhex(opcode)
    for va, opcode in {0x106DB8470: "08098352", 0x106D2D6D0: "08ea8452",
                       0x103D2F794: "7f6a2838"}.items():
        assert target[va - BASE:va - BASE + 4] == bytes.fromhex(opcode)
    for token in ("`bIsGunADS`", "`bIsWeaponFiring`", "索引 40", "索引 39",
                  "`0x1000c20a4", "`target-write-committed`", "停止恢复回执", "维持 unavailable"):
        assert token in report, token
    assert "bindGameConsumer(aimConsumer, to: \\.aim)" in coordinator
    assert "bindGameConsumer(recoilConsumer, to: \\.recoil)" in coordinator
    assert 'aimControls(in: aim, filter: filter, scenario: scenario)' in menu
    assert 'disabledRows(["倒地不瞄", "LOS掩体判断"]' in menu
    assert 'disabledRows(["启用压枪"' in menu
    assert "writeAt:" not in read_session
    assert "RemoteCall" in read_session and "fallback" in read_session
    assert "_backend.ready" in writer and "_backend connectForController:controller" in writer
    assert "_gate.transact(lease, oldBytes, newBytes, identity, read, write)" in writer
    assert "return [self initWithRequestAuthority:nil]" in writer
    assert writer.count("[_authority authorizesPID:pid imageBase:imageBase") >= 2
    assert "[CoreSetKernelWriteProfileRegistry matchesCurrentKernel]" in backend
    assert "static CoreSetKernelWriteProfile *sProfile;" in profile
    assert "if (!sProfile || !ds_is_ready()" in profile
    assert "CSCurrentKernelUUID()" in profile and 'CSKernelSysctl(@"kern.osversion")' in profile
    assert 'CSKernelSysctl(@"hw.machine")' in profile and "[offsets isEqualToDictionary:sProfile.offsets]" in profile
    assert "vmmapremotepage(_vmMap, page)" in backend
    assert "CSOffset(off_proc_p_pid, 4)" in backend and "CSOffset(off_task_map, 8)" in backend
    assert "_mappings[_mappingCount++]" in backend and "mach_vm_deallocate" in backend
    assert "mach_port_deallocate" in backend and "_pendingCleanup = YES" in backend
    assert "address == controller + offset && length == expectedOld.length" in writer
    assert "lane:lane slot:slot axis:axis" in writer
    assert "[_readSession readAt:address" in writer
    assert "mach_vm_write(" not in writer and "ds_kwrite(" not in writer
    check_basic_aim_contract(aim)


def main() -> None:
    with zipfile.ZipFile(SOURCE / "自签Core-SET和平-v1.7.ipa") as archive:
        core = archive.read("Payload/Core.app/Core")
    with zipfile.ZipFile(ROOT / "和平精英-1.38.12.ipa") as archive:
        target = archive.read("Payload/ShadowTrackerExtra.app/ShadowTrackerExtra")
    assert sha256(core).hexdigest() == "c842be92434b88b4d535d0d10a30ace068ce6b9a7b9a97ec5a6ca8fd97fa3dd5"
    assert sha256(target).hexdigest() == "e3b3e8d47f1ad116b74d0a578d3394f5f1ab85e85c9ceb4f61293bd7ba76dc98"
    report = (SOURCE / "artifacts/core-set-v1.7/sol-e8-battle-input-evidence.md").read_text(encoding="utf-8")
    coordinator = (SOURCE / "lara/views/app/CoreSetRuntimeCoordinator.swift").read_text(encoding="utf-8")
    menu = (SOURCE / "lara/views/app/CoreSetMenuViewController.swift").read_text(encoding="utf-8")
    read_session = (SOURCE / "lara/overlay/CoreSetReadSession.h").read_text(encoding="utf-8")
    writer = (SOURCE / "lara/overlay/CoreSetTargetWriteSession.mm").read_text(encoding="utf-8")
    backend = (SOURCE / "lara/overlay/CoreSetMappedPageWriteBackend.mm").read_text(encoding="utf-8")
    profile = (SOURCE / "lara/overlay/CoreSetKernelWriteProfile.mm").read_text(encoding="utf-8")
    aim = (SOURCE / "lara/views/app/CoreSetAimConsumer.swift").read_text(encoding="utf-8")
    gate(core, target, report, coordinator, menu, read_session, writer, backend, profile, aim)
    for wrong in (
        lambda: gate(core, target, report.replace("`bIsGunADS`", "`bIsADS`"), coordinator, menu, read_session, writer, backend, profile, aim),
        lambda: gate(core, target, report, coordinator.replace("bindGameConsumer(aimConsumer, to: \\.aim)",
                                                         "bindGameConsumer(aimConsumer, to: \\.player)"), menu,
                     read_session, writer, backend, profile, aim),
        lambda: gate(core, target, report, coordinator, menu.replace('disabledRows(["启用压枪"',
                                                                      'enabledRows(["启用压枪"'), read_session,
                     writer, backend, profile, aim),
        lambda: gate(core, target, report, coordinator, menu, read_session + "writeAt:", writer, backend, profile, aim),
        lambda: gate(core, target, report, coordinator, menu, read_session,
                     writer, backend.replace("[CoreSetKernelWriteProfileRegistry matchesCurrentKernel]", "YES"), profile, aim),
        lambda: gate(core, target, report, coordinator, menu, read_session,
                     writer.replace("address == controller + offset && length == expectedOld.length",
                                    "address == controller + 0x828"), backend, profile, aim),
        lambda: gate(core, target, report, coordinator, menu, read_session,
                     writer.replace("return [self initWithRequestAuthority:nil]", "return [self initWithRequestAuthority:self]"), backend, profile, aim),
    ):
        try:
            wrong()
        except AssertionError:
            continue
        raise AssertionError("unresolved battle mutation passed")
    print("PASS: Core ADS/fire sink and fail-closed mapped writer binding; 7 negatives")


if __name__ == "__main__":
    main()
