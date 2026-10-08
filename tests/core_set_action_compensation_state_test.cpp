#include "../lara/overlay/CoreSetActionCompensationState.h"
#include <cassert>
#include <iomanip>
#include <iostream>

using namespace CoreSet;

template <typename T, size_t N> void array(const std::array<T, N> &values) {
    std::cout << '[';
    for (size_t index = 0; index < N; ++index) { if (index) std::cout << ','; std::cout << values[index]; }
    std::cout << ']';
}
void record(const ActionPostRecord &value) {
    std::cout << '[' << value.valid << ',' << value.key << ',' << value.ownerToken << ',' << unsigned(value.active);
    for (float item : value.values) std::cout << ',' << item;
    std::cout << ']';
}
void state(const ActionPostState &value) {
    std::cout << '[' << value.valid << ',' << value.key << ',' << value.ownerToken << ',' << value.binding
              << ',' << value.phase << ',' << value.quietFrames << ',';
    record(value.previous); std::cout << ']';
}

int main() {
    static_assert(!ActionAngularMotion::writeReady && !ActionResidualObservation::writeReady &&
                  !ActionCompensationDelta::writeReady && !ActionPostObservation::writeReady);
    ActionAngularMotion motion;
    assert(!referenceActionAngularMotion({0, 0, 1}, {1, 2, 3}, &motion));
    assert(!referenceActionAngularMotion({1, 2, 3}, {NAN, 2, 3}, &motion));
    ActionResidualState residual; ActionResidualObservation observation;
    assert(!referenceActionResidual(residual, 0.050001f, true, {}, {360, 360}, 1, .1f, &observation));
    ActionCompensationDelta delta;
    ActionCompensationTuning invalid{.7f, .1f, 1, {360, 360}, .5f, .1f};
    invalid.smoothingSeconds = 0;
    assert(!referenceActionCompensation({1, 2}, .01f, {}, invalid, &delta));
    assert(referenceActionRecoilCallerMerge(INFINITY, 1, .5f) == 0);
    assert(referenceActionRecoilCallerMerge(1, 1, 0) == 0);
    std::cout << std::setprecision(17) << "{\"scope\":\"Core-self compensation CFG only; no target authority\",\"prediction\":[";
    bool comma = false;
    for (float distance : {-1.f, 0.f, 12.f, 12.01f, 21.f, 29.99f, 30.f, 37.5f, 45.f, 100.f}) {
        if (comma) std::cout << ','; comma = true;
        std::cout << "{\"distance\":" << distance << ",\"gain\":" << referenceActionPredictionGain(distance) << '}';
    }
    std::cout << "],\"angular\":["; comma = false;
    for (const auto &position : std::array<std::array<float, 3>, 4>{{{3,4,0},{30,40,20},{-30,40,-20},{0,0,0}}})
    for (const auto &velocity : std::array<std::array<float, 3>, 2>{{{2,-1,3},{-20,10,-4}}}) {
        const bool valid = referenceActionAngularMotion(position, velocity, &motion);
        if (comma) std::cout << ','; comma = true;
        std::cout << "{\"position\":"; array(position); std::cout << ",\"velocity\":"; array(velocity);
        std::cout << ",\"valid\":" << valid << ",\"value\":[" << motion.first << ',' << motion.second << "]}";
    }
    std::cout << "],\"residual\":["; comma = false;
    for (bool present : {false, true}) for (bool measured : {false, true})
    for (float first : {0.f, .01f, 8.f, -8.f, 800.f}) for (float error : {.01f, 2.f}) {
        ActionResidualState history{{first, -first}, present};
        assert(referenceActionResidual(history, .01f, measured, {500, -500}, {360, 240}, error, .1f, &observation));
        if (comma) std::cout << ','; comma = true;
        std::cout << "{\"present\":" << present << ",\"measured\":" << measured << ",\"before\":[" << first << ',' << -first
                  << "],\"error\":" << error << ",\"eligible\":" << observation.eligible
                  << ",\"afterPresent\":" << history.present << ",\"after\":"; array(history.angular); std::cout << '}';
    }
    std::cout << "],\"compensation\":["; comma = false;
    for (float error : {.01f, .4f, 2.f, 180.f}) for (float curve : {.5f, .8f, 1.f})
    for (bool present : {false, true}) for (float direction : {-1.f, 1.f}) {
        const ActionCompensationTuning tuning{.7f, .1f, curve, {360, 240}, .5f, .1f};
        const ActionResidualObservation observed{true, present, {100 * direction, -80 * direction}};
        assert(referenceActionCompensation({error, -error * .5f}, .01f, observed, tuning, &delta));
        if (comma) std::cout << ','; comma = true;
        std::cout << "{\"error\":[" << error << ',' << -error * .5f << "],\"curve\":" << curve
                  << ",\"present\":" << present << ",\"angular\":"; array(observed.angular);
        std::cout << ",\"delta\":"; array(delta.delta); std::cout << ",\"addition\":"; array(delta.residualContribution);
        std::cout << ",\"saturated\":"; array(delta.saturated); std::cout << '}';
    }
    std::cout << "],\"post\":["; comma = false;
    for (unsigned index = 0; index < 80; ++index) {
        ActionPostRecord current{true, 11, 9, static_cast<uint8_t>(index % 2), {1, 10, 20, 3, 1, 1}};
        ActionPostState history{true, 11, 9, 7, (index / 2) % 3, (index / 6) % 7,
                               {true, 11, 9, 1, {1, 11.5f, 22.5f, 3.025f, 1, 1}}};
        const ActionPostTuning tuning{.7f, .35f, .05f, 1.3f, .8f, 6,
                                     (index / 3) % 2 != 0, index % 4 == 0 ? 0.f : .7f, 1, .4f, .8f};
        uint32_t binding = 7;
        if (index % 10 == 0) current.key = 12;
        if (index % 10 == 1) ++current.ownerToken;
        if (index % 10 == 2) ++binding;
        if (index % 10 == 3) history.valid = false;
        if (index % 10 == 4) current.values[3] = 3.4f;
        if (index % 10 == 5) current.valid = false;
        if (index % 10 == 6) binding = 0;
        const ActionPostState before = history;
        ActionPostObservation result;
        const bool valid = referenceActionPostState(history, current, tuning, binding, &result);
        if (comma) std::cout << ','; comma = true;
        std::cout << "{\"before\":"; state(before); std::cout << ",\"current\":"; record(current);
        std::cout << ",\"binding\":" << binding << ",\"tail\":" << tuning.continueLocalTail
                  << ",\"secondStrength\":" << tuning.secondStrength << ",\"valid\":" << valid << ",\"after\":"; state(history);
        std::cout << ",\"status\":" << result.status << ",\"reset\":" << result.contextReset
                  << ",\"phaseCode\":" << result.phaseCode << ",\"value\":"; array(result.values); std::cout << '}';
    }
    std::cout << "],\"caller_merge\":["; comma = false;
    for (float caller : {-2.f, -.1f, .1f, 2.f}) for (float raw : {-1.f, 0.f, .5f}) {
        if (comma) std::cout << ','; comma = true;
        std::cout << "{\"caller\":" << caller << ",\"raw\":" << raw << ",\"result\":"
                  << referenceActionRecoilCallerMerge(caller, raw, .7f) << '}';
    }
    std::cout << "],\"feedback\":["; comma = false;
    for (bool input : {false, true}) for (bool recoil : {false, true})
    for (bool aim : {false, true}) for (bool receipt : {false, true}) for (bool zero : {false, true}) {
        if (comma) std::cout << ','; comma = true;
        std::cout << "{\"input\":" << input << ",\"recoil\":" << recoil << ",\"aim\":" << aim
                  << ",\"receipt\":" << receipt << ",\"zero\":" << zero << ",\"value\":"
                  << referenceActionPriorAimFeedback(.9f, .3f, input, recoil, aim, receipt, zero) << '}';
    }
    std::cout << "],\"geometry\":["; comma = false;
    for (unsigned clockCase = 0; clockCase < 5; ++clockCase) for (bool velocity : {false, true})
    for (float prediction : {0.f, 200.f}) for (unsigned pose = 0; pose < 4; ++pose) {
        ActionGeometryClockState history{clockCase != 0, clockCase == 2 ? 12u : 11u,
            clockCase == 3 ? 0u : 1000000000u, {5, -5}, clockCase % 2 != 0};
        ActionGeometryInput input{11, clockCase == 4 ? 1060000000u : 1010000000u, {}, {}, {}, velocity, {0, 0}};
        input.target = pose == 0 ? std::array<float,3>{3000, 4000, 0} :
            pose == 1 ? std::array<float,3>{3000, 4000, 2500} :
            pose == 2 ? std::array<float,3>{-3000, 4000, -2500} : std::array<float,3>{30000, 40000, 0};
        input.relativeVelocity = pose == 3 ? std::array<float,3>{50000, -25000, 30000} : std::array<float,3>{50, -25, 30};
        const ActionGeometryTuning tuning{{.7f, .1f, .8f, {360, 240}, .5f, .1f}, prediction, .25f, .1f};
        const auto before = history;
        ActionGeometryObservation observed;
        assert(referenceActionGeometry(history, input, tuning, &observed));
        if (comma) std::cout << ','; comma = true;
        std::cout << "{\"before\":[" << before.initialized << ',' << before.targetKey << ',' << before.previousNanoseconds
                  << ',' << before.residualPresent << ',' << before.residual[0] << ',' << before.residual[1]
                  << "],\"now\":" << input.monotonicNanoseconds << ",\"velocityPresent\":" << velocity
                  << ",\"prediction\":" << prediction << ",\"target\":"; array(input.target);
        std::cout << ",\"velocity\":"; array(input.relativeVelocity);
        std::cout << ",\"after\":[" << history.initialized << ',' << history.targetKey << ',' << history.previousNanoseconds
                  << ',' << history.residualPresent << ',' << history.residual[0] << ',' << history.residual[1]
                  << "],\"flags\":[" << observed.valid << ',' << observed.firstOrReset << ',' << observed.withinDeadzone
                  << ',' << observed.saturated[0] << ',' << observed.saturated[1] << ',' << observed.predictionUsed
                  << "],\"value\":"; array(observed.numerical); std::cout << '}';
    }
    std::cout << "]}";
}
