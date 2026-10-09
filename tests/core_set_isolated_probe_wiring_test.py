from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
probe = (ROOT / "lara/overlay/CoreSetIsolatedWriteProbe.mm").read_text(encoding="utf-8")
bridge = (ROOT / "lara/lara-Bridging-Header.h").read_text(encoding="utf-8")
project = (ROOT / "lara.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
writer = (ROOT / "lara/overlay/CoreSetTargetWriteSession.mm").read_text(encoding="utf-8")

assert '#import "overlay/CoreSetIsolatedWriteProbe.h"' in bridge
assert "PBXFileSystemSynchronizedRootGroup" in project and "path = lara;" in project
assert "CoreSetIsolatedWriteProbe.mm" not in project
assert "initWithRequestAuthority:_authority" in probe
assert "readSession:readSession" in probe
assert "_ownsReadSession = readSession == nil" in writer
assert "!_ownsReadSession || readCleanup.generationAdvanced" in writer
assert "CoreSet::SerialActionGate gate;" in probe
assert "_submitted" not in probe
assert "authority.controllerAddress" in probe
assert "std::fabs(pitch) > 36" in probe and "std::fabs(yaw) > 36" in probe
assert "CoreSetTargetWriteSlotRotationInput" in probe
assert "context.lane = lane" in probe and "controller:context.controller lane:lane" in probe
assert "restoreSnapshot:" not in probe and "absolute:YES" not in probe
assert "self.validator(self.input, self.token" in probe
assert "dispatch_sync(_queue, cleanup)" in probe
aim = (ROOT / "lara/views/app/CoreSetAimConsumer.swift").read_text(encoding="utf-8")
assert "private var actionProbe: CoreSetIsolatedWriteProbe?" in aim
assert "persistentActionWorker(input:" in aim
assert "CoreSetPlayerCollector.validateLiveAuthority(readSession, authority: captured)" in aim
snapshot = (ROOT / "lara/overlay/CoreSetPlayerSnapshot.mm").read_text(encoding="utf-8")
assert "+ (BOOL)validateLiveIdentity:" in snapshot
assert "+ (BOOL)validateLiveAuthority:" in snapshot
for anchor in ("session.imageBase + CSWorldSlot", "world + 0xc0", "driver + 0x88",
               "connection + 0x30", "controller == snapshot.controllerAddress",
               "local == snapshot.localActorAddress"):
    assert anchor in snapshot
submit = aim.split("private func submitMergedAction", 1)[1].split("private func tickRecoilOnly", 1)[0]
assert "let cleanup = probe.stop()" not in submit
assert "_ = self.retireActionWorker()" in aim
assert writer.count("[_authority authorizesPID:pid imageBase:imageBase") >= 2
assert "result = _gate.transact(" in writer
print("PASS: isolated aim authority and checked-write wiring")
