#include "../lara/overlay/CoreSetGrenadeClock.h"
#include <cassert>
#include <cstdio>
#include <limits>
#include <initializer_list>

int main() {
    using CoreSet::grenadeCountdownSeconds;
    float value = 42;
    assert(grenadeCountdownSeconds(107.5f, 100.0, 2.0f, 8, &value) && value == 5.5f);
    assert(grenadeCountdownSeconds(120, 100, 0, 8, &value) && value == 10);
    assert(grenadeCountdownSeconds(130, 100, 0, 8, &value) && value == 10);
    assert(!grenadeCountdownSeconds(131, 100, 0, 8, &value) && value == 0);
    assert(!grenadeCountdownSeconds(100, 100, 0, 8, &value) && value == 0);
    assert(!grenadeCountdownSeconds(99, 100, 0, 8, &value) && value == 0);
    assert(!grenadeCountdownSeconds(105, 100, 0, 0, &value) && value == 0);
    assert(!grenadeCountdownSeconds(105, 100, 0, 12, &value) && value == 0);
    assert(!grenadeCountdownSeconds(0, 100, 0, 8, &value) && value == 0);
    assert(!grenadeCountdownSeconds(105, -1, 0, 8, &value) && value == 0);
    assert(!grenadeCountdownSeconds(105, 100, 0, 8, nullptr));
    for (float bad : {std::numeric_limits<float>::quiet_NaN(), std::numeric_limits<float>::infinity()}) {
        assert(!grenadeCountdownSeconds(bad, 100, 0, 8, &value) && value == 0);
        assert(!grenadeCountdownSeconds(105, 100, bad, 8, &value) && value == 0);
        assert(!grenadeCountdownSeconds(105, bad, 0, 8, &value) && value == 0);
    }
    std::puts("PASS: production target clock arithmetic, clamp, expiry, explosion/valid bits and invalid value rejection");
}
