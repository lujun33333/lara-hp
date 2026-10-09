#pragma once

#include "CoreSetActionAuthorityGate.h"
#include <cmath>

namespace CoreSet {

// Reusable serial-worker authority. Each begin/finish pair owns exactly one
// current snapshot, while the worker and its mapped write session remain alive
// until stop. This mirrors Core's persistent c1a04 action worker lifetime.
class SerialActionGate {
public:
    bool begin(const ActionContext &captured, const ActionContext &live,
               double capturedAt, double now) {
        if (inFlight_ || stopped_ ||
            (hasLastSnapshot_ && (captured.snapshotID == lastSnapshot_ || capturedAt <= lastCapturedAt_))) return false;
        inFlight_ = true;
        capturedAt_ = capturedAt;
        if (!fresh(now) || !authority_.issue(captured, live)) {
            inFlight_ = false;
            authority_.revoke();
            return false;
        }
        lastSnapshot_ = captured.snapshotID;
        lastCapturedAt_ = capturedAt;
        hasLastSnapshot_ = true;
        return true;
    }
    bool authorizes(const ActionContext &requested, const ActionContext &live,
                    double now) const {
        return inFlight_ && !stopped_ && fresh(now) &&
            authority_.authorizes(requested, live);
    }
    void finish() { authority_.revoke(); inFlight_ = false; }
    void stop() { stopped_ = true; authority_.revoke(); inFlight_ = false; }
    bool inFlight() const { return inFlight_; }
    bool stopped() const { return stopped_; }
private:
    bool fresh(double now) const {
        return std::isfinite(now) && std::isfinite(capturedAt_) &&
               capturedAt_ > 0 && now >= capturedAt_ && now - capturedAt_ <= 0.5;
    }
    ActionAuthorityGate authority_;
    double capturedAt_ = 0;
    bool inFlight_ = false;
    bool stopped_ = false;
    std::array<uint8_t, 16> lastSnapshot_{};
    double lastCapturedAt_ = 0;
    bool hasLastSnapshot_ = false;
};

} // namespace CoreSet
