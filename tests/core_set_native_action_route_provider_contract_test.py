from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
read = lambda path: (ROOT / path).read_text(encoding="utf-8")
probe = read("lara/overlay/CoreSetIsolatedWriteProbe.mm")
header = read("lara/overlay/CoreSetIsolatedWriteProbe.h")
aim = read("lara/views/app/CoreSetAimConsumer.swift")
state = read("lara/overlay/CoreSetActionRouteState.h")

assert "CoreSet::NativeActionRouteProducer _producer" in probe
assert "- (BOOL)originalProviderBound { return NO; }" in probe
assert "guard routeProducer.originalProviderBound else" in aim
assert "return .unavailable(reason: routeProducer.unresolvedReason)" in aim
assert "guard let route, route.resolved else" in aim
assert "resolveRecoilOnly(nativeInput: nil)" in aim
assert "now: input.captureCompletedMonotonicSeconds, nativeInput: nil" in aim
assert "referenceActionTakeover(_takeover, true, false" not in probe
producer = probe[probe.index("@implementation CoreSetV17ActionRouteProducer"):probe.index("@interface CoreSetV17ActionDelta")]
assert "observation.mergePredecessor = CoreSet::ActionMergePredecessor::inputDirect" not in producer
assert "observeNativeFeedback" in header and "feedback->packedStatus" in producer
assert "feedback->w20" in producer and "source->forceInput" in producer
assert "source->lifecycle" in producer and "referenceC5AD8ResultByte" in state
assert "restoreConfigurationID27" in state and "route_.observeConfig(false)" in state
assert "referenceActionSlotForRouteState(route_, native.recoilEnabled)" in state
assert "observeNativeFeedback" not in aim  # No committed BOOL -> native byte1 synthesis.
print("PASS: production rejects missing original route provider; ID27/scene/reset lifecycle and packed-status classification stay explicit")
