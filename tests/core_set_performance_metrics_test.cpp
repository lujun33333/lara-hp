#include "../lara/overlay/CoreSetPerformanceMetrics.h"
#include <cassert>
#include <limits>
#include <thread>

int main() {
    using namespace CoreSetPerformanceMetrics;
    float cpu = 0;
    assert(accumulateThread(1000, false, cpu) && cpu == 100);
    assert(accumulateThread(500, false, cpu) && cpu == 150); // Multi-core >100 is valid.
    assert(accumulateThread(1000, true, cpu) && cpu == 150);
    assert(!accumulateThread(-1, false, cpu) && cpu == 150);
    assert(accumulateThread(-1, true, cpu) && cpu == 150); // Idle fields are ignored.
    float invalid = std::numeric_limits<float>::quiet_NaN();
    assert(!accumulateThread(1, false, invalid));
    float zero = 0;
    assert(accumulateThread(0, false, zero) && zero == 0);
    assert(footprintMiB(0) == 0);
    assert(footprintMiB(1048576) == 1);
    assert(footprintMiB(1572864) == 1.5f);
    std::atomic<float> peak{0};
    assert(updatePeak(0, peak));
    assert(updatePeak(64, peak) && peak.load() == 64);
    assert(updatePeak(32, peak) && peak.load() == 64);
    assert(!updatePeak(-1, peak) && peak.load() == 64);
    assert(!updatePeak(std::numeric_limits<float>::infinity(), peak));
    std::thread first([&] { for (int i = 0; i <= 127; ++i) assert(updatePeak(static_cast<float>(i), peak)); });
    std::thread second([&] { for (int i = 0; i <= 256; ++i) assert(updatePeak(static_cast<float>(i), peak)); });
    first.join(); second.join();
    assert(peak.load() == 256);
    peak.store(std::numeric_limits<float>::quiet_NaN());
    assert(!updatePeak(1, peak));
    // PID reset is explicit in the sampler, not an accidental low-value update.
    peak.store(0);
    assert(updatePeak(1, peak) && peak.load() == 1);
}
