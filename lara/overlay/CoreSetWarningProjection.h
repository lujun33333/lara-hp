#pragma once

#include <cmath>

namespace CoreSet {

// Core db8dc..db958: atan2(cameraY-actorY, cameraX-actorX), normalize
// against the actor's server yaw, then accept a difference of at most 4°.
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
