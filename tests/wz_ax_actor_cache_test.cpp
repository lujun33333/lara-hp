#include "../lara/kexploit/wz/WZAXActorCache.h"
#include <cassert>
#include <cstring>
#include <map>

using namespace AXActorCache;
int main() {
    constexpr uintptr_t base = 0x110000000;
    std::map<uintptr_t, Raw> memory;
    size_t reads = 0;
    auto read = [&](uintptr_t address, void *out, size_t size) {
        ++reads;
        auto it = memory.find(address);
        if (it == memory.end()) return false;
        assert(size == sizeof(Raw)); std::memcpy(out, &it->second, size); return true;
    };
    std::vector<Entry> entries(1);
    entries[0].actor = base + 0x10000;
    entries[0].raw = {1000, 0, 2000};
    entries[0].valid = entries[0].moved = true;
    memory[base + 599 * 16] = {1010, 0, 2010};
    memory[base + 600 * 16] = {1000, 0, 2000}; // Must never scan item 601.
    Update(entries, base, {}, 0, read);
    assert(reads == 600 && entries[0].pending == base + 599 * 16);
    assert(!entries[0].assigned);
    Update(entries, base, {}, 99999999, read);
    assert(reads == 600); // deadline excludes early samples
    memory[base + 599 * 16].x++;
    Update(entries, base, {}, 100000000, read);
    assert(entries[0].confirmations == 1 && !entries[0].assigned);
    memory[base + 599 * 16].x++;
    Update(entries, base, {}, 200000000, read);
    assert(entries[0].assigned == base + 599 * 16 && !entries[0].pending);
    const size_t afterCommit = reads;
    Update(entries, base, {}, 500000000, read);
    assert(reads == afterCommit); // assigned cache is reused

    entries[0].assigned = 0;
    Update(entries, base, {}, 600000000, read);
    Update(entries, base, {}, 700000000, read); // stationary pending is rejected
    assert(!entries[0].assigned && !entries[0].pending);
    std::vector<Raw> excluded{memory[base + 599 * 16]};
    Update(entries, base, excluded, 800000000, read);
    assert(!entries[0].pending);
    Entry other{}; other.raw = {1100, 0, 2100}; other.valid = true;
    entries.push_back(other);
    assert(!Unambiguous(entries, 0, {1000, 0, 2000}));
    entries[1].raw = {1551, 0, 2000};
    assert(Unambiguous(entries, 0, {1000, 0, 2000}));
    assert(!Valid({0, 0, 1}) && !Valid({1, 0, 60001}));
    assert(Valid({-60000, 0, 60000}));
    Root root;
    int probes = 0;
    auto resolve = [&] { ++probes; return base; };
    assert(root.Refresh(base, 0, 350000000, resolve));
    assert(!root.Refresh(base, 349999999, 350000000, resolve) && probes == 1);
    assert(!root.Refresh(base, 350000000, 350000000, resolve) && probes == 2);
    root.Refresh(base, 700000000, 350000000, [] { return uintptr_t(0); });
    assert(root.value == base && root.nextProbe == 750000000);
    assert(root.Refresh(base + 1, 700000001, 500000000, resolve));
    assert(root.nextProbe == 1200000001);
    SamplingBackoff sampling;
    sampling.Complete(true, 0, 24999999);
    assert(sampling.Due(24999999) && sampling.failures == 0);
    sampling.Complete(true, 0, 25000000);
    assert(!sampling.Due(124999999) && sampling.Due(125000000));
    sampling.Complete(false, 125000000, 125000000);
    assert(sampling.nextSample == 325000000);
    sampling.Complete(false, 325000000, 325000000);
    assert(sampling.nextSample == 725000000);
    sampling.Complete(false, 725000000, 725000000);
    assert(sampling.nextSample == 1525000000);
    sampling.Complete(false, 1525000000, 1525000000);
    assert(sampling.nextSample == 2525000000);
    sampling.Complete(true, 2525000000, 2525000001);
    assert(sampling.nextSample == 0 && sampling.failures == 0);
    AuxiliaryTable auxiliary;
    std::array<uint8_t, 0x1C8> table{};
    for (uint32_t i = 0; i < 5; ++i) {
        uint32_t id = 101 + i, a = (i + 1) * 8192000, b = (i + 10) * 8192000;
        std::memcpy(table.data() + i * 0x38, &id, 4);
        std::memcpy(table.data() + i * 0x38 + 0x14, &a, 4);
        std::memcpy(table.data() + i * 0x38 + 0x20, &b, 4);
    }
    bool readable = true;
    uint32_t tableReads = 0, discoveries = 0;
    auto readTable = [&](uintptr_t address, void *out, size_t size) {
        assert(address == base && size == table.size()); ++tableReads;
        if (!readable) return false;
        std::memcpy(out, table.data(), size); return true;
    };
    auto discover = [&] { ++discoveries; return base; };
    auxiliary.Poll(0, readTable, discover);
    auxiliary.Poll(19999999999, readTable, discover);
    assert(discoveries == 0 && tableReads == 0);
    auxiliary.Poll(20000000000, readTable, discover);
    assert(auxiliary.valid && discoveries == 1 && tableReads == 1);
    int32_t a = 0, b = 0;
    assert(auxiliary.Cooldowns(105, &a, &b) && a == 5 && b == 14);
    assert(!auxiliary.Cooldowns(999, &a, &b));
    auxiliary.Poll(20041666666, readTable, discover);
    assert(tableReads == 1); // 24Hz cached buffer reuse
    auxiliary.Poll(20041666667, readTable, discover);
    assert(tableReads == 2);
    readable = false;
    auxiliary.Poll(20083333334, readTable, discover);
    auxiliary.Poll(20125000001, readTable, discover);
    assert(auxiliary.address == base && !auxiliary.valid);
    auxiliary.Poll(20166666668, readTable, discover);
    assert(auxiliary.address == 0 && auxiliary.nextDiscovery == 40166666668);
    readable = true;
    auxiliary.Poll(40166666667, readTable, discover);
    assert(discoveries == 1);
    auxiliary.Poll(40166666668, readTable, discover);
    assert(discoveries == 2 && auxiliary.valid);

    AuxiliaryTable missing;
    uint32_t missingDiscoveries = 0;
    auto missingDiscover = [&] {
        ++missingDiscoveries;
        return uintptr_t(0);
    };
    missing.Poll(0, readTable, missingDiscover);
    missing.Poll(20000000000, readTable, missingDiscover);
    assert(missingDiscoveries == 1 && missing.attempts == 1);
    assert(!missing.exhausted &&
           missing.nextDiscovery == UINT64_C(40000000000));
    missing.Poll(39999999999, readTable, missingDiscover);
    assert(missingDiscoveries == 1 && !missing.exhausted);
    missing.Poll(40000000000, readTable, missingDiscover);
    // 0x100810e48 increments the attempt counter; 0x100810f00 compares the
    // old value with zero. Only the second failed discovery reaches f30 and
    // enables the direct-timer fallback.
    assert(missingDiscoveries == 2 && missing.attempts == 2);
    assert(missing.exhausted);
}
