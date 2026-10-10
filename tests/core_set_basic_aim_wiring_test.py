from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


aim = read("lara/views/app/CoreSetAimConsumer.swift")
native = read("lara/overlay/CoreSetIsolatedWriteProbe.mm")
snapshot_h = read("lara/overlay/CoreSetPlayerSnapshot.h")
snapshot_mm = read("lara/overlay/CoreSetPlayerSnapshot.mm")
menu = read("lara/views/app/CoreSetMenuViewController.swift")
coordinator = read("lara/views/app/CoreSetRuntimeCoordinator.swift")
manifest = read("scripts/build_ipa_pe.sh")

for token in (
    "CoreSetIsolatedWriteProbe", "battleProducer.requestAim(", "battleProducer.copyAction(",
    "triggerState.update(", "routeProducer.resolveAim(",
    "dynamics.plan(candidate:", "persistentActionWorker(input:",
    "guard result.committed, isLive(", "submitMergedAction(input:",
    "applyRecoil(", "tickRecoilOnly(",
):
    assert token in aim, token

assert "snapshot.battleInputsPresent = YES" in snapshot_mm

for token in (
    "CoreSetWorldPoint", "actorWorldPosition", "cameraWorldPosition",
    "localWorldPosition", "canvasSize", "rotationInputPitch", "rotationInputYaw",
):
    assert token in snapshot_h, token

for token in (
    "controller + 0x620", "controller + 0x828",
    "mark.actorWorldPosition =", "snapshot.cameraWorldPosition =",
    "snapshot.rotationInputPitch =", "snapshot.rotationInputYaw =",
):
    assert token in snapshot_mm, token

assert "initWithRequestAuthority:_authority" in native
assert "readSession:readSession" in native
assert "CoreSetIsolatedWriteProbe(readSession: readSession" in aim
assert "writeControllerActionForPID:" in native
assert "CoreSetTargetWriteSlotControlRotation" in native
assert "CoreSetTargetWriteSlotRotationInput" in native
assert "restoreSnapshot:" not in native
assert "expectedOld:[NSData dataWithBytes:oldValues + index length:length]" in native
assert "aimConsumer = CoreSetAimConsumer(coordinator: self, battleProducer: battleProducer)" in coordinator
assert "editGame(\\.aim)" in menu
assert "apply(\\.radar); apply(\\.aimDisplay); apply(\\.aim)" in menu
assert '"transportPolicy": "checked-control-and-input-rotation-write"' in manifest
assert '"writeFeaturesEnabled": true' in manifest
print("PASS: basic aim producer, authority, checked write and manifest wiring")
