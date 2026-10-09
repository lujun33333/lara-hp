#include "../lara/overlay/CoreSetBattlePublication.h"

#include <cassert>
#include <cmath>
#include <cstring>
#include <iostream>

using namespace CoreSet;

static ActionCandidatePublicationInput input(uint64_t key, double now,
                                              ActionPublicationIdentity identity = {7, 42, 0x100000000, 0x200000000}) {
    ActionCandidatePublicationInput value;
    value.identity = identity; value.candidateKey = key;
    value.target = {100, 200, 300}; value.camera = {10, 20, 30};
    value.bestPixels = 25; value.radius = 100; value.capturedAt = now;
    return value;
}

int main() {
    static_assert(sizeof(CoreSetActionCandidateRawRecord) == 0x3a);
    static_assert(offsetof(CoreSetActionCandidateRawRecord, publicationSerial) == 0x30);
    static_assert(std::is_standard_layout_v<CoreSetActionInputAuthorityRawRecord>);
    ActionCandidatePublicationState state;
    ActionCandidatePublicationCopy copy{};
    assert(state.publish(input(11, 1), &copy));
    assert(copy.record.publicationSerial == 1 && !copy.record.sameAsPrevious && !copy.record.hadPrevious);
    assert(std::fabs(copy.record.normalizedScreenError - .25f) < .00001f);
    for (uint8_t byte : copy.record.reserved01) assert(byte == 0);
    for (uint8_t byte : copy.record.reserved2C) assert(byte == 0);
    assert(state.publish(input(11, 1.01), &copy));
    assert(copy.record.publicationSerial == 2 && copy.record.sameAsPrevious && copy.record.hadPrevious);
    assert(copy.record.normalizedScreenError == 0);
    assert(state.publish(input(12, 1.02), &copy));
    assert(copy.record.publicationSerial == 3 && !copy.record.sameAsPrevious && copy.record.hadPrevious);
    assert(state.publishMissing({7, 42, 0x100000000, 0x200000000}, 1.095, &copy));
    assert(copy.record.publicationSerial == 4 && copy.record.sameAsPrevious && copy.record.hadPrevious);
    assert(!state.publishMissing({7, 42, 0x100000000, 0x200000000}, 1.170000002, &copy));
    assert(!state.copy(&copy));
    assert(state.serial() == 4);
    assert(state.publish(input(13, 2, {8, 42, 0x100000000, 0x200000000}), &copy));
    assert(copy.record.publicationSerial == 5 && !copy.record.sameAsPrevious && !copy.record.hadPrevious);
    auto bad = input(14, 3); bad.target[0] = NAN;
    assert(!state.publish(bad, &copy));
    assert(state.serial() == 5);
    state.clear(); assert(!state.copy(&copy)); assert(state.serial() == 5);
    std::cout << "PASS: exact 0x3a action publication, serial, identity and 75ms prior-key\n";
}
