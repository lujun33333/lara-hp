#include "../lara/overlay/CoreSetSingleAttemptGate.h"
#include "../lara/overlay/CoreSetBasicAimGeometry.h"
#include <cassert>
#include <limits>

int main() {
    CoreSet::BasicAimStep step;
    assert(CoreSet::basicAimStep({0,0,0}, {100,0,0}, 0, 0, &step));
    assert(step.pitch == 0 && step.yaw == 0);
    assert(CoreSet::basicAimStep({0,0,0}, {100,100,100}, 0, 0, &step));
    assert(step.pitch == 1 && step.yaw == 1);
    assert(CoreSet::basicAimStep({0,0,0}, {-100,-1,0}, 0, 179.9f, &step));
    assert(step.yaw > 0 && step.yaw < 1); // shortest wrap, not -359 degrees
    assert(!CoreSet::basicAimStep({0,0,0}, {0,0,100}, 0, 0, &step));
    assert(!CoreSet::basicAimStep({0,0,0}, {100,0,0}, NAN, 0, &step));
    assert(CoreSet::basicAimTrigger(1, true, false));
    assert(!CoreSet::basicAimTrigger(3, true, false));
    assert(CoreSet::basicAimTrigger(3, true, true));
    assert(!CoreSet::basicAimTrigger(4, true, true));
    CoreSet::BasicAimTriggerHold hold;
    assert(!hold.update(2, false, false, 1));
    assert(hold.update(2, false, true, 2));
    assert(hold.update(2, false, false, 2.25));
    assert(!hold.update(2, false, false, 2.251));
    assert(hold.update(1, true, false, 3));
    assert(!hold.update(1, false, false, 2)); // rollback rejects and clears
    assert(!hold.permits(3));
    assert(hold.update(3, true, true, 4));
    hold.reset(); assert(!hold.permits(4));
    assert(!hold.update(3, true, true, NAN));
    std::vector<CoreSet::BasicAimCandidate> candidates = {
        {5, false, true, true, 50, 50, 50}, {4, false, true, true, 50, 50, 50},
        {3, true, true, true, 5, 50, 50}, {2, false, true, false, 50, 50, 50},
        {1, false, true, true, 50, NAN, 50}};
    assert(CoreSet::basicAimSelect(candidates,100,100,30,100,false) == 0);
    assert(CoreSet::basicAimSelect(candidates,100,100,30,100,true) == 0);
    assert(CoreSet::basicAimSelect(candidates,100,100,30,1,true) == std::numeric_limits<size_t>::max());
    assert(CoreSet::basicAimSelect({},100,100,30,100,false) == std::numeric_limits<size_t>::max());
    assert(CoreSet::basicAimSelectLocked(candidates,100,100,30,100,false,true,4) == 1);
    candidates[1].x = 84; // outside nearest radius, inside 1.15x locked radius
    assert(CoreSet::basicAimSelectLocked(candidates,100,100,30,100,false,true,4) == 1);
    candidates[1].x = 85;
    assert(CoreSet::basicAimSelectLocked(candidates,100,100,30,100,false,true,4) == 0);
    CoreSet::BasicAimRuntimeState dynamics;
    CoreSet::BasicAimTuning tuning{0.8f, 0.05f, 220, 300};
    assert(!CoreSet::basicAimDynamicStep({0,0,0},{1000,100,100},0,0,11,7,1.0,
                                         tuning,&dynamics,&step));
    assert(CoreSet::basicAimDynamicStep({0,0,0},{1000,100,100},0,0,11,7,1.016,
                                        tuning,&dynamics,&step));
    assert(step.pitch > 0 && step.pitch <= 1 && step.yaw > 0 && step.yaw <= 1);
    assert(!CoreSet::basicAimDynamicStep({0,0,0},{1000,100,100},0,0,12,7,1.032,
                                         tuning,&dynamics,&step));
    assert(!CoreSet::basicAimDynamicStep({0,0,0},{1000,100,100},0,0,12,7,1.100,
                                         tuning,&dynamics,&step));
    CoreSet::BasicAimTakeoverGate takeover;
    assert(takeover.update(0.79, 0.80, 3, 0.14, 2.0));
    assert(takeover.update(0.80, 0.80, 3, 0.14, 2.01));
    assert(takeover.update(0.90, 0.80, 3, 0.14, 2.02));
    assert(!takeover.update(1.00, 0.80, 3, 0.14, 2.03));
    assert(!takeover.update(0.0, 0.80, 3, 0.14, 2.16));
    assert(takeover.update(0.0, 0.80, 3, 0.14, 2.171));
    CoreSet::BasicAimDropoutHold dropout;
    CoreSet::BasicAimPoint cached{}; uint64_t cachedActor = 0;
    assert(dropout.publish(44, 7, {1,2,3}, 3.0));
    assert(dropout.reuse(7, 3.075, true, &cachedActor, &cached));
    assert(cachedActor == 44 && cached.z == 3);
    assert(!dropout.reuse(7, 3.0751, true, &cachedActor, &cached));
    assert(!dropout.reuse(8, 3.01, true, &cachedActor, &cached));
    assert(!dropout.reuse(7, 3.01, false, &cachedActor, &cached));
    CoreSet::ActionContext context;
    context.pid = 3; context.imageBase = 0x100000000; context.readGeneration = 1;
    context.controller = 0x100001000; context.hostGeneration = 1; context.configRevision = 2;
    context.requestToken[0] = 1; context.snapshotID[0] = 2;
    context.lane = 1; context.slot = 1; context.axis = 3;
    CoreSet::SingleAttemptGate gate;
    assert(gate.begin(context, context, 10, 10.1));
    assert(gate.authorizes(context, context, 10.2));
    auto changed = context; changed.snapshotID[0] = 3;
    assert(!gate.authorizes(changed, context, 10.2));
    changed = context; changed.configRevision++;
    assert(!gate.authorizes(context, changed, 10.2));
    assert(!gate.authorizes(context, context, 10.501));
    gate.finish();
    assert(!gate.authorizes(context, context, 10.3));
    assert(!gate.begin(context, context, 10.3, 10.3));
    CoreSet::SingleAttemptGate failed;
    assert(!failed.begin(context, changed, 10, 10));
    assert(failed.spent());
    assert(!failed.begin(context, context, 10, 10));
    CoreSet::SingleAttemptGate stopped;
    stopped.stop();
    assert(!stopped.begin(context, context, 10, 10));
    CoreSet::SingleAttemptGate invalidTime;
    assert(!invalidTime.begin(context, context, 10, 9));
    CoreSet::SingleAttemptGate nanTime;
    assert(!nanTime.begin(context, context, 10, std::numeric_limits<double>::quiet_NaN()));
    CoreSet::SingleAttemptGate activeStop;
    assert(activeStop.begin(context, context, 10, 10));
    activeStop.stop();
    assert(!activeStop.authorizes(context, context, 10));
}
