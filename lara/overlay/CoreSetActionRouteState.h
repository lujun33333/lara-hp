#pragma once

#include "CoreSetTargetWriteContract.h"
#include <cstdint>

namespace CoreSet {

// Worker c2fbc reloads the same-cycle firing byte into w19; c2ef4..c2f24
// selects template 65 (ControlRotation) for zero and template 66
// (RotationInput) for nonzero. This is the slot selector, unlike the local
// c1d04/c3714 route-history bookkeeping below.
inline TargetActionSlot referenceActionSlotForFireSample(uint8_t rawFire) {
    return (rawFire & 1) != 0
        ? TargetActionSlot::rotationInput : TargetActionSlot::controlRotation;
}

enum class RouteResultGate : uint8_t {
    exactOne, // Core c3150: result+1 must equal 1.
    lowBit    // Core c3698: result+1 bit 0 must be set.
};

// Only Core's c1d04/c1d98/c1f90/c3714/c3754/c3838 globals. The worker's
// w19 selection and +620/+828 write permission are deliberately outside it.
struct ActionRouteState {
    bool modeFlag = false;       // 0x100bd9750
    bool alternate = false;      // 0x100bd9778 bit 0
    bool priorConfig = false;    // 0x100bd99f0, normalized C+0x164
    uint32_t resultGateCount = 0;// 0x100bd9774; not a successful-write count.
    static constexpr bool selectsWriteSlot = false;

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

    // The caller must supply the actual sink-result byte and the worker's
    // already resolved w20; this function does not infer them from fire/menu.
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
        if (oldCount >= 59 && !modeFlag) {
            modeFlag = true;
            resultGateCount = 0;
        } else if (oldCount >= 119 && modeFlag) {
            alternate = true;
        }
    }
};

} // namespace CoreSet
