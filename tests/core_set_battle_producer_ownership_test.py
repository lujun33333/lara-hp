from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


coordinator = read("lara/views/app/CoreSetRuntimeCoordinator.swift")
player = read("lara/views/app/CoreSetPlayerConsumer.swift")
aim = read("lara/views/app/CoreSetAimConsumer.swift")
snapshot_h = read("lara/overlay/CoreSetPlayerSnapshot.h")
publication_h = read("lara/overlay/CoreSetBattlePublication.h")

producer = coordinator.split("final class CoreSetBattleProducer", 1)[1].split(
    "final class CoreSetRuntimeCoordinator", 1
)[0]

for token in (
    "private let session = CoreSetReadSession()",
    "private var aimDemand: AimDemand?",
    "private var recoilDemand: RecoilDemand?",
    "private var displayDemand: DisplayDemand?",
    "CoreSetPlayerCollector.capture(session",
    "candidateStore.publishCandidateKey(",
    "CoreSetActionInputAuthority.authority(with: snapshot)",
    "func requestDisplay(",
    "func copyAction(",
    "let isClosed = closed",
):
    assert token in producer, token

capture = producer.split("private func capture()", 1)[1].split(
    "private func finishCapture()", 1
)[0]
assert capture.index("demandLock.lock()") < capture.index("let isClosed = closed")
assert capture.index("let isClosed = closed") < capture.index("demandLock.unlock()")
assert "guard !isClosed" in capture

assert "CoreSetPlayerCollector.capture" not in player
assert "CoreSetPlayerCollector.capture" not in aim
assert "refreshAction(for:" not in aim
assert "battleProducer.requestDisplay(" in player
assert "battleProducer.requestAim(" in aim
assert "battleProducer.requestRecoil(" in aim
assert "battleProducer.copyAction(" in aim
assert "dynamics.plan(candidate: candidate, input: input" in aim
assert "recoilDynamics.plan(input: input" in aim
assert "submit(authority: input" in aim
assert "snapshot: CoreSetPlayerSnapshot" not in aim

for token in (
    "CoreSetActionCandidateRawRecord",
    "static_assert(sizeof(CoreSetActionCandidateRawRecord) == 0x3a)",
    "uint64_t publicationSerial",
    "uint8_t sameAsPrevious",
    "uint8_t hadPrevious",
    "CoreSetActionInputAuthorityRawRecord",
    "uint64_t controllerAddress",
    "uint64_t localActorAddress",
    "float controlPitchDegrees",
    "float rotationInputPitch",
    "uint64_t recoilOwnerToken",
    "uint8_t routeAuthorityResolved",
    "int8_t resolvedActionSlot",
):
    assert token in publication_h, token

assert "@property(nonatomic, readonly) BOOL routeAuthorityResolved;" in snapshot_h
assert "@property(nonatomic, readonly) NSInteger resolvedActionSlotRaw;" in snapshot_h
assert "NS_SWIFT_NAME(authority(with:));" in snapshot_h
assert "拒绝用 firing 字节猜测 +0x620/+0x828" in aim
assert "routeDynamics.slot(firingSample:" not in aim

stop = coordinator.split("group.notify(queue: .main)", 1)[1]
assert stop.index("shutdownWriteSession()") < stop.index("shutdownReadSession()")
assert stop.index("shutdownReadSession()") < stop.index("battleProducer.shutdown()")

print("PASS: coordinator-owned union battle producer and typed compact action publication")
