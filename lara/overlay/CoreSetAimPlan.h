#pragma once

#include <cmath>

namespace CoreSet {

struct AimWorldPoint {
    float x;
    float y;
    float z;
};

struct AimGeometryPlan {
    float desiredPitch = 0;
    float desiredYaw = 0;
    float deltaPitch = 0;
    float deltaYaw = 0;
    float distanceMeters = 0;

    // This is only the c4af8 no-prediction angle geometry. Core's candidate
    // decision, prediction, smoothing, frame timing and write branch are not
    // represented, so no result from this type authorizes a target write.
    static constexpr bool writeReady = false;
};

struct AimDynamicBounds {
    float exponentialAlpha = 0;
    float firstAxisDegrees = 0;
    float secondAxisDegrees = 0;
    static constexpr bool writeReady = false;
};

// c5374..c5380 and c5430..c5450 only. The rest of c4af8's scene curve,
// velocity prediction, target lifetime and output clamping are not modeled.
inline bool aimDynamicBounds(float deltaSeconds, float smoothingSeconds,
                             float firstAxisDegreesPerSecond,
                             float secondAxisDegreesPerSecond,
                             AimDynamicBounds *out) {
    if (!out || !std::isfinite(deltaSeconds) || deltaSeconds <= 0 ||
        !std::isfinite(smoothingSeconds) || smoothingSeconds <= 0 ||
        !std::isfinite(firstAxisDegreesPerSecond) ||
        firstAxisDegreesPerSecond < 0 ||
        !std::isfinite(secondAxisDegreesPerSecond) ||
        secondAxisDegreesPerSecond < 0) return false;
    constexpr float epsilonDegrees = 0.0001f;
    const float alpha = 1.0f - std::exp(-deltaSeconds / smoothingSeconds);
    const float firstCap = firstAxisDegreesPerSecond * deltaSeconds + epsilonDegrees;
    const float secondCap = secondAxisDegreesPerSecond * deltaSeconds + epsilonDegrees;
    if (!std::isfinite(alpha) || !std::isfinite(firstCap) ||
        !std::isfinite(secondCap)) return false;
    *out = {alpha, firstCap, secondCap};
    return true;
}

inline float normalizeAimDelta(float degrees) {
    if (!std::isfinite(degrees)) return NAN;
    const float normalized = std::remainder(degrees, 360.0f);
    return normalized == -180.0f ? 180.0f : normalized;
}

// Core v1.7 c4af8: s0..s2 are the base XYZ, s3..s5 the candidate XYZ;
// caller stack+4/+8 holds current pitch/yaw in that order. The source owners
// of Core's point record remain unproven. Positions are centimeters. This
// does not perform Core's optional velocity/ballistic branch.
inline bool planAimGeometryWithoutPrediction(AimWorldPoint camera,
                                             AimWorldPoint target,
                                             float currentPitch,
                                             float currentYaw,
                                             AimGeometryPlan *out) {
    if (!out || !std::isfinite(camera.x) || !std::isfinite(camera.y) ||
        !std::isfinite(camera.z) || !std::isfinite(target.x) ||
        !std::isfinite(target.y) || !std::isfinite(target.z) ||
        !std::isfinite(currentPitch) || !std::isfinite(currentYaw)) return false;
    const float dx = target.x - camera.x;
    const float dy = target.y - camera.y;
    const float dz = target.z - camera.z;
    const float horizontal = std::hypot(dx, dy);
    const float distance = std::hypot(horizontal, dz);
    if (!std::isfinite(horizontal) || !std::isfinite(distance) ||
        horizontal < 0.001f || distance < 0.001f) return false;

    constexpr float radiansToDegrees = 57.295780181884766f;
    const float desiredYaw = std::atan2(dy, dx) * radiansToDegrees;
    const float desiredPitch = std::atan2(dz, horizontal) * radiansToDegrees;
    const float deltaYaw = normalizeAimDelta(desiredYaw - currentYaw);
    const float deltaPitch = normalizeAimDelta(desiredPitch - currentPitch);
    if (!std::isfinite(deltaYaw) || !std::isfinite(deltaPitch)) return false;

    *out = {desiredPitch, desiredYaw, deltaPitch, deltaYaw, distance * 0.01f};
    return true;
}

} // namespace CoreSet
