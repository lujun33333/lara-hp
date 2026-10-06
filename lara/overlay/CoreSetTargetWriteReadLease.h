#pragma once
#include <cstdint>

namespace CoreSet {
// This lease belongs to the writer's independent reader, not the snapshot owner.
struct TargetWriteReadLease {
    int32_t pid;
    uint64_t imageBase;
    uint64_t generation;

    bool matches(bool ready, int32_t observedPID, uint64_t observedBase,
                 uint64_t observedGeneration) const {
        return ready && pid > 0 && imageBase != 0 && generation != 0 &&
               observedPID == pid && observedBase == imageBase &&
               observedGeneration == generation;
    }
};
} // namespace CoreSet
