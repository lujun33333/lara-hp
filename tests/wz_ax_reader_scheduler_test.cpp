// Production reader behavior: independent progress, ordered publication and
// cancellation of a slow completion. Binary addresses are asserted by the
// companion wz_ax_collector_binary_oracle_test.py.
#include "../lara/kexploit/wz/YuanbaoCollector.mm"

#include <atomic>
#include <cassert>
#include <chrono>
#include <map>
#include <thread>

static std::map<uint64_t, uint8_t> memory;
static constexpr uintptr_t kAuxiliaryAddress = 0x1D0000000;
static constexpr uintptr_t kHostPositionAddress = 0x150004150;
static std::atomic<bool> blockAuxiliary{false};
static std::atomic<bool> auxiliaryEntered{false};
static std::atomic<bool> blockAutoKill{false};
static std::atomic<bool> autoKillEntered{false};

template<class T> void put(uint64_t address, const T &value) {
    const auto *bytes = reinterpret_cast<const uint8_t *>(&value);
    for (size_t i = 0; i < sizeof(T); ++i) memory[address + i] = bytes[i];
}

extern "C" long wz_read(uint64_t address, void *out, size_t size) {
    if (address == kAuxiliaryAddress && size == 0x1C8) {
        auxiliaryEntered.store(true, std::memory_order_release);
        while (blockAuxiliary.load(std::memory_order_acquire)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
    }
    if (address == kHostPositionAddress && size == 12) {
        autoKillEntered.store(true, std::memory_order_release);
        while (blockAutoKill.load(std::memory_order_acquire)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
    }
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
extern "C" const char *wz_transport_name(void) { return "mock"; }
extern "C" uint64_t wz_test_read_cache_invalidation_count;

int main() {
    using namespace KoiReaderScheduling;

    // A later publication wins; a delayed older completion is rejected.
    PublicationGate order;
    PublicationToken first{}, second{};
    order.Start(7);
    assert(order.Begin(7, &first));
    assert(order.Begin(7, &second));
    assert(order.Publish(second));
    assert(!order.Publish(first));

    constexpr uintptr_t unity = 0x140000000;
    uintptr_t cursor = 0x150000000;
    put(unity + 0x123FBC88, cursor);
    for (uintptr_t offset : {uintptr_t(0x138), uintptr_t(0x2C8),
                             uintptr_t(0x48), uintptr_t(0x170)}) {
        const uintptr_t next = cursor + 0x1000;
        put(cursor + offset, next);
        cursor = next;
    }
    const int32_t hostPosition[3]{12000, 0, -8000};
    put(cursor + 0x150, hostPosition);

    std::array<uint8_t, 0x1C8> auxiliary{};
    for (int32_t index = 0; index < 5; ++index) {
        const int32_t id = 101 + index;
        std::memcpy(auxiliary.data() + index * 0x38, &id, sizeof(id));
    }
    put(kAuxiliaryAddress, auxiliary);

    YuanbaoCollectorReadersStart(10);
    {
        std::lock_guard<std::mutex> guard(gAXAuxiliaryReaderLock);
        gAXAuxiliaryUnityBase = unity;
        gAXAuxiliaryTable.address = kAuxiliaryAddress;
        gAXAuxiliaryTable.valid = true;
        gAXAuxiliaryTable.nextRefresh = 0;
    }

    blockAuxiliary.store(true, std::memory_order_release);
    YuanbaoReaderTickResult slowResult = YuanbaoReaderTickSkipped;
    std::thread slow([&] {
        slowResult = YuanbaoCollectorAuxiliaryReaderTick(unity, 10);
    });
    while (!auxiliaryEntered.load(std::memory_order_acquire)) {
        std::this_thread::yield();
    }

    // The host/autokill producer is not serialized behind the blocked
    // auxiliary read and can publish immediately.
    assert(YuanbaoCollectorAutoKillReaderTick(
        unity, 10, YuanbaoReaderHostPosition) == YuanbaoReaderTickPublished);
    {
        std::lock_guard<std::mutex> guard(gAXAutoKillReaderLock);
        assert(gAXHostPositionSample.hostPositionValid);
        assert(gAXHostPositionSample.hostWorldX == 12.0f);
        assert(gAXHostPositionSample.hostWorldZ == -8.0f);
    }

    // AX 0x1008057b8 -> 0x1008071d0 increments both reader generations before
    // clearing caches. The blocked completion is stale, while a new reader in
    // the same external scene generation can publish immediately afterwards.
    const uint64_t oldAuxiliaryEpoch =
        gAXAuxiliaryEpoch.load(std::memory_order_acquire);
    const uint64_t oldAutoKillEpoch =
        gAXAutoKillEpoch.load(std::memory_order_acquire);
    const uint64_t oldConfigEpoch =
        gAXAutoKillConfigEpoch.load(std::memory_order_acquire);
    const uint64_t oldTransportInvalidations =
        wz_test_read_cache_invalidation_count;
    gReadinessConfidence = 2;
    gProducerReady = true;
    gCacheActorManager = UINT64_C(0x700000000);
    gAXLifeStates[UINT64_C(0x700001000)].dead = true;
    gAXHeroCache.push_back({});
    gAXActorRoot.value = UINT64_C(0x700002000);
    gAXCoordinateRoot.value = UINT64_C(0x700003000);
    gAXMonsterTimers.observed[0] = true;
    YuanbaoCollectorResetForTerminalChange();
    assert(gAXAuxiliaryEpoch.load(std::memory_order_acquire) ==
           oldAuxiliaryEpoch + 1);
    assert(gAXAutoKillEpoch.load(std::memory_order_acquire) ==
           oldAutoKillEpoch + 1);
    assert(gAXAutoKillConfigEpoch.load(std::memory_order_acquire) ==
           oldConfigEpoch + 1);
    assert(wz_test_read_cache_invalidation_count ==
           oldTransportInvalidations + 1);
    assert(gReadinessConfidence == 0 && !gProducerReady);
    assert(gCacheActorManager == 0);
    assert(gAXLifeStates.empty() && gAXHeroCache.empty());
    assert(gAXActorRoot.value == 0 && gAXCoordinateRoot.value == 0);
    assert(!gAXMonsterTimers.observed[0]);
    {
        std::lock_guard<std::mutex> guard(gAXAutoKillReaderLock);
        assert(!gAXHostPositionSample.hostPositionValid);
        assert(gAXHostPositionChain.address == 0);
        assert(gAXAutoKillGateAChain.address == 0);
        assert(gAXAutoKillGateBChain.address == 0);
    }
    blockAuxiliary.store(false, std::memory_order_release);
    slow.join();
    assert(slowResult == YuanbaoReaderTickStale);
    {
        std::lock_guard<std::mutex> guard(gAXAuxiliaryReaderLock);
        assert(gAXAuxiliaryTable.address == kAuxiliaryAddress);
        assert(!gAXAuxiliaryTable.valid);
    }
    assert(YuanbaoCollectorAuxiliaryReaderTick(
        unity, 10) == YuanbaoReaderTickPublished);
    {
        std::lock_guard<std::mutex> guard(gAXAuxiliaryReaderLock);
        assert(gAXAuxiliaryTable.address == kAuxiliaryAddress);
        assert(gAXAuxiliaryTable.valid);
    }
    assert(YuanbaoCollectorAutoKillReaderTick(
        unity, 10, YuanbaoReaderHostPosition) == YuanbaoReaderTickPublished);
    {
        std::lock_guard<std::mutex> guard(gAXAutoKillReaderLock);
        assert(gAXHostPositionSample.hostPositionValid);
    }

    // AX 0x100808e10..0x100808e1c owns a third, flags-only epoch. A slow
    // result from the old flags must not publish after the configuration flips.
    blockAutoKill.store(true, std::memory_order_release);
    autoKillEntered.store(false, std::memory_order_release);
    YuanbaoReaderTickResult oldFlagsResult = YuanbaoReaderTickSkipped;
    std::thread oldFlags([&] {
        oldFlagsResult = YuanbaoCollectorAutoKillReaderTick(
            unity, 10, YuanbaoReaderHostPosition);
    });
    while (!autoKillEntered.load(std::memory_order_acquire)) {
        std::this_thread::yield();
    }
    const uint64_t configEpochBeforeChange =
        gAXAutoKillConfigEpoch.load(std::memory_order_acquire);
    YuanbaoCollectorSetReaderFlags(
        YuanbaoReaderHostPosition | YuanbaoReaderAutoKill);
    assert(gAXAutoKillConfigEpoch.load(std::memory_order_acquire) ==
           configEpochBeforeChange + 1);
    blockAutoKill.store(false, std::memory_order_release);
    oldFlags.join();
    assert(oldFlagsResult == YuanbaoReaderTickStale);
    assert(YuanbaoCollectorAutoKillReaderTick(
        unity, 10, YuanbaoReaderHostPosition | YuanbaoReaderAutoKill) ==
        YuanbaoReaderTickPublished);

    // The ordinary scene stop still rejects an in-flight completion and does
    // not reopen publication for its old external generation.
    {
        std::lock_guard<std::mutex> guard(gAXAuxiliaryReaderLock);
        gAXAuxiliaryUnityBase = unity;
        gAXAuxiliaryTable.address = kAuxiliaryAddress;
        gAXAuxiliaryTable.valid = true;
        gAXAuxiliaryTable.nextRefresh = 0;
    }
    auxiliaryEntered.store(false, std::memory_order_release);
    blockAuxiliary.store(true, std::memory_order_release);
    slowResult = YuanbaoReaderTickSkipped;
    std::thread stoppedSlow([&] {
        slowResult = YuanbaoCollectorAuxiliaryReaderTick(unity, 10);
    });
    while (!auxiliaryEntered.load(std::memory_order_acquire)) {
        std::this_thread::yield();
    }
    YuanbaoCollectorReadersStop(11);
    blockAuxiliary.store(false, std::memory_order_release);
    stoppedSlow.join();
    assert(slowResult == YuanbaoReaderTickStale);
    assert(YuanbaoCollectorAuxiliaryReaderTick(
        unity, 10) == YuanbaoReaderTickStale);

    YuanbaoCollectorReadersStart(12);
    assert(YuanbaoCollectorAutoKillReaderTick(
        unity, 12, YuanbaoReaderHostPosition) == YuanbaoReaderTickPublished);
}
