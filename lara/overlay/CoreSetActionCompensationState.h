#pragma once

#include "CoreSetActionSelectionState.h"
#include "CoreSetRecoilStateMachine.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <limits>

namespace CoreSet {

// All fields below represent Core-self numerical records. No target owner,
// profile, controller lifetime, writer permission or restore receipt is implied.
inline float referenceActionSmoothstep(float value) {
    const float t = std::clamp(value, 0.0f, 1.0f);
    return (t * t) * std::fma(t, -2.0f, 3.0f);
}

// Full c6304: piecewise distance scaling, with two independent cubic segments.
inline float referenceActionPredictionGain(float distance) {
    if (!std::isfinite(distance) || distance <= 12.0f) return 0.3f;
    if (distance < 30.0f)
        return std::fma(referenceActionSmoothstep((distance - 12.0f) / 18.0f), 0.42000001668930054f, 0.3f);
    if (distance >= 45.0f) return 1.0f;
    return std::fma(referenceActionSmoothstep((distance - 30.0f) / 15.0f), 0.2799999713897705f, 0.72f);
}

struct ActionAngularMotion {
    float first = 0;
    float second = 0;
    static constexpr bool writeReady = false;
};

// c642c is displacement/relative-velocity -> angular derivatives in degrees.
// It contains no projectile speed or gravity operand; do not label it ballistic.
inline bool referenceActionAngularMotion(std::array<float, 3> displacement,
                                         std::array<float, 3> velocity,
                                         ActionAngularMotion *out) {
    if (!out) return false;
    *out = {};
    for (float value : displacement) if (!std::isfinite(value)) return false;
    for (float value : velocity) if (!std::isfinite(value)) return false;
    const float x = displacement[0], y = displacement[1], z = displacement[2];
    const float horizontal = std::hypot(x, y);
    const float squaredHorizontal = std::fma(x, x, y * y);
    const float squaredDistance = std::fma(z, z, squaredHorizontal);
    if (!std::isfinite(horizontal) || horizontal < 0.001f || squaredDistance < 0.000001f) return false;
    const float cross = std::fma(x, velocity[1], -(y * velocity[0]));
    const float first = (cross / squaredHorizontal) * 57.295780181884766f;
    const float negativeDot = -std::fma(x, velocity[0], y * velocity[1]);
    const float projected = (negativeDot / horizontal) * z;
    const float second = (std::fma(horizontal, velocity[2], projected) / squaredDistance) * 57.295780181884766f;
    if (!std::isfinite(first) || !std::isfinite(second)) return false;
    *out = {first, second};
    return true;
}

struct ActionResidualState {
    std::array<float, 2> angular{};
    bool present = false;
};
struct ActionResidualObservation {
    bool eligible = false;
    bool residualPresent = false;
    std::array<float, 2> angular{};
    static constexpr bool writeReady = false;
};

// c5134..c5244 after the independently proved <=50ms geometry-clock gate.
// No reset here can resolve a prior target-memory effect.
inline bool referenceActionResidual(ActionResidualState &state, float dt,
                                    bool measured, ActionAngularMotion motion,
                                    std::array<float, 2> maximumSpeed,
                                    float absoluteFirstError, float deadzone,
                                    ActionResidualObservation *out) {
    if (!out || !std::isfinite(dt) || dt <= 0 || dt > 0.05f ||
        !std::isfinite(absoluteFirstError) || absoluteFirstError < 0 ||
        !std::isfinite(deadzone) || deadzone < 0) return false;
    for (float value : state.angular) if (!std::isfinite(value)) return false;
    for (float value : maximumSpeed) if (!std::isfinite(value) || value <= 0) return false;
    if (measured && (!std::isfinite(motion.first) || !std::isfinite(motion.second))) return false;
    const float alpha = 1.0f - std::exp(-dt / 0.05f);
    bool present = state.present;
    if (measured) {
        std::array<float, 2> current{std::clamp(motion.first, -maximumSpeed[0], maximumSpeed[0]),
                                    std::clamp(motion.second, -maximumSpeed[1], maximumSpeed[1])};
        if (present) for (unsigned axis = 0; axis < 2; ++axis)
            current[axis] = std::fma(current[axis] - state.angular[axis], alpha, state.angular[axis]);
        state.angular = current; state.present = true; present = true;
    } else if (present) {
        for (float &value : state.angular) value = std::fma(-value, alpha, value);
        if (std::fabs(state.angular[0]) <= 0.05f && std::fabs(state.angular[1]) <= 0.05f) {
            state.angular = {}; state.present = false; present = false;
        }
    }
    *out = {absoluteFirstError > deadzone || present, present, state.angular};
    return true;
}

struct ActionCompensationTuning {
    float strength = 0;
    float smoothingSeconds = 0;
    float curveSelector = 0;
    std::array<float, 2> maximumSpeed{};
    float residualGain = 0;
    float minimumGain = 0;
};
struct ActionCompensationDelta {
    std::array<float, 2> delta{};
    std::array<float, 2> residualContribution{};
    std::array<bool, 2> saturated{};
    static constexpr bool writeReady = false;
};

// c5244..c5490 given proved finite error/dt/residual inputs. libm exp is the
// only transcendental here; the test records its synthetic import substitution.
inline bool referenceActionCompensation(std::array<float, 2> error, float dt,
                                        ActionResidualObservation residual,
                                        const ActionCompensationTuning &tuning,
                                        ActionCompensationDelta *out) {
    if (!out || !std::isfinite(dt) || dt <= 0 || dt > 0.05f ||
        !std::isfinite(tuning.strength) || tuning.strength <= 0 || tuning.strength > 1 ||
        !std::isfinite(tuning.smoothingSeconds) || tuning.smoothingSeconds <= 0 ||
        !std::isfinite(tuning.curveSelector) || tuning.curveSelector < 0 ||
        !std::isfinite(tuning.residualGain) || tuning.residualGain < 0 || tuning.residualGain > 1 ||
        !std::isfinite(tuning.minimumGain) || tuning.minimumGain <= 0 || tuning.minimumGain > 1) return false;
    for (float value : error) if (!std::isfinite(value)) return false;
    for (float value : residual.angular) if (!std::isfinite(value)) return false;
    for (float value : tuning.maximumSpeed) if (!std::isfinite(value) || value < 30 || value > 720) return false;
    const float absolute = std::fabs(error[0]);
    const float errorCurve = absolute <= 0.08f ? 0.0f : absolute >= 1.5f ? 1.0f :
        referenceActionSmoothstep((absolute - 0.08f) / 1.42f);
    float selectorMultiplier = 1.0f;
    if (tuning.curveSelector > 0.55f) selectorMultiplier = tuning.curveSelector >= 1.0f ? 0.18f :
        std::fma(referenceActionSmoothstep((tuning.curveSelector - 0.55f) / 0.45f), -0.82f, 1.0f);
    const float gain = std::fmax(tuning.minimumGain, errorCurve) * selectorMultiplier;
    const float smoothing = 1.0f - std::exp(-dt / tuning.smoothingSeconds);
    const float residualMultiplier = selectorMultiplier * tuning.residualGain;
    ActionCompensationDelta result;
    for (unsigned axis = 0; axis < 2; ++axis) {
        const float base = ((error[axis] * tuning.strength) * gain) * smoothing;
        const float pending = residual.residualPresent ? (residual.angular[axis] * dt) * residualMultiplier : 0.0f;
        const float remaining = error[axis] - base;
        const float addition = pending * remaining > 0 ?
            std::clamp(pending, -std::fabs(remaining), std::fabs(remaining)) : 0.0f;
        const float combined = base + addition;
        const float limit = tuning.maximumSpeed[axis] * dt;
        if (!std::isfinite(combined) || !std::isfinite(limit)) return false;
        result.saturated[axis] = std::fabs(combined) > limit + 0.0001f;
        result.delta[axis] = std::clamp(combined, -limit, limit);
        result.residualContribution[axis] = result.delta[axis] - std::clamp(base, -limit, limit);
    }
    *out = result;
    return true;
}

struct ActionPostRecord {
    bool valid = false;
    uint64_t key = 0;
    // Core-self identity token, not a counter or a validated object lifetime.
    uint64_t ownerToken = 0;
    uint8_t active = 0;
    // Core-local +1c..+30; names intentionally do not claim target fields.
    std::array<float, 6> values{};
};
struct ActionPostState {
    bool valid = false;
    uint64_t key = 0;
    uint64_t ownerToken = 0;
    uint32_t binding = 0;
    uint32_t phase = 0;
    uint32_t quietFrames = 0;
    ActionPostRecord previous{};
};
struct ActionPostTuning {
    float firstStrength = 0;
    float firstLimit = 0;
    float deadzone = 0;
    float firstWeight = 0;
    float firstBindingScale = 0;
    int quietFrameLimit = 0;
    bool continueLocalTail = false;
    float secondStrength = 0;
    float secondLimitScale = 0;
    float secondWeight = 0;
    float secondBindingScale = 0;
};
struct ActionPostObservation {
    uint16_t status = 0;
    bool contextReset = false;
    uint32_t phaseCode = 0;
    std::array<float, 6> values{};
    static constexpr bool writeReady = false;
};

// Exact c3270..c32dc worker construction of c416c's configuration record.
// Fixed constants stay beside the identity-bound native model instead of being
// restated by Objective-C/Swift consumers.
inline bool referenceActionRecoilPostTuning(const RecoilConfiguration &configuration,
                                             float firstWeight, float firstBindingScale,
                                             float secondWeight, float secondBindingScale,
                                             ActionPostTuning *out) {
    if (!out || !std::isfinite(firstWeight) || !std::isfinite(firstBindingScale) ||
        !std::isfinite(secondWeight) || !std::isfinite(secondBindingScale) ||
        !std::isfinite(configuration.verticalStrength) ||
        configuration.verticalStrength < 0 || configuration.verticalStrength > 1 ||
        !std::isfinite(configuration.horizontalStrength) ||
        configuration.horizontalStrength < 0 || configuration.horizontalStrength > 1) return false;
    ActionPostTuning result;
    result.firstStrength = configuration.verticalEnabled ? configuration.verticalStrength : 0;
    result.firstLimit = 1.5f;
    result.deadzone = 0.0005000000237487257f;
    result.firstWeight = firstWeight;
    result.firstBindingScale = firstBindingScale;
    result.quietFrameLimit = 6;
    result.continueLocalTail = configuration.verticalEnabled && !configuration.stopWhenNotFiring;
    result.secondStrength = configuration.horizontalEnabled ? configuration.horizontalStrength : 0;
    result.secondLimitScale = 1.0f;
    result.secondWeight = secondWeight;
    result.secondBindingScale = secondBindingScale;
    *out = result;
    return true;
}

// Full c416c finite-input key/ownerToken/binding post-state and second-axis tail.
// Invalid input clears only this Core-local model; it is not stop restoration.
inline bool referenceActionPostState(ActionPostState &state, const ActionPostRecord &current,
                                     const ActionPostTuning &tuning, uint32_t binding,
                                     ActionPostObservation *out) {
    if (!out) return false;
    *out = {};
    const auto bounded = [](float value, float limit) { return std::isfinite(value) && std::fabs(value) <= limit; };
    bool config = bounded(tuning.firstStrength, 1.5f) && tuning.firstStrength >= 0 &&
        std::isnormal(tuning.firstLimit) && tuning.firstLimit > 0 &&
        std::isfinite(tuning.deadzone) && tuning.deadzone >= 0 &&
        bounded(tuning.firstWeight, 16) && bounded(tuning.firstBindingScale, 16) &&
        tuning.quietFrameLimit >= 1 && bounded(tuning.secondStrength, 1.5f) && tuning.secondStrength >= 0;
    if (tuning.secondStrength != 0) config = config && std::isnormal(tuning.secondLimitScale) &&
        tuning.secondLimitScale > 0 && bounded(tuning.secondWeight, 16) && bounded(tuning.secondBindingScale, 16);
    bool record = current.valid && current.key && current.ownerToken;
    for (float value : current.values) record = record && std::isfinite(value);
    if (!binding || !config || !record) { state = {}; return false; }
    if (!state.valid || state.key != current.key || state.ownerToken != current.ownerToken || state.binding != binding) {
        state = {true, current.key, current.ownerToken, binding, current.active, 0, current};
        *out = {1, true, current.active, {}};
        return true;
    }
    float first = 0, second = 0;
    uint32_t code = 0;
    if (current.active == 1) {
        state.phase = 1; state.quietFrames = 0;
        first = state.previous.values[1] - current.values[1];
        second = state.previous.values[2] - current.values[2];
        code = 1;
    } else {
        const float difference = current.values[3] - state.previous.values[3];
        const bool changed = std::fabs(difference) > tuning.deadzone;
        if (changed || static_cast<uint32_t>(state.phase - 1) <= 1) {
            state.phase = 2;
            first = tuning.continueLocalTail ? difference : 0.0f;
            state.quietFrames = changed ? 0 : state.quietFrames + 1;
            if (static_cast<int32_t>(state.quietFrames) < tuning.quietFrameLimit) code = 2;
            else state.phase = 0;
        } else { state.phase = 0; state.quietFrames = 0; }
    }
    state.previous = current;
    const float scaledFirst = (first * tuning.firstWeight) * tuning.firstBindingScale;
    float scaledSecond = 0;
    if (tuning.secondStrength > 0) scaledSecond = (second * tuning.secondWeight) * tuning.secondBindingScale;
    if (!std::isfinite(first) || !std::isfinite(second) || !std::isfinite(scaledFirst) || !std::isfinite(scaledSecond)) {
        state = {}; return false;
    }
    float firstOutput = 0, secondOutput = 0;
    if (std::fabs(first) > tuning.deadzone && std::fabs(scaledFirst) > tuning.deadzone)
        firstOutput = std::clamp(-(scaledFirst * tuning.firstStrength), -tuning.firstLimit, tuning.firstLimit);
    if (tuning.secondStrength > 0 && std::fabs(second) > tuning.deadzone &&
        std::fabs(scaledSecond) > tuning.deadzone && (current.active & 1)) {
        const float limit = tuning.secondStrength * tuning.secondLimitScale;
        secondOutput = std::clamp(-(scaledSecond * tuning.secondStrength), -limit, limit);
    }
    *out = {0x101, false, code, {first, scaledFirst, firstOutput, second, scaledSecond, secondOutput}};
    return true;
}

// c2d34..c2dac: the raw recoil correction is added to caller component s11
// then bounded by 1.5*strength. This does not grant the eventual slot authority.
inline float referenceActionRecoilCallerMerge(float callerComponent, float rawCombined, float strength) {
    const float limit = strength * 1.5f;
    if (!std::isfinite(callerComponent) || !std::isfinite(rawCombined) ||
        !std::isnormal(limit) || limit <= 0) return 0;
    return std::clamp(callerComponent + rawCombined, -limit, limit);
}

// c2e3c..c2e50 (both-zero draft) and c3098..c30d0 (accepted first-axis
// flag) update only Core BSS prior Aim feedback. An accepted draft flag is NOT
// an independent target readback, and a zero draft is NOT target restoration.
inline float referenceActionPriorAimFeedback(float prior, float aimFirst, bool inputRoute,
                                             bool recoilEnabled, bool aimActive,
                                             bool acceptedFirstAxis, bool bothZeroDraft) {
    if (!std::isfinite(prior) || !std::isfinite(aimFirst)) return 0;
    if (inputRoute && recoilEnabled && aimActive && (acceptedFirstAxis || bothZeroDraft)) return aimFirst;
    return prior;
}

struct ActionGeometryTuning {
    ActionCompensationTuning compensation{};
    float predictionMilliseconds = 0;
    float deadzoneRatio = 0;
    float minimumDeadzone = 0;
};
struct ActionGeometryInput {
    uint64_t key = 0;
    uint64_t monotonicNanoseconds = 0;
    std::array<float, 3> camera{};
    std::array<float, 3> target{};
    std::array<float, 3> relativeVelocity{};
    bool velocityPresent = false;
    std::array<float, 2> currentAngles{};
};
struct ActionGeometryObservation {
    bool valid = false;
    bool firstOrReset = false;
    bool withinDeadzone = false;
    std::array<bool, 2> saturated{};
    bool predictionUsed = false;
    // Exact Core-self result +08..+30, +38..+58 in address order. Named types
    // above explain the arithmetic; this record is not a target memory layout.
    std::array<float, 20> numerical{};
    static constexpr bool writeReady = false;
};

inline float referenceActionWrappedAngle(float value) {
    const float wrapped = std::remainder(value, 360.0f);
    return wrapped == -180.0f ? 180.0f : wrapped;
}

// Complete c4af8 finite-input composition. Prediction Z intentionally uses
// half the relative-velocity factor. Its local key is supplied by the caller;
// it must not be confused with a validated target-object or generation lease.
inline bool referenceActionGeometry(ActionGeometryClockState &history,
                                    const ActionGeometryInput &input,
                                    const ActionGeometryTuning &tuning,
                                    ActionGeometryObservation *out) {
    if (!out) return false;
    *out = {};
    const auto &c = tuning.compensation;
    if (!input.key || !input.monotonicNanoseconds || !std::isfinite(c.strength) || c.strength <= 0 || c.strength > 1 ||
        !std::isnormal(c.smoothingSeconds) || c.smoothingSeconds <= 0 ||
        !std::isfinite(c.curveSelector) || c.curveSelector < 0 ||
        !std::isfinite(c.residualGain) || c.residualGain < 0 || c.residualGain > 1 ||
        !std::isfinite(c.minimumGain) || c.minimumGain <= 0 || c.minimumGain > 1 ||
        !std::isfinite(tuning.predictionMilliseconds) || tuning.predictionMilliseconds < 0 || tuning.predictionMilliseconds > 300 ||
        !std::isfinite(tuning.deadzoneRatio) || tuning.deadzoneRatio < .05f || tuning.deadzoneRatio > .5f ||
        !std::isfinite(tuning.minimumDeadzone) || tuning.minimumDeadzone < .02f || tuning.minimumDeadzone > .35f) return false;
    for (float value : c.maximumSpeed) if (!std::isfinite(value) || value < 30 || value > 720) return false;
    for (float value : input.currentAngles) if (!std::isfinite(value)) return false;
    for (float value : input.camera) if (!std::isfinite(value)) return false;
    for (float value : input.target) if (!std::isfinite(value)) return false;
    if (input.velocityPresent) for (float value : input.relativeVelocity) if (!std::isfinite(value)) return false;
    std::array<float, 3> difference{};
    for (unsigned axis = 0; axis < 3; ++axis) difference[axis] = input.target[axis] - input.camera[axis];
    const float originalHorizontal = std::hypot(difference[0], difference[1]);
    const float squared = std::fma(originalHorizontal, originalHorizontal, difference[2] * difference[2]);
    if (!std::isfinite(originalHorizontal) || originalHorizontal < .001f || squared < .000001f) return false;
    ActionGeometryObservation result;
    const float distance = std::sqrt(squared) * .01f;
    float deadzone = .35f;
    if (distance > .5f) {
        const float angle = std::atan(tuning.deadzoneRatio / distance) * 57.295780181884766f;
        deadzone = std::clamp(angle, tuning.minimumDeadzone, .35f);
    }
    result.numerical[18] = distance; result.numerical[19] = deadzone;
    auto predicted = input.target;
    if (input.velocityPresent && tuning.predictionMilliseconds > 0) {
        const float seconds = (tuning.predictionMilliseconds * .001f) * referenceActionPredictionGain(distance);
        std::array<float, 3> lead{seconds * input.relativeVelocity[0], seconds * input.relativeVelocity[1],
                                 (seconds * input.relativeVelocity[2]) * .5f};
        float leadNorm = std::hypot(std::hypot(lead[0], lead[1]), lead[2]);
        const float distanceFactor = distance * .035f;
        const float limit = distanceFactor < .2f ? 20.f : std::min(distanceFactor, 6.f) * 100.f;
        if (leadNorm > limit && leadNorm > 0) {
            const float scale = limit / leadNorm;
            for (float &value : lead) value *= scale;
            leadNorm = std::hypot(std::hypot(lead[0], lead[1]), lead[2]);
        }
        for (unsigned axis = 0; axis < 3; ++axis) predicted[axis] += lead[axis];
        result.predictionUsed = true;
        result.numerical[16] = leadNorm * .01f;
        result.numerical[17] = seconds;
    }
    std::array<float, 3> predictedDifference{};
    for (unsigned axis = 0; axis < 3; ++axis) {
        predictedDifference[axis] = predicted[axis] - input.camera[axis];
        result.numerical[11 + axis] = predicted[axis];
    }
    const float horizontal = std::hypot(predictedDifference[0], predictedDifference[1]);
    if (!std::isfinite(horizontal) || horizontal < .001f) { *out = result; return false; }
    const std::array<float, 2> angles{
        std::atan2(predictedDifference[1], predictedDifference[0]) * 57.295780181884766f,
        std::atan2(predictedDifference[2], horizontal) * 57.295780181884766f};
    std::array<float, 2> error{};
    for (unsigned axis = 0; axis < 2; ++axis) {
        error[axis] = referenceActionWrappedAngle(angles[axis] - input.currentAngles[axis]);
        if (!std::isfinite(angles[axis]) || !std::isfinite(error[axis])) { *out = result; return false; }
        result.numerical[axis] = angles[axis]; result.numerical[2 + axis] = error[axis];
    }
    result.valid = true; result.withinDeadzone = std::fabs(error[0]) <= deadzone;
    result.numerical[14] = referenceActionWrappedAngle(std::fma(
        std::atan2(difference[1], difference[0]), -57.295780181884766f, angles[0]));
    result.numerical[15] = referenceActionWrappedAngle(std::fma(
        std::atan2(difference[2], originalHorizontal), -57.295780181884766f, angles[1]));
    const auto clock = referenceActionGeometryClock(history, input.key, input.monotonicNanoseconds);
    result.firstOrReset = clock.firstOrReset;
    if (!clock.stepEligible) { *out = result; return true; }
    result.numerical[10] = clock.deltaSeconds;
    ActionAngularMotion motion;
    const bool measured = input.velocityPresent && referenceActionAngularMotion(predictedDifference, input.relativeVelocity, &motion);
    ActionResidualState residual{history.residual, history.residualPresent};
    ActionResidualObservation observed;
    if (!referenceActionResidual(residual, clock.deltaSeconds, measured, motion, c.maximumSpeed,
                                  std::fabs(error[0]), deadzone, &observed)) return false;
    history.residual = residual.angular; history.residualPresent = residual.present;
    if (!observed.eligible) { *out = result; return true; }
    result.numerical[8] = observed.angular[0]; result.numerical[9] = observed.angular[1];
    ActionCompensationDelta delta;
    if (!referenceActionCompensation(error, clock.deltaSeconds, observed, c, &delta)) return false;
    for (unsigned axis = 0; axis < 2; ++axis) {
        result.numerical[4 + axis] = delta.delta[axis];
        result.numerical[6 + axis] = delta.residualContribution[axis];
        result.saturated[axis] = delta.saturated[axis];
    }
    *out = result;
    return true;
}

} // namespace CoreSet
