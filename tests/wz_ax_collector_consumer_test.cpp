// End-to-end host test: production collector -> production exposure consumer.
// The oracle is tied to AX 1.2.8 consumers 0x1007a556c/0x1007a5cc0 and the
// friendly-coordinate builders 0x10080e464/0x10080eb2c.
#include "../lara/kexploit/wz/YuanbaoCollector.mm"
#include "../lara/kexploit/wzesp.mm"

#include <cassert>
#include <cstring>
#include <map>

extern "C" bool wzaim_runtime_consume_snapshot(
        const KoiEntity *, size_t, const KoiRuntimeDiagnostics *,
        const KoiProjectionState *) {
    return false;
}

static std::map<uint64_t, uint8_t> memory;

template<class T> void put(uint64_t address, const T &value) {
    const auto *bytes = reinterpret_cast<const uint8_t *>(&value);
    for (size_t i = 0; i < sizeof(T); ++i) memory[address + i] = bytes[i];
}

extern "C" long wz_read(uint64_t address, void *out, size_t size) {
    auto *bytes = static_cast<uint8_t *>(out);
    for (size_t i = 0; i < size; ++i) {
        const auto found = memory.find(address + i);
        if (found == memory.end()) return -1;
        bytes[i] = found->second;
    }
    return static_cast<long>(size);
}

extern "C" long wz_read_fresh_root(uint64_t address, void *out, size_t size,
                                   uint64_t *) {
    return wz_read(address, out, size);
}
extern "C" uint32_t _dyld_image_count(void) { return 0; }
extern "C" const char *_dyld_get_image_name(uint32_t) { return nullptr; }
extern "C" const mach_header *_dyld_get_image_header(uint32_t) {
    return nullptr;
}
extern "C" const char *wz_transport_name(void) { return "mock"; }
extern "C" bool wz_transport_ready(void) { return true; }
extern "C" void wz_invalidate_read_cache(void) {}
extern "C" bool wzax_touch_tap_async(
    double, double, bool, wzax_touch_completion_t, void *) { return false; }

extern "C" void KoiProjectionReset(KoiProjectionState *state) {
    std::memset(state, 0, sizeof(*state));
}
extern "C" bool KoiProjectionRefresh(uintptr_t, uint32_t width,
                                      uint32_t height,
                                      KoiProjectionState *state) {
    state->matrix[0] = 1.0f;
    state->matrix[5] = 1.0f;
    state->matrix[10] = 1.0f;
    state->matrix[15] = 1.0f;
    state->screenWidth = static_cast<float>(width);
    state->screenHeight = static_cast<float>(height);
    state->campOrientation = 1.0f;
    state->valid = 1;
    return true;
}
extern "C" void KoiProjectionInvalidateAddressCache(void) {}
extern "C" bool KoiProjectionMatrixLooksValid(const float *) { return true; }
extern "C" bool KoiProjectionWorldToScreen(const KoiProjectionState *,
    float worldX, float, float worldZ, float *screenX, float *screenY,
    float *) {
    *screenX = worldX;
    *screenY = worldZ;
    return true;
}
extern "C" bool KoiProjectionMinimapPoint(float worldX, float worldZ,
    float originX, float side, float, float *minimapX, float *minimapY) {
    *minimapX = originX + side * 0.5f + worldX;
    *minimapY = side * 0.5f + worldZ;
    return true;
}

static void putHeroPosition(uintptr_t actor, uintptr_t storage,
                            const AXActorCache::Raw &raw) {
    put(actor + 0x268, storage);
    put(storage + 0x10, storage + 0x1000);
    put(storage + 0x1000, storage + 0x2000);
    put(storage + 0x2060, storage + 0x3000);
    put(storage + 0x3000, raw);
}

static void putSoldierPosition(uintptr_t actor, uintptr_t storage,
                               const AXActorCache::Raw &raw) {
    put(actor + 0x250, storage);
    put(storage + 0x60, storage + 0x1000);
    put(storage + 0x1000, raw);
}

