"""Source contracts for the Foundation-only state model; does not execute Swift."""
from pathlib import Path
import hashlib
import json
import re

ROOT = Path(__file__).resolve().parents[1]
path = ROOT / "lara/views/app/CoreSetFeatureState.swift"
source = path.read_text(encoding="utf-8")
evidence = (ROOT / "artifacts/core-set-v1.7/v1.7-ui-evidence.md").read_text(encoding="utf-8")

def body(text, pattern):
    match = re.search(pattern, text)
    assert match, pattern
    start = text.index("{", match.end())
    depth = 1
    for end in range(start + 1, len(text)):
        depth += (text[end] == "{") - (text[end] == "}")
        if not depth:
            return text[start + 1:end]
    raise AssertionError("unclosed scope: " + pattern)

def scope(name, text=source):
    return body(text, r"(?:struct|enum|class) " + name + r"\b")

def function(text, name):
    return body(text, r"func " + name + r"\b")

def need(text, *tokens):
    for token in tokens:
        assert token in text, "missing " + token

assert source.startswith("import Foundation")
assert not re.search(r"import UIKit|UserDefaults|URLSession|smoba|UnityFramework|ShadowTrackerExtra|Yuanbao|\bWZ[A-Z_a-z]|\bAXHUD|wzesp|wzhud|wzaim|王者|task_for_pid|ds_run|ds_kread", source)
assert "case home, player, materials, adjustments, radar, aim, recoil" in scope("CoreSetPage")

def validate_channel(text):
    channel = scope("CoreSetFeatureChannel", text)
    binding = scope("CoreSetConsumerBinding", text)
    need(binding, "weak var owner: AnyObject?", "[weak consumer]", "consumer?.availability")
    assert "setAvailability" not in channel
    need(channel, 'availability: CoreSetAvailability = .unavailable(reason: "No consumer attached")', "actual: Value?", "pendingApply", "pendingStop")
    need(function(channel, "bind"), "consumer.capability == capability", "!mayHaveEffects", "pendingStop == nil", "ConsumerBinding(consumer)", "generation = UUID()")
    need(function(channel, "prepareApply"), "refreshAvailability()", "guard let binding = binding, binding.owner != nil", "!suspended", "availability == .ready", "pendingStop == nil", "pendingApply == nil", "consumerID: binding.id", "mayHaveEffects = true")
    receive = function(channel, "receive")
    need(receive, "binding?.owner != nil", "token.consumerID == binding?.id", "token.generation == generation", "pendingApply?.token == token", "!suspended", "case .applied(let observed):", "guard binding?.currentAvailability() == .ready", "actual = observed; phase = .active")
    assert len(re.findall(r"phase\s*=\s*\.active\b", channel)) == 1
    assert receive.index("case .applied(let observed):") < receive.index("guard binding?.currentAvailability() == .ready") < receive.index("phase = .active")
    confirmed = body(channel, r"var isDesiredConfirmed: Bool")
    need(confirmed, "binding?.owner != nil", "binding?.currentAvailability() == .ready", "availability == .ready", "!suspended", "actual == desired", "pendingApply == nil")
    need(function(channel, "refreshAvailability"), "binding?.currentAvailability()", "if case .unavailable", "pendingApply = nil", "phase = .failed(reason)")
    suspend = function(channel, "suspend")
    need(suspend, "suspended = true", "pendingApply = nil", "if mayHaveEffects { _ = prepareStop() }")
    assert not re.search(r"desired\s*=|actual\s*=", suspend)
    need(function(channel, "prepareStop"), "guard mayHaveEffects", "if let token = pendingStop { return token }", "consumerID: binding.id", "restoration = .pending", "phase = .stopping")
    stop = function(channel, "receiveStop")
    need(stop, "binding?.owner != nil", "token.consumerID == binding?.id", "token.generation == generation", "pendingStop == token", "case .restored:", "mayHaveEffects = false", "restoration = .confirmed", "actual = nil")
    resume = function(channel, "resume")
    need(resume, "guard !mayHaveEffects, pendingStop == nil", "generation = UUID()", "actual = nil", "phase = .unknown", "suspended = false")
    assert "prepareApply" not in resume and not re.search(r"desired\s*=", resume)

validate_channel(source)
# Negative controls verify the gate rejects representative former false-positive
# contracts; these mutations exist only in memory and never touch production.
mutations = [
    ("guard binding?.owner != nil, token.consumerID == binding?.id,", "guard token.consumerID == binding?.id,"),
    ("pendingApply?.token == token, !suspended", "true, !suspended"),
    ("guard consumer.capability == capability, !mayHaveEffects", "guard !mayHaveEffects"),
    ("guard binding?.currentAvailability() == .ready else { refreshAvailability(); return false }", ""),
]
for old, new in mutations:
    assert old in source
    try:
        validate_channel(source.replace(old, new))
    except AssertionError:
        pass
    else:
        raise AssertionError("state gate accepted removed precondition: " + old)

