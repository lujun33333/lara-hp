// End-to-end host replay: AX reader cache -> production collector -> autokill
// consumer -> touch stub. Instruction-level constants are checked separately
// against the immutable AX 1.2.8 binary oracle.
#include "../lara/kexploit/wz/YuanbaoCollector.mm"
#include "../lara/kexploit/wzesp.mm"

#include <atomic>
#include <cassert>
#include <cstring>
#include <map>

extern "C" bool wzaim_runtime_consume_snapshot(
        const KoiEntity *, size_t, const KoiRuntimeDiagnostics *,
        const KoiProjectionState *) {
    return false;
}

static std::map<uint64_t, uint8_t> memory;
static std::atomic<int> touchCalls{0};
static std::atomic<bool> acceptTouch{true};
static wzax_touch_completion_t touchCompletion = nullptr;
static void *touchCompletionContext = nullptr;

template<class T> void put(uint64_t address, const T &value) {
    const auto *bytes = reinterpret_cast<const uint8_t *>(&value);
    for (size_t index = 0; index < sizeof(T); ++index)
        memory[address + index] = bytes[index];
}

static void putIntChain(uintptr_t base, const uintptr_t *offsets,
                        size_t count, uintptr_t storage, int32_t value) {
    uintptr_t cursor = base;
    for (size_t index = 0; index + 1 < count; ++index) {
        const uintptr_t next = storage + index * 0x1000;
        put(cursor + offsets[index], next);
        cursor = next;
    }
    put(cursor + offsets[count - 1], value);
}

static void putHeroPosition(uintptr_t actor, uintptr_t storage,
                            const AXActorCache::Raw &raw) {
    put(actor + 0x268, storage);
    put(storage + 0x10, storage + 0x1000);
    put(storage + 0x1000, storage + 0x2000);
    put(storage + 0x2060, storage + 0x3000);
    put(storage + 0x3000, raw);
}

extern "C" long wz_read(uint64_t address, void *out, size_t size) {
    auto *bytes = static_cast<uint8_t *>(out);
    for (size_t index = 0; index < size; ++index) {
        const auto found = memory.find(address + index);
        if (found == memory.end()) return -1;
        bytes[index] = found->second;
    }
    return static_cast<long>(size);
}
extern "C" long wz_read_fresh_root(uint64_t address, void *out, size_t size,
                                   uint64_t *) {
    return wz_read(address, out, size);
}
extern "C" const char *wz_transport_name(void) { return "mock"; }
extern "C" bool wz_transport_ready(void) { return true; }
extern "C" void wz_invalidate_read_cache(void) {}
extern "C" bool wzax_touch_tap_async(
        double x, double y, bool fixed,
        wzax_touch_completion_t completion, void *context) {
    assert(x == 100.0 && y == 200.0 && fixed);
    ++touchCalls;
    if (!acceptTouch.load()) return false;
    touchCompletion = completion;
    touchCompletionContext = context;
    return true;
}
static void completeTouch(bool sent = true) {
    assert(touchCompletion != nullptr);
    const auto completion = touchCompletion;
    void *context = touchCompletionContext;
    touchCompletion = nullptr;
    touchCompletionContext = nullptr;
    completion(context, sent);
}
extern "C" uint32_t _dyld_image_count(void) { return 0; }
extern "C" const char *_dyld_get_image_name(uint32_t) { return nullptr; }
extern "C" const mach_header *_dyld_get_image_header(uint32_t) {
    return nullptr;
}
extern "C" void KoiProjectionReset(KoiProjectionState *state) {
    std::memset(state, 0, sizeof(*state));
}
extern "C" bool KoiProjectionRefresh(uintptr_t, uint32_t width,
                                      uint32_t height,
                                      KoiProjectionState *state) {
    state->matrix[0] = state->matrix[5] = state->matrix[10] =
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
    float x, float, float z, float *screenX, float *screenY, float *depth) {
    *screenX = x; *screenY = z;
    if (depth) *depth = 1.0f;
    return true;
}
extern "C" bool KoiProjectionMinimapPoint(float x, float z, float origin,
    float side, float, float *outX, float *outY) {
    *outX = origin + side * 0.5f + x;
    *outY = side * 0.5f + z;
    return true;
}

