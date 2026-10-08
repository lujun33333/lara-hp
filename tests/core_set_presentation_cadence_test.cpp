#include "../lara/overlay/CoreSetPresentationCadence.h"
#include <cassert>
#include <cmath>
#include <limits>

int main() {
    CoreSetPresentationCadence::Window window;
    const uint64_t firstEpoch = window.epoch();
    assert(!window.observe(10).valid);
    assert(!window.accept(firstEpoch, 0, 10)); // Dropped/unpresented drawable.
    assert(!window.accept(firstEpoch, 11, 10));
    assert(!window.accept(firstEpoch, 9, 10));
    assert(!window.accept(firstEpoch, std::numeric_limits<double>::quiet_NaN(), 10));
    for (int i = 0; i < 8; ++i) {
        const double time = 10 + static_cast<double>(i) / 60;
        assert(window.accept(firstEpoch, time, time + .001));
    }
    const auto sample = window.observe(10.12);
    assert(sample.valid && sample.sampleCount == 8);
    assert(std::fabs(sample.framesPerSecond - 60) < .00001);
    assert(!window.accept(firstEpoch, sample.lastPresentedTime, 10.12));
    assert(!window.accept(firstEpoch, 10.05, 10.12)); // Callback reordering.
    assert(!window.observe(10.8).valid);
    assert(!window.observe(9).valid);
    window.reset();
    assert(window.epoch() != firstEpoch && !window.observe(10.12).valid);
    assert(!window.accept(firstEpoch, 10.12, 10.12)); // Previous owner callback.
    const auto nextEpoch = window.epoch();
    for (int i = 0; i < 300; ++i) {
        const double time = 20 + static_cast<double>(i) / 120;
        assert(window.accept(nextEpoch, time, time));
    }
    const auto highRate = window.observe(22.5);
    assert(highRate.valid && highRate.sampleCount == 128);
    assert(std::fabs(highRate.framesPerSecond - 120) < .00001);
    // One post-idle presentation cannot fabricate a new rate from old samples.
    assert(window.accept(nextEpoch, 30, 30));
    assert(!window.observe(30).valid);
    window.reset();
    assert(!window.observe(30).valid); // Hide/clear/detach/stop uses this path.
}
