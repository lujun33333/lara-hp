#include "../lara/overlay/CoreSetBoneHead.h"
#include <cassert>
#include <cstdio>
#include <initializer_list>

int main() {
    uint8_t index = 99;
    for (int count : {61, 63, 64, 65, 66, 72, 73, 95}) {
        assert(CoreSet::referenceBoneHeadIndex(count, &index) && index == 6);
    }
    for (int count : {70, 71}) {
        assert(CoreSet::referenceBoneHeadIndex(count, &index) && index == 28);
    }
    for (int count : {-1, 0, 5, 6, 60, 62, 67, 69, 74, 96, 256, 257}) {
        index = 99;
        assert(!CoreSet::referenceBoneHeadIndex(count, &index) && index == 0);
    }
    assert(!CoreSet::referenceBoneHeadIndex(61, nullptr));
    std::puts("PASS: reference head profiles, unknown/bounds/null fail closed");
}
