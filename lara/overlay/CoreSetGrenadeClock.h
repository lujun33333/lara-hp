#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace CoreSet {

// Target EliteProjectile helper f124..f18c uses GameStateBase server time:
// float(world double + delta float), then clamps remaining time to 0..10.
// Core's warning input accepts only (0,30]. Missing fields never default to 10.
inline bool grenadeCountdownSeconds(float explosionTime, double worldTime,
                                      float serverDelta, uint8_t flags, float *output) {
    if (!output) return false;
    *output = 0;
    if (!(flags & 8) || (flags & 4) || !std::isfinite(explosionTime) ||
        !std::isfinite(worldTime) || !std::isfinite(serverDelta) ||
        explosionTime <= 0 || worldTime < 0 || worldTime > 1.0e9 ||
        std::fabs(serverDelta) > 1.0e9f) return false;
    const float serverTime = static_cast<float>(worldTime + serverDelta);
    const float remaining = explosionTime - serverTime;
    if (!std::isfinite(serverTime) || !std::isfinite(remaining) ||
        remaining <= 0 || remaining > 30) return false;
    *output = std::min(remaining, 10.0f);
    return true;
}

} // namespace CoreSet
