#define CORESET_READ_BUFFER_CONTRACT_ONLY
#include "../lara/overlay/CoreSetReadSession.h"
#include <array>
#include <cassert>
#include <cstdio>
#include <vector>

int main() {
    using coreset_read_contract::clearDestination;
    using coreset_read_contract::maximumLength;
    std::array<unsigned char, 10> guarded;
    guarded.fill(0xA5);
    assert(clearDestination(guarded.data() + 1, 8));
    assert(guarded.front() == 0xA5 && guarded.back() == 0xA5);
    for (size_t index = 1; index < 9; ++index) assert(guarded[index] == 0);

    guarded.fill(0xA5);
    assert(!clearDestination(nullptr, 8));
    assert(!clearDestination(guarded.data(), 0));
    assert(!clearDestination(guarded.data(), maximumLength + 1));
    for (unsigned char byte : guarded) assert(byte == 0xA5);

    std::vector<unsigned char> limit(maximumLength + 2, 0x7C);
    assert(clearDestination(limit.data() + 1, maximumLength));
    assert(limit.front() == 0x7C && limit.back() == 0x7C);
    for (size_t index = 1; index <= maximumLength; ++index) assert(limit[index] == 0);
    std::puts("PASS: bounded destination clear, invalid-span rejection and guard bytes");
}
