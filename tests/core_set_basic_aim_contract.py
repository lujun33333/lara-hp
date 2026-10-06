import re


def check_basic_aim_contract(aim: str) -> None:
    match = re.search(r'var supportedFields: Set<CoreSetField>\s*\{\s*\[([^\]]*)\]', aim)
    assert match is not None
    assert set(re.findall(r'\.(\w+)', match.group(1))) == {
        'basicAimEnabled', 'basicAimTrigger', 'basicAimDistance', 'basicAimRadius', 'basicAimBots',
        'basicAimScene', 'basicAimStrength', 'basicAimSmoothing', 'basicAimHorizontalSpeed',
        'basicAimVerticalSpeed', 'basicAimLockSameTarget', 'basicAimPoint',
        'basicAimLockThreshold', 'basicAimConfirmationFrames', 'basicAimTakeoverPause'}
    assert 'info["profileMatches"]' in aim and 'CoreSetKernelWriteProfileRegistry.diagnosticSnapshot()' in aim
    assert 'guard result.committed, cleanup.complete, isLive' in aim
    assert 'CoreSetBasicAimDelta.select(' in aim and 'dynamics.plan(' in aim
    assert 'request.desired.point != nil' in aim and 'tuning(request.desired) != nil' in aim
    assert 'request.desired.excludeKnocked != true' in aim
