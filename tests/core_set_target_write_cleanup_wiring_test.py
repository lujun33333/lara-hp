"""Verify production receipt wiring, not device write capability."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
writer = (ROOT / "lara/overlay/CoreSetTargetWriteSession.mm").read_text(encoding="utf-8")
assert "_complete = receipt.complete();" in writer
assert "_mayReportRestored = receipt.mayReportRestored();" in writer
assert "backendClean:backendClean noUnresolvedState:!_pendingCleanup" in writer
assert "targetWriteAttempted:_targetWriteAttempted" in writer
attempt = writer.index("_targetWriteAttempted = YES;")
assert attempt < writer.index("return [_backend writeControllerSlot:", attempt)
assert "_pendingCleanup = _pendingCleanup || !backendClean" in writer
assert "return [self initWithRequestAuthority:nil];" in writer
assert "if (!_authority || ![_authority authorizesPID:" in writer
recoil = (ROOT / "lara/views/app/CoreSetRecoilConsumer.swift").read_text(encoding="utf-8")
assert "cleanup.mayReportRestored ? .restored" in recoil
assert "cleanup.complete ? .restored" not in recoil
assert "writer.disconnect().complete" in recoil
aim = (ROOT / "lara/views/app/CoreSetAimConsumer.swift").read_text(encoding="utf-8")
assert "let restored = clean && !self.attemptedWrite" in aim
assert "restored ? .restored : .stopped(" in aim
assert "self.cleanupPending = !clean" in aim  # Resource stop permits a fresh session.
assert "if clean { self.session = CoreSetReadSession() }" in aim
assert "self.pendingProbes.filter { !$0.stop().complete }" in aim
assert "generation:readGeneration" in writer
assert "const uint64_t readGeneration = _readSession.generation;" in writer
assert "independentReadLease.matches(" in writer
assert "generation:generation\n" in writer  # Authority retains capture generation.
assert "_readSession.generation != generation" not in writer
print("PASS: receipt/attempt/history/consumer wiring; authority checks retained")
