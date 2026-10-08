#include "../lara/overlay/CoreSetPlayerCount.h"
#include <cassert>
#include <cstdio>
#include <limits>

int main() {
    using CoreSet::playerCountEligible;
    assert(playerCountEligible(100, 100, 0));
    assert(playerCountEligible(10, 100, 1));
    assert(playerCountEligible(0, 100, 1));
    assert(!playerCountEligible(0, 100, 0));
    assert(!playerCountEligible(0, 100, 2));
    assert(!playerCountEligible(0, 100, 3));
    assert(!playerCountEligible(100, 100, 4));
    assert(!playerCountEligible(100, 100, 5));
    assert(!playerCountEligible(100, 100, 255));
    assert(!playerCountEligible(-1, 100, 1));
    assert(!playerCountEligible(101, 100, 1));
    assert(!playerCountEligible(0, 0, 1));
    assert(!playerCountEligible(std::numeric_limits<float>::quiet_NaN(), 100, 1));
    assert(!playerCountEligible(10, std::numeric_limits<float>::infinity(), 1));
    std::puts("PASS: production count helper, last-breath zero health only, completed/sentinel and invalid fields rejected");
}
