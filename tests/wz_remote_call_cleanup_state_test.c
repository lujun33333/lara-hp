#include "../lara/kexploit/TaskRop/RemoteCallCleanupState.h"

#include <assert.h>
#include <stdbool.h>

typedef struct cleanup_state {
    bool creatingExtraThread;
    bool extraThreadExitConfirmed;
    bool destroying;
    bool cleanupPending;
} cleanup_state_t;

static rc_cleanup_action_t begin(cleanup_state_t *state)
{
    return rc_cleanup_begin(state->creatingExtraThread,
                            &state->destroying,
                            &state->cleanupPending);
}

int main(void)
{
    cleanup_state_t simple = {0};
    assert(begin(&simple) == RC_CLEANUP_FINALIZE);
    assert(simple.destroying && simple.cleanupPending);
    rc_cleanup_complete(&simple.creatingExtraThread,
                        &simple.extraThreadExitConfirmed,
                        &simple.destroying, &simple.cleanupPending);
    assert(!simple.creatingExtraThread && !simple.extraThreadExitConfirmed);
    assert(!simple.destroying && !simple.cleanupPending);

    cleanup_state_t reentrant = {0};
    assert(begin(&reentrant) == RC_CLEANUP_FINALIZE);
    assert(begin(&reentrant) == RC_CLEANUP_BUSY);
    assert(reentrant.destroying && reentrant.cleanupPending);

    cleanup_state_t worker = {.creatingExtraThread = true};
    assert(begin(&worker) == RC_CLEANUP_CONFIRM_EXTRA_THREAD);
    rc_cleanup_mark_extra_thread_exited(&worker.creatingExtraThread,
                                        &worker.extraThreadExitConfirmed);
    assert(!worker.creatingExtraThread && worker.extraThreadExitConfirmed);
    rc_cleanup_complete(&worker.creatingExtraThread,
                        &worker.extraThreadExitConfirmed,
                        &worker.destroying, &worker.cleanupPending);
    assert(!worker.creatingExtraThread && !worker.extraThreadExitConfirmed);
    assert(!worker.destroying && !worker.cleanupPending);

    cleanup_state_t pending = {0};
    assert(begin(&pending) == RC_CLEANUP_FINALIZE);
    rc_cleanup_defer(&pending.destroying, &pending.cleanupPending);
    assert(!pending.destroying && pending.cleanupPending);
    assert(begin(&pending) == RC_CLEANUP_FINALIZE);
    rc_cleanup_complete(&pending.creatingExtraThread,
                        &pending.extraThreadExitConfirmed,
                        &pending.destroying, &pending.cleanupPending);
    assert(!pending.destroying && !pending.cleanupPending);

    // Fully-cleared repeated destruction is harmless and re-enters only the
    // local finalization path with all resources already null.
    assert(begin(&pending) == RC_CLEANUP_FINALIZE);
}
