"""Menu staging and unavailable-feedback source contracts; no UIKit/device claim."""

from pathlib import Path
import argparse
import json
import re

ROOT = Path(__file__).resolve().parents[1]
menu = (ROOT / "lara/views/app/CoreSetMenuViewController.swift").read_text(encoding="utf-8")
state = (ROOT / "lara/views/app/CoreSetFeatureState.swift").read_text(encoding="utf-8")


def body(source: str, signature: str) -> str:
    opening = source.index("{", source.index(signature))
    depth = 1
    for position in range(opening + 1, len(source)):
        if source[position] == "{":
            depth += 1
        elif source[position] == "}":
            depth -= 1
            if depth == 0:
                return source[opening + 1:position]
    raise AssertionError(f"unterminated body: {signature}")


# A static configuration declaration must never promote the live apply surface.
assert "var configurableFields: Set<CoreSetField> { get }" in state
assert "var configurableFields: Set<CoreSetField> { supportedFields }" in state
assert "configurationFields = { consumer.configurableFields }" in menu
configuration = body(state, "func fieldConfigurationAvailability(")
assert "CoreSetField.required(for: capability).contains(field)" in configuration
assert "binding?.configurableFields().contains(field) == true" in configuration
assert "canStageDesired" in configuration
assert "currentAvailability" not in configuration
staging = body(state, "var canStageDesired:")
for gate in ("binding?.owner != nil", "!suspended", "pendingStop == nil", "restoration != .pending"):
    assert gate in staging, gate
assert "currentAvailability" not in staging
live = body(state, "func fieldAvailability(")
assert "binding?.supportedFields().contains(field) == true" in live
assert "binding?.currentAvailability()" in live
prepare = body(state, "mutating func prepareApply()")
assert "availability == .ready || canApplySupportedSubset" in prepare
assert "configurableFields" not in prepare
subset = body(state, "var canApplySupportedSubset:")
assert "binding?.currentAvailability() == .ready" in subset
assert "configurableFields" not in subset

assert "channel.canStageDesired" in body(menu, "private func canStage<")
assert "channel.fieldConfigurationAvailability(field)" in body(menu, "private func controlAvailability<")
edit = body(menu, "private func editGame<")
assert "updateDesired(edit)" in edit
assert "stagedConfigurationPaths.insert(path)" in edit
assert "canApply(featureState[keyPath: path])" in edit
assert "configured=1 confirmed=0" in edit
apply = body(menu, "private func applyGame<")
assert "prepareApply()" in apply
assert apply.index("stagedConfigurationPaths.remove(path)") < apply.index("consumer.apply(request)")
assert "receive(token, outcome: outcome)" in apply
assert "channel.isDesiredConfirmed" in apply
assert "case .notApplied, .unavailable:" in apply
assert "self.stagedConfigurationPaths.insert(path)" in apply
assert "self.stagedConfigurationReadiness[path] = self.canApply" in apply
deferred = body(menu, "private func applyStagedConfigurations()")
for channel in ("frameRate", "player", "materials", "adjustments", "radar", "aimDisplay"):
    assert f"apply(\\.{channel})" in deferred, channel
assert "apply(\\.aim)" not in deferred and "apply(\\.recoil)" not in deferred
assert "guard ready && !wasReady" in deferred
stop = body(menu, "func suspendGameConsumers(")
assert "stagedConfigurationPaths.removeAll()" in stop
assert "stagedConfigurationReadiness.removeAll()" in stop


def require_rejection_safety(source: str) -> None:
    receipt = body(source, "mutating func receive(")
    rejected = receipt.split("case .notApplied(let reason):", 1)[1].split("case .unavailable(let reason):", 1)[0]
    assert "if actual == nil" in rejected
    first, prior = rejected.split("} else {", 1)
    assert "mayHaveEffects = false" in first and "restoration = .notNeeded" in first
    assert "phase = .active" in prior
    assert "mayHaveEffects = false" not in prior and "restoration = .notNeeded" not in prior
    unavailable = receipt.split("case .unavailable(let reason):", 1)[1].split("case .failed(let reason):", 1)[0]
    assert "mayHaveEffects = false" not in unavailable and "restoration = .notNeeded" not in unavailable


require_rejection_safety(state)
# Negative controls reject accidentally treating a lost post-submit receipt as
# harmless, and reject forgetting an already observed state during a new refusal.
for unsafe in (
    state.replace("phase = .active\n            }\n        case .unavailable", "mayHaveEffects = false; phase = .active\n            }\n        case .unavailable"),
    state.replace("case .unavailable(let reason): availability", "case .unavailable(let reason): mayHaveEffects = false; availability"),
):
    try:
        require_rejection_safety(unsafe)
    except AssertionError:
        pass
    else:
        raise AssertionError("unsafe rejection handling was not detected")

