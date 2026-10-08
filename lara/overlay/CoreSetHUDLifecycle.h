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
    // A remotely hosted source UIWindow stays process-owned and keeps the same
    // CAMetalLayer context. Keep Metal active for that hosted source so the
    // v1.7 FPS scheduler and draw lanes do not silently fall back to CA when
    // the launcher resigns foreground after opening the target application.
    return metalAvailable && (foreground || crossApplicationHosted)
        ? CoreSetHUDBackendMetal : CoreSetHUDBackendCoreAnimation;
}

static inline bool CoreSetHUDHostingReady(bool menuRegistered, bool drawRegistered) {
    return menuRegistered && drawRegistered;
}
