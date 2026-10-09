#include "../lara/overlay/CoreSetActionCyclePlan.h"
#include "../lara/overlay/CoreSetActionEffectLedger.h"
#include "../lara/overlay/CoreSetActionRouteState.h"
#include <cassert>
#include <iomanip>
#include <iostream>
#include <limits>
#include <sstream>
#include <string>
#include <vector>

using namespace CoreSet;

static std::string hexBytes(const std::array<uint8_t, 8> &bytes, size_t length) {
    std::ostringstream output;
    output << std::hex << std::setfill('0');
    for (size_t index = 0; index < length; ++index)
        output << std::setw(2) << static_cast<unsigned>(bytes[index]);
    return output.str();
}

static void negativeAndTransactionCases() {
    static_assert(!ActionTriggerObservation::writeReady && !ActionScenePlan::writeReady);
    static_assert(!ActionWriteDraft::writeReady && !ActionWriteDraft::selectsWriteSlot);
    static_assert(!ActionWriteDraft::restoresTargetState);
    ActionTriggerLatch latch;
    ActionTriggerObservation trigger;
    assert(latch.observe(true, AimTrigger::fireOnly, 0, 1, 2.0, &trigger));
    assert(!latch.observe(true, AimTrigger::fireOnly, 0, 0, 1.0, &trigger));
    assert(!trigger.aimActive && trigger.deadlineSeconds == 0);
    assert(!latch.observe(true, static_cast<AimTrigger>(4), 1, 1, 3.0, &trigger));
    assert(!latch.observe(true, AimTrigger::either, 1, 1,
                          std::numeric_limits<double>::infinity(), &trigger));
    ActionScenePlan scene;
    ActionCustomSceneInput custom;
    assert(!planActionScene(3, 4, custom, &scene));
    assert(!planActionScene(4, 4, custom, &scene));
    AimSceneCompensationValues compensation;
    assert(aimSceneCompensationValues(0, &compensation));
    assert(compensation.residualGain == 0.90f && compensation.minimumGain == 0.38f);
    assert(compensation.deadzoneRatio == 0.12f && compensation.minimumDeadzone == 0.04f);
    assert(aimSceneCompensationValues(1, &compensation));
    assert(compensation.residualGain == 0.56f && compensation.minimumGain == 0.06f);
    assert(compensation.deadzoneRatio == 0.25f && compensation.minimumDeadzone == 0.10f);
    assert(aimSceneCompensationValues(2, &compensation));
    assert(compensation.residualGain == 0.62f && compensation.minimumGain == 0.06f);
    assert(compensation.deadzoneRatio == 0.25f && compensation.minimumDeadzone == 0.10f);
    assert(aimSceneCompensationValues(3, &compensation));
    assert(compensation.residualGain == 0.56f && compensation.minimumGain == 0.06f);
    assert(compensation.deadzoneRatio == 0.25f && compensation.minimumDeadzone == 0.10f);
    assert(!aimSceneCompensationValues(4, &compensation));
    ActionRouteState route;
    assert(referenceActionSlotForRouteState(route, false) == TargetActionSlot::rotationInput);
    assert(referenceActionSlotForRouteState(route, true) == TargetActionSlot::rotationInput);
    route.modeFlag = true;
    assert(referenceActionSlotForRouteState(route, true) == TargetActionSlot::controlRotation);
    route.alternate = true;
    assert(referenceActionSlotForRouteState(route, true) == TargetActionSlot::rotationInput);
    AimDeltaPlan delta;
    ActionWriteDraft draft;
    assert(mergeAimRecoilDeltas(0, 0, 0, 0, &delta));
    assert(planActionWriteDraft(TargetActionSlot::rotationInput, 10, -30, delta, &draft));
    assert(draft.noWrite && draft.length == 0 && !draft.restoresTargetState);
    delta.shape = ActionDeltaShape::both;
    assert(!planActionWriteDraft(TargetActionSlot::rotationInput, 10, -30, delta, &draft));
    assert(mergeAimRecoilDeltas(1, 2, 0, 0, &delta));
    assert(!planActionWriteDraft(static_cast<TargetActionSlot>(3), 10, -30, delta, &draft));
    assert(!planActionWriteDraft(TargetActionSlot::controlRotation,
        std::numeric_limits<float>::infinity(), -30, delta, &draft));
    // This is a fake-memory transaction, never a mapped kernel/backend write.
    assert(planActionWriteDraft(TargetActionSlot::controlRotation, 10, -30, delta, &draft));
    ControlRotationLease lease;
    lease.pid = 42; lease.imageBase = 0x100000000; lease.generation = 9;
    lease.controller = 0x123450000; lease.uuid = ControlRotationWriteGate::kUUID;
    lease.requestToken[0] = 1; lease.snapshotID[0] = 2;
    unsigned reads = 0, writes = 0;
    ActionEffectLedger effects;
    std::array<uint8_t, 8> memory = draft.expectedOld;
    const auto identity = [](const ControlRotationLease &) { return true; };
    const auto read = [&](uint64_t, void *output, size_t length) {
        ++reads; std::memcpy(output, memory.data(), length); return length;
    };
    const auto write = [&](uint64_t, const void *input, size_t length) {
        effects.markWriteAttempt();
        ++writes; std::memcpy(memory.data(), input, length); return length;
    };
    ControlRotationWriteGate gate;
    const auto result = gate.transact(lease, draft.expectedOld, draft.newValue, identity, read, write);
    assert(result.status == ControlRotationWriteStatus::committed && reads == 2 && writes == 1);
    assert(gate.stopAfterDrain());
    assert(!effects.cleanupComplete(true, true, true, true));
    const auto late = gate.transact(lease, draft.expectedOld, draft.newValue, identity, read, write);
    assert(late.status == ControlRotationWriteStatus::pendingCleanup && writes == 1);
    ControlRotationWriteGate changed;
    memory = {}; reads = writes = 0;
    const auto mismatch = changed.transact(lease, draft.expectedOld, draft.newValue, identity, read, write);
    assert(mismatch.status == ControlRotationWriteStatus::oldMismatch && writes == 0);
    ControlRotationWriteGate badReadback;
    memory = draft.expectedOld;
    const auto partialWrite = [&](uint64_t, const void *, size_t length) {
        effects.markWriteAttempt(); ++writes; return length - 1;
    };
    const auto partial = badReadback.transact(lease, draft.expectedOld, draft.newValue, identity, read, partialWrite);
    assert(partial.status == ControlRotationWriteStatus::partialWrite && partial.pending);
    // The serial transaction is drained; effect uncertainty remains in the
    // separate ledger and must not keep mapped resources alive forever.
    assert(badReadback.stopAfterDrain() && !badReadback.pending());
    assert(!effects.targetEffectsResolved());
    ControlRotationWriteGate zeroReturn;
    ActionEffectLedger zeroEffects;
    memory = draft.expectedOld;
    const auto zeroWrite = [&](uint64_t, const void *, size_t) {
        zeroEffects.markWriteAttempt(); return size_t{0};
    };
    const auto zero = zeroReturn.transact(lease, draft.expectedOld, draft.newValue, identity, read, zeroWrite);
    assert(zero.status == ControlRotationWriteStatus::partialWrite && zero.completedBytes == 0);
    assert(!zeroEffects.cleanupComplete(true, true, true, true));
}

