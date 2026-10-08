#pragma once

#include <cstdint>

namespace CoreSet {

// Core d8a04..d8ba8 selects these bone-count profiles and takes row[0]
// as its top anchor. Unknown profiles do not inherit a guessed head index.
inline bool referenceBoneHeadIndex(int32_t count, uint8_t *index) {
    if (!index) return false;
    *index = 0;
    if (count == 70 || count == 71) { *index = 28; return true; }
    if (count == 61 || count == 63 || count == 64 || count == 65 ||
        count == 66 || count == 72 || count == 73 || count == 95) {
        *index = 6; return true;
    }
    return false;
}

} // namespace CoreSet
