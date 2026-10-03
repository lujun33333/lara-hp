#include "../lara/kexploit/wz/WZAimRuntime.mm"

#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <thread>

namespace {

int gConnectedPid = 42;
uint64_t gConnectedGeneration = 9;
int gWriteCount = 0;

KoiEntity Enemy(uint64_t stableId, float x, float z, int health = 500) {
    KoiEntity entity{};
    entity.health = health;
    entity.healthTotal = 1000;
    entity.entityId = static_cast<int32_t>(stableId);
    entity.smoothingKey = stableId;
    entity.configId = 106;
    entity.category = KoiEntityCategoryHero;
    entity.enemy = 1;
    entity.onScreen = 1;
    entity.axPositionValid = 1;
    entity.axHealthValid = 1;
    entity.axWorldX = x;
    entity.axWorldZ = z;
    // A deliberately wrong unpredicted point proves the runtime does not copy
    // entity.screenX/Y into its external-drag snapshot.
    entity.screenX = 999.0f;
    entity.screenY = 999.0f;
    return entity;
}

}  // namespace

extern "C" bool wz_transport_ready(void) { return true; }
extern "C" bool wz_transport_can_write(void) { return true; }
extern "C" int wz_connected_pid(void) { return gConnectedPid; }
extern "C" uint64_t wz_session_generation(void) {
    return gConnectedGeneration;
}
extern "C" long wz_read(uint64_t, void *, size_t) { return -1; }
extern "C" long wz_write(uint64_t, const void *, size_t) {
    ++gWriteCount;
    return -1;
}

extern "C" bool KoiProjectionWorldToScreen(
        const KoiProjectionState *state, float worldX, float, float worldZ,
        float *screenX, float *screenY, float *clipW) {
    if (state == nullptr || state->valid == 0 || screenX == nullptr ||
        screenY == nullptr) {
        return false;
    }
    *screenX = state->screenWidth * 0.5f + worldX * 20.0f;
    *screenY = state->screenHeight * 0.5f + worldZ * 20.0f;
    if (clipW != nullptr) *clipW = 1.0f;
    return true;
}

