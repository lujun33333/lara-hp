#include "../lara/overlay/CoreSetSerialActionGate.h"
#include <cassert>

using namespace CoreSet;

static ActionContext context(uint64_t token) {
    ActionContext value{};
    value.pid = 15915; value.imageBase = 0x100000000; value.readGeneration = 7;
    value.controller = 0x123450000; value.hostGeneration = 9; value.configRevision = 11;
    value.lane = 1; value.slot = 1; value.axis = 3;
    value.requestToken[0] = (uint8_t)token;
    value.snapshotID[0] = (uint8_t)(token + 1);
    return value;
}

int main() {
    SerialActionGate gate;
    auto first = context(1);
    assert(gate.begin(first, first, 10.0, 10.1));
    assert(gate.inFlight());
    assert(gate.authorizes(first, first, 10.2));
    assert(!gate.begin(first, first, 10.0, 10.2));
    gate.finish();
    assert(!gate.inFlight());
    assert(!gate.begin(first, first, 10.2, 10.3));

    auto second = context(2);
    assert(gate.begin(second, second, 11.0, 11.1));
    assert(!gate.authorizes(first, second, 11.2));
    assert(gate.authorizes(second, second, 11.2));
    gate.finish();
    assert(!gate.begin(first, first, 10.0, 11.3));

    assert(!gate.begin(second, second, 11.0, 11.6));
    gate.stop();
    assert(gate.stopped());
    assert(!gate.begin(second, second, 12.0, 12.1));
    assert(!gate.authorizes(second, second, 12.1));
    return 0;
}
