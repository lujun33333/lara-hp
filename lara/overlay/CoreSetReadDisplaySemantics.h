#pragma once

#include <cmath>
#include <cstdint>
#include <limits>
#include <string>

namespace CoreSet {

// Core v1.7 dc80c uses fcvtzs for player distance; db9ec/db820 use
// fcvtas for warning/radar distance. Input is already game units / 100.
inline bool displayDistanceMeters(double distance, bool nearest, int32_t *output) {
    if (!output) return false;
    *output = 0;
    if (!std::isfinite(distance) || distance < 0 ||
        distance > double(std::numeric_limits<int32_t>::max()) - 0.5) return false;
    *output = static_cast<int32_t>(nearest ? std::round(distance) : std::trunc(distance));
    return true;
}

inline std::string referencePlayerDistanceText(double distance) {
    int32_t meters = 0;
    if (!displayDistanceMeters(distance, false, &meters)) return {};
    return std::to_string(meters) + " 米";
}

// The target name/weapon values must have passed the collector's same-frame
// reread. This reproduces the reference text, not its ImGui badge geometry.
// db9a4 fallback, dd944 name lookup, dd9b8 valid unknown ID, dda54/dda7c suffix.
inline std::string referenceWarningText(const char *playerName, bool bot,
                                         const char *weaponName, uint32_t weaponID,
                                         double distance) {
    int32_t meters = 0;
    if (!displayDistanceMeters(distance, true, &meters)) return {};
    std::string result = playerName && *playerName ? playerName : (bot ? "人机" : "未知玩家");
    if (weaponName && *weaponName) {
        result += " 使用 ";
        result += weaponName;
        result += " 瞄准您";
    } else if (weaponID >= 1 && weaponID <= 9999999) {
        result += " 使用 未知武器(" + std::to_string(weaponID) + ") 瞄准您";
    } else {
        result += " 正在瞄准您";
    }
    return result + " " + std::to_string(meters) + "m";
}

} // namespace CoreSet
