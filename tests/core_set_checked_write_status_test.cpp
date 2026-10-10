#include "../lara/overlay/CoreSetCheckedWriteStatus.h"

#include <cassert>
#include <cstdio>

using namespace CoreSet;

int main() {
    static_assert(referencePackCheckedWriteStatus(0, 1, 0, 0, 0) == 0);
    static_assert(referencePackCheckedWriteStatus(0, 1, 1, 1, 0) ==
                  (uint64_t(1) | (uint64_t(1) << 32)));
    static_assert(referencePackCheckedWriteStatus(0, 4, 1, 0, 1) ==
                  (uint64_t(5) | (uint64_t(1) << 32)));
    static_assert(referencePackCheckedWriteStatus(1, 4, 1, 0, 0) == 2);
    static_assert(referencePackCheckedWriteStatus(1, 4, 1, 0, 1) ==
                  (uint64_t(4) | (uint64_t(1) << 32)));
    static_assert(referencePackCheckedWriteStatus(2, 8, 1, 0, 4) ==
                  (uint64_t(4) | (uint64_t(4) << 32)));
    static_assert(referencePackCheckedWriteStatus(3, 8, 1, 0, 0) == 5);
    static_assert(checkedWriteRawStatus(referencePackCheckedWriteStatus(0, 8, 5, 5, 0)) == 1);
    static_assert(checkedWriteProgress(referencePackCheckedWriteStatus(0, 8, 5, 5, 0)) == 5);
    assert(referencePackCheckedWriteStatus(0, 3, 1, 1, 0) == 0);
    std::puts("PASS: Core 0x100063150 packed raw/progress contract");
}
