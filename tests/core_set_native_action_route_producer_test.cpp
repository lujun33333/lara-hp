#include "../lara/overlay/CoreSetActionRouteState.h"
#include <cassert>
#include <cstdio>
#include <limits>

using namespace CoreSet;

int main() {
    static_assert(!NativeActionRouteDecision::writeReady);
    ActionRouteState wrap;
    wrap.resultGateCount = UINT32_MAX;
    wrap.observeResult(1, RouteResultGate::exactOne, true);
    assert(wrap.resultGateCount == 0 && !wrap.modeFlag && !wrap.alternate);
    wrap.resultGateCount = 0x80000000;
    wrap.observeResult(1, RouteResultGate::exactOne, true);
    assert(wrap.resultGateCount == 0x80000001 && !wrap.modeFlag);
    NativeActionRouteProducer producer;
    NativeActionRouteInput native;
    NativeActionRouteDecision decision;
    static_assert(referenceC5AD8ResultByte(1) == 0);
    static_assert(referenceC5AD8ResultByte(2) == 1);
    static_assert(referenceC5AD8ResultByte(5) == 2);
    assert(!producer.resolve(native, 0, 0.05f, 2, 300, 1, &decision));
    producer.restoreConfigurationID27(1);
    assert(!producer.resolve(native, 0, 0.05f, 2, 300, 1, &decision));
    assert(!decision.resolved); // No original upstream provider: neither slot is authorized.

    // Offline native-record fixtures only. They do not become a live provider.
    native = {true, 1, true, false, true, true, RouteResultGate::exactOne,
              RouteLifecycleEvent::sceneDerivedClear, 0};
    assert(!producer.resolve(native, std::numeric_limits<float>::quiet_NaN(),
                             0.05f, 2, 300, 1, &decision));
    assert(producer.resolve(native, 0, 0.05f, 2, 300, 1, &decision));
    assert(decision.slot == TargetActionSlot::rotationInput);
    native.cycle = 2;
    assert(!producer.resolve(native, 0, 0.05f, 2, 300, 2, &decision));
    assert(!producer.observeNativeFeedback({false, 1, 2, true, RouteResultGate::exactOne}));
    assert(!producer.observeNativeFeedback({true, 2, 2, true, RouteResultGate::exactOne}));
    assert(!producer.observeNativeFeedback({true, 1, 2, false, RouteResultGate::exactOne}));
    assert(!producer.observeNativeFeedback({true, 1, 2, true, RouteResultGate::lowBit}));
    assert(producer.observeNativeFeedback({true, 1, 2, true, RouteResultGate::exactOne}));
    assert(!producer.observeNativeFeedback({true, 1, 2, true, RouteResultGate::exactOne}));
    assert(producer.state().resultGateCount == 1);

    for (uint64_t cycle = 2; cycle <= 60; ++cycle) {
        native.cycle = cycle;
        assert(producer.resolve(native, 0, 0.05f, 2, 300, double(cycle), &decision));
        assert(producer.observeNativeFeedback({true, cycle, 2, true, RouteResultGate::exactOne}));
    }
    assert(producer.state().modeFlag && !producer.state().alternate);
    assert(producer.state().resultGateCount == 0);
    native.cycle = 61;
    assert(producer.resolve(native, 0, 0.05f, 2, 300, 61, &decision));
    assert(decision.slot == TargetActionSlot::controlRotation);
    assert(decision.takeover.mergePredecessor == ActionMergePredecessor::controlFallthrough);
    assert(producer.observeNativeFeedback({true, 61, 2, true, RouteResultGate::exactOne}));
    for (uint64_t cycle = 62; cycle <= 180; ++cycle) {
        native.cycle = cycle;
        assert(producer.resolve(native, 0, 0.05f, 2, 300, double(cycle), &decision));
        assert(producer.observeNativeFeedback({true, cycle, 2, true, RouteResultGate::exactOne}));
    }
    assert(producer.state().alternate);
    native.cycle = 181;
    assert(producer.resolve(native, 0, 0.05f, 2, 300, 181, &decision));
    assert(decision.slot == TargetActionSlot::rotationInput);
    assert(producer.observeNativeFeedback({true, 181, 5, true, RouteResultGate::exactOne}));
    assert(producer.state().resultGateCount == 0); // Exact-one must reject byte2.

    producer.reset(); producer.deriveSceneConfiguration();
    native = {true, 1, false, true, true, false, RouteResultGate::lowBit};
    assert(producer.resolveInactive(native, &decision));
    assert(!decision.takeover.aimAllowed && decision.slot == TargetActionSlot::rotationInput);
    assert(producer.observeNativeFeedback({true, 1, 2, false, RouteResultGate::lowBit}));
    assert(producer.state().resultGateCount == 0); // No native w20: no advance.
    native.cycle = 2; native.w20 = true;
    assert(producer.resolveInactive(native, &decision));
    assert(producer.observeNativeFeedback({true, 2, 2, true, RouteResultGate::lowBit}));
    assert(producer.state().resultGateCount == 1); // Low-bit accepts byte3.
    producer.reset();
    assert(!producer.observeNativeFeedback({true, 2, 2, true, RouteResultGate::lowBit}));
    assert(!producer.resolveInactive(native, &decision));
    std::puts("PASS: Core derived C164, original raw feedback gates, 60/120 route transitions, missing/stale rejection; no live authority");
}
