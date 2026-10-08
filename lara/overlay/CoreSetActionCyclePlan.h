#pragma once

#include "CoreSetAimDeltaPlan.h"
#include "CoreSetAimPreselection.h"
#include "CoreSetTargetWriteContract.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>

namespace CoreSet {

// Exact valid-input c22a0..c2318 semantics, not a writer or live input lease.
// Failed reads/identity loss must reset at the caller rather than preserving an
// old deadline. Core's global deadline alone is not a same-cycle authority.
struct ActionTriggerObservation {
    bool ads = false;
    bool firing = false;
    bool matchedNow = false;
    bool aimActive = false;
    double deadlineSeconds = 0;
    static constexpr bool writeReady = false;
};

class ActionTriggerLatch {
public:
    bool observe(bool enabled, AimTrigger mode, uint8_t rawADS, uint8_t rawFire,
                 double monotonicSeconds, ActionTriggerObservation *out) {
        if (!out || !std::isfinite(monotonicSeconds) || monotonicSeconds < 0 ||
            (hasTime_ && monotonicSeconds < lastTime_) || static_cast<uint8_t>(mode) > 3) {
            reset();
            if (out) *out = {};
            return false;
        }
        const bool ads = (rawADS & 1) != 0;
        const bool fire = (rawFire & 1) != 0;
        const bool matched = enabled && aimTriggerActive(mode, ads, fire);
        if (!enabled) deadline_ = 0;
        else if (matched) deadline_ = monotonicSeconds + 0.25;
        if (!std::isfinite(deadline_)) { reset(); *out = {}; return false; }
        lastTime_ = monotonicSeconds;
        hasTime_ = true;
        *out = {ads, fire, matched, enabled && monotonicSeconds < deadline_, deadline_};
        return true;
    }