int main() {
    constexpr uintptr_t unity = 0x101000000;
    constexpr uintptr_t root = 0x120000000;
    constexpr uintptr_t manager = 0x121000000;
    constexpr uintptr_t entries = 0x122000000;
    constexpr uintptr_t enemy = 0x123000000;
    constexpr uintptr_t friendly = 0x123100000;
    constexpr uintptr_t health = 0x124000000;
    constexpr uintptr_t candidateOwner = 0x125000000;
    constexpr uintptr_t candidate = 0x126000000;

    put(unity + 0x1325A6C0, root);
    put(root + 0x138, manager);
    put(manager + 0x78, entries);
    put(manager + 0x94, int32_t(2));
    put(entries, enemy);
    put(entries + 0x18, friendly);
    const int32_t header[4]{101, 0, 0, 2};
    const int32_t friendlyHeader[4]{102, 0, 0, 1};
    put(enemy + 0x50, header);
    put(friendly + 0x50, friendlyHeader);
    const AXActorCache::Raw targetRaw{2000, 0, 1000, 0};
    putHeroPosition(enemy, 0x127000000, targetRaw);
    put(enemy + 0x1A0, health);
    put(health + 0x160, int32_t(100 * 8192));
    put(health + 0x170, int32_t(1000));
    put(unity + 0x1325A828, candidateOwner);
    put(candidateOwner, candidate);
    put(candidate, targetRaw);

    uintptr_t host = 0x130000000;
    put(unity + 0x123FBC88, host);
    for (uintptr_t offset : {uintptr_t(0x138), uintptr_t(0x2C8),
                             uintptr_t(0x48), uintptr_t(0x170)}) {
        const uintptr_t next = host + 0x1000;
        put(host + offset, next);
        host = next;
    }
    const int32_t hostPosition[3]{1000, 0, 1000};
    put(host + 0x150, hostPosition);

    constexpr uintptr_t gateA[]{0x127E39D0, 0xA8, 0xE0, 0x170,
                                0x150, 0x150, 0xDC};
    constexpr uintptr_t gateB[]{0x123FA130, 0xA8, 0x48, 0xE0,
                                0x170, 0x150, 0x3A8};
    putIntChain(unity, gateA, std::size(gateA), 0x140000000, 0);
    putIntChain(unity, gateB, std::size(gateB), 0x150000000, 0);

    wzesp_reset();
    ResetSkillCachesForUnity(unity);
    gCacheActorManager = manager;
    gAXCoordinateRoot.base = unity;
    gAXCoordinateRoot.value = candidate;
    gAXCoordinateRoot.nextProbe = UINT64_MAX;
    gAXHeroCache.assign(1, {});
    gAXHeroCache[0].actor = enemy;
    gAXHeroCache[0].raw = targetRaw;
    gAXHeroCache[0].valid = true;
    gAXHeroCache[0].assigned = candidate;

    YuanbaoCollectorReadersStart(1);
    assert(YuanbaoCollectorAutoKillReaderTick(
        unity, 1, YuanbaoReaderHostPosition | YuanbaoReaderAutoKill) ==
        YuanbaoReaderTickPublished);

    wzesp_config_t config{};
    config.flags = WZESP_AUTO_KILL;
    config.clickX = 100.0;
    config.clickY = 200.0;
    config.clickCoordinatesValid = 1;
    config.clickSpaceFixed = 1;
    wzesp_item_t items[8]{};

    (void)wzesp_tick(unity, 1000, 500, &config, items, 8);
    assert(touchCalls == 1 && wzesp_stats().autoKillState == 4);
    (void)wzesp_tick(unity, 1000, 500, &config, items, 8);
    assert(touchCalls == 1 && wzesp_stats().autoKillState == 3);
    completeTouch();

    acceptTouch.store(false);
    (void)wzesp_tick(unity, 1000, 500, &config, items, 8);
    assert(touchCalls == 2 && wzesp_stats().autoKillState == 5);
    assert(g_autoKillSubmitBusy.load() == 0);

    acceptTouch.store(true);
    (void)wzesp_tick(unity, 1000, 500, &config, items, 8);
    assert(touchCalls == 3 && wzesp_stats().autoKillState == 4);
    completeTouch();

    {
        std::lock_guard<std::mutex> guard(gAXAutoKillReaderLock);
        gAXAutoKillSample.autoKillGateB = 1;
    }
    (void)wzesp_tick(unity, 1000, 500, &config, items, 8);
    assert(touchCalls == 3 && wzesp_stats().autoKillState == 1);

    {
        std::lock_guard<std::mutex> guard(gAXAutoKillReaderLock);
        gAXAutoKillSample.autoKillGateB = 0;
    }
    put(health + 0x160, int32_t(900 * 8192));
    (void)wzesp_tick(unity, 1000, 500, &config, items, 8);
    assert(touchCalls == 3 && wzesp_stats().autoKillState == 6);

    YuanbaoCollectorReadersStop(2);
}
