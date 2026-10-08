#pragma once

#include <cstdint>

namespace CoreSet {

// A receipt schema, NOT proof or target-memory authority. The independent
// verifier must establish the same target/identity, all owned baseline ranges,
// fresh non-alias readback, and stopped producers. No verifier is installed by
// the current production writer; its attempted effects therefore stay pending.
struct ActionRestorationReceipt {
    uint64_t attemptEpoch = 0;
    bool producerStopped = false;
    bool writerDrained = false;
    bool identityStable = false;
    bool independentReadback = false;
    bool allOwnedRangesMatchBaseline = false;
};

class ActionEffectLedger {
public:
    void markWriteAttempt() {
        unresolved_ = true;
        if (attemptEpoch_ != UINT64_MAX) ++attemptEpoch_;
        else exhausted_ = true;
    }

    template <typename IndependentVerifier>
    bool acknowledgeVerifiedRestoration(const ActionRestorationReceipt &receipt,
                                        IndependentVerifier independentVerifier) {
        if (!unresolved_ || exhausted_ || receipt.attemptEpoch != attemptEpoch_ ||
            !receipt.producerStopped || !receipt.writerDrained ||
            !receipt.identityStable || !receipt.independentReadback ||
            !receipt.allOwnedRangesMatchBaseline || !independentVerifier(receipt)) return false;
        unresolved_ = false;
        return true;
    }

    bool targetEffectsResolved() const { return !unresolved_; }
    uint64_t attemptEpoch() const { return attemptEpoch_; }
    bool cleanupComplete(bool readReleased, bool aliasesReleased,
                         bool generationAdvanced, bool noInFlight) const {
        return readReleased && aliasesReleased && generationAdvanced && noInFlight && !unresolved_;
    }

private:
    uint64_t attemptEpoch_ = 0;
    bool unresolved_ = false;
    bool exhausted_ = false;
};

} // namespace CoreSet
