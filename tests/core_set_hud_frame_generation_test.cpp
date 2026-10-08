#include "CoreSetHUDLifecycle.h"
#include <cassert>
#include <cstdio>

int main() {
    const uint64_t oldRenderGeneration = 42;
    const uint64_t newRenderGeneration = CoreSetHUDNextGeneration(oldRenderGeneration);
    const uint64_t oldLastSequence = 500;

    // A quarter-turn without a remote context rebuild changes only frame
    // provenance. The old queued frame must be rejected, while sequence 1
    // in the new provenance is accepted after the host resets its counter.
    assert(!CoreSetHUDFrameIsCurrent(true, newRenderGeneration,
                                     oldRenderGeneration, 0, oldLastSequence + 1));
    assert(CoreSetHUDFrameIsCurrent(true, newRenderGeneration,
                                    newRenderGeneration, 0, 1));
    assert(!CoreSetHUDFrameIsCurrent(true, newRenderGeneration,
                                     newRenderGeneration, oldLastSequence, 1));

    // Core 1.7 has one ImGui/Metal backend. Foreground/hosting state cannot
    // select a second renderer; a missing Metal surface is unavailable.
    assert(CoreSetHUDSelectBackend(true, true, false) == CoreSetHUDBackendMetal);
    assert(CoreSetHUDSelectBackend(false, true, true) == CoreSetHUDBackendMetal);
    assert(CoreSetHUDSelectBackend(true, true, true) == CoreSetHUDBackendMetal);
    assert(CoreSetHUDSelectBackend(false, true, false) == CoreSetHUDBackendMetal);
    assert(CoreSetHUDSelectBackend(true, false, true) == CoreSetHUDBackendUnavailable);
    std::puts("CoreSet frame generation boundary passed");
}
