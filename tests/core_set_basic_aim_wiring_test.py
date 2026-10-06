from pathlib import Path

root = Path(__file__).resolve().parents[1]
aim = (root / 'lara/views/app/CoreSetAimConsumer.swift').read_text(encoding='utf-8')
native = (root / 'lara/overlay/CoreSetIsolatedWriteProbe.mm').read_text(encoding='utf-8')
state = (root / 'lara/views/app/CoreSetFeatureState.swift').read_text(encoding='utf-8')
ui = (root / 'lara/views/app/CoreSetMenuViewController.swift').read_text(encoding='utf-8')
coordinator = (root / 'lara/views/app/CoreSetRuntimeCoordinator.swift').read_text(encoding='utf-8')
assert 'includeBattleInputs: true' in aim
assert 'dynamics.plan(' in aim and 'CoreSetBasicAimDelta.select(' in aim
assert 'triggerState.update(' in aim and 'triggerState.permits(' in aim
assert 'CoreSet::basicAimStep(' in native and 'CoreSet::basicAimSelect(' in native
assert 'guard result.committed, cleanup.complete, isLive' in aim
assert aim.index('guard result.committed') < aim.index('.applied(observed: request.desired)', aim.index('guard result.committed'))
assert 'CoreSetKernelWriteProfileRegistry.diagnosticSnapshot()' in aim
assert 'info["profileMatches"]' in aim
assert 'guard let verified = capture(canvas, distance: tuning.distance)' in aim
assert 'validate(captured: snapshot, live: verified' in aim
validator = aim.split('CoreSetIsolatedWriteProbe(liveValidator:', 1)[1].split('})', 1)[0]
assert 'self.capture(' not in validator
assert 'self.pendingProbes = self.pendingProbes.filter' in aim
assert 'if clean { self.session = CoreSetReadSession() }' in aim
assert 'self.cleanupPending = !clean' in aim
assert 'current != request.token' in aim
assert '.stopped(reason:' in aim and 'case .stopped:' in state
assert 'callback(canceled.token, .failed' in aim
assert 'let aim = card("Core稳定自瞄"' in ui
assert 'aimControls(in: aim, filter: filter, scenario: scenario)' in ui
assert '闭合视角链' not in ui and '开始基础测试' not in ui
assert 'height: 440))' in ui and 'in: filter, y: 400)' in ui
assert 'let y = 82 + CGFloat(index) * 38' in ui
assert 'content.contentSize.height = 735' in ui
assert 'menu.suspendAimConsumer' in coordinator and 'menu.resumeAimConsumer()' in coordinator
assert 'CoreSetBasicAimDelta.validate(captured: snapshot, live: verified' in aim
assert 'controller + 0x828' in (root / 'lara/overlay/CoreSetPlayerSnapshot.mm').read_text(encoding='utf-8')
assert 'UISegmentedControl(items: ["上身 fallback +30", "胯部 fallback +25"])' in ui
assert 'let supportedPoint = state.point == .head || state.point == .hips' in ui
assert 'activateAfterAimStop = true' in coordinator
assert 'restoration == .notNeeded ||' in ui
assert 'CoreSetAimConsumer(coordinator: self)' in coordinator
print('basic aim integration checks passed (static only; no Swift/Apple execution)')
