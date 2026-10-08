#pragma once

#include <cmath>
#include <cstdint>
#include <cstring>

namespace CoreSet {

enum class WarningYawSource : uint8_t { none = 0, serverControlRotation = 1, replicatedMovement = 2 };
struct WarningYawSelection {
    bool valid = false;
    double degrees = 0;
    WarningYawSource source = WarningYawSource::none;
};

inline bool warningYawRawValid(uint32_t raw, float *output = nullptr) {
    float value = 0;
    static_assert(sizeof(value) == sizeof(raw), "target yaw is a four-byte float");
    std::memcpy(&value, &raw, sizeof(value));
    if (output) *output = value;
    return std::isfinite(value) && std::fabs(value) <= 360.0f;
}

// Core da864..daa54: primary first, fallback only for an invalid value, then
// fmod(yaw + 180, 360) into [-180, 180). The caller rejects transport failures.
// Target fallback is Actor.ReplicatedMovement(+168).Rotation(+24).Yaw(+4).
inline WarningYawSelection selectWarningYaw(uint32_t primary, bool fallbackPresent,
                                            uint32_t fallback) {
    float value = 0;
    WarningYawSource source = WarningYawSource::serverControlRotation;
    if (!warningYawRawValid(primary, &value)) {
        if (!fallbackPresent || !warningYawRawValid(fallback, &value)) return {};
        source = WarningYawSource::replicatedMovement;
    }
    double degrees = std::fmod(double(value) + 180.0, 360.0);
    if (degrees < 0) degrees += 360.0;
    return {true, degrees - 180.0, source};
}

// Core db8dc..db958: atan2(cameraY-actorY, cameraX-actorX), normalize
// against the selected actor yaw, then accept a difference of at most 4°.
inline bool warningAngleMatches(double cameraMinusActorX, double cameraMinusActorY,
                                double serverYawDegrees) {
    if (!std::isfinite(cameraMinusActorX) || !std::isfinite(cameraMinusActorY) ||
        !std::isfinite(serverYawDegrees) || std::fabs(serverYawDegrees) > 360.0 ||
        (cameraMinusActorX == 0.0 && cameraMinusActorY == 0.0)) return false;
    constexpr double radiansToDegrees = 57.2957795130823208768;
    const double bearing = std::atan2(cameraMinusActorY, cameraMinusActorX) * radiansToDegrees;
    const double delta = std::remainder(bearing - serverYawDegrees, 360.0);
    return std::isfinite(delta) && std::fabs(delta) <= 4.0;
}

} // namespace CoreSet
