#include "../lara/kexploit/wz/YuanbaoCollector.mm"
#include <cassert>
#include <map>
static std::map<uint64_t, uint8_t> memory;
template<class T> void put(uint64_t address, const T &value) {
    const auto *bytes = reinterpret_cast<const uint8_t *>(&value);
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
extern "C" const char *wz_transport_name() { return "mock"; }
extern "C" long wz_read_fresh_root(uint64_t address, void *out, size_t size, uint64_t *) {
    return wz_read(address, out, size);
}
int main() {
    constexpr uintptr_t unity = 0x100000000, root = 0x110000000;
    constexpr uintptr_t manager = 0x120000000, heroes = 0x130000000;
    constexpr uintptr_t soldiers = 0x140000000;
    MemoryReader reader;
    put(unity + 0x1325A6C0, root);
    put(root + 0x138, manager);
    put(manager + 0x78, heroes);
    put(manager + 0x94, int32_t(20));
    put(manager + 0x120, soldiers);
    put(manager + 0x13C, int32_t(128));
    KoiActorTables tables{};
    KoiRuntimeDiagnostics diagnostics{};
    assert(ResolveActorTables(reader, unity, true, &tables, &diagnostics));
    assert(tables.heroTableValid && tables.heroCount == 20 && tables.soldierCount == 128);
    put(manager + 0x94, int32_t(21));
    put(manager + 0x13C, int32_t(129));
    put(manager + 0x108, soldiers);
    put(manager + 0x124, int32_t(10)); // old alternative must not rescue invalid AX table
    tables = {};
    assert(ResolveActorTables(reader, unity, true, &tables, &diagnostics));
    assert(!tables.heroTableValid && tables.soldierEntries == 0);
    std::vector<uintptr_t> actors;
    for (int i = 0; i < 12; ++i) {
        const uintptr_t actor = 0x150000000 + i * 0x1000;
        actors.push_back(actor);
        int32_t header[4]{101+i, 0, 0, 2};
        put(actor + 0x50, header); // only 16B mapped: former 544B read fails
    }
    KoiProjectionState projection{}; projection.valid = 1; projection.matrix[0] = 1;
    KoiHostIdentity host{};
    std::vector<KoiHeroHeader> headers;
    uint32_t failures = 0;
    assert(CollectHeroHeaders(reader, unity, actors, projection, &host,
                              &failures, &headers, nullptr));
    assert(headers.size() == 10 && host.camp == 1);
    put(actors[0] + 0x50, int32_t(100));
    put(actors[1] + 0x50, int32_t(801));
    put(actors[2] + 0x5C, int32_t(1));
    put(actors[3] + 0x50, int32_t(105)); // duplicate of actor index 4
    headers.clear();
    std::vector<KoiHeroHeader> friendlyObservers;
    CollectHeroHeaders(reader, unity, actors, projection, &host,
                       &failures, &headers, &friendlyObservers);
    assert(headers.size() == 8);
    // AX 0x10080e464/0x10080eb2c keeps the friendly hero coordinate vector
    // for the exposure consumer instead of dropping it with enemy filtering.
    assert(friendlyObservers.size() == 1);
    assert(friendlyObservers[0].actor == actors[2]);

    // AX's 0x1008064ec enemy-vector cap does not belong to the independent
    // friendly observer chains at 0x10080e464/0x10080eb2c.
    for (int i = 0; i < 12; ++i) {
        int32_t friendlyHeader[4]{201 + i, 0, 0, 1};
        put(actors[i] + 0x50, friendlyHeader);
    }
    headers.clear();
    friendlyObservers.clear();
    CollectHeroHeaders(reader, unity, actors, projection, &host,
                       &failures, &headers, &friendlyObservers);
    assert(headers.empty());
    assert(friendlyObservers.size() == 12);
    uintptr_t cursor = 0x160000000;
    put(unity + 0x126DAF40, cursor);
    for (uintptr_t offset : {uintptr_t(0xB0), uintptr_t(8), uintptr_t(0x1A0), uintptr_t(8), uintptr_t(0x30)}) {
        put(cursor + offset, cursor + 0x1000); cursor += 0x1000;
    }
    put(cursor + 0x750, int32_t(0x4A65));
    std::array<uint8_t, 0x1C8> aux{};
    for (int32_t i = 0; i < 5; ++i) {
        const int32_t id = 101 + i;
        std::memcpy(aux.data() + i * 0x38, &id, sizeof(id));
    }
    put(cursor + 0x220, aux);
    AXActorCache::AuxiliaryTable auxiliaryTable{};
    auxiliaryTable.started = true;
    UpdateAXAuxiliaryTable(reader, unity, &auxiliaryTable);
    assert(auxiliaryTable.valid && auxiliaryTable.address == cursor + 0x220);

    // AX increments the miss counter, compares the old value with two, then
    // 0x100805a64 invokes reset 0x1008071d0 on miss three. The reset clears
    // both producer-ready and the miss counter itself.
    ResetSkillCaches();
    UpdateProducerReadiness(true);
    assert(gProducerReady && gReadinessConfidence == 0);
    UpdateProducerReadiness(false);
    UpdateProducerReadiness(false);
    assert(gProducerReady && gReadinessConfidence == 2);
    UpdateProducerReadiness(false);
    assert(!gProducerReady && gReadinessConfidence == 0);
    UpdateProducerReadiness(true);
    assert(gProducerReady && gReadinessConfidence == 0);

    memory.clear();
    constexpr uintptr_t unity2 = 0x210000000;
    constexpr uintptr_t hero = 0x220000000;
    constexpr uintptr_t candidateRoot = 0x230000000;
    constexpr uintptr_t monsterRoot = 0x240000000;
    constexpr uintptr_t monsterOwner = 0x250000000;
    constexpr uintptr_t monsterState = 0x260000000;
    constexpr uintptr_t monsterEntries = 0x270000000;
    constexpr uintptr_t monsterActor = 0x280000000;
    uintptr_t position = 0x290000000;
    put(hero + 0x268, position);
    for (uintptr_t offset : {uintptr_t(0x10), uintptr_t(0), uintptr_t(0x60)}) {
        const uintptr_t next = position + 0x1000;
        put(position + offset, next);
        position = next;
    }
    const AXActorCache::Raw current{1000, 0, 2000, 0};
    put(position, current);
    put(hero + 0x5C, int32_t(2));
    put(candidateRoot, current);
    put(unity2 + 0x127E3240, monsterRoot);
    put(monsterRoot + 0x3B8, monsterOwner);
    put(monsterOwner + 0x88, monsterState);
    put(monsterState + 0x140, monsterEntries);
    // AX 0x10080f070/0x10080f098/0x10080f33c use slot * 0x18.
    // Slot 8 is outside the incorrect i*8 scan range and catches that bug.
    put(monsterEntries + 8 * 0x18, monsterActor);
    put(monsterActor + 0x2B8, current.x);
    put(monsterActor + 0x2BC, current.y);
    put(monsterActor + 0x2C0, current.z);

    gAXCoordinateRoot = {};
    gAXCoordinateRoot.base = unity2;
    gAXCoordinateRoot.value = candidateRoot;
    gAXCoordinateRoot.nextProbe = UINT64_MAX;
    gAXHeroCache.assign(1, {});
    gAXHeroCache[0].actor = hero;
    gAXHeroCache[0].raw = {900, 0, 1900, 0};
    gAXHeroCache[0].valid = true;
    KoiActorTables cacheTables{};
    cacheTables.manager = 0x2A0000000;
    std::vector<uintptr_t> cacheActors{hero};
    std::vector<KoiHeroHeader> cacheHeaders(1);
    cacheHeaders[0].actor = hero;
    cacheHeaders[0].configId = 101;
    cacheHeaders[0].camp = 2;
    UpdateAXHeroCoordinates(reader, unity2, cacheTables, cacheActors,
                            cacheHeaders, 1);
    assert(gAXHeroCache[0].moved);
    assert(gAXHeroCache[0].pending == 0);
}
