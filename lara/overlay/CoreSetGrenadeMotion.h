#pragma once

#include "CoreSetPlayerProjection.h"
#include <algorithm>
#include <unordered_map>

namespace CoreSet {

struct GrenadeMotionContext {
    uint64_t generation = 0, imageBase = 0;
    int32_t pid = 0;
    bool operator==(const GrenadeMotionContext &other) const {
        return generation == other.generation && imageBase == other.imageBase && pid == other.pid;
    }
};
struct GrenadeMotionIdentity {
    uint64_t actor = 0, type = 0;
    uint32_t nameIndex = 0, explosionRaw = 0;
    bool operator==(const GrenadeMotionIdentity &other) const {
        return actor == other.actor && type == other.type && nameIndex == other.nameIndex &&
            explosionRaw == other.explosionRaw;
    }
};
enum class GrenadeMotionStatus : uint8_t {
    warm = 0, ready = 1, contextMismatch = 2, clockInvalid = 3,
    speedInvalid = 4, sampleStale = 5, lifetimeExpired = 6, capacity = 7,
};
struct GrenadeMotionResult {
    GrenadeMotionStatus status = GrenadeMotionStatus::warm;
    Vec3 velocity = {};
};

// Core producer d9b1c..d9c88. The velocity is a LOCAL position-delta estimate,
// not RepMovement.LinearVelocity. The wrapper uses monotonic seconds, binds
// every sample to the current read identity and clears on stop/failure.
class GrenadeMotionTracker {
    struct Entry {
        GrenadeMotionIdentity identity;
        Vec3 position = {}, velocity = {};
        double firstSeen = 0, sampleTime = 0, lastSeen = 0;
        bool velocityPresent = false;
    };
    GrenadeMotionContext context_;
    std::unordered_map<uint64_t, Entry> entries_;
    double frameTime_ = 0;
    bool bound_ = false, framePresent_ = false;
    static bool finite(Vec3 value) {
        return std::isfinite(value.x) && std::isfinite(value.y) && std::isfinite(value.z) &&
            std::fabs(value.x) < 1.0e9f && std::fabs(value.y) < 1.0e9f && std::fabs(value.z) < 1.0e9f;
    }
public:
    static constexpr size_t maximumEntries = 256;
    void clear() { entries_.clear(); context_ = {}; frameTime_ = 0; bound_ = framePresent_ = false; }
    size_t size() const { return entries_.size(); }
    bool beginFrame(GrenadeMotionContext context, double now) {
        if (!context.generation || context.pid <= 0 || !context.imageBase || !std::isfinite(now) || now < 0) {
            clear(); return false;
        }
        if (!bound_ || !(context == context_)) {
            clear(); context_ = context; bound_ = true;
        }
        if (framePresent_ && now <= frameTime_) { clear(); return false; }
        frameTime_ = now; framePresent_ = true;
        for (auto entry = entries_.begin(); entry != entries_.end();) {
            if (now - entry->second.lastSeen > 0.35) entry = entries_.erase(entry);
            else ++entry;
        }
        return true;
    }
    GrenadeMotionResult sample(GrenadeMotionContext context, GrenadeMotionIdentity identity,
                               Vec3 position, double now) {
        if (!bound_ || !(context == context_)) return {GrenadeMotionStatus::contextMismatch, {}};
        if (!framePresent_ || !std::isfinite(now) || now != frameTime_ || !finite(position) ||
            !identity.actor || !identity.type) return {GrenadeMotionStatus::clockInvalid, {}};
        auto found = entries_.find(identity.actor);
        if (found == entries_.end() || !(found->second.identity == identity)) {
            if (found == entries_.end() && entries_.size() >= maximumEntries)
                return {GrenadeMotionStatus::capacity, {}};
            entries_[identity.actor] = {identity, position, {}, now, now, now, false};
            return {};
        }
        Entry &entry = found->second;
        if (now <= entry.lastSeen) { entries_.erase(found); return {GrenadeMotionStatus::clockInvalid, {}}; }
        entry.lastSeen = now;
        if (now - entry.firstSeen > 2) return {GrenadeMotionStatus::lifetimeExpired, {}};
        const double interval = now - entry.sampleTime;
        const Vec3 delta = {position.x - entry.position.x, position.y - entry.position.y, position.z - entry.position.z};
        const float distance = std::sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z);
        if (!std::isfinite(distance)) { entry.velocityPresent = false; return {GrenadeMotionStatus::speedInvalid, {}}; }
        if (distance > 0.75f && interval >= 0.004 && interval <= 1) {
            const float inverse = 1.0f / static_cast<float>(interval);
            Vec3 velocity = {delta.x * inverse, delta.y * inverse, delta.z * inverse};
            const float speed = std::sqrt(velocity.x * velocity.x + velocity.y * velocity.y + velocity.z * velocity.z);
            entry.position = position; entry.sampleTime = now;
            if (!std::isfinite(speed) || speed <= 1 || speed >= 30000) {
                entry.velocityPresent = false; return {GrenadeMotionStatus::speedInvalid, {}};
            }
            if (entry.velocityPresent) velocity = {
                std::fma(entry.velocity.x, 0.35f, velocity.x * 0.65f),
                std::fma(entry.velocity.y, 0.35f, velocity.y * 0.65f),
                std::fma(entry.velocity.z, 0.35f, velocity.z * 0.65f)};
            entry.velocity = velocity; entry.velocityPresent = true;
        }
        if (!entry.velocityPresent || now - entry.sampleTime > 0.35)
            return {GrenadeMotionStatus::sampleStale, {}};
        const Vec3 velocity = entry.velocity;
        const float speed = std::sqrt(velocity.x * velocity.x + velocity.y * velocity.y + velocity.z * velocity.z);
        if (!finite(velocity) || !std::isfinite(speed) || speed <= 25)
            return {GrenadeMotionStatus::speedInvalid, {}};
        return {GrenadeMotionStatus::ready, velocity};
    }
};

// Reference de084..de0bc is a 28-step LOCAL quadratic prediction. -490 is
// a reference display constant, not a read or a claim about target gravity.
inline bool referenceGrenadePrediction(Vec3 position, Vec3 velocity, float remaining,
                                        unsigned step, Vec3 *output) {
    if (!output) return false;
    *output = {};
    if (!std::isfinite(remaining) || remaining <= 0 || remaining > 10 || step < 1 || step > 28 ||
        !std::isfinite(position.x) || !std::isfinite(position.y) || !std::isfinite(position.z) ||
        !std::isfinite(velocity.x) || !std::isfinite(velocity.y) || !std::isfinite(velocity.z)) return false;
    const float time = std::min(remaining, 2.0f) * (static_cast<float>(step) / 28.0f);
    const Vec3 result = {std::fma(velocity.x, time, position.x), std::fma(velocity.y, time, position.y),
        std::fma(-490.0f * time, time, std::fma(velocity.z, time, position.z))};
    if (!std::isfinite(result.x) || !std::isfinite(result.y) || !std::isfinite(result.z) ||
        std::fabs(result.x) >= 1.0e9f || std::fabs(result.y) >= 1.0e9f || std::fabs(result.z) >= 1.0e9f) return false;
    *output = result;
    return true;
}

} // namespace CoreSet
