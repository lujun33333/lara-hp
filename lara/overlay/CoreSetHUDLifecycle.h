#pragma once
#include <stdbool.h>
#include <stdint.h>

// Presentation policy only. No game or process identity belongs in this module.
typedef enum CoreSetHUDBackend {
    CoreSetHUDBackendMetal = 0,
    CoreSetHUDBackendUnavailable = 1,
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
    (void)foreground;
    (void)crossApplicationHosted;
    // Core 1.7 has one ImGui/Metal frame pump. A missing Metal surface is an
    // unavailable renderer, not a request to switch drawing implementations.
    return metalAvailable ? CoreSetHUDBackendMetal : CoreSetHUDBackendUnavailable;
}

static inline bool CoreSetHUDHostingReady(bool menuRegistered, bool drawRegistered) {
    return menuRegistered && drawRegistered;
}
