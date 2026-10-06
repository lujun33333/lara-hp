"""Battle inputs are opt-in and do not make action fields available."""

from pathlib import Path
from core_set_basic_aim_contract import check_basic_aim_contract

SOURCE = Path(__file__).resolve().parents[1]


def check(snapshot: str, header: str, plan: str, aim: str) -> None:
    assert "includeRadar:includeRadar includeBattleInputs:NO" in snapshot
    assert "includeBattleInputs:(BOOL)includeBattleInputs" in header
    for offset in ("local + 0x1848", "local + 0x2750", "controller + 0x620"):
        assert snapshot.count(offset) >= 2, offset
    assert snapshot.count("actor + 0x3be0") >= 1
    assert "actor.address + 0x3be0" in snapshot
    assert "healthStatusCode" in header and "mark.healthStatusCode = status" in snapshot
    assert "std::memcmp(controlRotation, rotationAfter" in snapshot
    assert "snapshot.battleInputsPresent = includeBattleInputs" in snapshot
    assert "snapshot.actorAddress" not in snapshot  # ID belongs to each mark, not frame.
    assert "mark.actorAddress = actor" in snapshot
    assert "bool writeReady = false" in plan
    assert "{76, 3, 300, 300, 220, 110}" in plan
    assert "{88, 2, 70, 600, 420, 60}" in plan
    assert "storedScene > 2" in plan
    assert "{0, 0, 3, 3, 4}" in plan
    assert "out->smoothingStep = 0.024 + 0.012 * smoothing" in plan
    assert "out->lockThreshold01 = std::fmin(5.0, std::fmax(0.05" in plan
    assert "item.generation != generation" in plan
    assert "!item.downedKnown || item.downed" in plan
    check_basic_aim_contract(aim)


def main() -> None:
    snapshot = (SOURCE / "lara/overlay/CoreSetPlayerSnapshot.mm").read_text(encoding="utf-8")
    header = (SOURCE / "lara/overlay/CoreSetPlayerSnapshot.h").read_text(encoding="utf-8")
    plan = (SOURCE / "lara/overlay/CoreSetAimPreselection.h").read_text(encoding="utf-8")
    aim = (SOURCE / "lara/views/app/CoreSetAimConsumer.swift").read_text(encoding="utf-8")
    check(snapshot, header, plan, aim)
    for mutated in (
        lambda: check(snapshot.replace("includeBattleInputs:NO", "includeBattleInputs:YES"), header, plan, aim),
        lambda: check(snapshot.replace("local + 0x1848", "local + 0x828"), header, plan, aim),
        lambda: check(snapshot.replace("actor.address + 0x3be0", "actor.address + 0x828"), header, plan, aim),
        lambda: check(snapshot.replace("std::memcmp(controlRotation, rotationAfter", "std::memcmp(old, rotationAfter"), header, plan, aim),
        lambda: check(snapshot, header, plan.replace("bool writeReady = false", "bool writeReady = true"), aim),
        lambda: check(snapshot, header, plan.replace("storedScene > 2", "storedScene > 3"), aim),
        lambda: check(snapshot, header, plan, aim.replace(".basicAimEnabled", ".aimEnabled")),
    ):
        try:
            mutated()
        except AssertionError:
            continue
        raise AssertionError("unsafe aim mutation passed")
    print("PASS: opt-in battle snapshot and non-writing aim preselection; 7 negatives")


if __name__ == "__main__":
    main()