int main() {
    constexpr uintptr_t unity = 0x101000000;
    constexpr uintptr_t root = 0x110000000;
    constexpr uintptr_t manager = 0x120000000;
    constexpr uintptr_t entries = 0x130000000;
    constexpr uintptr_t enemy = 0x140000000;
    constexpr uintptr_t friendly = 0x150000000;
    constexpr uintptr_t candidate = 0x160000000;
    constexpr uintptr_t enemyHealth = 0x190000000;

    put(unity + 0x1325A6C0, root);
    put(root + 0x138, manager);
    put(manager + 0x78, entries);
    put(manager + 0x94, int32_t(2));
    put(entries, enemy);
    put(entries + 0x18, friendly);
    const int32_t enemyHeader[4]{101, 0, 0, 2};
    const int32_t friendlyHeader[4]{102, 0, 0, 1};
    put(enemy + 0x50, enemyHeader);
    put(friendly + 0x50, friendlyHeader);
    const AXActorCache::Raw enemyRaw{1000, 0, 1000, 0};
    const AXActorCache::Raw friendlyRaw{11000, 0, 1000, 0};
    putHeroPosition(enemy, 0x170000000, enemyRaw);
    putHeroPosition(friendly, 0x180000000, friendlyRaw);
    put(enemy + 0x1A0, enemyHealth);
    put(enemyHealth + 0x160, int32_t(100 * 8192));
    put(enemyHealth + 0x170, int32_t(1000));
    put(candidate, enemyRaw);

    ResetSkillCachesForUnity(unity);
    gCacheActorManager = manager;
    gAXCoordinateRoot.base = unity;
    gAXCoordinateRoot.value = candidate;
    gAXCoordinateRoot.nextProbe = UINT64_MAX;
    gAXHeroCache.assign(1, {});
    gAXHeroCache[0].actor = enemy;
    gAXHeroCache[0].raw = enemyRaw;
    gAXHeroCache[0].valid = true;
    gAXHeroCache[0].assigned = candidate;

    wzesp_config_t config{};
    config.flags = WZESP_SHOW_ENEMY_VISION;
    config.minimapSize = 50.0f;
    wzesp_item_t items[8]{};
    const int count = wzesp_tick(unity, 1000, 500, &config, items, 8);
    assert(count == 1);  // Friendly observer is not emitted as a HUD entity.
    assert(items[0].configId == 101 && items[0].enemy);
    assert(items[0].minimapExposureValid);
    assert(!items[0].minimapDimmed);
    assert(items[0].minimapRingRGBA == 0xFF0000FFu);

    // AX 0x10080bd6c/0x10080be6c gates both soldier publication vectors on
    // current HP > 0. Exercise the actual Gather -> wzesp consumer chain so
    // a dead record cannot be hidden merely by a source-level predicate test.
    constexpr uintptr_t soldierEntries = 0x1A0000000;
    constexpr uintptr_t deadSoldier = 0x1B0000000;
    constexpr uintptr_t liveSoldier = 0x1C0000000;
    constexpr uintptr_t deadHealth = 0x1D0000000;
    constexpr uintptr_t liveHealth = 0x1E0000000;
    put(manager + 0x120, soldierEntries);
    put(manager + 0x13C, int32_t(2));
    put(soldierEntries, std::array<uint8_t, 0x30>{});
    put(soldierEntries, deadSoldier);
    put(soldierEntries + 0x18, liveSoldier);
    put(deadSoldier + 0x5C, int32_t(2));
    put(liveSoldier + 0x5C, int32_t(2));
    putSoldierPosition(deadSoldier, 0x1F0000000,
                       AXActorCache::Raw{2000, 0, 2000, 0});
    putSoldierPosition(liveSoldier, 0x200000000,
                       AXActorCache::Raw{3000, 0, 3000, 0});
    put(deadSoldier + 0x1A0, deadHealth);
    put(liveSoldier + 0x1A0, liveHealth);
    put(deadHealth + 0x160, int32_t(0));
    put(liveHealth + 0x160, int32_t(10 * 8192));

    config.flags = WZESP_SHOW_SOLDIER;
    std::memset(items, 0, sizeof(items));
    const int soldierCount = wzesp_tick(
        unity, 1000, 500, &config, items, 8);
    assert(soldierCount == 1);
    assert(items[0].category == KoiEntityCategorySoldier);
    assert(items[0].enemy && items[0].minimapValid);
}