static void cleanupEffectCases() {
    ActionEffectLedger noWrite;
    assert(noWrite.targetEffectsResolved());
    assert(noWrite.cleanupComplete(true, true, true, true));
    for (unsigned missing = 0; missing < 4; ++missing)
        assert(!noWrite.cleanupComplete(missing != 0, missing != 1, missing != 2, missing != 3));
    ActionRestorationReceipt receipt{1, true, true, true, true, true};
    const auto syntheticVerifier = [](const ActionRestorationReceipt &) { return true; };
    assert(!noWrite.acknowledgeVerifiedRestoration(receipt, syntheticVerifier));

    ActionEffectLedger attempted;
    attempted.markWriteAttempt();
    assert(attempted.attemptEpoch() == 1 && !attempted.targetEffectsResolved());
    assert(!attempted.cleanupComplete(true, true, true, true));
    // Zero/partial/full backend returns cannot erase an already recorded attempt.
    for (unsigned returnedBytes : {0u, 3u, 8u}) {
        (void)returnedBytes;
        assert(!attempted.targetEffectsResolved());
    }
    for (unsigned missing = 0; missing < 5; ++missing) {
        auto incomplete = receipt;
        if (missing == 0) incomplete.producerStopped = false;
        if (missing == 1) incomplete.writerDrained = false;
        if (missing == 2) incomplete.identityStable = false;
        if (missing == 3) incomplete.independentReadback = false;
        if (missing == 4) incomplete.allOwnedRangesMatchBaseline = false;
        assert(!attempted.acknowledgeVerifiedRestoration(incomplete, syntheticVerifier));
        assert(!attempted.targetEffectsResolved());
    }
    assert(!attempted.acknowledgeVerifiedRestoration(receipt,
        [](const ActionRestorationReceipt &) { return false; }));
    auto stale = receipt; stale.attemptEpoch = 0;
    assert(!attempted.acknowledgeVerifiedRestoration(stale, syntheticVerifier));
    assert(attempted.acknowledgeVerifiedRestoration(receipt, syntheticVerifier));
    assert(attempted.cleanupComplete(true, true, true, true));
    assert(!attempted.acknowledgeVerifiedRestoration(receipt, syntheticVerifier));
    attempted.markWriteAttempt();
    assert(attempted.attemptEpoch() == 2 && !attempted.targetEffectsResolved());
    assert(!attempted.acknowledgeVerifiedRestoration(receipt, syntheticVerifier));
    receipt.attemptEpoch = 2;
    assert(attempted.acknowledgeVerifiedRestoration(receipt, syntheticVerifier));
    assert(!attempted.cleanupComplete(true, false, true, true));

    ActionEffectLedger abandoned;
    abandoned.markWriteAttempt();
    assert(abandoned.abandonWithoutRestoration());
    assert(abandoned.targetEffectsResolved());
    assert(abandoned.targetEffectsAbandoned());
    assert(abandoned.cleanupComplete(true, true, true, true));
}

