#pragma once
#include <stdbool.h>
#include <stdint.h>

// Actual MTLDrawable.presentedTime observations, never requested scheduler FPS.
typedef struct CoreSetPresentationCadenceSample {
    bool valid;
    uint64_t adapterEpoch;
    uint64_t sampleCount;
    double framesPerSecond;
    double firstPresentedTime;
    double lastPresentedTime;
    double observedHostTime;
} CoreSetPresentationCadenceSample;

#ifdef __cplusplus
#include <array>
#include <cmath>
#include <cstddef>
namespace CoreSetPresentationCadence {
class Window {
    std::array<double, 128> times_{};
    std::size_t count_ = 0;
    uint64_t epoch_ = 1;
public:
    uint64_t epoch() const { return epoch_; }
    void reset() { count_ = 0; if (++epoch_ == 0) epoch_ = 1; }
    bool accept(uint64_t epoch, double presented, double now) {
        if (epoch != epoch_ || !std::isfinite(presented) || presented <= 0 ||
            !std::isfinite(now) || now < presented || now - presented > .5 ||
            (count_ && presented <= times_[count_ - 1])) return false;
        std::size_t expired = 0;
        while (expired < count_ && presented - times_[expired] > 2) ++expired;
        if (expired) {
            for (std::size_t i = expired; i < count_; ++i) times_[i - expired] = times_[i];
            count_ -= expired;
        }
        if (count_ == times_.size()) {
            for (std::size_t i = 1; i < count_; ++i) times_[i - 1] = times_[i];
            --count_;
        }
        times_[count_++] = presented;
        return true;
    }
    CoreSetPresentationCadenceSample observe(double now) const {
        CoreSetPresentationCadenceSample result{};
        result.adapterEpoch = epoch_; result.sampleCount = count_; result.observedHostTime = now;
        if (count_) { result.firstPresentedTime = times_[0]; result.lastPresentedTime = times_[count_ - 1]; }
        if (count_ < 4 || !std::isfinite(now) || now < result.lastPresentedTime ||
            now - result.lastPresentedTime > .5) return result;
        const double duration = result.lastPresentedTime - result.firstPresentedTime;
        if (!(duration >= .05 && duration <= 2)) return result;
        const double rate = static_cast<double>(count_ - 1) / duration;
        if (!std::isfinite(rate) || rate <= 0 || rate > 1000) return result;
        result.framesPerSecond = rate; result.valid = true;
        return result;
    }
};
}
#endif
