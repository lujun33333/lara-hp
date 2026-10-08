#include "../lara/overlay/CoreSetActionInputReadContract.h"
#include <cassert>
#include <iostream>
#include <vector>

using namespace CoreSet;

int main() {
    static_assert(!ActionInputReadObservation::writeReady);
    ActionInputReadLease lease;
    lease.pid = 42; lease.imageBase = 0x100000000; lease.generation = 9;
    lease.controller = 0x123450000; lease.uuid = ControlRotationWriteGate::kUUID;
    lease.snapshotID[0] = 1; lease.snapshotCompletedSeconds = 10;
    lease.capturedControl = {10, -30};
    std::array<float, 2> input = {1, -2}, control = lease.capturedControl;
    std::vector<uint64_t> addresses;
    unsigned identityCalls = 0, clockCalls = 0, writerCalls = 0;
    bool validIdentity = true;
    uint64_t partialAddress = 0;
    bool loseAfterRead = false;
    double startTime = 10.1, endTime = 10.2;
    const auto identity = [&](const ActionInputReadLease &current) {
        ++identityCalls; return validIdentity && current.generation == 9;
    };
    const auto read = [&](uint64_t address, void *out, size_t length) {
        assert(length == 8);
        assert(address == lease.controller + 0x828 || address == lease.controller + 0x620);
        addresses.push_back(address);
        const auto &bytes = address == lease.controller + 0x828 ? input : control;
        const size_t completed = address == partialAddress ? 4 : length;
        std::memcpy(out, bytes.data(), completed);
        if (loseAfterRead) validIdentity = false;
        return completed;
    };
    const auto clock = [&] { return clockCalls++ == 0 ? startTime : endTime; };
    const auto reset = [&] {
        addresses.clear(); identityCalls = clockCalls = 0; validIdentity = true;
        partialAddress = 0; loseAfterRead = false; startTime = 10.1; endTime = 10.2;
        input = {1, -2}; control = lease.capturedControl;
    };
    auto result = observeActionControllerInput(lease, identity, read, clock);
    assert(result.complete() && addresses.size() == 2 && identityCalls == 3);
    assert(result.inputFingerprint && result.controlBeforeFingerprint == result.controlAfterFingerprint);
    assert(result.completedSeconds == endTime && writerCalls == 0);
    reset(); validIdentity = false;
    assert(observeActionControllerInput(lease, identity, read, clock).status == ActionInputReadStatus::identityChanged);
    assert(addresses.empty());
    reset(); auto oldLease = lease; oldLease.generation = 8;
    assert(!observeActionControllerInput(oldLease, identity, read, clock).complete() && addresses.empty());
    reset(); auto wrongProfile = lease; wrongProfile.uuid[0] ^= 1;
    assert(observeActionControllerInput(wrongProfile, identity, read, clock).status == ActionInputReadStatus::invalidLease);
    assert(addresses.empty());
    reset(); partialAddress = lease.controller + 0x828;
    result = observeActionControllerInput(lease, identity, read, clock);
    assert(result.status == ActionInputReadStatus::partialInput && !result.inputFingerprint && addresses.size() == 1);
    reset(); partialAddress = lease.controller + 0x620;
    result = observeActionControllerInput(lease, identity, read, clock);
    assert(result.status == ActionInputReadStatus::partialControl && !result.controlAfterFingerprint && addresses.size() == 2);
    reset(); input[0] = NAN;
    result = observeActionControllerInput(lease, identity, read, clock);
    assert(result.status == ActionInputReadStatus::nonfiniteValue && !result.inputFingerprint);
    reset(); control[1] = INFINITY;
    assert(observeActionControllerInput(lease, identity, read, clock).status == ActionInputReadStatus::nonfiniteValue);
    reset(); control[0] = 10.1f;
    result = observeActionControllerInput(lease, identity, read, clock);
    assert(result.status == ActionInputReadStatus::controlChanged && !result.complete());
    assert(result.controlBeforeFingerprint != result.controlAfterFingerprint);
    reset(); startTime = 10.500001;
    assert(observeActionControllerInput(lease, identity, read, clock).status == ActionInputReadStatus::staleSnapshot);
    assert(addresses.empty());
    reset(); endTime = 10.500001;
    assert(observeActionControllerInput(lease, identity, read, clock).status == ActionInputReadStatus::staleSnapshot);
    assert(addresses.size() == 2);
    reset(); startTime = 9.9;
    assert(observeActionControllerInput(lease, identity, read, clock).status == ActionInputReadStatus::invalidClock);
    reset(); endTime = 10.05;
    assert(observeActionControllerInput(lease, identity, read, clock).status == ActionInputReadStatus::invalidClock);
    reset(); loseAfterRead = true;
    result = observeActionControllerInput(lease, identity, read, clock);
    assert(result.status == ActionInputReadStatus::identityChanged && addresses.size() == 1);
    assert(!result.inputFingerprint && !result.controlAfterFingerprint && writerCalls == 0);
    std::cout << "PASS: typed read observation/full-length/old-generation/profile/nonfinite/freshness/identity/control-change cases; writerCalls=0\n";
}
