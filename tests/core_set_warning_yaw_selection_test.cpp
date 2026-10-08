#include "../lara/overlay/CoreSetWarningProjection.h"
#include <cassert>
#include <cstdio>
#include <cstring>
#include <limits>
#include <initializer_list>

static uint32_t raw(float value) {
    uint32_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    return bits;
}

int main() {
    using namespace CoreSet;
    const uint32_t nan = raw(std::numeric_limits<float>::quiet_NaN());
    auto selected = selectWarningYaw(raw(90), true, raw(-90));
    assert(selected.valid && selected.degrees == 90 && selected.source == WarningYawSource::serverControlRotation);
    selected = selectWarningYaw(nan, true, raw(90));
    assert(selected.valid && selected.degrees == 90 && selected.source == WarningYawSource::replicatedMovement);
    assert(warningAngleMatches(0, 100, selected.degrees));
    for (float invalid : {361.0f, -361.0f, std::numeric_limits<float>::infinity(),
                           std::numeric_limits<float>::quiet_NaN()}) {
        selected = selectWarningYaw(raw(invalid), false, raw(90));
        assert(!selected.valid && selected.source == WarningYawSource::none && selected.degrees == 0);
        selected = selectWarningYaw(nan, true, raw(invalid));
        assert(!selected.valid && selected.source == WarningYawSource::none);
    }
    for (float boundary : {-360.0f, -180.0f, 0.0f, 180.0f, 360.0f}) {
        selected = selectWarningYaw(raw(boundary), false, 0);
        assert(selected.valid && selected.degrees >= -180 && selected.degrees < 180);
        assert(warningAngleMatches(-100, 0, selectWarningYaw(raw(180), false, 0).degrees));
    }
    assert(selectWarningYaw(raw(180), false, 0).degrees == -180);
    assert(selectWarningYaw(raw(360), false, 0).degrees == 0);
    assert(!warningAngleMatches(0, 0, 0));
    std::puts("PASS: production yaw selector, primary precedence, reflected fallback, normalization and invalid input rejection");
}
