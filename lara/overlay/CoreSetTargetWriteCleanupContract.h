#pragma once

namespace CoreSet {
// Releasing transport resources does not restore bytes previously written.
struct TargetWriteCleanupReceipt {
    bool readTaskPortReleased = false;
    bool mappedAliasReleased = false;
    bool generationAdvanced = false;
    bool noInFlight = false;
    bool backendClean = false;
    bool noUnresolvedState = false;
    bool targetWriteAttempted = false;

    bool resourcesReleased() const {
        return readTaskPortReleased && mappedAliasReleased;
    }
    bool complete() const {
        return resourcesReleased() && generationAdvanced && noInFlight &&
               backendClean && noUnresolvedState;
    }
    bool mayReportRestored() const {
        return complete() && !targetWriteAttempted;
    }
};
} // namespace CoreSet
