#pragma once

#include "CoreSetTargetWriteContract.h"
#include "CoreSetActionSelectionState.h"
#include "CoreSetCheckedWriteStatus.h"
#include <cstdint>

namespace CoreSet {

enum class RouteResultGate : uint8_t {
    exactOne, // Core c3150: result+1 must equal 1.
    lowBit    // Core c3698: result+1 bit 0 must be set.
};

// Core c5ad8 classifies the checked-write helper's raw w0 before publishing
// result byte +1: raw 1 -> class 0, raw 2 -> class 1, every other raw value
// (including verify mismatch 5) -> class 2.
inline constexpr uint8_t referenceC5AD8ResultByte(uint32_t rawStatus) {
    return rawStatus == 1 ? 0 : (rawStatus == 2 ? 1 : 2);
}

inline constexpr uint8_t referenceC5AD8PackedResultByte(uint64_t packedStatus) {
    return referenceC5AD8ResultByte(checkedWriteRawStatus(packedStatus));
}

enum class RouteLifecycleEvent : uint8_t {
    none = 0,
    restoreConfigID27 = 1,
    sceneDerivedClear = 2,
    resetWithCount = 3,
    resetWithoutCount = 4,
};

// Core's c1d04/c1d98/c1f90/c3714/c3754/c3838 route globals. The state must be
// advanced from the real sink result; firing is not route authority.
struct ActionRouteState {
    bool modeFlag = false;       // 0x100bd9750
    bool alternate = false;      // 0x100bd9778 bit 0
    bool priorConfig = false;    // 0x100bd99f0, normalized C+0x164
    uint32_t resultGateCount = 0;// 0x100bd9774; not a successful-write count.

    // c1d04..c1d10 clears alternate, flag and count.
    void resetWithCount() {
        alternate = false;
        modeFlag = false;
        resultGateCount = 0;
    }

    // c1d90..c1d9c clears alternate and flag, but not this count.
    void resetWithoutCount() {
        alternate = false;
        modeFlag = false;
    }

    // c1f88..c1fbc: alternate mode skips this comparison entirely.
    void observeConfig(bool normalizedC164) {
        if (alternate || priorConfig == normalizedC164) return;
        priorConfig = normalizedC164;
        modeFlag = normalizedC164;
        resultGateCount = 0;
    }

    // The caller must supply c5ad8's actual classified byte1 and the worker's
    // resolved w20. byte1 is not a success BOOL: raw status other than 1/2
    // (including readback mismatch 5) belongs to class2. No fire/menu inference.
    void observeResult(uint8_t resultByte1, RouteResultGate gate, bool w20) {
        if (!w20) return;
        const bool advance = gate == RouteResultGate::exactOne
            ? resultByte1 == 1 : (resultByte1 & 1) != 0;
        if (!advance) {
            resultGateCount = 0;
            return;
        }
        const uint32_t oldCount = resultGateCount;
        ++resultGateCount; // ARM add w9 wraps modulo 2^32.
        // c3730/c3838 use signed b.lt after cmp, including wrapped values.
        const int32_t signedOldCount = static_cast<int32_t>(oldCount);
        if (signedOldCount >= 59 && !modeFlag) {
            modeFlag = true;
            resultGateCount = 0;
        } else if (signedOldCount >= 119 && modeFlag) {
            alternate = true;
        }
    }
};

// c2e14 selects slot 65 only for the established control-route state.
// c3914/c3988 select slot 66 for every other reachable write-tail path.
inline TargetActionSlot referenceActionSlotForRouteState(
    const ActionRouteState &state, bool recoilEnabled) {
    return !state.alternate && state.modeFlag && recoilEnabled
        ? TargetActionSlot::controlRotation
        : TargetActionSlot::rotationInput;
}

// These must come from the original upstream/c5ad8 observation. Neither a
// firing bit nor a local writer's committed BOOL supplies native w20/byte1.
struct NativeActionRouteInput {
    bool present = false;
    uint64_t cycle = 0;
    bool currentAimActive = false;
    bool forceInput = false;
    bool recoilEnabled = false;
    bool w20 = false;
    RouteResultGate resultGate = RouteResultGate::exactOne;
    RouteLifecycleEvent lifecycle = RouteLifecycleEvent::none;
    int32_t configID27Value = 0;
};
struct NativeActionRouteFeedback {
    bool present = false;
    uint64_t cycle = 0;
    uint64_t packedStatus = 0;
    bool w20 = false;
    RouteResultGate resultGate = RouteResultGate::exactOne;
};

struct NativeActionRouteDecision {
    bool resolved = false;
    ActionTakeoverObservation takeover{};
    TargetActionSlot slot = TargetActionSlot::rotationInput;
    uint64_t cycle = 0;
    bool w20 = false;
    RouteResultGate resultGate = RouteResultGate::exactOne;
    static constexpr bool writeReady = false;
};

class NativeActionRouteProducer {
public:
    void reset() { *this = {}; }

