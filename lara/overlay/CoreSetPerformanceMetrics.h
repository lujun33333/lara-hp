#pragma once
#include <atomic>
#include <cmath>
#include <cstdint>

namespace CoreSetPerformanceMetrics {
// Reference primary CPU is Float32 sum(cpu_usage / 1000 * 100), not the
// independent RUSAGE interval fallback. Idle threads contribute nothing.
inline bool accumulateThread(std::int32_t cpuUsage, bool idle, float &sum) {
    if (idle) return true;
    if (cpuUsage < 0 || !std::isfinite(sum) || sum < 0) return false;
    sum = std::fma(static_cast<float>(cpuUsage) / 1000.0f, 100.0f, sum);
    return std::isfinite(sum) && sum >= 0;
}
inline float footprintMiB(std::uint64_t bytes) {
    return static_cast<float>(bytes) / (1024.0f * 1024.0f);
}
inline bool updatePeak(float observed, std::atomic<float> &peak) {
    if (!std::isfinite(observed) || observed < 0) return false;
    float previous = peak.load(std::memory_order_acquire);
    if (!std::isfinite(previous) || previous < 0) return false;
    while (observed > previous && !peak.compare_exchange_weak(previous, observed,
           std::memory_order_acq_rel, std::memory_order_acquire)) {
        if (!std::isfinite(previous) || previous < 0) return false;
    }
    return true;
}
}
