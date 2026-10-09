#pragma once

#include <cstdint>

namespace CoreSet {

struct BoneArrayState {
    uint64_t data = 0;
    int32_t count = 0;
    int32_t capacity = 0;
};
static_assert(sizeof(BoneArrayState) == 0x10, "TArray header size");

// Core v1.7 0x1000e35f8..0x1000e3630 accepts the transform TArray's
// allocation count when Num is zero. Keep the delivered read length bounded
// while preserving that exact zero-Num selection rule.
inline bool normalizeBoneArray(BoneArrayState *array, bool *usedCapacity = nullptr) {
    if (usedCapacity) *usedCapacity = false;
    if (!array || array->data < 0x100000000ULL ||
        array->data > 0x8000000000ULL - 256 * 0x30) return false;
    if (array->count < 0 || array->count > 256 || array->capacity < 1) return false;
    const int32_t effective = array->count == 0 ? array->capacity : array->count;
    if (effective < 6 || effective > 256 || array->capacity < effective) return false;
    if (usedCapacity) *usedCapacity = array->count == 0;
    array->count = effective;
    return true;
}

} // namespace CoreSet