for name in ("Player", "Material", "Radar", "Adjustment", "AimDisplay", "FrameRate", "Aim", "Recoil"):
    consumer = (ROOT / "lara/views/app" / f"CoreSet{name}Consumer.swift").read_text(encoding="utf-8")
    entry = body(consumer, "func apply(")
    assert ".notApplied(reason:" in entry, name
    if "revision += 1" in entry:
        assert entry.index(".notApplied(reason:") < entry.index("revision += 1"), name
    if name in ("Player", "Material", "Radar", "Adjustment", "AimDisplay"):
        assert ".unavailable(reason:" in body(consumer, "func consumed("), name
fps = body((ROOT / "lara/views/app/CoreSetFrameRateConsumer.swift").read_text(encoding="utf-8"), "func apply(")
assert fps.index(".notApplied(reason:") < fps.index("coordinator?.applyFrameRate(value)") < fps.index(".unavailable(reason:")

# Disabled actions retain their original gate; an explicit explanation is hittable.
feedback = body(menu, "private func installUnavailableFeedback(")
assert "disabledControl || disabledRow" in feedback
assert "UnavailableInfoButton" in feedback
assert "explainedView === child" in feedback
assert "info.addTarget(self, action: #selector(explainUnavailable(_:))" in feedback
assert "registerHosted(info, .unavailableInfo)" in feedback
assert ".unavailableInfo: explainUnavailable(button)" in menu
explain = body(menu, "@objc private func explainUnavailable(")
assert "showConfigurationFeedback(" in explain
assert "configured=0 confirmed=0" in explain
assert "updateDesired" not in explain and "applyGame" not in explain

scene = body(menu, "private func scenePreview(")
assert "controlAvailability(.basicAimScene" not in scene
assert "尚未生效" in scene
start = body(menu, "@objc private func startBasicAim()")
assert "guard canApply(featureState.aim)" in start
for filename in ("CoreSetAimConsumer.swift", "CoreSetRecoilConsumer.swift"):
    consumer = (ROOT / "lara/views/app" / filename).read_text(encoding="utf-8")
    assert "var supportedFields: Set<CoreSetField> { [] }" in consumer
    assert ".unavailable(reason:" in body(consumer, "var availability:")

# An unrelated observation cannot destroy the pointer between down and up.
rebuild = body(menu, "private func rebuildMenu(")
assert rebuild.index("hostedPointerID != nil && hostedDispatchControlID == nil") < rebuild.index("hostedMenuRevision &+= 1")
register = body(menu, "private func registerHosted(")
assert "slider.isContinuous = false" in register
assert "beginUIKitSliderTracking" in register and "endUIKitSliderTracking" in register
assert "trackingUIKitSlider != nil" in rebuild
native_end = body(menu, "@objc private func endUIKitSliderTracking(")
assert "DispatchQueue.main.async" in native_end and "homeStatusNeedsRebuild" in native_end
handler = body(menu, "func handleHostedControl(")
assert "if homeStatusNeedsRebuild && hostedPointerID == nil {" in handler
assert "selectedPage == 0" not in handler
circle = body(menu, "@objc private func toggleLocalAimCircle(")
assert "featureState.aimDisplay.desired.circleVisible" in circle
preview = body(menu, "@objc private func toggleLocalAimPreviewField(")
assert "let desired = featureState.aimDisplay.desired" in preview
visible_aim_ranges = body(menu, "@objc private func configureBasicAimRange(")
assert "editGame(\\.aimDisplay) { $0.circleSize.set" in visible_aim_ranges
assert "editGame(\\.aimDisplay) { $0.maximumDistance.set" in visible_aim_ranges
assert "applyGame(\\.aim)" not in visible_aim_ranges
visible_aim_bots = body(menu, "@objc private func configureBasicAimBots(")
assert "editGame(\\.aimDisplay) { $0.includeBots" in visible_aim_bots

parser = argparse.ArgumentParser()
parser.add_argument("--inventory", type=Path)
args = parser.parse_args()
if args.inventory:
    points = json.loads(args.inventory.read_text(encoding="utf-8"))["points"]
    pages = {point["page"] for point in points}
    cards = {(point["page"], point["card"]) for point in points}
    assert len(pages) == 7 and len(cards) == 19
    for _, card in cards:
        assert f'card("{card}"' in menu, card
    print(f"REFERENCE: {len(pages)} pages / {len(cards)} cards / {len(points)} inventory points; all card names present")

print("PASS: local configuration staging, live apply gates, observable unavailable actions, pointer lifetime; source only")
print("LIMIT: no Swift/UIKit compilation, physical hit testing, consumer receipt or device output verification")
