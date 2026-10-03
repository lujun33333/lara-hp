// Portable integration test of the actual consumer. The iOS transport and
// rendering entrypoints are removed by section GC; only touch submission is a
// stub, so this never sends input to a device.
#include "../lara/kexploit/wzesp.mm"
#include <atomic>
#include <cassert>
#include <vector>

static int aimSnapshotCalls = 0;
static uint64_t aimSnapshotGeneration = 0;
static bool aimProjectionSupplied = false;
extern "C" bool wzaim_runtime_consume_snapshot(
        const KoiEntity *, size_t, const KoiRuntimeDiagnostics *diagnostics,
        const KoiProjectionState *projection) {
    ++aimSnapshotCalls;
    aimSnapshotGeneration = diagnostics != nullptr
        ? diagnostics->snapshotGeneration : 0;
    aimProjectionSupplied = projection != nullptr;
    return false;
}

static std::atomic<int> taps{0};
static std::atomic<bool> acceptTap{true};
struct PendingTapCompletion {
    wzax_touch_completion_t callback;
    void *context;
};
static std::vector<PendingTapCompletion> completions;
extern "C" bool wzax_touch_tap_async(
        double x, double y, bool fixed,
        wzax_touch_completion_t completion, void *context) {
    assert(x == 100 && y == 200 && fixed);
    ++taps;
    if (!acceptTap.load(std::memory_order_acquire)) return false;
    completions.push_back({completion, context});
    return true;
}
static void completeTap(size_t index, bool sent = true) {
    const PendingTapCompletion pending = completions.at(index);
    pending.callback(pending.context, sent);
}
extern "C" bool wz_transport_ready(void) { return true; }
extern "C" const char *wz_transport_name(void) { return "mock"; }
extern "C" void KoiProjectionReset(KoiProjectionState *) {}
extern "C" bool KoiProjectionRefresh(uintptr_t, uint32_t, uint32_t,
                                       KoiProjectionState *) { return false; }
extern "C" void KoiProjectionInvalidateAddressCache(void) {}
extern "C" bool KoiProjectionWorldToScreen(const KoiProjectionState *,
    float, float, float, float *, float *, float *) { return false; }
extern "C" size_t YuanbaoCollectorGather(uintptr_t,
    const YuanbaoCollectorInput *, KoiEntity *, size_t,
    KoiProjectionState *, KoiRuntimeDiagnostics *) { return 0; }
extern "C" void YuanbaoCollectorReadersStart(uint64_t) {}
extern "C" void YuanbaoCollectorReadersStop(uint64_t) {}
extern "C" void YuanbaoCollectorResetForTerminalChange(void) {}
extern "C" void YuanbaoCollectorSetReaderFlags(uint32_t) {}
extern "C" YuanbaoReaderTickResult YuanbaoCollectorAuxiliaryReaderTick(
    uintptr_t, uint64_t) { return YuanbaoReaderTickSkipped; }
extern "C" YuanbaoReaderTickResult YuanbaoCollectorAutoKillReaderTick(
    uintptr_t, uint64_t, uint32_t) { return YuanbaoReaderTickSkipped; }

