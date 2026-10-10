"""Menu staging and unavailable-feedback source contracts; no UIKit/device claim."""

from pathlib import Path
import argparse
import json
import re
from collections import Counter

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
assert "CoreSetField.configurable(for: capability).contains(field)" in configuration
assert "binding?.configurableFields().contains(field) == true" in configuration
assert "canStageDesired" in configuration
assert "currentAvailability" not in configuration
staging = body(state, "var canStageDesired:")
for gate in ("binding?.owner != nil", "!suspended", "pendingStop == nil", "restoration != .pending"):
    assert gate in staging, gate
assert "currentAvailability" not in staging
live = body(state, "func fieldAvailability(")
assert "CoreSetField.required(for: capability).contains(field)" in live
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
assert "channel.isSupportedDesiredConfirmed" in apply
assert "scope=consumer-declared-fields" in apply
assert "case .notApplied, .unavailable:" in apply
assert "self.stagedConfigurationPaths.insert(path)" in apply
assert "self.stagedConfigurationReadiness[path] = self.canApply" in apply
deferred = body(menu, "private func applyStagedConfigurations()")
for channel in ("frameRate", "player", "materials", "adjustments", "radar", "aimDisplay", "aim", "recoil"):
    assert f"apply(\\.{channel})" in deferred, channel
assert "guard ready && !wasReady" in deferred
stop = body(menu, "func suspendGameConsumers(")
assert "stagedConfigurationPaths.removeAll()" in stop
assert "stagedConfigurationReadiness.removeAll()" in stop


def require_rejection_safety(source: str) -> None:
    receipt = body(source, "mutating func receive(")
    rejected = receipt.split("case .notApplied(let reason):", 1)[1].split("case .unavailable(let reason):", 1)[0]
    assert "if actual == nil && !effectsBeforePendingApply" in rejected
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
    state.replace("if actual == nil && !effectsBeforePendingApply", "if actual == nil"),
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
    if name == "Aim":
        assert ".unavailable(reason:" in entry and "CoreSetIsolatedWriteProbe" in consumer, name
    elif name == "Recoil":
        assert ".unavailable(reason:" in entry and "CoreSetAimConsumer" in consumer, name
    else:
        assert ".notApplied(reason:" in entry, name
    if "revision += 1" in entry:
        assert entry.index(".notApplied(reason:") < entry.index("revision += 1"), name
    if name in ("Player", "Material", "Radar", "Adjustment", "AimDisplay"):
        receipt_owner = body(consumer, "private func finishUnavailable(") if name == "Player" \
            else body(consumer, "func consumed(")
        assert ".unavailable(reason:" in receipt_owner, name
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
assert "aimConfigurationAvailable(.basicAimScene)" in scene
assert "选择基础视角自瞄场景参数" in scene
start = body(menu, "@objc private func startBasicAim()")
assert "aimConfigurationAvailable(.basicAimEnabled)" in start
assert r"editGame(\.aim)" in start
aim_consumer = (ROOT / "lara/views/app/CoreSetAimConsumer.swift").read_text(encoding="utf-8")
assert "CoreSetIsolatedWriteProbe" in aim_consumer
assert "var supportedFields: Set<CoreSetField> { [] }" not in aim_consumer
recoil_consumer = (ROOT / "lara/views/app/CoreSetRecoilConsumer.swift").read_text(encoding="utf-8")
assert "var supportedFields: Set<CoreSetField> { [] }" not in recoil_consumer
assert ".recoilEnabled" in body(recoil_consumer, "var supportedFields:")
assert ".unavailable(reason:" in body(recoil_consumer, "var availability:")

# An unrelated observation cannot destroy the pointer between down and up.
rebuild = body(menu, "private func rebuildMenu(")
assert "if imguiRuntimeEnabled" in rebuild
assert rebuild.index("if imguiRuntimeEnabled") < rebuild.index("hostedPointerID != nil")
for gate in ("hostedPointerID != nil", "hostedDispatchControlID != nil", "trackingUIKitSlider != nil"):
    assert rebuild.index(gate) < rebuild.rindex("hostedMenuRevision &+= 1")
