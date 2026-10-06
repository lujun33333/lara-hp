from pathlib import Path

root = Path(__file__).resolve().parents[1]
probe = (root / 'lara/overlay/CoreSetIsolatedWriteProbe.mm').read_text(encoding='utf-8')
bridge = (root / 'lara/lara-Bridging-Header.h').read_text(encoding='utf-8')
project = (root / 'lara.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
writer = (root / 'lara/overlay/CoreSetTargetWriteSession.mm').read_text(encoding='utf-8')
assert '#import "overlay/CoreSetIsolatedWriteProbe.h"' in bridge
assert 'PBXFileSystemSynchronizedRootGroup' in project and 'path = lara;' in project
# New .mm belongs to synchronized root; no exception or duplicate explicit source.
assert 'CoreSetIsolatedWriteProbe.mm' not in project
assert 'installAuditedProfile' not in probe
assert 'writeControllerActionForPID:' in probe
assert 'snapshot.battleInputsPresent' in probe
assert 'expectedOld:[NSData dataWithBytes:oldValues + index length:length]' in probe
assert 'self->_submitted = YES;' in probe
assert 'std::fabs(pitchDelta) > 1' in probe and 'std::fabs(yawDelta) > 1' in probe
assert 'self.validator(self.snapshot, self.token' in probe
assert 'CoreSetTargetWriteSlotControlRotation' in probe
assert 'CoreSetTargetWriteSlotRotationInput' not in probe
assert 'CACurrentMediaTime()' in probe
assert 'stopping.store(true)' in probe and 'dispatch_sync(_queue, cleanup)' in probe
assert 'initWithRequestAuthority:_authority' in probe
assert writer.count('[_authority authorizesPID:pid imageBase:imageBase') >= 2
assert 'result = _gate.transact(' in writer
print('isolated probe wiring checks passed (static only)')
