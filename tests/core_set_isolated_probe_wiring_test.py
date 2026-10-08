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
assert "self->_submitted = YES;" in probe
assert "snapshot.battleInputsPresent" in probe
assert "std::fabs(pitch) > 36" in probe and "std::fabs(yaw) > 36" in probe
assert "CoreSetTargetWriteSlotRotationInput" in probe
assert "context.lane = lane" in probe and "controller:context.controller lane:lane" in probe
assert "restoreSnapshot:" not in probe and "absolute:YES" not in probe
assert "self.validator(self.snapshot, self.token" in probe
assert "dispatch_sync(_queue, cleanup)" in probe
assert writer.count("[_authority authorizesPID:pid imageBase:imageBase") >= 2
assert "result = _gate.transact(" in writer
print("PASS: isolated aim authority and checked-write wiring")