    void restoreConfigurationID27(int32_t rawValue) {
        route_.observeConfig(rawValue > 0);
        lifecycleObserved_ = true;
    }
    void deriveSceneConfiguration() {
        route_.observeConfig(false);
        lifecycleObserved_ = true;
    }
    void resetRouteWithCount() {
        route_.resetWithCount();
        lifecycleObserved_ = true;
    }
    void resetRouteWithoutCount() {
        route_.resetWithoutCount();
        lifecycleObserved_ = true;
    }

    bool resolve(const NativeActionRouteInput &native, float magnitude,
                 float threshold, int frames, int pauseMilliseconds, double now,
                 NativeActionRouteDecision *out) {
        if (out) *out = {};
        if (!out || !accepts(native) || !applyLifecycle(native) ||
            !std::isfinite(magnitude) || magnitude < 0 ||
            !std::isfinite(threshold) || threshold <= 0 || frames < 1 || frames > 6 ||
            pauseMilliseconds < 50 || pauseMilliseconds > 1000 ||
            !std::isfinite(now) || now < 0) return false;
        NativeActionRouteDecision decision;
        decision.slot = referenceActionSlotForRouteState(route_, native.recoilEnabled);
        if (decision.slot == TargetActionSlot::controlRotation) {
            decision.takeover.aimAllowed = native.currentAimActive;
            decision.takeover.mergePredecessor = ActionMergePredecessor::controlFallthrough;
        } else if (!referenceActionTakeover(takeover_, native.currentAimActive,
            native.forceInput, magnitude, threshold, frames, pauseMilliseconds,
            now, &decision.takeover)) return false;
        publish(native, decision, out);
        return true;
    }

    bool resolveInactive(const NativeActionRouteInput &native, NativeActionRouteDecision *out) {
        if (out) *out = {};
        if (!out || !accepts(native) || !applyLifecycle(native) ||
            native.currentAimActive) return false;
        NativeActionRouteDecision decision;
        takeover_.confirmationCount = 0;
        decision.takeover.aimAllowed = false;
        decision.slot = referenceActionSlotForRouteState(route_, native.recoilEnabled);
        decision.takeover.mergePredecessor = decision.slot == TargetActionSlot::controlRotation
            ? ActionMergePredecessor::controlFallthrough : ActionMergePredecessor::inputDirect;
        publish(native, decision, out);
        return true;
    }

    bool observeNativeFeedback(const NativeActionRouteFeedback &native) {
        if (!native.present || !feedbackPending_ || native.cycle != lastCycle_ ||
            native.w20 != expectedW20_ || native.resultGate != expectedResultGate_)
            return false;
        route_.observeResult(referenceC5AD8PackedResultByte(native.packedStatus),
                             native.resultGate, native.w20);
        feedbackPending_ = false;
        return true;
    }

    const ActionRouteState &state() const { return route_; }

private:
    bool accepts(const NativeActionRouteInput &native) const {
        return native.present && native.cycle &&
            native.cycle > lastCycle_ && !feedbackPending_ &&
            static_cast<uint8_t>(native.resultGate) <= 1 &&
            static_cast<uint8_t>(native.lifecycle) <=
                static_cast<uint8_t>(RouteLifecycleEvent::resetWithoutCount);
    }
    bool applyLifecycle(const NativeActionRouteInput &native) {
        switch (native.lifecycle) {
        case RouteLifecycleEvent::none: break;
        case RouteLifecycleEvent::restoreConfigID27:
            restoreConfigurationID27(native.configID27Value); break;
        case RouteLifecycleEvent::sceneDerivedClear:
            deriveSceneConfiguration(); break;
        case RouteLifecycleEvent::resetWithCount:
            resetRouteWithCount(); break;
        case RouteLifecycleEvent::resetWithoutCount:
            resetRouteWithoutCount(); break;
        default: return false;
        }
        return lifecycleObserved_;
    }
    void publish(const NativeActionRouteInput &native, NativeActionRouteDecision decision,
                 NativeActionRouteDecision *out) {
        decision.resolved = true;
        decision.cycle = native.cycle;
        decision.w20 = native.w20;
        decision.resultGate = native.resultGate;
        lastCycle_ = native.cycle;
        expectedW20_ = native.w20;
        expectedResultGate_ = native.resultGate;
        feedbackPending_ = true;
        *out = decision;
    }
    ActionRouteState route_{};
    ActionTakeoverState takeover_{};
    bool lifecycleObserved_ = false;
    bool feedbackPending_ = false;
    uint64_t lastCycle_ = 0;
    bool expectedW20_ = false;
    RouteResultGate expectedResultGate_ = RouteResultGate::exactOne;
};

} // namespace CoreSet
