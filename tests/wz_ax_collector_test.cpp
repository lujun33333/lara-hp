// Executes the production AX readers against a byte-addressed mock transport.
#include "../lara/kexploit/wz/YuanbaoCollector.mm"
#include <cassert>
#include <map>

static std::map<uint64_t, uint8_t> memory;
template<class T> void put(uint64_t address, const T &value) {
    const uint8_t *bytes = reinterpret_cast<const uint8_t *>(&value);
    for (size_t i = 0; i < sizeof(T); ++i) memory[address + i] = bytes[i];
}
extern "C" long wz_read(uint64_t address, void *out, size_t size) {
    auto *bytes = static_cast<uint8_t *>(out);
    for (size_t i = 0; i < size; ++i) {
        auto found = memory.find(address + i);
        if (found == memory.end()) return -1;
        bytes[i] = found->second;
    }
    return static_cast<long>(size);
}
extern "C" long wz_read_fresh_root(uint64_t address, void *out, size_t size,
                                   uint64_t *) {
    return wz_read(address, out, size);
}
extern "C" const char *wz_transport_name(void) { return "mock"; }
extern "C" uint64_t wz_test_read_cache_invalidation_count;
extern "C" uint64_t wz_test_projection_invalidation_count;

int main() {
    MemoryReader reader;
    constexpr uintptr_t cacheBase = 0x101000000;
    constexpr uintptr_t cacheFirst = 0x102000000;
    constexpr uintptr_t cacheSecond = 0x103000000;
    constexpr uintptr_t cacheOffsets[]{0x10, 0x20};
    put(cacheBase + 0x10, cacheFirst);
    AXPointerChainCache chainCache{};
    assert(ResolveAXCachedChainAddress(
        reader, cacheBase, cacheOffsets, 2, 100, &chainCache) ==
        cacheFirst + 0x20);
    assert(chainCache.expires == UINT64_C(2000000100));
    put(cacheBase + 0x10, cacheSecond);
    assert(ResolveAXCachedChainAddress(
        reader, cacheBase, cacheOffsets, 2, UINT64_C(1000000000),
        &chainCache) == cacheFirst + 0x20);
    assert(ResolveAXCachedChainAddress(
        reader, cacheBase, cacheOffsets, 2, UINT64_C(2000000100),
        &chainCache) == cacheSecond + 0x20);

    constexpr uintptr_t actor = 0x110000000;
    constexpr uintptr_t pos = 0x120000000;
    constexpr uintptr_t hp = 0x130000000;
    put(actor + 0x268, pos);
    put(pos + 0x10, pos + 0x1000);
    put(pos + 0x1000, pos + 0x2000);
    put(pos + 0x2060, pos + 0x3000);
    const int32_t xyz[3]{1000, 9000, -2000};
    put(pos + 0x3000, xyz);
    put(actor + 0x1A0, hp);
    put(hp + 0x160, int32_t(100 * 8192));
    put(hp + 0x170, int32_t(1000));
    KoiEntity entity{};
    ReadAXEntityState(reader, actor, true, &entity);
    assert(entity.axPositionValid && entity.axWorldX == 1 &&
           entity.axWorldY == 9 && entity.axWorldZ == -2);
    assert(entity.axHealthValid && entity.axHealth == 100 && entity.axHealthTotal == 1000);
    assert(!entity.axDead);
    put(hp + 0x160, int32_t(0));
    ReadAXEntityState(reader, actor, true, &entity);
    assert(!entity.axDead);

    constexpr uintptr_t skillOwner = 0x131000000;
    constexpr uintptr_t skillState = 0x132000000;
    put(actor + 0x280, skillOwner);
    put(skillOwner + 0x68, skillState);
    put(skillState + 0x34, int32_t(80115));
    put(skillState + 0x14, int32_t(80102));
    int32_t summonerSkillId = 0;
    assert(ReadAXSummonerSkillId(reader, actor, 1, &summonerSkillId));
    assert(summonerSkillId == 80115);
    assert(ReadAXSummonerSkillId(reader, actor, 2, &summonerSkillId));
    assert(summonerSkillId == 80102);
    ReadAXEntityState(reader, actor, true, &entity);
    assert(entity.axDead);
    put(hp + 0x160, int32_t(100 * 8192));
    ReadAXEntityState(reader, actor, true, &entity);
    assert(entity.axDead);
    ReadAXEntityState(reader, actor, true, &entity);
    assert(!entity.axDead);
    KoiRuntimeDiagnostics diagnostics{};
    diagnostics.hostPositionValid = 1;
    diagnostics.autoKillSampleValid = 1;
    assert(!ReadAXHostPosition(reader, 0x140000000, &diagnostics));
    assert(!diagnostics.hostPositionValid);
    ReadAXAutoKillState(reader, 0x140000000, &diagnostics);
    assert(!diagnostics.autoKillSampleValid);

    // AX 0x10080dc90..0x10080dca8 clears the matrix terminal and invokes the
    // same global reset when either cached world root changes non-zero value.
    memory.clear();
    constexpr uintptr_t rootUnity = 0x180000000;
    constexpr uintptr_t oldActorRoot = 0x181000000;
    constexpr uintptr_t newActorRoot = 0x182000000;
    constexpr uintptr_t rootManager = 0x183000000;
    put(rootUnity + kActorRootRVA, newActorRoot);
    put(newActorRoot + 0x138, rootManager);
    put(rootManager + 0x78, uintptr_t(0x184000000));
    put(rootManager + 0x94, int32_t(2));
    gAXActorRoot = {};
    gAXActorRoot.base = rootUnity;
    gAXActorRoot.value = oldActorRoot;
    gAXActorRoot.nextProbe = 0;
    const uint64_t actorTransportResets =
        wz_test_read_cache_invalidation_count;
    const uint64_t actorProjectionResets =
        wz_test_projection_invalidation_count;
    KoiActorTables rootTables{};
    KoiRuntimeDiagnostics rootDiagnostics{};
    assert(ResolveActorTables(
        reader, rootUnity, false, &rootTables, &rootDiagnostics));
    assert(gAXActorRoot.value == newActorRoot);
    assert(wz_test_read_cache_invalidation_count == actorTransportResets + 1);
    assert(wz_test_projection_invalidation_count == actorProjectionResets + 1);

    constexpr uintptr_t coordinateOwner = 0x185000000;
    constexpr uintptr_t oldCoordinateRoot = 0x186000000;
    constexpr uintptr_t newCoordinateRoot = 0x187000000;
    put(rootUnity + 0x1325A828, coordinateOwner);
    put(coordinateOwner, newCoordinateRoot);
    gAXCoordinateRoot = {};
    gAXCoordinateRoot.base = rootUnity;
    gAXCoordinateRoot.value = oldCoordinateRoot;
    gAXCoordinateRoot.nextProbe = 0;
    const uint64_t coordinateTransportResets =
        wz_test_read_cache_invalidation_count;
    const uint64_t coordinateProjectionResets =
        wz_test_projection_invalidation_count;
    const std::vector<uintptr_t> noActors;
    const std::vector<KoiHeroHeader> noHeaders;
    UpdateAXHeroCoordinates(
        reader, rootUnity, rootTables, noActors, noHeaders, 1);
    assert(gAXCoordinateRoot.value == newCoordinateRoot);
    assert(gAXActorRoot.value == newActorRoot);
    assert(wz_test_read_cache_invalidation_count ==
           coordinateTransportResets + 1);
    assert(wz_test_projection_invalidation_count ==
           coordinateProjectionResets + 1);

    // AX 0x100805a3c..0x100805a68 resets on the third consecutive producer
    // miss (the comparison uses the old count == 2), but not on miss one/two.
    gReadinessConfidence = 0;
    gProducerReady = false;
    UpdateProducerReadiness(true);
    const uint64_t readinessResets =
        wz_test_read_cache_invalidation_count;
    UpdateProducerReadiness(false);
    UpdateProducerReadiness(false);
    assert(gReadinessConfidence == 2 && gProducerReady);
    assert(wz_test_read_cache_invalidation_count == readinessResets);
    UpdateProducerReadiness(false);
    assert(gReadinessConfidence == 0 && !gProducerReady);
    assert(wz_test_read_cache_invalidation_count == readinessResets + 1);

    memory.clear();
    constexpr uintptr_t unity = 0x140000000;
    uintptr_t cursor = 0x150000000;
    // AX host position producer 0x100812454: decoded chain
    // 123FBC88 -> 138 -> 2C8 -> 48 -> 170, terminal address +150.
    put(unity + 0x123FBC88, cursor);
    for (uintptr_t offset : {uintptr_t(0x138), uintptr_t(0x2C8),
                             uintptr_t(0x48), uintptr_t(0x170)}) {
        const uintptr_t next = cursor + 0x1000;
        put(cursor + offset, next);
        cursor = next;
    }
    const int32_t hostPosition[3]{12000, 0, -8000};
    put(cursor + 0x150, hostPosition);

    YuanbaoCollectorInput input{};
    input.featureMask = KoiFeatureHero;
    input.collectExposure = 1;
    input.collectAutoKill = 1;
    KoiProjectionState projection{};
    projection.valid = 1;
    projection.matrix[0] = 1.0f;
    KoiEntity output[4]{};
    diagnostics = {};
    ResetSkillCachesForUnity(unity);
    YuanbaoCollectorReadersStart(1);
    assert(YuanbaoCollectorAutoKillReaderTick(
        unity, 1, YuanbaoReaderHostPosition | YuanbaoReaderAutoKill) ==
        YuanbaoReaderTickPublished);
    (void)YuanbaoCollectorGather(unity, &input, output, 4,
                                 &projection, &diagnostics);
    // A failed 0x100811160 autokill-gate snapshot must not erase the
    // independently successful 0x100812454 host-position sample.
    assert(diagnostics.hostPositionValid);
    assert(diagnostics.hostWorldX == 12.0f);
    assert(diagnostics.hostWorldZ == -8.0f);
    assert(!diagnostics.autoKillSampleValid);
    YuanbaoCollectorReadersStop(2);
}
