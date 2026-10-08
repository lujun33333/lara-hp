#include "../lara/overlay/CoreSetGrenadeMotion.h"
#include <cassert>
#include <cstdio>
#include <limits>

int main() {
    using namespace CoreSet;
    const GrenadeMotionContext context = {9, 0x100000000, 123};
    const GrenadeMotionIdentity id = {0x200000000, 0x210000000, 6, 123};
    GrenadeMotionTracker tracker;
    assert(tracker.beginFrame(context, 0));
    assert(tracker.sample(context, id, {0, 0, 0}, 0).status == GrenadeMotionStatus::warm);
    assert(tracker.beginFrame(context, 0.1));
    auto motion = tracker.sample(context, id, {10, 0, 0}, 0.1);
    assert(motion.status == GrenadeMotionStatus::ready && motion.velocity.x == 100);
    assert(tracker.beginFrame(context, 0.2));
    motion = tracker.sample(context, id, {30, 0, 0}, 0.2);
    assert(motion.status == GrenadeMotionStatus::ready && motion.velocity.x == 165);
    // Same address with different type/name/explosion is a new identity.
    assert(tracker.beginFrame(context, 0.3));
    auto reused = id; reused.explosionRaw++;
    assert(tracker.sample(context, reused, {40, 0, 0}, 0.3).status == GrenadeMotionStatus::warm);
    auto oldContext = context; oldContext.generation--;
    assert(tracker.sample(oldContext, id, {}, 0.3).status == GrenadeMotionStatus::contextMismatch);
    auto wrongPID = context; wrongPID.pid++;
    auto wrongBase = context; wrongBase.imageBase += 0x1000;
    assert(tracker.sample(wrongPID, id, {}, 0.3).status == GrenadeMotionStatus::contextMismatch);
    assert(tracker.sample(wrongBase, id, {}, 0.3).status == GrenadeMotionStatus::contextMismatch);
    assert(tracker.sample(context, id, {}, 0.4).status == GrenadeMotionStatus::clockInvalid);
    assert(!tracker.beginFrame(context, 0.2) && tracker.size() == 0);
    assert(!tracker.beginFrame(context, std::numeric_limits<double>::quiet_NaN()));
    assert(tracker.beginFrame(context, 1));
    assert(tracker.sample(context, id, {}, 1).status == GrenadeMotionStatus::warm);
    assert(tracker.beginFrame(context, 1.1));
    assert(tracker.sample(context, id, {3000, 0, 0}, 1.1).status == GrenadeMotionStatus::speedInvalid);
    assert(tracker.beginFrame(context, 1.5)); // Missing for >.35: old speed must not survive.
    assert(tracker.sample(context, id, {3010, 0, 0}, 1.5).status == GrenadeMotionStatus::warm);
    for (int i = 1; i <= 21; ++i) {
        double now = 1.5 + 0.1 * i;
        assert(tracker.beginFrame(context, now));
        motion = tracker.sample(context, id, {3010.0f + 10.0f * i, 0, 0}, now);
    }
    assert(motion.status == GrenadeMotionStatus::lifetimeExpired);
    auto nextGeneration = context; nextGeneration.generation++;
    assert(tracker.beginFrame(nextGeneration, 4));
    assert(tracker.size() == 0);
    assert(tracker.sample(nextGeneration, id, {}, 4).status == GrenadeMotionStatus::warm);
    assert(tracker.beginFrame(nextGeneration, 4.003));
    assert(tracker.sample(nextGeneration, id, {10, 0, 0}, 4.003).status == GrenadeMotionStatus::sampleStale);
    tracker.clear();
    assert(tracker.size() == 0);
    assert(tracker.beginFrame(context, 10));
    for (uint64_t actor = 1; actor <= 256; ++actor) {
        auto item = id; item.actor = actor;
        assert(tracker.sample(context, item, {}, 10).status == GrenadeMotionStatus::warm);
    }
    auto excess = id; excess.actor = 257;
    assert(tracker.sample(context, excess, {}, 10).status == GrenadeMotionStatus::capacity);
    assert(tracker.size() == 256);
    Vec3 point = {9, 9, 9};
    assert(referenceGrenadePrediction({0, 0, 0}, {100, 0, 0}, 10, 28, &point));
    assert(point.x == 200 && point.y == 0 && point.z == -1960);
    assert(!referenceGrenadePrediction({}, {}, 10, 0, &point) && point.x == 0);
    assert(!referenceGrenadePrediction({}, {}, 11, 28, &point));
    assert(!referenceGrenadePrediction({}, {}, 1, 29, &point));
    assert(!referenceGrenadePrediction({}, {}, 1, 1, nullptr));
    std::puts("PASS: bounded identity/time/speed/lifetime/cleanup and 28-step local prediction");
}