int main() {
    const wzesp_config_t defaults{};
    assert(defaults.flags == 0 && !defaults.clickCoordinatesValid &&
           !defaults.clickSpaceFixed);

    KoiEntity target{};
    target.axPositionValid = 1;
    KoiEntity observers[2]{};
    observers[0].category = KoiEntityCategorySoldier;
    observers[0].axPositionValid = 1;
    observers[0].axWorldX = 12;
    observers[0].exposureState = 1;
    assert(AXMinimapExposed(target, observers, 2)); // Inclusive 12m edge.
    observers[0].axWorldX = 12.01f;
    assert(!AXMinimapExposed(target, observers, 2));
    observers[0].axWorldX = 1;
    observers[0].exposureState = 0;
    assert(!AXMinimapExposed(target, observers, 2)); // Dead soldier cannot see.
    observers[1].category = KoiEntityCategoryHero;
    observers[1].axPositionValid = 1;
    observers[1].axWorldX = 1;
    observers[1].axDead = 1; // AX's friendly-hero scan does not test this byte.
    observers[1].visibility = KoiVisibilityFogged;
    assert(AXMinimapExposed(target, observers, 2));
    observers[1].enemy = 1;
    assert(!AXMinimapExposed(target, observers, 2));

    wzesp_config_t config{};
    config.flags = WZESP_AUTO_KILL;
    config.clickX = 100;
    config.clickY = 200;
    config.clickCoordinatesValid = 1;
    config.clickSpaceFixed = 1;
    KoiRuntimeDiagnostics state{};
    state.autoKillSampleValid = 1;
    KoiEntity enemies[2]{};
    for (auto &enemy : enemies) {
        enemy.category = KoiEntityCategoryHero;
        enemy.enemy = 1;
        enemy.axPositionValid = enemy.axHealthValid = 1;
        enemy.axWorldX = enemy.axWorldZ = 1;
        enemy.axHealth = 100;
        enemy.axHealthTotal = 1000;
    }
    // Producer order is the target-selection and tie-break order.
    const KoiEntity *selected = wzax_auto_kill_first_eligible(
        enemies, 2, [&](const KoiEntity &candidate) {
            return wzax_auto_kill_eligible(
                static_cast<float>(candidate.axHealth),
                static_cast<float>(candidate.axHealthTotal),
                state.hostWorldX, state.hostWorldZ,
                candidate.axWorldX, candidate.axWorldZ);
        });
    assert(selected == &enemies[0]);

    assert(TryAXAutoKill(config, state, enemies, 2) == 4 && taps == 1);
    // The production sender is asynchronous. AX keeps the action byte claimed
    // until block 0x100801ce0 reaches 0x100802384/0x100802420.
    assert(TryAXAutoKill(config, state, enemies, 2) == 3 && taps == 1);
    assert(g_autoKillSubmitBusy.load(std::memory_order_acquire) == 1);
    completeTap(0);
    assert(g_autoKillSubmitBusy.load() == 0);

    // AX has no one-second consumer cooldown: after terminal completion, the
    // next eligible frame may submit immediately.
    assert(TryAXAutoKill(config, state, enemies, 2) == 4 && taps == 2);
    completeTap(1);

    // A stale completion from an invalidated generation cannot release the
    // reservation belonging to a newer submission.
    assert(TryAXAutoKill(config, state, enemies, 2) == 4 && taps == 3);
    const PendingTapCompletion stale = completions.back();
    wzesp_reset();
    assert(TryAXAutoKill(config, state, enemies, 2) == 4 && taps == 4);
    stale.callback(stale.context, false);
    assert(g_autoKillSubmitBusy.load() == 1);
    completeTap(3);
    assert(g_autoKillSubmitBusy.load() == 0);

    state.autoKillSampleValid = 0;
    assert(TryAXAutoKill(config, state, enemies, 2) == 1 && taps == 4);
    state.autoKillSampleValid = 1;
    state.autoKillGateB = 1;
    assert(TryAXAutoKill(config, state, enemies, 2) == 1 && taps == 4);
    state.autoKillGateB = 0;
    config.clickCoordinatesValid = 0;
    assert(TryAXAutoKill(config, state, enemies, 2) == 2 && taps == 4);
    config.clickCoordinatesValid = 1;
    acceptTap.store(false);
    assert(TryAXAutoKill(config, state, enemies, 2) == 5 && taps == 5);
    assert(g_autoKillSubmitBusy.load() == 0);
    // A rejected send unlocks immediately and does not poison nextAllowed.
    acceptTap.store(true);
    assert(TryAXAutoKill(config, state, enemies, 2) == 4 && taps == 6);
    completeTap(4);

    enemies[0].enemy = enemies[1].enemy = 0;
    assert(TryAXAutoKill(config, state, enemies, 2) == 6 && taps == 6);
    enemies[0].enemy = enemies[1].enemy = 1;
    config.flags = 0;
    assert(TryAXAutoKill(config, state, enemies, 2) == 0 && taps == 6);

    wzesp_config_t aimConfig{};
    aimConfig.flags = WZESP_COLLECT_AIM;
    wzesp_item_t aimItems[1]{};
    assert(wzesp_tick(0x101000000, 1000, 500,
                      &aimConfig, aimItems, 1) == 0);
    assert(aimSnapshotCalls == 1 && aimSnapshotGeneration == 1 &&
           aimProjectionSupplied);
    assert(wzesp_tick(0x101000000, 1000, 500,
                      &aimConfig, aimItems, 1) == 0);
    assert(aimSnapshotCalls == 2 && aimSnapshotGeneration == 2);
    wzesp_reset();
    assert(wzesp_tick(0x101000000, 1000, 500,
                      &aimConfig, aimItems, 1) == 0);
    assert(aimSnapshotCalls == 3 && aimSnapshotGeneration == 1);
}
