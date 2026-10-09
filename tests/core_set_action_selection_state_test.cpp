#include "../lara/overlay/CoreSetActionSelectionState.h"
#include "../lara/overlay/CoreSetRecoilStateMachine.h"
#include <cassert>
#include <iomanip>
#include <iostream>
#include <limits>

using namespace CoreSet;

int main() {
    static_assert(!ActionScreenRank::writeReady && !ActionGeometryClockObservation::writeReady);
    static_assert(!ActionMergeRouteObservation::writeReady && !ActionMergeRouteObservation::authorizesUpstreamPath);
    ActionMergeRouteObservation route;
    assert(!referenceActionMergeRoute(static_cast<ActionMergePredecessor>(3), &route));
    AimWorldPoint point;
    assert(!referenceActionWorldPoint(3, 1, {}, {}, {}, &point));
    assert(!referenceActionWorldPoint(1, 1, {}, {INFINITY, 0, 0}, {}, &point));
    assert(referenceActionWorldPoint(0, 1, {}, {INFINITY, 0, 0}, {1, 2, 3}, &point));
    assert(!referenceActionScreenRank(NAN, 10, 100, 100, 20, 999, true, 1, 1).ordinaryUpdated);
    RecoilConfiguration recoilConfiguration;
    assert(!planRecoilConfiguration(false, true, 80, true, true, 60, &recoilConfiguration));
    assert(!planRecoilConfiguration(true, true, -1, true, true, 60, &recoilConfiguration));
    assert(!planRecoilConfiguration(true, true, 80, true, true, 101, &recoilConfiguration));
    assert(planRecoilConfiguration(true, true, 80, false, true, 60, &recoilConfiguration));
    assert(recoilConfiguration.verticalEnabled && recoilConfiguration.verticalStrength == 0.8f);
    assert(!recoilConfiguration.stopWhenNotFiring && recoilConfiguration.horizontalEnabled);
    assert(recoilConfiguration.horizontalStrength == 0.6f);
    std::cout << std::setprecision(17) << "{\"actor_gate\":[";
    bool comma = false;
    for (unsigned state = 0; state < 2; ++state) for (uint8_t flag = 0; flag < 2; ++flag)
    for (uint8_t bot = 0; bot < 2; ++bot) for (uint8_t bone = 0; bone < 2; ++bone)
    for (unsigned include = 0; include < 2; ++include) for (unsigned exclude = 0; exclude < 2; ++exclude) {
        ActionReferenceActorGate gate{state ? 0x100000u : 0u, flag, bot, bone, 100, 50, 300,
                                      include != 0, exclude != 0};
        if (comma) std::cout << ','; comma = true;
        std::cout << "{\"state\":" << gate.stateWord10 << ",\"flag\":" << unsigned(flag)
                  << ",\"bot\":" << unsigned(bot) << ",\"bone\":" << unsigned(bone)
                  << ",\"include\":" << include << ",\"exclude\":" << exclude
                  << ",\"eligible\":" << referenceActionActorEligible(gate) << '}';
    }
    std::cout << "],\"point\":["; comma = false;
    for (uint8_t bone = 0; bone < 2; ++bone) for (int selection = 0; selection < 3; ++selection) {
        assert(referenceActionWorldPoint(selection, bone, {1, 2, 3}, {101, 202, 303}, {11, 22, 33}, &point));
        if (comma) std::cout << ','; comma = true;
        std::cout << "{\"bone\":" << unsigned(bone) << ",\"point\":" << selection
                  << ",\"value\":[" << point.x << ',' << point.y << ',' << point.z << "]}";
    }
    std::cout << "],\"rank\":["; comma = false;
    for (const auto &input : std::array<std::array<float, 4>, 8>{{
        {320, 240, 100, 999}, {420, 240, 100, 999}, {435, 240, 100, 999},
        {436, 240, 100, 999}, {420, 240, 100, 100}, {0, 240, 100, 999},
        {640, 240, 100, 999}, {300, 240, 100, 10}}}) {
        const auto rank = referenceActionScreenRank(input[0], input[1], 640, 480, input[2], input[3], true, 9, 9);
        if (comma) std::cout << ','; comma = true;
        std::cout << "{\"x\":" << input[0] << ",\"y\":" << input[1] << ",\"radius\":" << input[2]
                  << ",\"best\":" << input[3] << ",\"updated\":" << rank.ordinaryUpdated
                  << ",\"sticky\":" << rank.stickyMatched << ",\"newBest\":" << rank.bestPixels << '}';
    }
    std::cout << "],\"clock\":["; comma = false;
    for (const auto &input : std::array<std::array<uint64_t, 5>, 8>{{
        {0, 9, 1000000000, 9, 1010000000}, {1, 9, 1000000000, 9, 1010000000},
        {1, 9, 1000000000, 9, 1000000000}, {1, 9, 1000000000, 9, 999999999},
        {1, 9, 1000000000, 10, 1010000000}, {1, 9, 1000000000, 9, 1050000000},
        {1, 9, 1000000000, 9, 1050000001}, {1, 9, 0, 9, 1000000000}}}) {
        ActionGeometryClockState state{input[0] != 0, input[1], input[2], {2, 4}, true};
        const auto observed = referenceActionGeometryClock(state, input[3], input[4]);
        if (comma) std::cout << ','; comma = true;
        std::cout << "{\"initialized\":" << input[0] << ",\"previousKey\":" << input[1]
                  << ",\"previousNS\":" << input[2] << ",\"key\":" << input[3] << ",\"nowNS\":" << input[4]
                  << ",\"first\":" << observed.firstOrReset << ",\"eligible\":" << observed.stepEligible
                  << ",\"dt\":" << observed.deltaSeconds << ",\"residualPresent\":" << state.residualPresent
                  << ",\"residual\":[" << state.residual[0] << ',' << state.residual[1] << "]}";
    }
    std::cout << "],\"route\":["; comma = false;
    for (int predecessor = 0; predecessor < 3; ++predecessor) for (unsigned fire = 0; fire < 2; ++fire) {
        assert(referenceActionMergeRoute(static_cast<ActionMergePredecessor>(predecessor), &route));
        if (comma) std::cout << ','; comma = true;
        std::cout << "{\"predecessor\":" << predecessor << ",\"fire\":" << fire
                  << ",\"slot\":" << unsigned(route.slot) << ",\"w19\":" << route.nativeW19 << '}';
    }
    std::cout << "],\"takeover\":["; comma = false;
    for (bool force : {false, true}) for (float magnitude : {0.025f, 0.1f})
    for (uint32_t count : {0u, 1u}) for (double deadline : {0.5, 2.0}) {
        ActionTakeoverState state{count, deadline}; ActionTakeoverObservation result;
        assert(referenceActionTakeover(state, true, force, magnitude, 0.05f, 2, 300, 1.0, &result));
        if (comma) std::cout << ','; comma = true;
        std::cout << "{\"force\":" << force << ",\"magnitude\":" << magnitude << ",\"oldCount\":" << count
                  << ",\"oldDeadline\":" << deadline << ",\"allowed\":" << result.aimAllowed
                  << ",\"zeroFirst\":" << result.zeroAimFirst << ",\"zeroSecond\":" << result.zeroAimSecond
                  << ",\"predecessor\":" << unsigned(result.mergePredecessor)
                  << ",\"newCount\":" << state.confirmationCount << ",\"newDeadline\":" << state.pauseDeadline << '}';
    }
    ActionTakeoverState takeover; ActionTakeoverObservation transition;
    assert(!referenceActionTakeover(takeover, true, false, 1, 0, 2, 300, 1, &transition));
    assert(!referenceActionTakeover(takeover, true, false, 1, 0.05f, 7, 300, 1, &transition));
    assert(!referenceActionTakeover(takeover, true, false, 1, 0.05f, 2, 49, 1, &transition));
    assert(!referenceActionTakeover(takeover, true, false, 1, 0.05f, 2, 300, NAN, &transition));
    assert(referenceActionTakeover(takeover, false, true, 1, 0.05f, 2, 300, 1, &transition));
    assert(!transition.aimAllowed && !transition.zeroAimFirst && !transition.zeroAimSecond);
    std::cout << "],\"recoil\":["; comma = false;
    for (unsigned index = 0; index < 40; ++index) {
        RecoilRawState state{1, 11, 7, 0, 10.025f, 5, -0.13f};
        RecoilRawInput input{true, true, 11, 7, 10, -0.075f, 0.76f};
        if (index == 0) { state.mode = 0; state.accumulator = 0; }
        if (index == 2) { state.mode = 0x100; state.pausedAngle = 11.2f; input.currentPitch = 12; input.priorAimPitch = -0.2f; }
        if (index == 3) input.firing = false;
        if (index == 4) ++input.binding;
        if (index == 5) ++input.sampleKey;
        if (index == 6) { state.angle = 10.4f; state.positiveFrames = 2; input.priorAimPitch = 0; }
        if (index == 7) { state.angle = 10; input.currentPitch = 9.995f; input.priorAimPitch = 0; }
        if (index >= 8) {
            state.angle = 10; state.accumulator = -0.005f * static_cast<float>(index);
            input.currentPitch = 10 + 0.0037f * static_cast<float>(index);
            input.priorAimPitch = -0.017f;
            input.strength01 = static_cast<float>(index + 1) / 41.0f;
        }
        const RecoilRawState before = state;
        RecoilRawResult result; assert(stepRecoilRawState(&state, input, &result));
        if (comma) std::cout << ','; comma = true;
        const auto emitState = [](const RecoilRawState &value) {
            std::cout << '[' << value.mode << ',' << value.sampleKey << ',' << value.binding << ','
                      << value.positiveFrames << ',' << value.angle << ',' << value.pausedAngle << ',' << value.accumulator << ']';
        };
        std::cout << "{\"before\":"; emitState(before);
        std::cout << ",\"fire\":" << input.firing << ",\"key\":" << input.sampleKey << ",\"binding\":" << input.binding
                  << ",\"pitch\":" << input.currentPitch << ",\"priorAim\":" << input.priorAimPitch
                  << ",\"strength\":" << input.strength01 << ",\"after\":"; emitState(state);
        std::cout << ",\"result\":[" << result.status << ',' << unsigned(result.contextFlag) << ',' << unsigned(result.resetFlag)
                  << ',' << result.angle << ',' << result.filteredDelta << ',' << result.feedforward
                  << ',' << result.accumulator << ',' << result.combined << "]}";
    }
    std::cout << "],\"motion\":["; comma = false;
    for (unsigned index = 0; index < 8; ++index) {
        ActionCandidateMotionState state{true, 9, 3, 1, {100, 200, 300}, {10, 20, 30}, {1, 2, 3}, true, 1};
        uint64_t key = 9, generation = 4; double now = 1.1;
        if (index == 0) state.initialized = false;
        if (index == 2) generation = 3;
        if (index == 3) { generation = 3; now = 1.300001; }
        if (index == 4) now = 1;
        if (index == 5) now = 1.300001;
        if (index == 6) key = 10;
        if (index == 7) now = 1.000001;
        const auto before = state;
        assert(referenceActionCandidateMotion(state, key, generation, now, {110, 240, 360}, {15, 30, 45}));
        if (comma) std::cout << ','; comma = true;
        const auto emitMotion = [](const ActionCandidateMotionState &value) {
            std::cout << '[' << value.initialized << ',' << value.key << ',' << value.publicationGeneration
                      << ',' << value.sampleSeconds << ',' << value.target.x << ',' << value.target.y << ',' << value.target.z
                      << ',' << value.camera.x << ',' << value.camera.y << ',' << value.camera.z
                      << ',' << value.relativeVelocity.x << ',' << value.relativeVelocity.y << ',' << value.relativeVelocity.z
                      << ',' << value.velocityPresent << ',' << value.velocitySeconds << ']';
        };
        std::cout << "{\"before\":"; emitMotion(before);
        std::cout << ",\"key\":" << key << ",\"generation\":" << generation << ",\"now\":" << now << ",\"after\":";
        emitMotion(state); std::cout << '}';
    }
    std::cout << "],\"scope\":\"original selector and state edges only; no target action authority\"}\n";
}