int main() {
    negativeAndTransactionCases();
    cleanupEffectCases();
    std::cout << std::setprecision(17) << "{\"trigger\":[";
    bool comma = false;
    const auto emitTrigger = [&](int group, ActionTriggerLatch &latch, bool enabled,
                                 int mode, uint8_t ads, uint8_t fire, double now) {
        ActionTriggerObservation value;
        assert(latch.observe(enabled, static_cast<AimTrigger>(mode), ads, fire, now, &value));
        if (comma) std::cout << ','; comma = true;
        std::cout << "{\"group\":" << group << ",\"enabled\":" << enabled << ",\"mode\":" << mode
                  << ",\"ads\":" << static_cast<unsigned>(ads) << ",\"fire\":" << static_cast<unsigned>(fire)
                  << ",\"now\":" << now << ",\"active\":" << value.aimActive
                  << ",\"matched\":" << value.matchedNow << ",\"deadline\":" << value.deadlineSeconds << '}';
    };
    int group = 0;
    for (int mode = 0; mode < 4; ++mode) for (uint8_t ads = 0; ads < 2; ++ads)
        for (uint8_t fire = 0; fire < 2; ++fire) {
            ActionTriggerLatch fresh;
            emitTrigger(group++, fresh, true, mode, ads, fire, 10.0);
        }
    ActionTriggerLatch sequence;
    for (const auto &frame : std::vector<std::array<double, 4>>{
        {1, 0, 1, 1.0}, {1, 0, 0, 1.1}, {1, 0, 0, 1.249999},
        {1, 0, 0, 1.25}, {1, 0, 0, 1.26}, {1, 1, 0, 1.27},
        {1, 0, 1, 1.4}, {0, 0, 1, 1.41}})
        emitTrigger(group, sequence, frame[0] != 0, 2, static_cast<uint8_t>(frame[1]),
                    static_cast<uint8_t>(frame[2]), frame[3]);

    std::cout << "],\"scene\":["; comma = false;
    const std::array<ActionCustomSceneInput, 3> customCases = {{
        {true, 80, 5, 220, 550, 660, 120, 40, 5, 250},
        {true, -2, -2, -2, -2, -2, -2, -2, -2, -2},
        {true, 10000, 10000, 10000, 10000, 10000, 10000, 10000, 10000, 10000}}};
    const auto emitScene = [&](int storedScene, int lockStrength, const ActionCustomSceneInput &custom) {
        ActionScenePlan plan;
        assert(planActionScene(storedScene, lockStrength, custom, &plan));
        if (comma) std::cout << ','; comma = true;
        std::cout << "{\"scene\":" << storedScene << ",\"lockStrength\":" << lockStrength
                  << ",\"custom\":[" << custom.strength << ',' << custom.smoothing << ','
                  << custom.maximumDistance << ',' << custom.horizontalSpeed << ',' << custom.verticalSpeed << ','
                  << custom.predictionMilliseconds << ',' << custom.lockThreshold << ',' << custom.confirmationFrames
                  << ',' << custom.pauseMilliseconds << "],\"effective\":[" << plan.scene.strength << ','
                  << plan.scene.smoothing << ',' << plan.scene.maximumDistance << ',' << plan.scene.horizontalSpeed << ','
                  << plan.scene.verticalSpeed << ',' << plan.scene.predictionMilliseconds << ',' << plan.lock.threshold
                  << ',' << plan.lock.confirmationFrames << ',' << plan.lock.pauseMilliseconds
                  << "],\"normalizedLock\":" << plan.normalizedLockStrength << '}';
    };
    for (int scene = 0; scene < 3; ++scene) for (int lock : {0, 3, 4}) emitScene(scene, lock, {});
    for (const auto &custom : customCases) emitScene(3, 4, custom);

    std::cout << "],\"post_flag\":["; comma = false;
    for (uint32_t vertical = 0; vertical < 4; ++vertical) for (uint8_t stored = 0; stored < 2; ++stored)
        for (uint8_t fire = 0; fire < 2; ++fire) {
            if (comma) std::cout << ','; comma = true;
            std::cout << "{\"vertical\":" << vertical << ",\"storedContinue\":" << static_cast<unsigned>(stored)
                      << ",\"fire\":" << static_cast<unsigned>(fire) << ",\"flag\":"
                      << actionPostStateContinueFlag(vertical, stored) << '}';
        }
    std::cout << "],\"draft\":["; comma = false;
    for (TargetActionSlot slot : {TargetActionSlot::controlRotation, TargetActionSlot::rotationInput})
        for (const auto &axes : std::vector<std::array<float, 2>>{{0, 0}, {1.5f, 0}, {0, -2}, {1.5f, -2}}) {
            AimDeltaPlan delta; ActionWriteDraft draft;
            assert(mergeAimRecoilDeltas(axes[0], axes[1], 0, 0, &delta));
            assert(planActionWriteDraft(slot, 10, -30, delta, &draft));
            if (comma) std::cout << ','; comma = true;
            std::cout << "{\"slot\":" << static_cast<unsigned>(slot) << ",\"old\":[10,-30],\"delta\":["
                      << axes[0] << ',' << axes[1] << "],\"offset\":" << draft.relativeOffset
                      << ",\"length\":" << draft.length << ",\"noWrite\":" << draft.noWrite
                      << ",\"expectedOld\":\"" << hexBytes(draft.expectedOld, draft.length)
                      << "\",\"newValue\":\"" << hexBytes(draft.newValue, draft.length) << "\"}";
        }
    std::cout << "],\"cleanup\":["
        "{\"case\":\"no-write-resource-clean\",\"complete\":true},"
        "{\"case\":\"write-attempt-no-restore\",\"complete\":false},"
        "{\"case\":\"explicit-synthetic-restoration-receipt\",\"complete\":true}],"
        "\"scope\":\"pure-planner-and-fake-memory-contract; no target writes\"}\n";
}
