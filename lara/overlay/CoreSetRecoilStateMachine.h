#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace CoreSet {

// Core c571c's local state fields only. This is not a target-game object.
struct RecoilRawState {
    uint16_t mode = 0;          // local +0: 0, 1, or paused 0x100
    uint64_t sampleKey = 0;     // local +8: geometry-result float bit pattern
    uint32_t binding = 0;       // local +0x10: caller's snapshot binding value
    uint32_t positiveFrames = 0;// local +0x14
    float angle = 0;            // local +0x18
    float pausedAngle = 0;      // local +0x1c
    float accumulator = 0;      // local +0x20
};

struct RecoilRawInput {
    bool firing = false;        // c2318 / sp+0x40, Core index 39
    bool readValid = false;     // prior c4554 result at state+0x37
    uint64_t sampleKey = 0;    // previously staged c4af8 +8 bits, not actor ID
    uint32_t binding = 0;      // sp+0x44
    float currentPitch = 0;    // prior controller+0x620 sample, state+0xb8
    float priorAimPitch = 0;   // prior s13 or zero, state+0xa4
    float strength01 = 0;      // caller's fixed config+0, not a write command
};

struct RecoilRawResult {
    uint16_t status = 0;       // c571c local result+0
    uint8_t contextFlag = 0;   // local result+2
    uint8_t resetFlag = 0;     // local result+3
    float angle = 0;           // local result+4
    float filteredDelta = 0;   // local result+8
    float feedforward = 0;     // local result+0xc
    float accumulator = 0;     // local result+0x10; c2cf4 consumes this
    float combined = 0;        // local result+0x14
    static constexpr bool writeReady = false;
};

inline float recoilRemainder(float value) {
    if (!std::isfinite(value)) return NAN;
    const float reduced = std::remainder(value, 360.0f);
    return reduced == -180.0f ? 180.0f : reduced;
}

// Models only the single confirmed c2cd8 -> c571c call site and its raw
// state/result, including the constant config [.72,.08,1.5,1.25,.005,.2,3].
// Corrupt prior state is rejected more strictly than Core's reset branches.
// No caller merge, scene timing, target write, or stop restoration is implied.
inline bool stepRecoilRawState(RecoilRawState *state, const RecoilRawInput &input,
                               RecoilRawResult *out) {
    if (!state || !out) return false;
    *out = {};
    const auto reject = [&]() { *state = {}; *out = {}; return false; };
    if (!input.sampleKey || !input.binding || !input.readValid ||
        !std::isfinite(input.currentPitch) || !std::isfinite(input.priorAimPitch) ||
        !std::isfinite(input.strength01) || input.strength01 < 0 ||
        input.strength01 > 1 || !std::isfinite(state->accumulator) ||
        state->positiveFrames >= 3) return reject();

    const bool changed = state->sampleKey != input.sampleKey ||
                         state->binding != input.binding;
    if (!input.firing) {
        const float angle = recoilRemainder(input.currentPitch);
        if (!std::isfinite(angle)) return reject();
        state->mode = 0x100;
        state->sampleKey = input.sampleKey;
        state->binding = input.binding;
        state->positiveFrames = 0;
        state->angle = angle;
        state->pausedAngle = angle;
        state->accumulator = 0;
        out->status = 1;
        out->resetFlag = changed ? 1 : 0;
        out->angle = angle;
        return true;
    }

    const bool newContext = changed || !(state->mode & 1);
    bool pausedReuse = false;
    float base = 0;
    if (newContext) {
        pausedReuse = !changed && (state->mode & 0x100);
        base = pausedReuse ? state->pausedAngle : recoilRemainder(input.currentPitch);
        state->mode = 1;
        state->sampleKey = input.sampleKey;
        state->binding = input.binding;
        state->positiveFrames = 0;
        state->accumulator = 0;
        // c5820..c5864 does not update local +1c on a fresh firing context.
        // Only the non-firing c58c8 path records pausedAngle for later reuse.
    } else {
        base = state->angle;
    }
    if (!std::isfinite(base)) return reject();
    const float angle = recoilRemainder(base + input.priorAimPitch);
    if (!std::isfinite(angle)) return reject();
    state->angle = angle;
    out->status = 0x101;
    out->contextFlag = newContext ? 1 : 0;
    out->resetFlag = changed ? 1 : 0;
    out->angle = angle;
    if (newContext && !pausedReuse) return true;

    const float delta = recoilRemainder(angle - input.currentPitch);
    if (!std::isfinite(delta)) return reject();
    if (delta > 0.2f) {
        ++state->positiveFrames;
        if (state->positiveFrames >= 3) {
            const float resetAngle = recoilRemainder(input.currentPitch);
            if (!std::isfinite(resetAngle)) return reject();
            state->angle = resetAngle;
            state->positiveFrames = 0;
            state->accumulator = 0;
            out->angle = resetAngle;
            return true;
        }
    } else {
        state->positiveFrames = 0;
    }
    const float filtered = std::fabs(delta) > 0.005f ? delta : 0.0f;
    // Preserve c5a74/c5a7c's multiplication order and fused round-to-f32.
    const float integral = std::fma(filtered, input.strength01 * 0.08f, state->accumulator);
    const float accumulator = std::clamp(integral, -1.25f * input.strength01, 0.0f);
    const float feedforward = filtered * (0.72f * input.strength01);
    const float combined = std::clamp(feedforward + accumulator,
                                      -1.5f * input.strength01, 0.0f);
    if (!std::isfinite(filtered) || !std::isfinite(accumulator) ||
        !std::isfinite(feedforward) || !std::isfinite(combined)) return reject();
    state->accumulator = accumulator;
    out->filteredDelta = filtered;
    out->feedforward = feedforward;
    out->accumulator = accumulator;
    out->combined = combined;
    return true;
}

} // namespace CoreSet
