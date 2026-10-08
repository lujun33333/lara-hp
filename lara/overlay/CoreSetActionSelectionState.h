#pragma once

#include "CoreSetAimPlan.h"
#include "CoreSetTargetWriteContract.h"
#include <array>
#include <cmath>
#include <cstdint>

namespace CoreSet {

// These are Core-local record fields, NEVER target game-object offsets. The
// raw flag owner/knocked mapping still needs build15915 evidence at the caller.
struct ActionReferenceActorGate {
    uint32_t stateWord10 = 0;
    uint8_t flag14 = 0;
    uint8_t bot240 = 0;
    uint8_t bone58 = 0;
    float positiveScalar244 = 0;
    float distanceMeters = 0;
    int maximumDistanceMeters = 0;
    bool includeBots = false;
    bool excludeFlag14 = false;
};

// dd46c..dd4d8 valid-input gates; no guessed HealthStatus -> knocked conversion.
inline bool referenceActionActorEligible(const ActionReferenceActorGate &input) {
    if (!std::isfinite(input.positiveScalar244) || !std::isfinite(input.distanceMeters) ||
        input.distanceMeters < 0 || input.maximumDistanceMeters <= 0) return false;
    bool positive = (input.stateWord10 & 0x100000) == 0;
    if (positive && !(input.flag14 & 1)) positive = input.positiveScalar244 > 0;
    if (!positive || (!input.includeBots && (input.bot240 & 1)) ||
        (input.excludeFlag14 && (input.flag14 & 1)) ||
        input.distanceMeters > static_cast<float>(input.maximumDistanceMeters)) return false;
    return ((input.bone58 | input.flag14) & 1) != 0;
}

// dd4dc..dd59c: point=0 uses local record +1ec; 1/2 interpolate +1e0/+1ec.
// Their physical bone owners are NOT inferred from the UI names. The fallback
// is root Z+30 (0/1), root Z+25 (2), not the current HUD's head/feet estimates.
inline bool referenceActionWorldPoint(int point, uint8_t bone58, AimWorldPoint root,
                                     AimWorldPoint anchor1e0, AimWorldPoint anchor1ec,
                                     AimWorldPoint *out) {
    if (!out || point < 0 || point > 2) return false;
    const auto finite = [](AimWorldPoint value) {
        return std::isfinite(value.x) && std::isfinite(value.y) && std::isfinite(value.z);
    };
    AimWorldPoint value = root;
    if (bone58 == 0) {
        if (!finite(root)) return false;
        value.z += point == 2 ? 25.0f : 30.0f;
    } else {
        if (!finite(anchor1ec) || (point != 0 && !finite(anchor1e0))) return false;
        value = anchor1ec;
        if (point != 0) {
            const float weight = point == 1 ? 0.32f : 0.72f;
            value = {anchor1ec.x + (anchor1e0.x - anchor1ec.x) * weight,
                     anchor1ec.y + (anchor1e0.y - anchor1ec.y) * weight,
                     anchor1ec.z + (anchor1e0.z - anchor1ec.z) * weight};
        }
    }
    if (!finite(value)) return false;
    *out = value;
    return true;
}

struct ActionScreenRank {
    bool ordinaryUpdated = false;
    bool stickyMatched = false;
    float bestPixels = 0;
    static constexpr bool writeReady = false;
};

// dd5b8..dd6c0: ordinary boundary is <= radius (not <); equal scores retain
// the earlier ordinary candidate. Sticky candidate is tracked independently.
inline ActionScreenRank referenceActionScreenRank(float x, float y, float width, float height,
                                                  float radius, float bestPixels,
                                                  bool lockSameTarget, uint64_t previousKey,
                                                  uint64_t candidateKey) {
    ActionScreenRank result{false, false, bestPixels};
    if (!candidateKey || !std::isfinite(x) || !std::isfinite(y) || !std::isfinite(width) ||
        !std::isfinite(height) || !std::isfinite(radius) || !std::isfinite(bestPixels) ||
        width <= 0 || height <= 0 || radius <= 0 || bestPixels < 0 ||
        x <= 0 || x >= width || y <= 0 || y >= height) return result;
    const float dx = std::fma(width, 0.5f, -x);
    const float dy = std::fma(height, 0.5f, -y);
    const float pixels = std::sqrt(std::fma(dx, dx, dy * dy));
    result.stickyMatched = lockSameTarget && previousKey && previousKey == candidateKey &&
        pixels <= radius * 1.15f;
    result.ordinaryUpdated = pixels <= radius && pixels < bestPixels;
    if (result.ordinaryUpdated) result.bestPixels = pixels;
    return result;
}

struct ActionGeometryClockState {
    bool initialized = false;
    uint64_t targetKey = 0;
    uint64_t previousNanoseconds = 0;
    std::array<float, 2> residual{};
    bool residualPresent = false;
};
struct ActionGeometryClockObservation {
    bool firstOrReset = false;
    bool stepEligible = false;
    float deltaSeconds = 0;
    static constexpr bool writeReady = false;
};

// c5014..c50e0/c518c. The clock producer is clock_gettime_nsec_np(6).
// A reset is Core-local history only; it does not restore any prior target write.
inline ActionGeometryClockObservation referenceActionGeometryClock(ActionGeometryClockState &state,
                                                                   uint64_t key, uint64_t now) {
    ActionGeometryClockObservation result;
    if (!state.initialized || state.targetKey != key || !state.previousNanoseconds ||
        now <= state.previousNanoseconds) {
        state = {true, key, now, {}, false};
        result.firstOrReset = true;
        return result;
    }
    const uint64_t elapsed = now - state.previousNanoseconds;
    state.targetKey = key;
    state.previousNanoseconds = now;
    if (elapsed >= 50000001) {
        state.residual = {}; state.residualPresent = false;
        result.firstOrReset = true;
        return result;
    }
    result.deltaSeconds = static_cast<float>(static_cast<double>(elapsed) / 1000000000.0);
    result.stepEligible = true;
    return result;
}

struct ActionCandidateMotionState {
    bool initialized = false;
    uint64_t key = 0;
    uint64_t publicationGeneration = 0;
    double sampleSeconds = 0;
    AimWorldPoint target{};
    AimWorldPoint camera{};
    AimWorldPoint relativeVelocity{};
    bool velocityPresent = false;
    double velocitySeconds = 0;
    static constexpr bool writeReady = false;
};

// Full c494c valid-finite-input state/expiry path. Positions come from the
// Core-local publication's target/camera XYZ, not guessed game-object fields.
// Changed publication estimates relative velocity; unchanged generation never
// invents a new sample. Angular-motion projection c642c is a separate helper.
inline bool referenceActionCandidateMotion(ActionCandidateMotionState &state, uint64_t key,
                                           uint64_t publicationGeneration, double now,
                                           AimWorldPoint target, AimWorldPoint camera) {
    const auto finite = [](AimWorldPoint value) {
        return std::isfinite(value.x) && std::isfinite(value.y) && std::isfinite(value.z);
    };
    if (!key || !publicationGeneration || !std::isfinite(now) || now < 0 ||
        !finite(target) || !finite(camera) || !std::isfinite(state.sampleSeconds) ||
        !std::isfinite(state.velocitySeconds)) return false;
    if (!state.initialized || state.key != key) {
        state = {true, key, publicationGeneration, now, target, camera, {}, false, now};
        return true;
    }
    if (state.publicationGeneration == publicationGeneration) {
        if (state.velocityPresent && now - state.velocitySeconds > 0.3) state.velocityPresent = false;
        return true;
    }
    const double elapsed = now - state.sampleSeconds;
    state.publicationGeneration = publicationGeneration;
    state.sampleSeconds = now;
    if (elapsed > 0 && elapsed <= 0.3) {
        const float inverse = static_cast<float>(1.0 / elapsed);
        state.relativeVelocity = {
            ((target.x - state.target.x) - (camera.x - state.camera.x)) * inverse,
            ((target.y - state.target.y) - (camera.y - state.camera.y)) * inverse,
            ((target.z - state.target.z) - (camera.z - state.camera.z)) * inverse};
        state.velocityPresent = finite(state.relativeVelocity);
    } else {
        state.relativeVelocity = {}; state.velocityPresent = false;
    }
    state.velocitySeconds = now;
    state.target = target; state.camera = camera;
    return true;
}

// Exhaustive DIRECT incoming edges into c2e24 in the authenticated worker
// candidate range: c2e20 fallthrough, c3918 branch, c3990 branch. This resolves
// that join only, NOT which upstream path a live candidate is permitted to take.
enum class ActionMergePredecessor : uint8_t { controlFallthrough, inputDirect, inputPaused };
struct ActionMergeRouteObservation {
    TargetActionSlot slot = TargetActionSlot::controlRotation;
    uint32_t nativeW19 = 0;
    static constexpr bool writeReady = false;
    static constexpr bool authorizesUpstreamPath = false;
};
inline bool referenceActionMergeRoute(ActionMergePredecessor predecessor,
                                      ActionMergeRouteObservation *out) {
    if (!out || static_cast<uint8_t>(predecessor) > 2) return false;
    const bool input = predecessor != ActionMergePredecessor::controlFallthrough;
    *out = {input ? TargetActionSlot::rotationInput : TargetActionSlot::controlRotation,
            input ? 1u : 0u};
    return true;
}

struct ActionTakeoverState {
    uint32_t confirmationCount = 0;
    double pauseDeadline = 0;
};
struct ActionTakeoverObservation {
    bool aimAllowed = true;
    bool zeroAimFirst = false;
    bool zeroAimSecond = false;
    ActionMergePredecessor mergePredecessor = ActionMergePredecessor::inputDirect;
    static constexpr bool writeReady = false;
};

// c3018/c38c8..c3990: forceInput covers zero/exact prior RotationInput, inactive
// aim or the separately computed native tiny-input gate. Threshold-confirmed
// input pauses Aim components; it does NOT erase player input or stop Recoil.
// This is a Core-local policy transition, never a target restoration receipt.
inline bool referenceActionTakeover(ActionTakeoverState &state, bool currentAimActive, bool forceInput,
                                    float inputMagnitude, float threshold, int frames,
                                    int pauseMilliseconds, double now,
                                    ActionTakeoverObservation *out) {
    if (!out || !std::isfinite(inputMagnitude) || inputMagnitude < 0 ||
        !std::isfinite(threshold) || threshold <= 0 || frames < 1 || frames > 6 ||
        pauseMilliseconds < 50 || pauseMilliseconds > 1000 || !std::isfinite(now) ||
        now < 0 || !std::isfinite(state.pauseDeadline)) return false;
    ActionTakeoverObservation result;
    result.aimAllowed = currentAimActive;
    if (!currentAimActive || forceInput || inputMagnitude < threshold) {
        state.confirmationCount = 0;
        if (currentAimActive && now < state.pauseDeadline) {
            result = {false, true, true, ActionMergePredecessor::inputPaused};
        }
    } else {
        ++state.confirmationCount;
        if (static_cast<int32_t>(state.confirmationCount) >= frames)
            state.pauseDeadline = now + static_cast<double>(pauseMilliseconds) / 1000.0;
        result = {false, true, true, ActionMergePredecessor::inputPaused};
    }
    *out = result;
    return true;
}

} // namespace CoreSet
