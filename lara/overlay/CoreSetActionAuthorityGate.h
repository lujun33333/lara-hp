#pragma once

#include <array>
#include <cstdint>

namespace CoreSet {

// A single-use action context, not a target-memory capability. Every field is
// captured by the coordinator from one request and one complete snapshot.
struct ActionContext {
    int32_t pid = 0;
    uint64_t imageBase = 0;
    uint64_t readGeneration = 0;
    uint64_t controller = 0;
    uint64_t hostGeneration = 0;
    uint64_t configRevision = 0;
    std::array<uint8_t, 16> requestToken{};
    std::array<uint8_t, 16> snapshotID{};
    uint8_t lane = 0;
    uint8_t slot = 0;
    uint8_t axis = 0;
};

inline bool completeActionContext(const ActionContext &value) {
    return value.pid > 0 && value.imageBase && value.readGeneration &&
           value.controller && value.hostGeneration && value.configRevision &&
           value.requestToken != std::array<uint8_t, 16>{} &&
           value.snapshotID != std::array<uint8_t, 16>{} &&
           (value.lane == 1 || value.lane == 2) &&
           (value.slot == 1 || value.slot == 2) &&
           (value.axis >= 1 && value.axis <= 3);
}

class ActionAuthorityGate {
public:
    bool issue(const ActionContext &requested, const ActionContext &live) {
        revoke();
        if (!completeActionContext(requested) || !same(requested, live)) return false;
        lease_ = requested;
        active_ = true;
        return true;
    }

    bool authorizes(const ActionContext &requested, const ActionContext &live) const {
        return active_ && same(lease_, requested) && same(lease_, live);
    }

    void revoke() {
        active_ = false;
        lease_ = {};
        if (epoch_ != UINT64_MAX) ++epoch_;
    }

    bool active() const { return active_; }
    uint64_t epoch() const { return epoch_; }

private:
    static bool same(const ActionContext &left, const ActionContext &right) {
        return left.pid == right.pid && left.imageBase == right.imageBase &&
               left.readGeneration == right.readGeneration &&
               left.controller == right.controller &&
               left.hostGeneration == right.hostGeneration &&
               left.configRevision == right.configRevision &&
               left.requestToken == right.requestToken &&
               left.snapshotID == right.snapshotID && left.lane == right.lane &&
               left.slot == right.slot && left.axis == right.axis;
    }

    ActionContext lease_{};
    uint64_t epoch_ = 1;
    bool active_ = false;
};

} // namespace CoreSet
