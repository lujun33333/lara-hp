#pragma once

#include <cstdint>

namespace CoreSet {

// Exact portable port of Core v1.7 0x100063150. Names remain structural until
// every caller operand has a closed business meaning; the returned layout is
// proven: low 32 bits are the raw status consumed by c5ad8 and bits 32..39 are
// the packed progress byte. Higher bits are zero in this helper.
inline constexpr uint64_t referencePackCheckedWriteStatus(
    uint8_t mode, uint8_t requestLength, uint8_t produced,
    uint8_t prior, uint8_t tail) {
    if ((requestLength != 1 && requestLength != 4 && requestLength != 8) ||
        prior > produced || requestLength <= static_cast<uint8_t>(produced - 1))
        return 0;
    uint8_t progress = static_cast<uint8_t>(requestLength - produced);
    if (progress < tail) return 0;
    progress = static_cast<uint8_t>(tail + prior);
    uint32_t raw = 0;
    if (mode <= 1) {
        if (mode == 0) {
            raw = 1;
            const uint32_t noPrior = tail != 0 ? 5u : (prior == 0 ? 3u : 5u);
            const uint8_t noTailProgress = tail != 0 ? progress : prior;
            if (prior != produced) {
                progress = noTailProgress;
                raw = noPrior;
            }
        } else {
            raw = 5;
            if (prior == 0) {
                progress = tail;
                raw = tail == 0 ? 2u : 4u;
            }
        }
    } else {
        raw = 5;
        if (mode == 2) {
            if (prior == 0) {
                progress = tail;
                raw = tail == 0 ? 3u : 4u;
            }
        }
    }
    return uint64_t(raw) | (uint64_t(progress) << 32);
}

inline constexpr uint32_t checkedWriteRawStatus(uint64_t packed) {
    return static_cast<uint32_t>(packed);
}

inline constexpr uint8_t checkedWriteProgress(uint64_t packed) {
    return static_cast<uint8_t>(packed >> 32);
}

} // namespace CoreSet
