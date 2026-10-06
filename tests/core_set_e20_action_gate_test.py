"""E20 action dataflow counterexample and fail-closed writer activation gate."""

from hashlib import sha256
from pathlib import Path
import struct
import subprocess
import sys
import zipfile
from core_set_basic_aim_contract import check_basic_aim_contract

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "自签Core-SET和平-v1.7.ipa"
XREF = ROOT / "tools/core_set_e20_state_xrefs.py"
FILES = (
    ROOT / "lara/views/app/CoreSetAimConsumer.swift",
    ROOT / "lara/views/app/CoreSetRecoilConsumer.swift",
    ROOT / "lara/overlay/CoreSetTargetWriteSession.mm",
    ROOT / "lara/overlay/CoreSetMappedPageWriteBackend.mm",
    ROOT / "lara/overlay/CoreSetKernelWriteProfile.mm",
    ROOT / "lara/overlay/CoreSetTargetWriteSession.h",
    ROOT / "lara/overlay/CoreSetTargetWriteContract.h",
)


def gate(values: list[str]) -> None:
    aim, recoil, writer, backend, registry, header, contract = values
    check_basic_aim_contract(aim)
    assert "probe.stop()" in aim and "pendingProbes.isEmpty" in aim
    for consumer in (recoil,):
        assert "var supportedFields: Set<CoreSetField> { [] }" in consumer
        assert ".unavailable(reason:" in consumer
        assert "writer.disconnect()" in consumer
        assert "writeControllerRotationForPID:" not in consumer
    assert "return [self initWithRequestAuthority:nil];" in writer
    assert "if (!_authority || ![_authority authorizesPID:" in writer
    assert "address == controller + offset && length == expectedOld.length" in writer
    assert "controller:controller lane:lane slot:slot axis:axis" in writer
    assert "newValue.length != length" in writer
    assert "_backend writeControllerSlot:slot axis:axis" in writer
    assert "_gate.stopAfterDrain()" in writer
    assert "if (_stopped)" in writer and "_stopped = YES;" in writer
    assert writer.index("if (_stopped)") < writer.index("if (![_readSession connect]")
    assert "noInFlight:drained]" in writer
    assert "_backend.writeControllerRotation" not in aim + recoil
    assert "ControlRotationWriteGate::shape(" in backend
    assert "length != expectedLength" in backend
    assert "const uint64_t address = controller + offset" in backend
    assert "return [CoreSetKernelWriteProfileRegistry matchesCurrentKernel];" in backend
    assert "if (!sProfile || !ds_is_ready()" in registry
    assert "installAuditedProfile:" in registry
    for token in ("CoreSetTargetWriteLaneAim", "CoreSetTargetWriteLaneRecoil",
                  "CoreSetTargetWriteSlotControlRotation", "CoreSetTargetWriteSlotRotationInput",
                  "CoreSetTargetWriteAxisFirst", "CoreSetTargetWriteAxisSecond",
                  "CoreSetTargetWriteAxisBoth", "requestToken:(NSUUID *)requestToken"):
        assert token in header
    for token in ("base = 0x620", "base = 0x828", "base + 4",
                  "*length = 4", "*length = 8", "lease.lane != TargetActionLane::aim",
                  "expectedOld[index] || newValue[index]", "std::memcmp(observed.data(), newValue.data(), length)"):
        assert token in contract


def binary_gate() -> None:
    with zipfile.ZipFile(CORE) as archive:
        core = archive.read("Payload/Core.app/Core")
    assert sha256(core).hexdigest() == "c842be92434b88b4d535d0d10a30ace068ce6b9a7b9a97ec5a6ca8fd97fa3dd5"
    assert struct.unpack_from("<Q", core, 0x797628 + 65 * 8)[0] == 0x620
    assert struct.unpack_from("<Q", core, 0x797628 + 66 * 8)[0] == 0x828
    base = 0x100000000
    for va, opcode in (
        (0x1000C2A84, "1d080094"),  # aim geometry call
        (0x1000C2E24, "e9292d1e"),  # first-axis merge
        (0x1000C2E28, "cb292c1e"),  # second-axis merge
        (0x1000C2F4C, "e30a0094"),  # checked write wrapper
        (0x1000C3914, "33008052"),  # w19 = 1, alternate slot
        (0x1000C2F9C, "08c12191"),  # index 66 read feeding c46b4
        (0x1000C5010, "604a00bd"),  # aim result +0x48 producer
        (0x1000C2B20, "ea5b42bd"),  # caller sp+0x258 to s10
        (0x1000C5B98, "a0010054"),  # zero first-axis skips its four-byte sink
        (0x1000C5BAC, "e1020094"),  # first-axis four-byte helper
        (0x1000C5C20, "c4020094"),  # second-axis four-byte helper
        (0x1000C6784, "4d6efe97"),  # helper calls checked four-byte writer
    ):
        assert core[va - base:va - base + 4] == bytes.fromhex(opcode), hex(va)


def main() -> None:
    binary_gate()
    xrefs = subprocess.run([sys.executable, str(XREF)], check=True,
                           capture_output=True, text=True, timeout=20).stdout
    for anchor in ("0x1000c2cc4 state+0xb8 ldr s0",
                   "0x1000c2cc8 state+0xa4 ldr s1",
                   "0x1000c4594 state+0xb8 stur s9",
                   "0x1000c2e50 state+0xa4 str s13",
                   "0x1000c30d0 state+0xa4 str s13"):
        assert anchor in xrefs, anchor
    values = [path.read_text(encoding="utf-8") for path in FILES]
    gate(values)
    negatives = (
        (0, ".basicAimEnabled", ".aimEnabled"),
        (1, "var supportedFields: Set<CoreSetField> { [] }", "var supportedFields: Set<CoreSetField> { [.recoilEnabled] }"),
        (2, "return [self initWithRequestAuthority:nil];", "return [self initWithRequestAuthority:defaultAuthority];"),
        (2, "address == controller + offset && length == expectedOld.length", "address == controller + 0x828"),
        (2, "if (_stopped)", "if (NO)"),
        (2, "noInFlight:drained]", "noInFlight:YES]"),
        (3, "length != expectedLength", "length > expectedLength"),
        (4, "if (!sProfile || !ds_is_ready()", "if (!ds_is_ready()"),
        (5, "CoreSetTargetWriteAxisSecond", "CoreSetTargetWriteAxisThird"),
        (6, "expectedOld[index] || newValue[index]", "false"),
    )
    for index, before, after in negatives:
        mutated = values.copy()
        assert before in mutated[index]
        mutated[index] = mutated[index].replace(before, after, 1)
        try:
            gate(mutated)
        except AssertionError:
            continue
        raise AssertionError(f"unsafe E20 action mutation passed: {before}")
    print(f"PASS: E20 Core action split and uninstalled writer gates; {len(negatives)} negatives")


if __name__ == "__main__":
    main()
