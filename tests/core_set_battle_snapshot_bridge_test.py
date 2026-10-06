"""Static freshness/data provenance gate; not an Objective-C or device test."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def check(header: str, source: str) -> None:
    for field in ("CoreSetWorldPoint", "CoreSetBoneWorldPoint", "boneIndex",
                  "boneCount", "worldPosition", "screenPoint", "actorWorldPosition",
                  "cameraWorldPosition", "localWorldPosition", "canvasSize"):
        assert field in header, field
    # Exports must derive from the same world data used by existing projection.
    for line in (
        "if (includeBattleInputs) mark.actorWorldPosition = CSWorldPoint(position);",
        "point.worldPosition = CSWorldPoint(world);",
        "point.screenPoint = points[sample.index];",
        "point.boneIndex = sample.index; point.boneCount = state.array.count;",
        "snapshot.cameraWorldPosition = CSWorldPoint(camera.location);",
        "snapshot.localWorldPosition = CSWorldPoint(localPosition);",
        "snapshot.canvasSize = size;",
        "if (onScreen && (wantsDrawBones || includeBattleInputs))",
        "includeBattleInputs ? &worldPoints : nullptr",
    ):
        assert line in source, line
    # Each world source has a rejecting read-back before snapshot publication.
    publish = source.index("CoreSetPlayerSnapshot *snapshot = [CoreSetPlayerSnapshot new]")
    for guard in (
        "std::memcmp(&camera, &cameraAfter, sizeof(camera)) != 0",
        "std::memcmp(&localPosition, &localPositionAfter, sizeof(localPosition)) != 0",
        "std::memcmp(&position, &actor.position, sizeof(position)) != 0",
        "!present || !CSBoneStatesEqual(bone.state, after)) return nil;",
        "session.processID != pid || session.imageBase != base) return nil;",
        "if (!session.ready || session.generation != generation) return nil;",
    ):
        assert source.index(guard) < publish, guard
    projection = source.split("static NSArray<CoreSetBoneSegment *> *CSProjectBones", 1)[1]
    projection = projection.split("@interface CoreSetPlayerMark", 1)[0]
    assert projection.index("if (worldPoints) *worldPoints = @[];") < projection.index("for (const CSBoneSample")
    assert projection.index("return @[];") < projection.index("[captured addObject:point]")
    assert projection.index("if (worldPoints) *worldPoints = [captured copy];") > projection.index("for (const CSBoneSample")


def main() -> None:
    header = (ROOT / "lara/overlay/CoreSetPlayerSnapshot.h").read_text(encoding="utf-8")
    source = (ROOT / "lara/overlay/CoreSetPlayerSnapshot.mm").read_text(encoding="utf-8")
    check(header, source)
    mutations = (
        ("CSWorldPoint(world)", "CSWorldPoint({0, 0, 0})"),
        ("point.screenPoint = points[sample.index];", "point.screenPoint = CGPointZero;"),
        ("std::memcmp(&camera, &cameraAfter, sizeof(camera)) != 0", "false"),
        ("std::memcmp(&position, &actor.position, sizeof(position)) != 0", "false"),
        ("!present || !CSBoneStatesEqual(bone.state, after)) return nil;", "false) return nil;"),
        ("if (onScreen && (wantsDrawBones || includeBattleInputs))", "if (onScreen && wantsDrawBones)"),
    )
    for old, new in mutations:
        assert old in source
        try:
            check(header, source.replace(old, new))
        except (AssertionError, ValueError):
            continue
        raise AssertionError(f"provenance/freshness mutation accepted: {old}")
    print("PASS: battle snapshot bridge static provenance and 6 negative mutations")


if __name__ == "__main__":
    main()