    // Diagnostic/planner reset only. This never restores target memory/input.
    void reset() { deadline_ = 0; lastTime_ = 0; hasTime_ = false; }

private:
    double deadline_ = 0;
    double lastTime_ = 0;
    bool hasTime_ = false;
};

struct ActionCustomSceneInput {
    bool allNinePresent = false; // Missing configuration is not an implicit zero.
    int strength = 0;
    int smoothing = 0;
    int maximumDistance = 0;
    int horizontalSpeed = 0;
    int verticalSpeed = 0;
    int predictionMilliseconds = 0;
    int lockThreshold = 0;
    int confirmationFrames = 0;
    int pauseMilliseconds = 0;
};

struct ActionScenePlan {
    int storedScene = 0;
    int normalizedLockStrength = 0;
    AimSceneValues scene{};
    AimLockValues lock{};
    AimWorkerTuning tuning{};
    static constexpr bool writeReady = false;
};

// c1664 table/custom bounds + c4854 lock table/custom bounds. Only the
// established six scene values and three lock values are named here. The
// remaining four native table columns retain opaque semantics in the probe.
inline bool planActionScene(int storedScene, int storedLockStrength,
                            const ActionCustomSceneInput &custom,
                            ActionScenePlan *out) {
    if (!out || storedScene < 0 || storedScene > 3) return false;
    ActionScenePlan result;
    result.storedScene = storedScene;
    if (storedScene == 3) {
        if (!custom.allNinePresent) return false;
        result.scene = {std::clamp(custom.strength, 5, 100),
                        std::clamp(custom.smoothing, 1, 10),
                        std::clamp(custom.maximumDistance, 10, 500),
                        std::clamp(custom.horizontalSpeed, 30, 720),
                        std::clamp(custom.verticalSpeed, 30, 720),
                        std::clamp(custom.predictionMilliseconds, 0, 300)};
        result.lock = {std::clamp(custom.lockThreshold, 5, 500),
                       std::clamp(custom.confirmationFrames, 1, 6),
                       std::clamp(custom.pauseMilliseconds, 50, 1000)};
        // Native custom mode does not rewrite C+184. It is not an active
        // noncustom lock-strength selector and remains an opaque preserved int.
        result.normalizedLockStrength = storedLockStrength;
    } else {
        if (!aimSceneValues(storedScene, &result.scene) ||
            !aimLockValues(storedLockStrength, &result.lock)) return false;
        constexpr int mapping[5] = {0, 0, 3, 3, 4};
        result.normalizedLockStrength = mapping[storedLockStrength];
    }
    if (!aimWorkerTuning(result.scene, result.lock, &result.tuning)) return false;
    *out = result;
    return true;
}

// SSA: c1a80 loads w28 from vertical-enabled C+1bc; c3278/c32a8..c32b0
// computes (w28 & 1) & stored-C18d. It is NOT the raw firing bit at sp+40.
// This feeds c416c's local post-state policy, not an immediate no-fire writer
// cancellation/zeroing rule or an action-stop receipt.
inline bool actionPostStateContinueFlag(uint32_t verticalEnabledW28,
                                        uint8_t storedContinueWhenNotFiring) {
    return ((verticalEnabledW28 & 1) & storedContinueWhenNotFiring) != 0;
}

inline float actionRecoilStrength01(int rawPercent) {
    return std::clamp(static_cast<float>(rawPercent) / 100.0f, 0.0f, 1.0f);
}

struct ActionWriteDraft {
    TargetActionSlot resolvedSlot = TargetActionSlot::controlRotation;
    TargetActionAxis axis = TargetActionAxis::both;
    uint64_t relativeOffset = 0;
    size_t length = 0;
    std::array<uint8_t, 8> expectedOld{};
    std::array<uint8_t, 8> newValue{};
    bool noWrite = true;
    static constexpr bool writeReady = false;
    static constexpr bool selectsWriteSlot = false;
    static constexpr bool restoresTargetState = false;
};

// c5ad8/c6730 payload preparation only. The caller must independently resolve
// the full c2e24 predecessor and supply the actual slot; fire=false does NOT
// select ControlRotation. Every draft still needs fresh expected-old, trusted
// request/snapshot authority, exact profile, checked write and independent
// same-cycle readback. A two-zero draft means no write, never target restored.
inline bool planActionWriteDraft(TargetActionSlot resolvedSlot,
                                 float oldPitch, float oldYaw,
                                 const AimDeltaPlan &delta,
                                 ActionWriteDraft *out) {
    if (!out || !std::isfinite(oldPitch) || !std::isfinite(oldYaw) ||
        !std::isfinite(delta.pitch) || !std::isfinite(delta.yaw) ||
        (resolvedSlot != TargetActionSlot::controlRotation &&
         resolvedSlot != TargetActionSlot::rotationInput)) return false;
    const bool pitch = delta.pitch != 0;
    const bool yaw = delta.yaw != 0;
    const ActionDeltaShape actualShape = pitch && yaw ? ActionDeltaShape::both :
        (pitch ? ActionDeltaShape::pitchOnly : yaw ? ActionDeltaShape::yawOnly : ActionDeltaShape::none);
    if (delta.shape != actualShape) return false;
    ActionWriteDraft result;
    result.resolvedSlot = resolvedSlot;
    if (!pitch && !yaw) { *out = result; return true; }
    result.axis = pitch && yaw ? TargetActionAxis::both :
        (pitch ? TargetActionAxis::first : TargetActionAxis::second);
    if (!ControlRotationWriteGate::shape(resolvedSlot, result.axis,
                                          &result.relativeOffset, &result.length)) return false;
    const float newPitch = oldPitch + delta.pitch;
    const float newYaw = oldYaw + delta.yaw;
    if (!std::isfinite(newPitch) || !std::isfinite(newYaw)) return false;
    const float oldValues[2] = {oldPitch, oldYaw};
    const float newValues[2] = {newPitch, newYaw};
    const size_t firstAxis = result.axis == TargetActionAxis::second ? 1 : 0;
    std::memcpy(result.expectedOld.data(), oldValues + firstAxis, result.length);
    std::memcpy(result.newValue.data(), newValues + firstAxis, result.length);
    result.noWrite = false;
    *out = result;
    return true;
}

} // namespace CoreSet