int main() {
    constexpr uint64_t kUnityBase = UINT64_C(0x101000000);
    wzaim_runtime_attach(gConnectedPid, gConnectedGeneration, kUnityBase,
                         true, true);

    WZAimRuntimeConfig config{};
    config.enabled = 1;
    config.requireVisible = 1;
    config.externalTouch = 1;
    config.priority = 2;
    config.drawTargetMode = 1;
    config.heroId = 106;
    config.skillSlot = 0;
    wzaim_runtime_apply_config(&config);

    KoiRuntimeDiagnostics diagnostics{};
    diagnostics.unityBase = kUnityBase;
    diagnostics.hostCampReady = 1;
    diagnostics.hostPositionValid = 1;
    diagnostics.snapshotGeneration = 77;
    KoiProjectionState projection{};
    projection.valid = 1;
    projection.screenWidth = 1000.0f;
    projection.screenHeight = 500.0f;

    KoiEntity enemies[2]{Enemy(11, 5.0f, 0.0f), Enemy(22, 8.0f, 0.0f)};
    WZAimObservedIndicator accidentalBinding{};
    gIndicator = UINT64_C(0x100200000);
    gSession.profileVerified = true;
    gGestureActive = true;
    gOriginalCaptured = true;
    assert(!wzaim_runtime_bind_verified_indicator(&accidentalBinding));
    assert(gIndicator == 0 && !gSession.profileVerified && !gGestureActive &&
           !gOriginalCaptured && gWriteCount == 0);
    // Simulate an observer racing with the UI mode transition. External mode
    // must discard the binding before slot inference or any game write.
    gIndicator = UINT64_C(0x100200000);
    gSession.profileVerified = true;
    gGestureActive = true;
    assert(!wzaim_runtime_is_ready());
    assert(!wzaim_runtime_consume_snapshot(
        enemies, 2, &diagnostics, &projection));
    WZAimRuntimeTargetSnapshot snapshot{};
    assert(wzaim_runtime_copy_target(&snapshot));
    assert(snapshot.status == WZAimRuntimeStatusWaitingForSkill);
    assert(snapshot.skillSlot == 0 && !snapshot.targetScreenValid);
    assert(gIndicator == 0 && !gSession.profileVerified && !gGestureActive);
    assert(gWriteCount == 0);

    wzaim_runtime_set_gesture_active(true);
    assert(!gGestureActive);

    // An explicit slot makes the complete read-only selection path available
    // without an indicator, a verified write profile, or write capability.
    config.skillSlot = 1;
    wzaim_runtime_apply_config(&config);
    assert(wzaim_runtime_consume_snapshot(
        enemies, 2, &diagnostics, &projection));
    assert(wzaim_runtime_copy_target(&snapshot));
    assert(snapshot.status == WZAimRuntimeStatusWaitingForIndicator);
    assert(snapshot.result == WZAimRuntimeResultObserved);
    assert(snapshot.stableId == 11 && snapshot.skillSlot == 1);
    assert(snapshot.sessionGeneration == gConnectedGeneration);
    assert(snapshot.sourceSnapshotGeneration == 77);
    assert(snapshot.observedAtSeconds > 0.0);
    assert(snapshot.hostScreenValid && snapshot.targetScreenValid);
    assert(snapshot.hostScreenX == 500.0f && snapshot.hostScreenY == 250.0f);
    assert(snapshot.screenX == 600.0f && snapshot.screenY == 250.0f);
    assert(snapshot.screenX != enemies[0].screenX);
    assert(!snapshot.writeReady && gWriteCount == 0);

    // Velocity is retained and the published screen point comes from the
    // predicted world position, not from the selected entity's old point.
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    enemies[0].axWorldX = 5.1f;
    diagnostics.snapshotGeneration = 78;
    assert(wzaim_runtime_consume_snapshot(
        enemies, 2, &diagnostics, &projection));
    assert(wzaim_runtime_copy_target(&snapshot));
    assert(snapshot.targetX > enemies[0].axWorldX);
    assert(std::fabs(snapshot.screenX -
                     (500.0f + snapshot.targetX * 20.0f)) < 0.001f);
    assert(snapshot.sourceSnapshotGeneration == 78);
    assert(gWriteCount == 0);

    // "Closest to crosshair" remains usable without an indicator ray by
    // scoring filtered targets in the same frame's projection.
    config.priority = 3;
    wzaim_runtime_apply_config(&config);
    enemies[0] = Enemy(11, 5.0f, 0.0f);
    enemies[1] = Enemy(22, 2.0f, 0.0f);
    diagnostics.snapshotGeneration = 79;
    assert(wzaim_runtime_consume_snapshot(
        enemies, 2, &diagnostics, &projection));
    assert(wzaim_runtime_copy_target(&snapshot));
    assert(snapshot.stableId == 22 && snapshot.targetScreenValid);
    assert(!snapshot.writeReady && gWriteCount == 0);

    config.priority = 2;
    wzaim_runtime_apply_config(&config);
    projection.valid = 0;
    assert(!wzaim_runtime_consume_snapshot(
        enemies, 2, &diagnostics, &projection));
    assert(wzaim_runtime_copy_target(&snapshot));
    assert(snapshot.result == WZAimRuntimeResultObserved);
    assert(!snapshot.hostScreenValid && !snapshot.targetScreenValid);
    assert(gWriteCount == 0);
    projection.valid = 1;

    gConnectedGeneration = 10;
    assert(!wzaim_runtime_consume_snapshot(
        enemies, 2, &diagnostics, &projection));
    assert(wzaim_runtime_copy_target(&snapshot));
    assert(snapshot.status == WZAimRuntimeStatusSessionMismatch);
    assert(!snapshot.hostScreenValid && !snapshot.targetScreenValid);
    assert(gWriteCount == 0);
    gConnectedGeneration = 9;

    wzaim_runtime_detach();
    return 0;
}
