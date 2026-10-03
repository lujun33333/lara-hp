#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <mutex>

namespace CoreSet {

// Internal typed transaction gate, not a general-purpose UVA writer. Values
// are source-contract slots for build 15915; no profile or authority is shipped.
enum class TargetActionLane : uint8_t { aim = 1, recoil = 2 };
enum class TargetActionSlot : uint8_t { controlRotation = 1, rotationInput = 2 };
enum class TargetActionAxis : uint8_t { first = 1, second = 2, both = 3 };

struct ControlRotationLease {
    int32_t pid = -1;
    uint64_t imageBase = 0;
    uint64_t generation = 0;
    uint64_t controller = 0;
    std::array<uint8_t, 16> uuid{};
    std::array<uint8_t, 16> requestToken{};
    std::array<uint8_t, 16> snapshotID{};
    TargetActionLane lane = TargetActionLane::aim;
    TargetActionSlot slot = TargetActionSlot::controlRotation;
    TargetActionAxis axis = TargetActionAxis::both;
};

enum class ControlRotationWriteStatus {
    unavailable, invalidRequest, staleIdentity, oldReadFailed, oldMismatch,
    partialWrite, readbackFailed, readbackMismatch, committed, pendingCleanup
};

struct ControlRotationWriteResult {
    ControlRotationWriteStatus status = ControlRotationWriteStatus::unavailable;
    size_t completedBytes = 0;
    bool pending = false;
};

class ControlRotationWriteGate {
public:
    static constexpr uint64_t kOffset = 0x620;
    static constexpr size_t kSize = 8;
    static constexpr size_t kMaxSize = 8;
    static constexpr std::array<uint8_t, 16> kUUID = {
        0x34, 0xb7, 0x85, 0xb2, 0x0d, 0xab, 0x39, 0x92,
        0x98, 0x5d, 0x35, 0x9e, 0x6b, 0xf4, 0x55, 0x85
    };

    // NonAliasRead and MappedWrite must return the number of completed bytes.
    // Identity must independently confirm pid, map/task, UUID, generation,
    // controller, lane/slot/axis, requestToken and snapshotID on every call.
    // Four-byte requests require zero unused bytes in both fixed-size buffers.
    static constexpr bool shape(TargetActionSlot slot, TargetActionAxis axis,
                                uint64_t *offset, size_t *length) {
        if (!offset || !length) return false;
        uint64_t base = 0;
        switch (slot) {
        case TargetActionSlot::controlRotation: base = 0x620; break;
        case TargetActionSlot::rotationInput: base = 0x828; break;
        default: return false;
        }
        switch (axis) {
        case TargetActionAxis::first: *offset = base; *length = 4; return true;
        case TargetActionAxis::second: *offset = base + 4; *length = 4; return true;
        case TargetActionAxis::both: *offset = base; *length = 8; return true;
        default: return false;
        }
    }

    template <typename Identity, typename NonAliasRead, typename MappedWrite>
    ControlRotationWriteResult transact(const ControlRotationLease &lease,
                                        const std::array<uint8_t, kMaxSize> &expectedOld,
                                        const std::array<uint8_t, kMaxSize> &newValue,
                                        Identity identity, NonAliasRead read, MappedWrite write) {
        std::lock_guard<std::mutex> guard(mutex_);
        ControlRotationWriteResult result;
        if (stopped_ || pending_) { result.status = ControlRotationWriteStatus::pendingCleanup; result.pending = pending_; return result; }
        uint64_t offset = 0;
        size_t length = 0;
        if (!shape(lease.slot, lease.axis, &offset, &length) ||
            (lease.lane != TargetActionLane::aim && lease.lane != TargetActionLane::recoil)) {
            result.status = ControlRotationWriteStatus::invalidRequest; return result;
        }
        if (lease.pid <= 0 || !lease.imageBase || !lease.generation || !lease.controller ||
            lease.requestToken == std::array<uint8_t, 16>{} ||
            lease.snapshotID == std::array<uint8_t, 16>{} || lease.uuid != kUUID ||
            lease.controller > UINT64_MAX - offset - length ||
            lease.controller < 0x100000000ULL || lease.controller >= 0x8000000000ULL) {
            result.status = ControlRotationWriteStatus::invalidRequest; return result;
        }
        for (size_t index = length; index < kMaxSize; ++index) {
            if (expectedOld[index] || newValue[index]) {
                result.status = ControlRotationWriteStatus::invalidRequest; return result;
            }
        }
        const uint64_t address = lease.controller + offset;
        if (!identity(lease)) {
            pending_ = true; result.pending = true;
            result.status = ControlRotationWriteStatus::staleIdentity; return result;
        }
        std::array<uint8_t, kMaxSize> observed{};
        if (read(address, observed.data(), length) != length) {
            pending_ = true; result.pending = true;
            result.status = ControlRotationWriteStatus::oldReadFailed; return result;
        }
        if (!identity(lease)) {
            pending_ = true; result.pending = true;
            result.status = ControlRotationWriteStatus::staleIdentity; return result;
        }
        if (std::memcmp(observed.data(), expectedOld.data(), length) != 0) {
            result.status = ControlRotationWriteStatus::oldMismatch; return result;
        }
        result.completedBytes = write(address, newValue.data(), length);
        if (result.completedBytes != length) {
            pending_ = true; result.pending = true;
            result.status = ControlRotationWriteStatus::partialWrite; return result;
        }
        if (!identity(lease)) {
            pending_ = true; result.pending = true;
            result.status = ControlRotationWriteStatus::staleIdentity; return result;
        }
        observed.fill(0);
        if (read(address, observed.data(), length) != length) {
            pending_ = true; result.pending = true;
            result.status = ControlRotationWriteStatus::readbackFailed; return result;
        }
        const bool matchesNew = std::memcmp(observed.data(), newValue.data(), length) == 0;
        if (!identity(lease) || !matchesNew) {
            pending_ = true; result.pending = true;
            result.status = matchesNew ? ControlRotationWriteStatus::staleIdentity
                                       : ControlRotationWriteStatus::readbackMismatch;
            return result;
        }
        result.status = ControlRotationWriteStatus::committed;
        return result;
    }

    // A caller must have drained its worker before stop. Pending uncertainty
    // cannot be turned into a restored receipt by merely clearing this object.
    bool stopAfterDrain() {
        std::lock_guard<std::mutex> guard(mutex_);
        stopped_ = true;
        return !pending_;
    }
    bool pending() const { std::lock_guard<std::mutex> guard(mutex_); return pending_; }

private:
    mutable std::mutex mutex_;
    bool pending_ = false;
    bool stopped_ = false;
};

} // namespace CoreSet
