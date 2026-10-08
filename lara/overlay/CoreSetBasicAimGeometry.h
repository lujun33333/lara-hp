#pragma once
#include <cmath>
#include <cstdint>
#include <limits>
#include <vector>
namespace CoreSet {
struct BasicAimPoint { float x, y, z; };
struct BasicAimStep { float pitch, yaw; };
struct BasicAimTuning {
    float strength01, smoothingSeconds;
    float pitchDegreesPerSecond, yawDegreesPerSecond;
};
struct BasicAimRuntimeState {
    uint64_t actor = 0, generation = 0;
    double lastSeconds = -1;
    BasicAimPoint lastTarget{};
    bool targetValid = false;
    void reset() { actor = generation = 0; lastSeconds = -1; lastTarget = {}; targetValid = false; }
};
class BasicAimTakeoverGate {
public:
    void reset() { consecutive_ = 0; pauseUntil_ = -1; lastObserved_ = -1; }
    bool update(double magnitude, double threshold, int confirmationFrames,
                double pauseSeconds, double now) {
        if (!std::isfinite(magnitude) || magnitude < 0 || !std::isfinite(threshold) ||
            threshold < 0.05 || threshold > 5 || confirmationFrames < 1 ||
            confirmationFrames > 6 || !std::isfinite(pauseSeconds) ||
            pauseSeconds < 0.05 || pauseSeconds > 1 || !std::isfinite(now) || now < 0 ||
            (lastObserved_ >= 0 && now < lastObserved_)) {
            reset(); return false;
        }
        lastObserved_ = now;
        if (pauseUntil_ >= 0 && now < pauseUntil_) return false;
        if (magnitude >= threshold) {
            if (++consecutive_ >= confirmationFrames) {
                consecutive_ = 0; pauseUntil_ = now + pauseSeconds; return false;
            }
        } else consecutive_ = 0;
        return true;
    }
private:
    int consecutive_ = 0;
    double pauseUntil_ = -1, lastObserved_ = -1;
};
class BasicAimDropoutHold {
public:
    void reset() { actor_ = generation_ = 0; lastSeconds_ = -1; point_ = {}; }
    bool publish(uint64_t actor, uint64_t generation, BasicAimPoint point, double now) {
        if (!actor || !generation || !std::isfinite(point.x) || !std::isfinite(point.y) ||
            !std::isfinite(point.z) || !std::isfinite(now) || now < 0) { reset(); return false; }
        actor_ = actor; generation_ = generation; point_ = point; lastSeconds_ = now; return true;
    }
    bool reuse(uint64_t generation, double now, bool stateClear,
               uint64_t *actor, BasicAimPoint *point) const {
        if (!actor || !point || !stateClear || !actor_ || generation != generation_ ||
            !std::isfinite(now) || now < lastSeconds_ || now - lastSeconds_ > 0.075000001) return false;
        *actor = actor_; *point = point_; return true;
    }
private:
    uint64_t actor_ = 0, generation_ = 0;
    double lastSeconds_ = -1;
    BasicAimPoint point_{};
};
inline bool basicAimTrigger(int mode, bool ads, bool firing) {
    switch (mode) { case 0: return ads || firing; case 1: return ads;
    case 2: return firing; case 3: return ads && firing; default: return false; }
}
class BasicAimTriggerHold {
public:
    void reset() { lastObserved_ = -1; lastActive_ = -1; }
    bool update(int mode, bool ads, bool firing, double now) {
        if (!std::isfinite(now) || now < 0 || (lastObserved_ >= 0 && now < lastObserved_) || mode < 0 || mode > 3) {
            reset(); return false;
        }
        lastObserved_ = now;
        if (basicAimTrigger(mode, ads, firing)) lastActive_ = now;
        return permits(now);
    }
    bool permits(double now) const {
        return std::isfinite(now) && now >= lastObserved_ && lastActive_ >= 0 &&
               now >= lastActive_ && now - lastActive_ <= 0.25;
    }
private:
    double lastObserved_ = -1, lastActive_ = -1;
};
struct BasicAimCandidate {
    uint64_t actor; bool bot, onScreen, worldPointPresent;
    bool downedKnown, downed, lineOfSightKnown, lineOfSight;
    double distance, x, y;
};
inline size_t basicAimSelectFiltered(const std::vector<BasicAimCandidate> &items,
                                    double width, double height, double radius,
                                    double distanceLimit, bool includeBots,
                                    bool excludeKnocked, bool requireLineOfSight) {
    size_t best = std::numeric_limits<size_t>::max();
    if (!std::isfinite(width) || !std::isfinite(height) || width <= 0 || height <= 0 ||
        !std::isfinite(radius) || radius <= 0 || !std::isfinite(distanceLimit) || distanceLimit <= 0) return best;
    double bestScore = INFINITY;
    for (size_t i = 0; i < items.size(); ++i) {
        const auto &v = items[i];
        if (!v.actor || !v.onScreen || !v.worldPointPresent || (!includeBots && v.bot) ||
            (excludeKnocked && (!v.downedKnown || v.downed)) ||
            (requireLineOfSight && (!v.lineOfSightKnown || !v.lineOfSight)) ||
            !std::isfinite(v.distance) || v.distance < 0 || v.distance > distanceLimit ||
            !std::isfinite(v.x) || !std::isfinite(v.y) || v.x < 0 || v.y < 0 || v.x > width || v.y > height) continue;
        const double score = std::hypot(v.x - width * 0.5, v.y - height * 0.5);
        if (score > radius) continue;
        if (score < bestScore) {
            best = i; bestScore = score;
        }
    }
    return best;
}
inline size_t basicAimSelect(const std::vector<BasicAimCandidate> &items,
                            double width, double height, double radius,
                            double distanceLimit, bool includeBots) {
    return basicAimSelectFiltered(items, width, height, radius, distanceLimit,
                                  includeBots, false, false);
}
inline size_t basicAimSelectLocked(const std::vector<BasicAimCandidate> &items,
                                  double width, double height, double radius,
                                  double distanceLimit, bool includeBots,
                                  bool lockSameTarget, uint64_t previousActor) {
    const size_t nearest = basicAimSelect(items, width, height, radius,
                                         distanceLimit, includeBots);
    if (!lockSameTarget || !previousActor || !std::isfinite(radius) || radius <= 0)
        return nearest;
    const double lockRadius = radius * 1.15;
    for (size_t i = 0; i < items.size(); ++i) {
        const auto &v = items[i];
        if (v.actor != previousActor || !v.onScreen || !v.worldPointPresent ||
            (!includeBots && v.bot) || !std::isfinite(v.distance) ||
            v.distance < 0 || v.distance > distanceLimit ||
            !std::isfinite(v.x) || !std::isfinite(v.y) ||
            v.x <= 0 || v.y <= 0 || v.x >= width || v.y >= height ||
            std::hypot(v.x - width * 0.5, v.y - height * 0.5) > lockRadius) continue;
        return i;
    }
    return nearest;
}
inline size_t basicAimSelectLockedFiltered(const std::vector<BasicAimCandidate> &items,
                                           double width, double height, double radius,
                                           double distanceLimit, bool includeBots,
                                           bool excludeKnocked, bool requireLineOfSight,
                                           bool lockSameTarget, uint64_t previousActor) {
    const size_t nearest = basicAimSelectFiltered(items, width, height, radius,
        distanceLimit, includeBots, excludeKnocked, requireLineOfSight);
    if (!lockSameTarget || !previousActor || !std::isfinite(radius) || radius <= 0)
        return nearest;
    const double lockRadius = radius * 1.15;
    for (size_t i = 0; i < items.size(); ++i) {
        const auto &v = items[i];
        if (v.actor != previousActor || !v.onScreen || !v.worldPointPresent ||
            (!includeBots && v.bot) || (excludeKnocked && (!v.downedKnown || v.downed)) ||
            (requireLineOfSight && (!v.lineOfSightKnown || !v.lineOfSight)) ||
            !std::isfinite(v.distance) || v.distance < 0 || v.distance > distanceLimit ||
            !std::isfinite(v.x) || !std::isfinite(v.y) || v.x <= 0 || v.y <= 0 ||
            v.x >= width || v.y >= height ||
            std::hypot(v.x - width * 0.5, v.y - height * 0.5) > lockRadius) continue;
        return i;
    }
    return nearest;
}
// Our explicit basic test policy, not Core v1.7 prediction/smoothing semantics.
inline bool basicAimStep(BasicAimPoint camera, BasicAimPoint target,
                         float currentPitch, float currentYaw, BasicAimStep *out) {
    if (!out || !std::isfinite(camera.x) || !std::isfinite(camera.y) ||
        !std::isfinite(camera.z) || !std::isfinite(target.x) ||
        !std::isfinite(target.y) || !std::isfinite(target.z) ||
        !std::isfinite(currentPitch) || !std::isfinite(currentYaw) ||
        std::fabs(currentPitch) > 360 || std::fabs(currentYaw) > 360) return false;
    const double dx = (double)target.x - camera.x, dy = (double)target.y - camera.y;
    const double dz = (double)target.z - camera.z;
    const double horizontal = std::hypot(dx, dy);
    if (!std::isfinite(horizontal) || horizontal < 0.001) return false;
    constexpr double toDegrees = 57.29577951308232;
    auto step = [](double degrees) -> float {
        const double normalized = std::remainder(degrees, 360.0);
        return (float)std::fmax(-1.0, std::fmin(1.0, normalized));
    };
    const float pitch = step(std::atan2(dz, horizontal) * toDegrees - currentPitch);
    const float yaw = step(std::atan2(dy, dx) * toDegrees - currentYaw);
    if (!std::isfinite(pitch) || !std::isfinite(yaw)) return false;
    *out = {pitch, yaw}; return true;
}

// Closed c4af8 sub-pipeline: same-target/clock lifetime, exponential response,
// strength and independent per-axis speed bounds. Prediction and the remaining
// scene curve are intentionally absent because their live producers are not closed.
inline bool basicAimDynamicStep(BasicAimPoint camera, BasicAimPoint target,
                                float currentPitch, float currentYaw,
                                uint64_t actor, uint64_t generation, double now,
                                BasicAimTuning tuning, BasicAimRuntimeState *state,
                                 BasicAimStep *out, double predictionMilliseconds = 0.0,
                                 const BasicAimPoint *knownVelocity = nullptr) {
    if (!state || !out || !actor || !generation || !std::isfinite(now) || now < 0 ||
        !std::isfinite(tuning.strength01) || tuning.strength01 < 0.05f || tuning.strength01 > 1 ||
        !std::isfinite(tuning.smoothingSeconds) || tuning.smoothingSeconds <= 0 ||
        !std::isfinite(tuning.pitchDegreesPerSecond) || tuning.pitchDegreesPerSecond < 30 ||
        tuning.pitchDegreesPerSecond > 720 || !std::isfinite(tuning.yawDegreesPerSecond) ||
        tuning.yawDegreesPerSecond < 30 || tuning.yawDegreesPerSecond > 720 ||
        !std::isfinite(predictionMilliseconds) || predictionMilliseconds < 0 ||
        predictionMilliseconds > 300) {
        if (state) state->reset();
        return false;
    }
    if (!std::isfinite(camera.x) || !std::isfinite(camera.y) || !std::isfinite(camera.z) ||
        !std::isfinite(target.x) || !std::isfinite(target.y) || !std::isfinite(target.z) ||
        !std::isfinite(currentPitch) || !std::isfinite(currentYaw)) {
        state->reset(); return false;
    }
    if (state->actor != actor || state->generation != generation || state->lastSeconds < 0 ||
        now <= state->lastSeconds || now - state->lastSeconds >= 0.050000001) {
        state->actor = actor; state->generation = generation; state->lastSeconds = now;
        state->lastTarget = target; state->targetValid = true;
        return false;
    }
    const double dt = now - state->lastSeconds;
    state->lastSeconds = now;
    BasicAimPoint aimed = target;
    bool predicted = false;
    if (predictionMilliseconds > 0 && knownVelocity &&
        std::isfinite(knownVelocity->x) && std::isfinite(knownVelocity->y) &&
        std::isfinite(knownVelocity->z)) {
        const double speed = std::sqrt((double)knownVelocity->x * knownVelocity->x +
            (double)knownVelocity->y * knownVelocity->y +
            (double)knownVelocity->z * knownVelocity->z);
        if (std::isfinite(speed) && speed <= 15000.0) {
            const double lead = predictionMilliseconds / 1000.0;
            aimed.x = (float)(target.x + knownVelocity->x * lead);
            aimed.y = (float)(target.y + knownVelocity->y * lead);
            aimed.z = (float)(target.z + knownVelocity->z * lead);
            predicted = true;
        }
    }
    if (!predicted && predictionMilliseconds > 0 && state->targetValid) {
        const double vx = ((double)target.x - state->lastTarget.x) / dt;
        const double vy = ((double)target.y - state->lastTarget.y) / dt;
        const double vz = ((double)target.z - state->lastTarget.z) / dt;
        const double speed = std::sqrt(vx * vx + vy * vy + vz * vz);
        if (std::isfinite(speed) && speed <= 15000.0) {
            const double lead = predictionMilliseconds / 1000.0;
            aimed.x = (float)(target.x + vx * lead);
            aimed.y = (float)(target.y + vy * lead);
            aimed.z = (float)(target.z + vz * lead);
        }
    }
    state->lastTarget = target; state->targetValid = true;
    const double dx = (double)aimed.x - camera.x, dy = (double)aimed.y - camera.y;
    const double dz = (double)aimed.z - camera.z;
    const double horizontal = std::hypot(dx, dy);
    if (!std::isfinite(horizontal) || horizontal < 0.001) { state->reset(); return false; }
    constexpr double toDegrees = 57.29577951308232;
    const double rawPitch = std::remainder(std::atan2(dz, horizontal) * toDegrees - currentPitch, 360.0);
    const double rawYaw = std::remainder(std::atan2(dy, dx) * toDegrees - currentYaw, 360.0);
    if (!std::isfinite(rawPitch) || !std::isfinite(rawYaw)) { state->reset(); return false; }
    const double alpha = 1.0 - std::exp(-dt / tuning.smoothingSeconds);
    const double pitchCap = tuning.pitchDegreesPerSecond * dt + 0.0001;
    const double yawCap = tuning.yawDegreesPerSecond * dt + 0.0001;
    auto bounded = [](double value, double cap) -> float {
        // The isolated production probe keeps its independently reviewed 1 degree
        // transaction bound even when Core's per-frame cap is larger.
        cap = std::fmin(cap, 1.0);
        return (float)std::fmax(-cap, std::fmin(cap, value));
    };
    const float pitch = bounded(rawPitch * tuning.strength01 * alpha, pitchCap);
    const float yaw = bounded(rawYaw * tuning.strength01 * alpha, yawCap);
    if (!std::isfinite(pitch) || !std::isfinite(yaw)) { state->reset(); return false; }
    *out = {pitch, yaw};
    return true;
}
}

