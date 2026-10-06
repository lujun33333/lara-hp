#include "../lara/overlay/CoreSetTargetWriteReadLease.h"
#include "../lara/overlay/CoreSetTargetWriteContract.h"
#include <cassert>
#include <cstring>
#include <iostream>

int main() {
    using namespace CoreSet;
    for (int scenario = 0; scenario < 3; ++scenario) {
        ControlRotationLease captured;
        captured.pid = 7; captured.imageBase = 0x100000000;
        captured.generation = 29; captured.controller = 0x200000000;
        captured.uuid = ControlRotationWriteGate::kUUID;
        captured.requestToken[0] = 1; captured.snapshotID[0] = 2;
        TargetWriteReadLease reader {captured.pid, captured.imageBase, 3};
        uint64_t liveCaptureGeneration = 29, liveReaderGeneration = 3;
        int reads = 0, writes = 0;
        std::array<uint8_t, 8> old{}, next{{1}}, memory = old;
        ControlRotationWriteGate gate;
        auto result = gate.transact(captured, old, next,
            [&](const ControlRotationLease &lease) {
                return lease.generation == liveCaptureGeneration &&
                       reader.matches(true, captured.pid, captured.imageBase, liveReaderGeneration);
            },
            [&](uint64_t, void *out, size_t count) -> size_t {
                assert(reader.generation == 3); // Actual read uses the independent reader lease.
                std::memcpy(out, memory.data(), count);
                if (++reads == 1) {
                    if (scenario == 1) ++liveReaderGeneration;
                    if (scenario == 2) ++liveCaptureGeneration;
                }
                return count;
            },
            [&](uint64_t, const void *in, size_t count) -> size_t {
                ++writes; std::memcpy(memory.data(), in, count); return count;
            });
        if (scenario == 0) {
            assert(result.status == ControlRotationWriteStatus::committed && writes == 1 && reads == 2);
        } else {
            assert(result.status == ControlRotationWriteStatus::staleIdentity && writes == 0 && gate.pending());
        }
    }
    std::cout << "PASS: unequal reader/capture generations accepted; either lease change rejected\n";
}
