"""Shared boundary: basic write controls cannot consume local preview fields."""
import re

BASIC_FIELDS = """[.basicAimEnabled, .basicAimTrigger, .basicAimDistance, .basicAimRadius, .basicAimBots,
         .basicAimScene, .basicAimStrength, .basicAimSmoothing, .basicAimHorizontalSpeed,
         .basicAimVerticalSpeed, .basicAimLockSameTarget, .basicAimPoint,
         .basicAimLockThreshold, .basicAimConfirmationFrames, .basicAimTakeoverPause]"""
PROFILE_GUARD = 'guard (info["profileMatches"] as? Bool) == true else'


def assert_basic_aim_boundary(source: str) -> None:
    match = re.search(r"var supportedFields: Set<CoreSetField> \{\s*(\[[^\]]*\])\s*\}", source)
    assert match, "basic write field declaration missing"
    assert re.findall(r"\.\w+", match.group(1)) == re.findall(r"\.\w+", BASIC_FIELDS)
    assert "let capability = CoreSetCapability.aimControl" in source
    assert "CoreSetKernelWriteProfileRegistry.diagnosticSnapshot()" in source
    assert PROFILE_GUARD in source
    assert "includeBattleInputs: true" in source
    assert "guard result.committed, cleanup.complete" in source
