#pragma once

#include <cmath>
#include <cstdint>

namespace CoreSet {

struct VehiclePercent {
    bool valid = false;
    uint32_t value = 0;
};

// Core dabc4..dafb0: a finite current/max pair may be at most 2x max;
// the displayed ratio is clamped to 100 and rounded to the nearest integer.
inline VehiclePercent vehiclePercent(float current, float maximum, bool health) {
    const float floor = health ? 1.0f : 0.0f;
    if (!std::isfinite(current) || !std::isfinite(maximum) || maximum <= floor ||
        maximum >= 10000000.0f ||
        current < 0.0f || current > maximum * 2.0f) return {};
    const float percent = std::fmin(100.0f, (current / maximum) * 100.0f);
    return {true, static_cast<uint32_t>(std::lround(percent))};
}

} // namespace CoreSet