register = body(menu, "private func registerHosted(")
assert "slider.isContinuous = false" in register
assert "beginUIKitSliderTracking" in register and "endUIKitSliderTracking" in register
assert "trackingUIKitSlider != nil" in rebuild
native_end = body(menu, "@objc private func endUIKitSliderTracking(")
assert "DispatchQueue.main.async" in native_end and "homeStatusNeedsRebuild" in native_end
handler = body(menu, "func handleHostedControl(")
assert "if homeStatusNeedsRebuild && hostedPointerID == nil {" in handler
assert "DispatchQueue.main.async" in handler and "self.hostedDispatchControlID == nil" in handler
assert "selectedPage == 0" not in handler
circle = body(menu, "@objc private func toggleLocalAimCircle(")
assert "featureState.aimDisplay.desired.circleVisible" in circle
preview = body(menu, "@objc private func toggleLocalAimPreviewField(")
assert "let action = featureState.aim.desired" in preview
assert "previewReady" in preview and "actionReady" in preview
visible_aim_ranges = body(menu, "@objc private func configureBasicAimRange(")
assert "editGame(\\.aimDisplay) { $0.circleSize.set" in visible_aim_ranges
assert "editGame(\\.aimDisplay) { $0.maximumDistance.set" in visible_aim_ranges
assert "applyGame(\\.aim)" not in visible_aim_ranges
visible_aim_bots = body(menu, "@objc private func configureBasicAimBots(")
assert "editGame(\\.aimDisplay) { $0.includeBots" in visible_aim_bots

# Nil/stale periodic frames revoke proof without forgiving a previous effect.
invalidation = body(state, "mutating func invalidateReadFrameObservation(")
assert invalidation.index("actual = nil") < invalidation.index("guard pendingStop == nil") < invalidation.index("generation = UUID()")
assert "observationInvalidationReason = reason" in invalidation
assert "mayHaveEffects = false" not in invalidation
assert "restoration = .notNeeded" not in invalidation
assert "phase = mayHaveEffects ? .active : .unknown" in invalidation
assert "effectsBeforePendingApply = mayHaveEffects" in prepare
full_proof = body(state, "var isDesiredConfirmed:")
assert "availability == .ready" in full_proof and "canApplySupportedSubset" not in full_proof
field_proof = body(state, "func isFieldDesiredConfirmed(")
assert "fieldAvailability(field) == .ready" in field_proof
assert "isSupportedDesiredConfirmed" in field_proof
subset_proof = body(state, "var isSupportedDesiredConfirmed:")
for gate in ("currentAvailability() == .ready", "actual == desired", "pendingApply == nil", "phase == .active"):
    assert gate in subset_proof, gate
display_proof = body(menu, "private func updateControlProof(")
assert "guard explicit else" in display_proof
assert "channel.isFieldDesiredConfirmed(field)" in display_proof
assert "observationInvalidationReason" in display_proof
assert "替代预览，不算v1.7原效果" in display_proof
assert "control.accessibilityIdentifier" in display_proof
assert "stage=field-state" in display_proof
forward = (ROOT / "lara/views/app/CoreSetRuntimeCoordinator.swift").read_text(encoding="utf-8")
assert "menu.invalidateReadFrameObservation(capability: capability, reason: reason)" in body(forward, "func invalidateReadFrameObservation(")

# Reference custom controls are in the scenario card and remain local config.
aim_ui = body(menu, "private func aimControls(")
assert 'UISegmentedControl(items: ["头部", "胸部", "屁股"])' in aim_ui
for title in ("水平速度", "垂直速度", "预判提前", "锁定门槛", "接管暂停"):
    assert f'("{title}"' in aim_ui, title
assert "scenario.addSubview(slider)" in aim_ui
assert "else if state.scene != nil" in aim_ui
assert "case 9: $0.custom.predictionMilliseconds.set" in visible_aim_ranges
assert "recordAimConfiguration" in visible_aim_ranges
record = body(menu, "private func recordAimConfiguration(")
assert "configured=1 confirmed=0" in record and "targetEffectsCreated=0" in record
assert "prepareApply" not in record and "applyGame" not in record
chest = body(menu, "@objc private func configureBasicAimPoint(")
assert "if point == .chest" not in chest
assert "featureState.aim.updateDesired" in chest

for signature, field in (("@objc private func toggleRecoilField(", "recoilStopWhenNotFiring"),
                          ("@objc private func configureRecoilStrength(", "recoilVerticalStrength")):
    action = body(menu, signature)
    assert field in action
    assert "editGame(\\.recoil)" in action
    assert "recordRecoilConfiguration" in action
home_run = body(menu, "@objc private func configureHomeRunMode(")
home_cover = body(menu, "@objc private func configureHomeCoverMode(")
assert "featureState.home.updateDesired" in home_run and "targetEffectsCreated=0" in home_run
assert "selectCoverMode" in home_cover and "targetEffectsCreated=0" in home_cover
assert "if mode != .off { retainedCoverMode = mode }" in state

