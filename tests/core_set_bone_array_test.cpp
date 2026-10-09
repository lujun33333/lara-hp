#include "../lara/overlay/CoreSetBoneArray.h"

#include <cassert>
#include <cstdio>
#include <initializer_list>

int main() {
    bool recovered = true;
    CoreSet::BoneArrayState ordinary{0x120000000ULL, 61, 61};
    assert(CoreSet::normalizeBoneArray(&ordinary, &recovered));
    assert(ordinary.count == 61 && !recovered);

    CoreSet::BoneArrayState coreZeroNum{0x120000000ULL, 0, 73};
    assert(CoreSet::normalizeBoneArray(&coreZeroNum, &recovered));
    assert(coreZeroNum.count == 73 && recovered);

    CoreSet::BoneArrayState largeAllocation{0x120000000ULL, 61, 512};
    assert(CoreSet::normalizeBoneArray(&largeAllocation, &recovered));
    assert(largeAllocation.count == 61 && !recovered);

    for (CoreSet::BoneArrayState invalid : {
             CoreSet::BoneArrayState{0, 61, 61},
             CoreSet::BoneArrayState{0x120000000ULL, -1, 61},
             CoreSet::BoneArrayState{0x120000000ULL, 257, 257},
             CoreSet::BoneArrayState{0x120000000ULL, 61, 60},
             CoreSet::BoneArrayState{0x120000000ULL, 0, 5},
             CoreSet::BoneArrayState{0x120000000ULL, 0, 512},
         }) {
        recovered = true;
        assert(!CoreSet::normalizeBoneArray(&invalid, &recovered));
        assert(!recovered);
    }
    assert(!CoreSet::normalizeBoneArray(nullptr));
    std::puts("PASS: Core zero-Num bone array normalization and bounds");
}
