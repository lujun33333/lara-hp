#include "../lara/overlay/CoreSetTargetWriteCleanupContract.h"
#include "../lara/overlay/CoreSetTargetWriteContract.h"
#include <cassert>
#include <cstring>
#include <iostream>

int main() {
    using namespace CoreSet;
    TargetWriteCleanupReceipt untouched{true, true, true, true, true, true, false};
    assert(untouched.resourcesReleased() && untouched.complete() && untouched.mayReportRestored());

    // Execute the real transaction contract against isolated memory.
    ControlRotationLease lease;
    lease.pid = 7; lease.imageBase = 0x100000000; lease.generation = 3;
    lease.controller = 0x200000000; lease.uuid = ControlRotationWriteGate::kUUID;
    lease.requestToken[0] = 1; lease.snapshotID[0] = 2;
    std::array<uint8_t, 8> old{}, value{{1, 2, 3, 4, 5, 6, 7, 8}}, memory = old;
    bool attempted = false;
    ControlRotationWriteGate gate;
    auto result = gate.transact(lease, old, value,
        [](const ControlRotationLease &) { return true; },
        [&](uint64_t, void *out, size_t count) -> size_t {
            std::memcpy(out, memory.data(), count); return count;
        },
        [&](uint64_t, const void *in, size_t count) -> size_t {
            attempted = true; std::memcpy(memory.data(), in, count); return count;
        });
    assert(result.status == ControlRotationWriteStatus::committed && attempted && memory == value);
    const bool drained = gate.stopAfterDrain();
    assert(drained);

    // Outer-session authority is revoked after commit, before the next transaction:
    // the gate itself has no pending work, but the session retains unresolved state.
    TargetWriteCleanupReceipt revoked{true, true, true, drained, true, false, attempted};
    assert(revoked.resourcesReleased() && !revoked.complete() && !revoked.mayReportRestored());
    // Resource cleanup alone after a normal committed write also cannot imply restoration.
    TargetWriteCleanupReceipt committed{true, true, true, drained, true, true, attempted};
    assert(committed.complete() && !committed.mayReportRestored() && memory == value);

    // Each missing cleanup condition independently prevents successful stop receipts.
    for (int condition = 0; condition < 6; ++condition) {
        auto failure = untouched;
        switch (condition) {
        case 0: failure.readTaskPortReleased = false; break;
        case 1: failure.mappedAliasReleased = false; break;
        case 2: failure.generationAdvanced = false; break;
        case 3: failure.noInFlight = false; break;
        case 4: failure.backendClean = false; break;
        case 5: failure.noUnresolvedState = false; break;
        }
        assert(!failure.complete() && !failure.mayReportRestored());
    }
    std::cout << "PASS: untouched stop, committed write, revoked authority, six cleanup failures\n";
}
