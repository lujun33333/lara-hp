#include "../lara/kexploit/wz/WZHUDLifecyclePolicy.h"
#include "../lara/kexploit/WZHUDBridge.h"

#include <assert.h>

static void verify_outcome(bool menu, bool draw, bool ready)
{
    wzhud_hosting_outcome_t outcome = wzhud_hosting_outcome(menu, draw);
    assert(outcome.menuRegistered == menu);
    assert(outcome.drawRegistered == draw);
    assert(outcome.ready == ready);
}

int main(void)
{
    const bool applicationEvents[] = {true, false, false, true, false, true};
    const wzhud_render_backend_t expectedBackends[] = {
        WZHUDRenderBackendMetal,
        WZHUDRenderBackendCoreAnimation,
        WZHUDRenderBackendCoreAnimation,
        WZHUDRenderBackendMetal,
        WZHUDRenderBackendCoreAnimation,
        WZHUDRenderBackendMetal,
    };
    for (size_t index = 0;
         index < sizeof(applicationEvents) / sizeof(applicationEvents[0]);
         ++index) {
        const bool active = applicationEvents[index];
        const wzhud_render_transition_t transition =
            wzhud_render_transition_for_application_active(active);
        assert(transition.backend == expectedBackends[index]);
        assert(transition.foregroundTickEnabled == active);
        assert(transition.metalVisible == active);
        assert(transition.coreAnimationVisible == !active);
    }

    // AX keeps each successful side independently; only TT is fully ready.
    verify_outcome(true, true, true);
    verify_outcome(true, false, false);
    verify_outcome(false, true, false);
    verify_outcome(false, false, false);

    bool terminationRequested = false;
    assert(wzhud_try_begin_termination(&terminationRequested));
    assert(terminationRequested);
    assert(!wzhud_try_begin_termination(&terminationRequested));
    wzhud_reset_termination(&terminationRequested);
    assert(wzhud_try_begin_termination(&terminationRequested));

    assert(wzhud_remote_cleanup_status_succeeded(0));
    assert(!wzhud_remote_cleanup_status_succeeded(-1));
    assert(!wzhud_remote_cleanup_status_succeeded(1));

    for (unsigned int resultMask = 0; resultMask != 4; ++resultMask) {
        wzhud_hosting_fields_t fields = {true, true, 0x22, 0x11, true};
        wzhud_clear_hosting_fields(&fields,
                                   (resultMask & 1u) != 0,
                                   (resultMask & 2u) != 0);
        assert(!fields.menuController && !fields.drawController);
        assert(fields.menuContext == 0 && fields.drawContext == 0);
        assert(!fields.ready);
    }
    return 0;
}
