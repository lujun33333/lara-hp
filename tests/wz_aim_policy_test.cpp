#include "../lara/kexploit/wz/WZAimPolicy.h"
#include "../lara/kexploit/wz/WZAimObserverPolicy.h"

#include <array>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstring>

using namespace WZAimPolicy;

int main() {
    std::array<Target, 6> targets{};
    targets[0] = {11, 400, 1000, {4,0,0}, {}, true, true, false};
    targets[1] = {12, 300, 300, {2,0,0}, {}, true, true, false};
    targets[2] = {13, 1, 1000, {1,0,0}, {}, false, true, false};
    targets[3] = {14, 1, 1000, {1,0,0}, {}, true, true, true};
    targets[4] = {15, 1, 1000, {1,0,0}, {}, true, false, false};
    targets[5] = {16, 1, 1000, {40,0,0}, {}, true, true, false};

    SelectionInput input{};
    input.origin = {0,0,0};
    input.maxRange = 20;
    input.requireVisible = true;

    input.priority = 0;
    auto selected = SelectTarget(targets.data(), targets.size(), input);
    assert(selected.found && targets[selected.index].stableId == 12);
    input.priority = 1;
    selected = SelectTarget(targets.data(), targets.size(), input);
    assert(selected.found && targets[selected.index].stableId == 11);
    input.priority = 2;
    selected = SelectTarget(targets.data(), targets.size(), input);
    assert(selected.found && targets[selected.index].stableId == 12);

    targets[0].position = {4,2,0};
    targets[1].position = {4,0.2f,0};
    input.priority = 3;
    input.rayValid = true;
    input.rayOrigin = {0,0,0};
    input.rayDirection = {1,0,0};
    selected = SelectTarget(targets.data(), targets.size(), input);
    assert(selected.found && targets[selected.index].stableId == 12);
    input.rayValid = false;
    assert(!SelectTarget(targets.data(), targets.size(), input).found);

    const SkillParameters parameters{10, 5, 0, 0};
    const Vec3 predicted = Predict({5,0,0}, {0,0,0}, {1,0,0}, parameters);
    assert(predicted.x > 6.0f && predicted.x < 7.0f);
    const Vec3 stationary = Predict({5,0,0}, {0,0,0}, {1,0,0}, {10,0,0,0});
    assert(stationary.x == 5.0f);
    assert(ValidSkillParameters(parameters));
    assert(!ValidSkillParameters({0,5,0,0}));

    LifecycleGate gate{101,101,7,7,0x100100000,true,true,true,true};
    assert(LifecycleReady(gate));
    gate.connectedPid = 102; assert(!LifecycleReady(gate));
    gate.connectedPid = 101; gate.connectedGeneration = 8;
    assert(!LifecycleReady(gate));
    gate.connectedGeneration = 7; gate.transportWritable = false;
    assert(!LifecycleReady(gate));
    gate.transportWritable = true; gate.profileVerified = false;
    assert(TransportSessionReady(gate));
    assert(!LifecycleReady(gate));

    WZAimObserverPolicy::Layout layout{};
    layout.managerDown = 0x80;
    layout.managerDragging = 0x81;
    layout.managerUsingSlot = 0x90;
    layout.managerCurrentSlot = 0x98;
    layout.slotType = 0x30;
    layout.slotIndicator = 0x140;
    layout.indicatorSlot = 0x48;
    layout.indicatorManager = 0x190;
    layout.indicatorPosition = 0xBC;
    layout.indicatorDirection = 0xDC;
    layout.indicatorOrigin = 0xE8;
    layout.managerSize = 0x300;
    layout.slotSize = 0x200;
    layout.indicatorSize = 0x300;
    assert(WZAimObserverPolicy::ExactLayout(layout));
    layout.indicatorDirection = 0xD8;
    assert(!WZAimObserverPolicy::ExactLayout(layout));
    static_assert(WZAimObserverPolicy::kArrayMaxLengthOffset == 0x18);
    static_assert(WZAimObserverPolicy::kArrayVectorOffset == 0x20);
    static_assert(WZAimObserverPolicy::kMaxSkillSlotCount == 16);
    static_assert(WZAimObserverPolicy::kClassNameOffset == 0x10);
    static_assert(WZAimObserverPolicy::kClassNamespaceOffset == 0x18);
    static_assert(WZAimObserverPolicy::kClassParentOffset == 0x58);
    static_assert(WZAimObserverPolicy::kClassFieldsOffset == 0x80);
    static_assert(WZAimObserverPolicy::kClassStaticFieldsOffset == 0xB8);
    static_assert(WZAimObserverPolicy::kClassInstanceSizeOffset == 0xF8);
    static_assert(WZAimObserverPolicy::kClassFieldCountOffset == 0x124);
    static_assert(WZAimObserverPolicy::kFieldInfoStride == 0x20);
    static_assert(WZAimObserverPolicy::kFieldNameOffset == 0x00);
    static_assert(WZAimObserverPolicy::kFieldTypeOffset == 0x08);
    static_assert(WZAimObserverPolicy::kFieldParentOffset == 0x10);
    static_assert(WZAimObserverPolicy::kFieldOffsetOffset == 0x18);
    static_assert(WZAimObserverPolicy::kTypeAttributesOffset == 0x08);
    static_assert(WZAimObserverPolicy::kFieldAttributeStatic == 0x10);

    WZAimObserverPolicy::ClassStructure classStructure{
        0x100100000, 0x100200000, 0x100300000, 0x100400000,
        0x300, 12};
    assert(WZAimObserverPolicy::ValidClassStructure(classStructure));
    classStructure.fieldCount =
        WZAimObserverPolicy::kMaxClassFieldCount + 1;
    assert(!WZAimObserverPolicy::ValidClassStructure(classStructure));
    classStructure.fieldCount = 12;
    classStructure.fields = 0;
    assert(!WZAimObserverPolicy::ValidClassStructure(classStructure));
    classStructure.fields = 0x100400000;
    classStructure.instanceSize = 8;
    assert(!WZAimObserverPolicy::ValidClassStructure(classStructure));

    assert(WZAimObserverPolicy::MetadataRetryDelaySeconds(0) == 0.0);
    assert(WZAimObserverPolicy::MetadataRetryDelaySeconds(1) == 0.25);
    assert(WZAimObserverPolicy::MetadataRetryDelaySeconds(4) == 0.5);
    assert(WZAimObserverPolicy::MetadataRetryDelaySeconds(8) == 0.5);

    WZAimObserverPolicy::Observation observation{
        0x100300000,0x100400000,0x100400000,
        0x100500000,0x100600000,0x100600000,
        0x100700000,0x100800000,0x100800000,
        0x100500000,0x100300000,2,2,true,false};
    assert(WZAimObserverPolicy::ExactObservation(observation));
    observation.indicatorSlot = 0x100500008;
    assert(!WZAimObserverPolicy::ExactObservation(observation));
    observation.indicatorSlot = observation.slot;
    observation.indicatorManager = 0x100300008;
    assert(!WZAimObserverPolicy::ExactObservation(observation));
    observation.indicatorManager = observation.manager;
    observation.slotObservedClass = 0x100600008;
    assert(!WZAimObserverPolicy::ExactObservation(observation));
    observation.slotObservedClass = observation.slotClass;
    observation.down = false;
    assert(!WZAimObserverPolicy::ExactObservation(observation));

    const uintptr_t indicator = 0x100200000;
    assert(ExactIndicatorField(indicator, indicator + 0xBC, 0xBC,
                               sizeof(Vec3)));
    assert(!ExactIndicatorField(indicator, indicator + 0xC0, 0xBC,
                                sizeof(Vec3)));

    Vec3 memoryPosition{1,2,3}, memoryDirection{0,1,0};
    int writes = 0;
    auto read = [&](uintptr_t address, void *output, size_t size) {
        if (size != sizeof(Vec3)) return false;
        if (address == indicator + 0xBC) std::memcpy(output, &memoryPosition, size);
        else if (address == indicator + 0xDC) std::memcpy(output, &memoryDirection, size);
        else return false;
        return true;
    };
    auto write = [&](uintptr_t address, const void *inputBytes, size_t size) {
        ++writes;
        if (size != sizeof(Vec3)) return false;
        if (address == indicator + 0xBC) std::memcpy(&memoryPosition, inputBytes, size);
        else if (address == indicator + 0xDC) std::memcpy(&memoryDirection, inputBytes, size);
        else return false;
        return true;
    };
    const auto ok = WriteIndicatorPair(indicator, {8,9,10}, {1,0,0}, read, write);
    assert(ok.status == PairWriteStatus::Success && writes == 2);
    assert(memoryPosition.x == 8 && memoryDirection.x == 1);

    memoryPosition = {1,2,3}; memoryDirection = {0,1,0}; writes = 0;
    auto failDirection = [&](uintptr_t address, const void *inputBytes, size_t size) {
        ++writes;
        if (writes == 2) return false;
        if (address == indicator + 0xBC) std::memcpy(&memoryPosition, inputBytes, size);
        else if (address == indicator + 0xDC) std::memcpy(&memoryDirection, inputBytes, size);
        return true;
    };
    const auto failed = WriteIndicatorPair(
        indicator, {8,9,10}, {1,0,0}, read, failDirection);
    assert(failed.status == PairWriteStatus::DirectionWriteFailed);
    assert(failed.rollbackAttempted && failed.rollbackSucceeded);
    assert(memoryPosition.x == 1 && memoryPosition.y == 2 &&
           memoryDirection.y == 1);

    std::puts("WZ aim policy: selection, prediction, observer proof, lifecycle and pair-write rollback passed");
    return 0;
}
