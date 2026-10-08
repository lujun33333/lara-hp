#pragma once
#include "CoreSetTargetWriteContract.h"
#include <cmath>

namespace CoreSet {

struct ActionInputReadLease {
    int32_t pid = -1;
    uint64_t imageBase = 0;
    uint64_t generation = 0;
    uint64_t controller = 0;
    std::array<uint8_t, 16> uuid{};
    std::array<uint8_t, 16> snapshotID{};
    double snapshotCompletedSeconds = 0;
    std::array<float, 2> capturedControl{};
};
enum class ActionInputReadStatus : uint8_t {
    invalidLease, invalidClock, staleSnapshot, identityChanged, partialInput, partialControl,
    nonfiniteValue, controlChanged, observed
};
struct ActionInputReadObservation {
    ActionInputReadStatus status = ActionInputReadStatus::invalidLease;
    uint64_t inputFingerprint = 0;
    uint64_t controlBeforeFingerprint = 0;
    uint64_t controlAfterFingerprint = 0;
    double completedSeconds = 0;
    bool complete() const { return status == ActionInputReadStatus::observed; }
    static constexpr bool writeReady = false;
};

// Non-cryptographic diagnostic summary only. It is NEVER an identity, candidate
// permission, successful write/readback, or restoration receipt.
inline uint64_t actionInputDiagnosticFingerprint(const void *bytes, size_t length) {
    uint64_t result = UINT64_C(14695981039346656037);
    const auto *source = static_cast<const uint8_t *>(bytes);
    for (size_t index = 0; index < length; ++index) {
        result ^= source[index]; result *= UINT64_C(1099511628211);
    }
    return result;
}

// Only the already-proven build15915 controller fields, two exact eight-byte
// reads. No writer callback or transport fallback exists. Object lifetime is
// the captured NetConnection controller lease, not an atomic engine frame.
template <typename Identity, typename ReadOnly, typename MonotonicClock>
ActionInputReadObservation observeActionControllerInput(const ActionInputReadLease &lease,
                                                        Identity identity, ReadOnly read,
                                                        MonotonicClock now) {
    ActionInputReadObservation result;
    if (lease.pid <= 0 || !lease.imageBase || !lease.generation ||
        lease.uuid != ControlRotationWriteGate::kUUID ||
        lease.snapshotID == std::array<uint8_t, 16>{} ||
        lease.controller < 0x100000000ULL || lease.controller > 0x8000000000ULL - 0x830 ||
        !std::isfinite(lease.snapshotCompletedSeconds) || lease.snapshotCompletedSeconds < 0 ||
        !std::isfinite(lease.capturedControl[0]) || !std::isfinite(lease.capturedControl[1])) return result;
    const auto fresh = [&](double time) {
        return std::isfinite(time) && time >= lease.snapshotCompletedSeconds &&
            time - lease.snapshotCompletedSeconds <= 0.5;
    };
    if (!identity(lease)) { result.status = ActionInputReadStatus::identityChanged; return result; }
    const double started = now();
    if (!std::isfinite(started) || started < lease.snapshotCompletedSeconds) {
        result.status = ActionInputReadStatus::invalidClock; return result;
    }
    if (!fresh(started)) { result.status = ActionInputReadStatus::staleSnapshot; return result; }
    std::array<float, 2> input{}, control{};
    if (read(lease.controller + 0x828, input.data(), sizeof(input)) != sizeof(input)) {
        result.status = ActionInputReadStatus::partialInput; return result;
    }
    if (!identity(lease)) { result.status = ActionInputReadStatus::identityChanged; return result; }
    if (read(lease.controller + 0x620, control.data(), sizeof(control)) != sizeof(control)) {
        result.status = ActionInputReadStatus::partialControl; return result;
    }
    if (!identity(lease)) { result.status = ActionInputReadStatus::identityChanged; return result; }
    const double completed = now();
    if (!std::isfinite(completed) || completed < started) {
        result.status = ActionInputReadStatus::invalidClock; return result;
    }
    if (!fresh(completed)) { result.status = ActionInputReadStatus::staleSnapshot; return result; }
    if (!std::isfinite(input[0]) || !std::isfinite(input[1]) ||
        !std::isfinite(control[0]) || !std::isfinite(control[1]) ||
        std::fabs(control[0]) > 360 || std::fabs(control[1]) > 360) {
        result.status = ActionInputReadStatus::nonfiniteValue; return result;
    }
    result.completedSeconds = completed;
    result.inputFingerprint = actionInputDiagnosticFingerprint(input.data(), sizeof(input));
    result.controlBeforeFingerprint = actionInputDiagnosticFingerprint(lease.capturedControl.data(), sizeof(control));
    result.controlAfterFingerprint = actionInputDiagnosticFingerprint(control.data(), sizeof(control));
    result.status = std::memcmp(control.data(), lease.capturedControl.data(), sizeof(control)) == 0
        ? ActionInputReadStatus::observed : ActionInputReadStatus::controlChanged;
    return result;
}

} // namespace CoreSet