need(scope("CoreSetToggleMode"), "enabled: Bool?", "mode: Mode?", "self.mode = mode; enabled = true")
assert not re.search(r"mode\s*=", function(scope("CoreSetToggleMode"), "disable"))
need(scope("CoreSetInvertedFlag"), "get { enabled.map { !$0 } }", "set { enabled = newValue.map { !$0 } }")
expected_enums = {
    "CoreSetWeaponMode": {"image": 0, "text": 1},
    "CoreSetCountMode": {"detailed": 1, "compact": 0},
    "CoreSetInformationMode": {"modern": 0, "minimal": 1},
    "CoreSetBackIndicator": {"withDistance": 0, "indicatorOnly": 1, "off": 2},
    "CoreSetAimPoint": {"head": 0, "chest": 1, "hips": 2},
    "CoreSetAimTrigger": {"scopeOnly": 1, "fireOnly": 2, "either": 0, "both": 3},
    "CoreSetAimScene": {"far": 0, "close": 2, "general": 1, "custom": 3},
    "CoreSetLockStrength": {"strong": 4, "medium": 3, "light": 0},
    "CoreSetFloatingPalette": {"first": 6, "second": 4, "third": 1, "fourth": 0, "fifth": 2, "sixth": 3, "gradient": 5},
}
for name, expected in expected_enums.items():
    actual = {key: int(value) for key, value in re.findall(r"(\w+)\s*=\s*(-?\d+)", scope(name))}
    assert actual == expected, (name, actual)
for token in ["存值[1,2,0,3]", "强/中/轻→存值4/3/0", "关闭保留mode", "反向布尔语义", "0<=min<=max<=2000"]:
    assert token in evidence, token

ranges = {
    "CoreSetHomeSettings": {"framesPerSecond": (30, 144)},
    "CoreSetPlayerSettings": {"drawingDistance": (1, 1000), "boneDistance": (1, 500), "backSize": (40, 160)},
    "CoreSetAdjustmentSettings": {"rayThickness": (1, 10), "boneThickness": (1, 10), "materialFontSize": (5, 30)},
    "CoreSetRadarSettings": {"detectionDistance": (100, 1000), "warningRange": (20, 300), "warningTextSize": (10, 200)},
    "CoreSetAimSettings": {"circleSize": (30, 525)},
    "CoreSetAimCustomSettings": {"maximumDistance": (10, 500), "strength": (5, 100), "smoothing": (1, 10), "confirmationFrames": (1, 6), "horizontalSpeed": (30, 720), "verticalSpeed": (30, 720), "predictionMilliseconds": (0, 300), "lockThreshold": (5, 500), "takeoverPauseMilliseconds": (50, 1000)},
    "CoreSetRecoilSettings": {"verticalStrength": (0, 100), "horizontalStrength": (0, 100)},
}
for name, expected in ranges.items():
    actual = {key: (int(low), int(high)) for key, low, high in re.findall(r"var (\w+) = CoreSetIntSetting\((\d+)\.\.\.(\d+)\)", scope(name))}
    assert actual == expected, (name, actual)
need(scope("CoreSetAimSettings"), "scene == .custom", "scene != nil && scene != .custom")
need(scope("CoreSetMaterialDistance"), "minimum: Int?", "maximum: Int?", "min(maximum ?? 2000", "max(minimum ?? 0")
group = scope("CoreSetMaterialGroup")
need(group, "members: [Bool?]", "Array(repeating: nil", "guard members.allSatisfy({ $0 != nil }) else { return .unknown }", "members.contains(true) ? .partial : .none", "setAll(selection != .all)")
catalog = json.loads(re.findall(r"```json\s*(\{.*?\})\s*```", evidence, re.S)[0])
names = json.loads(re.search(r"static let names: \[\[String\]\] = (\[.*?\])\s*static func", source, re.S).group(1))
assert names == list(catalog.values()) and sum(map(len, names)) == 149
counts = json.loads(re.findall(r"```json\s*(\{.*?\})\s*```", evidence, re.S)[1])
multiplicity = function(scope("CoreSetMaterialCatalog"), "multiplicity")
for category in ("载具车辆", "物资箱子"):
    for label, count in counts[category].items():
        assert f'"{label}": {count}' in multiplicity
assert 'name == "雪人" ? 2 : 1' in multiplicity
assert sum(counts.get(category, {}).get(name, 1) for category, entries in catalog.items() for name in entries) == 177
need(scope("CoreSetRadarCanvas"), "for candidate in [native, display]", "value.isFinite, value > 0", "fallback: 390", "fallback: 844")
need(function(scope("CoreSetRadarPlacement"), "setRadius"), "if radius == nil { x = nil; y = nil; return }", "setX(x); setY(y)")
need(scope("CoreSetHomeSnapshot"), "completedPages != nil", "downloadedBytes != nil")
state = scope("CoreSetFeatureState")
assert len(re.findall(r"CoreSetFeatureChannel\(capability:", state)) == 9
infra = function(state, "setInfrastructure")
need(infra, "guard capability.isInfrastructure", "infrastructure[capability] = availability")
assert not re.search(r"\.bind\(|\.receive\(|\.prepareApply\(|\.ready", infra)
assert len(re.findall(r"\.suspend\(\)", function(state, "suspendAll"))) == 9
print("PASS: seven-page state schemas, 149/177 candidate mapping, ranges/modes/inversions, unknown values, bound-consumer receipt gates and four negative controls; Swift not compiled/executed")
print("source_sha256=" + hashlib.sha256(path.read_bytes()).hexdigest())
