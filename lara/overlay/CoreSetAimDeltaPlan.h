#pragma once

#include <cmath>
#include <cstdint>

namespace CoreSet {

enum class ActionDeltaShape : uint8_t { none, pitchOnly, yawOnly, both };

struct AimDeltaPlan {
    float pitch = 0;  // c2e24 s9 = recoil s15 + aim s13
    float yaw = 0;    // c2e28 s11 = recoil s14 + aim s12
    ActionDeltaShape shape = ActionDeltaShape::none;
    static constexpr bool writeReady = false;
};

// This is the confirmed c2e24/c2e28 merge and c5b30/c5c20 width choice.
// Producers, scene/prediction timing, profile and authority are not modeled.
inline bool mergeAimRecoilDeltas(float aimPitch, float aimYaw,
                                 float recoilPitch, float recoilYaw,
                                 AimDeltaPlan *out) {
    if (!out || !std::isfinite(aimPitch) || !std::isfinite(aimYaw) ||
        !std::isfinite(recoilPitch) || !std::isfinite(recoilYaw)) return false;
    const float pitch = recoilPitch + aimPitch;
    const float yaw = recoilYaw + aimYaw;
    if (!std::isfinite(pitch) || !std::isfinite(yaw)) return false;
    const bool first = pitch != 0;
    const bool second = yaw != 0;
    const ActionDeltaShape shape = first && second ? ActionDeltaShape::both :
        (first ? ActionDeltaShape::pitchOnly :
         (second ? ActionDeltaShape::yawOnly : ActionDeltaShape::none));
    *out = {pitch, yaw, shape};
    return true;
}

} // namespace CoreSet
