#pragma once
#include <stdbool.h>
#include <stdint.h>

// Presentation policy only. No game or process identity belongs in this module.
typedef enum CoreSetHUDBackend {
    CoreSetHUDBackendCoreAnimation = 0,
    CoreSetHUDBackendMetal = 1,
} CoreSetHUDBackend;

static inline uint64_t CoreSetHUDNextGeneration(uint64_t generation) {
    return generation == UINT64_MAX ? 1 : generation + 1;
}

static inline bool CoreSetHUDFrameIsCurrent(bool running, uint64_t generation,
                                           uint64_t frameGeneration,
                                           uint64_t lastSequence, uint64_t sequence) {
    return running && generation != 0 && frameGeneration == generation &&
           sequence > lastSequence;
}

static inline CoreSetHUDBackend CoreSetHUDSelectBackend(bool foreground,
                                                        bool metalAvailable,
                                                        bool crossApplicationHosted) {
    // The hosted source remains process-owned, but driving its MTKView while
    // this app is in the background keeps a continuous drawable loop alive in
    // parallel with the game. Use retained CoreAnimation for cross-application
    // frames; it updates only when a composer frame changes and avoids stealing
    // game/UI time from the foreground application.
    return foreground && metalAvailable && !crossApplicationHosted
        ? CoreSetHUDBackendMetal : CoreSetHUDBackendCoreAnimation;
}

static inline bool CoreSetHUDHostingReady(bool menuRegistered, bool drawRegistered) {
    return menuRegistered && drawRegistered;
}
