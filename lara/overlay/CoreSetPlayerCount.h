#pragma once

#include <cmath>
#include <cstdint>

namespace CoreSet {

// Target ECharacterHealthStatus: 0 HealthyAlive, 1 HasLastBreath,
// 2 ZombieState, 3 WaitingForRevival, 4 FinishedLastBreath, 5 MAX.
// Core excludes state 4 before its health gate, which accepts zero. Keep the
// zero-health extension narrow: only the independently named last-breath state.
inline bool playerCountEligible(float health, float maximum, uint8_t status) {
    if (!std::isfinite(health) || !std::isfinite(maximum) || maximum <= 0 ||
        health < 0 || health > maximum || status >= 4) return false;
    return health > 0 || status == 1;
}

} // namespace CoreSet
