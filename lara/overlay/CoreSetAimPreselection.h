#pragma once
#include <cmath>
#include <cstdint>
#include <vector>

namespace CoreSet {

// Confirmed Core v1.7 candidate filtering only. This deliberately does not
// produce a target write or choose between locked and ordinary candidates:
// confirmation frames, bone point, prediction and angle delta remain unknown.
enum class AimTrigger : uint8_t { either = 0, scopeOnly = 1, fireOnly = 2, both = 3 };

struct AimSceneValues {
    int strength;
    int smoothing;
    int maximumDistance;
    int horizontalSpeed;
    int verticalSpeed;
    int predictionMilliseconds;
};

// Remaining c1664 table columns at 0x1008a9a00/10/20. They are consumed by
// c4af8 as normalized compensation/deadzone values. Keep the conversion here
// with the identity-bound table instead of recreating scene constants in Swift.
struct AimSceneCompensationValues {
    float residualGain;
    float minimumGain;
    float deadzoneRatio;
    float minimumDeadzone;
};

inline bool aimSceneCompensationValues(int storedScene, AimSceneCompensationValues *out) {
    if (!out || storedScene < 0 || storedScene > 3) return false;
    static constexpr int rows[4][4] = {
        {90, 38, 12, 4},
        {56, 6, 25, 10},
        {62, 6, 25, 10},
        {56, 6, 25, 10},
    };
    const int *row = rows[storedScene];
    *out = {row[0] / 100.0f, row[1] / 100.0f,
            row[2] / 100.0f, row[3] / 100.0f};
    return true;
}

// C+0x180 scene 0/1/2 only. Scene 3 is custom and requires explicit user
// slider values; no compiled row is treated as a default.
inline bool aimSceneValues(int storedScene, AimSceneValues *out) {
    if (!out || storedScene < 0 || storedScene > 2) return false;
    static constexpr AimSceneValues rows[3] = {
        {76, 3, 300, 300, 220, 110}, // stable
        {80, 3, 180, 420, 300, 90}, // balanced
        {88, 2, 70, 600, 420, 60}   // responsive
    };
    *out = rows[storedScene];
    return true;
}

struct AimLockValues { int threshold; int confirmationFrames; int pauseMilliseconds; };
inline bool aimLockValues(int storedStrength, AimLockValues *out) {
    if (!out || storedStrength < 0 || storedStrength > 4) return false;
    static constexpr uint8_t mapped[5] = {0, 0, 3, 3, 4};
    static constexpr AimLockValues rows[5] = {
        {80, 3, 140}, {55, 3, 180}, {35, 2, 220},
        {20, 2, 300}, {10, 1, 420}
    };
    *out = rows[mapped[storedStrength]];
    return true;
}

struct AimWorkerTuning {
    double strength01;
    double smoothingStep;
    double horizontalDegreesPerSecond;
    double verticalDegreesPerSecond;
    double predictionMilliseconds;
    double lockThreshold01;
};

// c26a8..c29d0 preparation only. Later candidate/angle and timing consumers
// are not closed, so these numbers must not be used to authorize a write.
inline bool aimWorkerTuning(const AimSceneValues &scene, const AimLockValues &lock,
                            AimWorkerTuning *out) {
    if (!out || scene.strength < 0 || scene.smoothing < 0 ||
        scene.horizontalSpeed < 0 || scene.verticalSpeed < 0 ||
        scene.predictionMilliseconds < 0 || lock.threshold < 0) return false;
    const double strength = scene.strength / 100.0;
    const double smoothing = std::fmin(10.0, std::fmax(1.0, (double)scene.smoothing));
    out->strength01 = std::fmin(1.0, std::fmax(0.05, strength));
    out->smoothingStep = 0.024 + 0.012 * smoothing;
    out->horizontalDegreesPerSecond =
        std::fmin(720.0, std::fmax(30.0, (double)scene.horizontalSpeed));
    out->verticalDegreesPerSecond =
        std::fmin(720.0, std::fmax(30.0, (double)scene.verticalSpeed));
    out->predictionMilliseconds =
        std::fmin(300.0, std::fmax(0.0, (double)scene.predictionMilliseconds));
    out->lockThreshold01 = std::fmin(5.0, std::fmax(0.05, lock.threshold / 100.0));
    return true;
}

inline bool aimTriggerActive(AimTrigger mode, bool ads, bool firing) {
    switch (mode) {
    case AimTrigger::either: return ads || firing;
    case AimTrigger::scopeOnly: return ads;
    case AimTrigger::fireOnly: return firing;
    case AimTrigger::both: return ads && firing;
    }
    return false;
}

inline double aimCircleRadius(double width, double height, int size) {
    if (!std::isfinite(width) || !std::isfinite(height) || width <= 0 || height <= 0 ||
        size < 30 || size > 525) return 0;
    const double shortSide = width < height ? width : height;
    const double raw = shortSide * size / 1170.0;
    const double upper = std::fmin(shortSide * 0.45, 525.0);
    return raw < 30.0 ? 30.0 : std::fmin(raw, upper);
}

struct AimScreenCandidate {
    uint64_t actor = 0;
    uint64_t generation = 0;
    bool bot = false;
    bool downedKnown = false;
    bool downed = false;
    double distanceMeters = 0;
    double screenX = 0;
    double screenY = 0;
};

struct AimPreselection {
    uint64_t nearestActor = 0;
    uint64_t lockedActor = 0;
    double nearestCenterPixels = INFINITY;
    double lockedCenterPixels = INFINITY;
    // Neither candidate is authorized for a ControlRotation write.
    static constexpr bool writeReady = false;
};

inline AimPreselection preselectAimCandidates(const std::vector<AimScreenCandidate> &candidates,
                                               uint64_t generation, uint64_t previousActor,
                                               uint64_t previousGeneration,
                                               bool includeBots, bool excludeKnocked,
                                               bool lockSameTarget, double maximumDistanceMeters,
                                               double radius, double width, double height) {
    AimPreselection result;
    if (!generation || !std::isfinite(maximumDistanceMeters) || maximumDistanceMeters <= 0 ||
        !std::isfinite(radius) || radius <= 0 || !std::isfinite(width) ||
        !std::isfinite(height) || width <= 0 || height <= 0 ||
        candidates.size() > 50000) return result;
    for (const auto &item : candidates) {
        if (!item.actor || item.generation != generation ||
            (!includeBots && item.bot) ||
            (excludeKnocked && (!item.downedKnown || item.downed)) ||
            !std::isfinite(item.distanceMeters) || item.distanceMeters < 0 ||
            item.distanceMeters > maximumDistanceMeters ||
            !std::isfinite(item.screenX) || !std::isfinite(item.screenY) ||
            item.screenX <= 0 || item.screenX >= width ||
            item.screenY <= 0 || item.screenY >= height) continue;
        const double pixels = std::hypot(item.screenX - width * 0.5,
                                         item.screenY - height * 0.5);
        if (!std::isfinite(pixels)) continue;
        if (lockSameTarget && previousGeneration == generation &&
            previousActor == item.actor && pixels <= radius * 1.15) {
            result.lockedActor = item.actor;
            result.lockedCenterPixels = pixels;
        }
        if (pixels < radius && pixels < result.nearestCenterPixels) {
            result.nearestActor = item.actor;
            result.nearestCenterPixels = pixels;
        }
    }
    return result;
}
} // namespace CoreSet
