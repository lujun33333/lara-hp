from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
read = lambda path: (ROOT / path).read_text(encoding="utf-8")

aim = read("lara/views/app/CoreSetAimConsumer.swift")
state = read("lara/views/app/CoreSetFeatureState.swift")
menu = read("lara/views/app/CoreSetMenuViewController.swift")
snapshot_h = read("lara/overlay/CoreSetPlayerSnapshot.h")
snapshot_mm = read("lara/overlay/CoreSetPlayerSnapshot.mm")
geometry = read("lara/overlay/CoreSetBasicAimGeometry.h")
probe_h = read("lara/overlay/CoreSetIsolatedWriteProbe.h")
probe_mm = read("lara/overlay/CoreSetIsolatedWriteProbe.mm")

for token in (
    "referenceAnchor1e0WorldPosition", "referenceAnchor1ecWorldPosition",
    "downedKnown", "referenceStateWord", "referenceFlag14",
):
    assert token in snapshot_h and token in snapshot_mm, token

for token in (
    "CSPublishAimAnchors", "CSBoneWorldPoint(state, 0)", "state.edges[0]",
    "CSBoneSample rootSample = {0, {}}",
):
    assert token in snapshot_mm, token

for token in (
    "playerBones: true", "botBones: true", "excludeKnocked:",
    "publicationID: snapshot.snapshotID", "predictionMilliseconds:",
    "curveSelector:", "residualGain:", "minimumDeadzone:",
    "actionSlot(recoilEnabled:", "routeDynamics.useControlRotation", "routeDynamics.observeCommitted",
    "slot == .rotationInput", "CoreSetV17RecoilDynamics",
):
    assert token in aim, token

for token in (
    "referenceActionActorEligible", "referenceActionWorldPoint", "referenceActionScreenRank",
    "referenceActionCandidateMotion", "referenceActionGeometry", "referenceActionTakeover",
    "@property(nonatomic) float aimPitch;", "@property(nonatomic) float aimYaw;",
    "@property(nonatomic) float recoilPitch;", "@property(nonatomic) float recoilYaw;",
):
    assert token in probe_mm, token

assert "basicAimLineOfSight" not in state
assert "var lineOfSight: Bool?" not in state
assert "LOS掩体判断" not in menu
assert "meshComponent + 0xb40" not in snapshot_mm
assert "rootComponent + 0x250" not in snapshot_mm
assert "basicAimDynamicStep(" not in probe_mm
assert "verified.localFiring ?" not in aim
assert "restoreActiveState" not in aim
assert "CoreSetTargetWriteSlotRotationInput" in probe_mm
assert "restoreSnapshot:" not in probe_h and "restoreSnapshot:" not in probe_mm
print("PASS: Core v1.7 selection, point, relative-motion geometry, Aim route and stop wiring")
