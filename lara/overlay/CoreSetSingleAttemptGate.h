#pragma once
#include "CoreSetActionAuthorityGate.h"
#include <cmath>

namespace CoreSet {
// Independent from kernel capability. One explicit attempt, including failure.
// The owner serializes calls; stopping must also revoke the live validator.
class SingleAttemptGate {
public:
    bool begin(const ActionContext &captured, const ActionContext &live,
               double capturedAt, double now) {
        if (spent_ || stopped_) return false;
        spent_ = true;
        capturedAt_ = capturedAt;
        return fresh(now) && authority_.issue(captured, live);
    }
    bool authorizes(const ActionContext &requested, const ActionContext &live,
                    double now) const {
        return !stopped_ && fresh(now) && authority_.authorizes(requested, live);
    }
    void finish() { authority_.revoke(); }
    void stop() { stopped_ = true; authority_.revoke(); }
    bool spent() const { return spent_; }
private:
    bool fresh(double now) const {
        return std::isfinite(now) && std::isfinite(capturedAt_) &&
               capturedAt_ > 0 && now >= capturedAt_ && now - capturedAt_ <= 0.5;
    }
    ActionAuthorityGate authority_;
    double capturedAt_ = 0;
    bool spent_ = false;
    bool stopped_ = false;
};
}