# Executable inventory: every point has reference, state, conversion, lifecycle,
# consumer and receipt entries. Missing actions cannot silently become closed.
matrix = json.loads((ROOT / "tests/fixtures/core_set_v17_menu_point_map.json").read_text(encoding="utf-8"))
rows = [dict(zip(matrix["columns"], row)) for row in matrix["points"]]
native_matrix = json.loads((ROOT / "tests/fixtures/core_set_v17_native_point_chain_map.json").read_text(encoding="utf-8"))
native_points = {point["id"]: point for point in native_matrix["points"]}
assert len(rows) == 137
assert [row["id"] for row in rows] == [f"v17-{index:03}" for index in range(137)]
assert len({row["page"] for row in rows}) == 7
assert len({(row["page"], row["card"]) for row in rows}) == 19
assert not any(row["device_effect_verified"] for row in rows)
contracts = matrix["contracts"]
for row in rows:
    native_point = native_points[row["id"]]
    assert (native_point["page"], native_point["title"]) == (row["page"], row["title"])
    assert row["reference_evidence_key"] == native_point["reference_evidence_key"]
    assert not native_point["one_to_one_complete"] and not native_point["original_runtime_receipt_verified"]
    assert row["reference_prior_static_evidence_key"]
    for callback in row["entry"].split("|"):
        assert re.search(rf"\bfunc {callback}\b", menu), (row["id"], callback)
    assert row["reference_evidence_key"] and row["reference_binding_grade"]
    assert row["configuration"] and row["parameter_conversion"] and row["current_implementation_status"]
    assert row["ax_role"] == "carrier-only; NOT feature algorithm/source"
    contract = contracts[row["consumer_contract"]]
    assert (ROOT / contract["source"]).is_file()
    assert contract["receipt"] and set(contract["lifecycle"]) == {"start", "update", "stop"}
    assert not contract["runtime_device_verified"]
missing_local = [row for row in rows if row["consumer_contract"].startswith("missing_")]
assert len(missing_local) == 2
counts = Counter(row["consumer_contract"] for row in rows)
assert counts["local_appearance"] + counts["local_directory"] + counts["host_palette"] == 31
assert counts["home_observation"] + counts["performance_observation"] == 10
assert sum(counts[key] for key in ("player", "materials", "adjustments", "radar", "frame_rate")) == 61
original_action_gaps = [row for row in rows if row["id"] in set(matrix["downstream_requirements"]) - {
    "v17-131", "v17-132", "v17-133", "v17-134", "v17-135", "v17-136"}
]
assert len(original_action_gaps) == 29
assert {row["id"] for row in original_action_gaps} == set(matrix["downstream_requirements"]) - {
    "v17-131", "v17-132", "v17-133", "v17-134", "v17-135", "v17-136"}
for row in original_action_gaps:
    requirement = matrix["downstream_requirements"][row["id"]]
    for key in ("interface", "state_field", "evidence_required", "receipt_required"):
        assert requirement[key], (row["id"], key)
    assert row["downstream_requirement"] == row["id"]
assert [row["id"] for row in rows if row["alternative_preview_field"]] == [
    "v17-108", "v17-110", "v17-111", "v17-112", "v17-113", "v17-115", "v17-117"]
preview_only = {"v17-108", "v17-110", "v17-111", "v17-112"}
assert {row["id"] for row in rows if row["consumer_contract"] == "aim_display_alternative"} == preview_only
assert all(row["consumer_contract"] == "aim" for row in rows
           if row["id"].startswith("v17-") and 106 <= int(row["id"][4:]) <= 130
           and row["id"] not in preview_only)
assert sum(row["consumer_contract"] in ("aim", "recoil") for row in rows) == 27
assert set(matrix["original_observation_producer_gaps"]) == {"v17-005", "v17-006", "v17-008", "v17-009", "v17-010"}
assert all(extra["local_equivalent_producer_available"] for extra in matrix["original_observation_producer_gaps"].values())
assert all(not extra["original_producer_available"] for extra in matrix["original_observation_producer_gaps"].values())
assert all(not extra["counts_toward_v17_closure"] for extra in matrix["original_observation_producer_gaps"].values())
assert all(not extra["counts_toward_v17_closure"] for extra in matrix["current_ui_extensions"])

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
    assert [(point["page"], point["card"], point["title"], point.get("condition") or "", point.get("range")) for point in points] == [
        (row["page"], row["card"], row["title"], row["reference_condition"], row["reference_range"]) for row in rows]
    print(f"REFERENCE: {len(pages)} pages / {len(cards)} cards / {len(points)} inventory points; all card names present")

print("PASS: local configuration staging, live apply gates, observable unavailable actions, pointer lifetime; source only")
print("MATRIX: 137 reference points, 6 missing original action consumers, 27 Aim/Recoil points source-closed/device-unverified, 7 alternative preview fields, 5 missing original observation producers; device effect closure=0")
print("LIMIT: no Swift/UIKit compilation, physical hit testing, consumer receipt or device output verification")
