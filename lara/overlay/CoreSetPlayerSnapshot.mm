#import "CoreSetPlayerSnapshot.h"
#import "CoreSetPlayerProjection.h"
#import "CoreSetWeaponNames.h"
#import "CoreSetMaterialName.h"
#import "CoreSetWarningProjection.h"
#import "CoreSetReadDisplaySemantics.h"
#import "CoreSetGrenadeClock.h"
#import "CoreSetPlayerCount.h"
#import "CoreSetBoneHead.h"
#import "CoreSetGrenadeMotion.h"
#import <QuartzCore/QuartzCore.h>
#import <algorithm>
#import <array>
#import <cmath>
#import <cstring>
#import <string>
#import <unordered_map>
#import <unordered_set>
#import <utility>
#import <vector>

// Values below are target image-relative RVAs from build 15915; Core menu
// offsets never enter this table. See sol-e6-actor-profile-evidence.md.
static constexpr uint64_t CSWorldSlot = 0x1148b608;
static constexpr uint64_t CSCharacterClassSlot = 0x11c2b598;
static constexpr uint64_t CSPositionCallbackSlot = 0x1146b3e8;
static constexpr uint64_t CSPositionCallbackRVA = 0x76526bc;
static constexpr uint64_t CSPositionXORKeySlot = 0x110712dc;
static constexpr uint64_t CSEliteProjectileClassSlot = 0x11b3c458;
static constexpr uint64_t CSGameStateClassSlot = 0x120a9590;
static constexpr uint64_t CSServerClockImplementationRVA = 0xa529b68;
static constexpr int32_t CSMaxActors = 50000;
// Core v1.7 helper 0x1000d632c copies at most 0x200 pointers per batch,
// then falls back to individual 8-byte reads when the bulk copy fails.
static constexpr int32_t CSActorPointerBatch = 0x200;
static constexpr size_t CSMaxBoneActors = 256;
static constexpr NSUInteger CSMaxRenderedMarks = 8192;
static thread_local std::string CSLastCaptureDiagnostic = "not-attempted";

using CSVector = CoreSet::Vec3;
using CSCamera = CoreSet::Camera;

static bool CSRead(CoreSetReadSession *session, uint64_t generation,
                   uint64_t address, void *output, size_t length) {
    if (address < 0x100000000ULL || address >= 0x8000000000ULL ||
        length == 0 || address > 0x8000000000ULL - length) return false;
    size_t done = 0;
    return [session readAt:address to:output length:length generation:generation
            completedBytes:&done error:nullptr] && done == length;
}

template <typename T> static bool CSReadValue(CoreSetReadSession *session, uint64_t generation,
                                               uint64_t address, T *value) {
    return address <= UINT64_MAX - sizeof(T) && CSRead(session, generation, address, value, sizeof(T));
}

struct CSActorArrayState {
    uint64_t data = 0;
    int32_t count = 0;
    int32_t capacity = 0; // Core v1.7 does not read Max; mirror Num for bounded local loops.
};

enum class CSActorArraySource : uint8_t { unavailable = 0, primary = 1, levelFallback = 2 };

static bool CSActorArraySpanValid(uint64_t data, int32_t count) {
    return count > 0 && count < CSMaxActors &&
        (data & (alignof(uint64_t) - 1)) == 0 && data >= 0x100000000ULL &&
        data <= 0x8000000000ULL - (uint64_t)count * sizeof(uint64_t);
}

static bool CSUserPointerValid(uint64_t value) {
    return value >= 0x100000000ULL && value <= 0x8000000000ULL - sizeof(uint64_t) &&
        (value & (alignof(uint64_t) - 1)) == 0;
}

// Core v1.7 0x1000d5440..0x1000d569c does not begin with UClass. It first
// identifies its player-shaped row with DefaultSpeedValue and then applies the
// team/status/health/component filters below. Keep these predicates separate
// so the scan order remains reviewable against the exact reference image.
static bool CSCorePlayerSpeedMatches(float value) {
    return std::isfinite(value) && std::fabs(value - 479.5f) < 0.1f;
}

static bool CSCorePlayerHealthMatches(float health, float maximum) {
    return std::isfinite(health) && std::isfinite(maximum) &&
        health >= 0 && maximum > 0 && health <= maximum * 1.5f;
}

struct CSCorePlayerState {
    float speed = 0;
    uint32_t team = 0;
    uint64_t stateOwner = 0;
    uint32_t stateFlags = 0;
    uint8_t status = 0;
    float health = 0;
    float maximum = 0;
    uint64_t rootComponent = 0;
    uint64_t meshComponent = 0;
    uint8_t ai = 0;
};

// End-of-capture validation repeats the same widths and predicate order as
// Core v1.7 0x1000d5440..0x1000d569c. UClass is intentionally absent.
static bool CSReadCorePlayerState(CoreSetReadSession *session, uint64_t generation,
                                  uint64_t actor, uint64_t local, uint32_t localTeam,
                                  CSCorePlayerState *state) {
    *state = {};
    if (!CSUserPointerValid(actor) ||
        !CSReadValue(session, generation, actor + 0x10bc, &state->speed) ||
        !CSCorePlayerSpeedMatches(state->speed) || actor == local ||
        !CSReadValue(session, generation, actor + 0xb78, &state->team) ||
        state->team < 1 || state->team > 100 || state->team == localTeam ||
        !CSReadValue(session, generation, actor + 0x1700, &state->stateOwner) ||
        !CSUserPointerValid(state->stateOwner) ||
        !CSReadValue(session, generation, state->stateOwner, &state->stateFlags) ||
        (state->stateFlags & (1u << 20)) ||
        !CSReadValue(session, generation, actor + 0x3be0, &state->status) ||
        state->status == 4 ||
        !CSReadValue(session, generation, actor + 0x1060, &state->health) ||
        !CSReadValue(session, generation, actor + 0x1068, &state->maximum) ||
        !CSCorePlayerHealthMatches(state->health, state->maximum) ||
        !CSReadValue(session, generation, actor + 0x260, &state->rootComponent) ||
        !CSUserPointerValid(state->rootComponent) ||
        !CSReadValue(session, generation, actor + 0x658, &state->meshComponent) ||
        !CSUserPointerValid(state->meshComponent) ||
        !CSReadValue(session, generation, actor + 0xb94, &state->ai)) return false;
    return true;
}

static CSActorArraySource CSReadCoreActorArray(CoreSetReadSession *session, uint64_t generation,
                                                uint64_t level, uint64_t *container,
                                                CSActorArrayState *array,
                                                const char **failureDiagnostic) {
    *container = 0;
    *array = {};
    *failureDiagnostic = "root-actor-array-core17-unavailable";
    uint64_t primaryContainer = 0, data = 0;
    int32_t count = 0;
    if (CSReadValue(session, generation, level + 0xe0, &primaryContainer) &&
        primaryContainer >= 0x100000000ULL &&
        primaryContainer <= 0x8000000000ULL - 0x34 &&
        (primaryContainer & (alignof(uint64_t) - 1)) == 0 &&
        CSReadValue(session, generation, primaryContainer + 0x28, &data) &&
        CSReadValue(session, generation, primaryContainer + 0x30, &count) &&
        CSActorArraySpanValid(data, count)) {
        *container = primaryContainer;
        array->data = data; array->count = count; array->capacity = count;
        return CSActorArraySource::primary;
    }
    data = 0; count = 0;
    const bool fallbackDataRead = CSReadValue(session, generation, level + 0xa0, &data);
    const bool fallbackCountRead = CSReadValue(session, generation, level + 0xa8, &count);
    if (fallbackDataRead && fallbackCountRead && CSActorArraySpanValid(data, count)) {
        array->data = data; array->count = count; array->capacity = count;
        return CSActorArraySource::levelFallback;
    }
    if (!fallbackDataRead || !fallbackCountRead)
        *failureDiagnostic = "root-actor-array-core17-fallback-read-failed";
    else if (count <= 0 || count >= CSMaxActors)
        *failureDiagnostic = "root-actor-array-core17-fallback-count-invalid";
    else
        *failureDiagnostic = "root-actor-array-core17-fallback-data-invalid";
    return CSActorArraySource::unavailable;
}

static bool CSFinite(CSVector v) {
    return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z) &&
           std::fabs(v.x) < 1.0e9f && std::fabs(v.y) < 1.0e9f && std::fabs(v.z) < 1.0e9f;
}

static bool CSCameraValid(const CSCamera &camera) {
    return CSFinite(camera.location) && CSFinite(camera.rotation) &&
           std::fabs(camera.rotation.x) <= 360 && std::fabs(camera.rotation.y) <= 360 &&
           std::fabs(camera.rotation.z) <= 360 && std::isfinite(camera.fov) &&
           camera.fov > 1 && camera.fov < 170;
}

static bool CSClassIsChildOf(CoreSetReadSession *session, uint64_t generation,
                             uint64_t actor, uint64_t wanted, bool *isChild,
                             uint64_t *observedType = nullptr) {
    uint64_t type = 0;
    if (!CSReadValue(session, generation, actor + 0x10, &type)) return false;
    if (observedType) *observedType = type;
    for (unsigned depth = 0; depth < 64 && type; ++depth) {
        if (type == wanted) { *isChild = true; return true; }
        if (!CSReadValue(session, generation, type + 0x30, &type)) return false;
    }
    if (type != 0) return false; // Cyclic or unexpectedly deep superclass chain.
    *isChild = false;
    return true;
}

static bool CSClassTypeIsChildOf(CoreSetReadSession *session, uint64_t generation,
                                 uint64_t type, uint64_t wanted, bool *isChild) {
    for (unsigned depth = 0; depth < 64 && type; ++depth) {
        if (type == wanted) { *isChild = true; return true; }
        if (!CSReadValue(session, generation, type + 0x30, &type)) return false;
    }
    if (type != 0) return false; // Cyclic or unexpectedly deep superclass chain.
    *isChild = false;
    return true;
}

struct CSGrenadeClockObservation {
    uint64_t gameState = 0, type = 0, outer = 0, vtable = 0, getter = 0;
    double worldTime = 0;
    float delta = 0;
    bool present = false;
    uint8_t status = 0; // 0 unrequested, 1..7 unavailable reasons, 8 ready.
};

static bool CSReadGrenadeClock(CoreSetReadSession *session, uint64_t generation,
                               uint64_t base, uint64_t world, uint64_t level,
                               uint64_t gameStateClass, CSGrenadeClockObservation *clock) {
    *clock = {};
    if (!gameStateClass) { clock->status = 1; return true; }
    if (!CSReadValue(session, generation, world + 0xad8, &clock->gameState)) return false;
    if (!clock->gameState) { clock->status = 2; return true; }
    bool typed = false;
    if (!CSClassIsChildOf(session, generation, clock->gameState, gameStateClass, &typed, &clock->type)) return false;
    if (!typed) { clock->status = 3; return true; }
    uint64_t levelWorld = 0;
    if (!CSReadValue(session, generation, clock->gameState + 0x20, &clock->outer) ||
        !CSReadValue(session, generation, level + 0xc0, &levelWorld)) return false;
    if (clock->outer != level) { clock->status = 4; return true; }
    if (levelWorld != world) { clock->status = 5; return true; }
    if (!CSReadValue(session, generation, clock->gameState, &clock->vtable) || !clock->vtable ||
        !CSReadValue(session, generation, clock->vtable + 0x950, &clock->getter)) return false;
    // Observe the implementation identity; never execute a target function.
    if (clock->getter != base + CSServerClockImplementationRVA) { clock->status = 6; return true; }
    if (!CSReadValue(session, generation, world + 0x15b0, &clock->worldTime) ||
        !CSReadValue(session, generation, clock->gameState + 0x600, &clock->delta)) return false;
    clock->present = std::isfinite(clock->worldTime) && clock->worldTime >= 0 &&
        clock->worldTime <= 1.0e9 && std::isfinite(clock->delta) && std::fabs(clock->delta) <= 1.0e9f;
    clock->status = clock->present ? 8 : 7;
    return true;
}

static bool CSWeaponID(CoreSetReadSession *session, uint64_t generation,
                       uint64_t actor, uint64_t *weapon, uint32_t *identifier) {
    *weapon = 0; *identifier = 0;
    if (actor > UINT64_MAX - 0x1178) return false;
    if (!CSReadValue(session, generation, actor + 0x1170, weapon)) return false;
    if (!*weapon) return true;
    return *weapon <= UINT64_MAX - 0xdd4 &&
        CSReadValue(session, generation, *weapon + 0xdd0, identifier);
}

static bool CSPlayerName(CoreSetReadSession *session, uint64_t generation,
                         uint64_t actor, uint64_t *pointer,
                         std::array<uint16_t, 16> *raw, NSString **name) {
    *pointer = 0; raw->fill(0); *name = nil;
    if (actor > UINT64_MAX - 0xb00 ||
        !CSReadValue(session, generation, actor + 0xaf8, pointer)) return false;
    if (!*pointer) return true;
    if (!CSRead(session, generation, *pointer, raw->data(), raw->size() * sizeof(uint16_t))) return false;
    size_t length = 0;
    for (; length < raw->size() && (*raw)[length]; ++length) {
        const uint16_t unit = (*raw)[length];
        if (unit < 0x20 || unit == 0x7f ||
            (unit >= 0x200b && unit <= 0x200f) ||
            (unit >= 0x202a && unit <= 0x202e) ||
            (unit >= 0x2066 && unit <= 0x2069) || unit == 0xfeff) return true;
        if (unit >= 0xd800 && unit <= 0xdbff) {
            if (length + 1 >= raw->size() || (*raw)[length + 1] < 0xdc00 ||
                (*raw)[length + 1] > 0xdfff) return true;
            ++length;
        } else if (unit >= 0xdc00 && unit <= 0xdfff) return true;
    }
    if (length == 0 || length == raw->size()) return true;
    *name = [[NSString alloc] initWithCharacters:reinterpret_cast<const unichar *>(raw->data())
                                         length:length];
    return true;
}

static bool CSPosition(CoreSetReadSession *session, uint64_t generation, uint64_t base,
                       uint64_t actor, CSVector *position, bool *present) {
    *present = false;
    uint64_t component = 0;
    if (!CSReadValue(session, generation, actor + 0x260, &component)) return false;
    if (!component) return true; // No invented zero-vector fallback.
    uint32_t flags = 0;
    if (!CSReadValue(session, generation, component + 0x25c, &flags)) return false;
    if ((flags & ((1u << 20) | (1u << 22))) == ((1u << 20) | (1u << 22))) {
        uint64_t callback = 0;
        if (!CSReadValue(session, generation, base + CSPositionCallbackSlot, &callback)) return false;
        if (callback) {
            if (callback != base + CSPositionCallbackRVA) return false;
            uint8_t block[0x30] = {0};
            uint32_t key = 0;
            if (!CSRead(session, generation, component + 0x1f0, block, sizeof(block)) ||
                !CSReadValue(session, generation, base + CSPositionXORKeySlot, &key)) return false;
            CoreSet::decodePositionBlock(block, key);
            std::memcpy(position, block + 0x10, sizeof(*position));
            *present = CSFinite(*position);
            return true;
        }
    }
    if (!CSRead(session, generation, component + 0x200, position, sizeof(*position))) return false;
    *present = CSFinite(*position);
    return true;
}

static bool CSProject(CSCamera camera, CSVector point, CGSize size, CGPoint *screen) {
    CoreSet::Point projected = {0, 0};
    if (!CoreSet::project(camera, point, size.width, size.height, &projected)) return false;
    *screen = CGPointMake(projected.x, projected.y);
    return true;
}
static bool CSProjectIndicator(CSCamera camera, CSVector point, CGSize size, CGPoint *screen) {
    CoreSet::Point projected = {0, 0};
    if (!CoreSet::projectForIndicator(camera, point, size.width, size.height, &projected)) return false;
    *screen = CGPointMake(projected.x, projected.y);
    return true;
}

// Fourteen source edges per known bone-count profile. The ninth row is Core's
// fallback and is accepted only if every referenced index is in bounds.
static constexpr uint8_t CSBoneEdges[9][28] = {
    {6,5,5,1,5,8,8,9,9,10,5,29,29,30,30,31,1,49,49,50,50,51,1,53,53,54,54,55},
    {6,5,5,1,5,9,9,10,10,11,5,31,31,32,32,33,1,51,51,52,52,53,1,55,55,56,56,57},
    {6,5,5,1,5,8,8,9,9,10,5,30,30,31,31,32,1,51,51,52,52,53,1,57,57,58,58,59},
    {6,5,5,1,5,12,12,13,13,14,5,33,33,34,34,35,1,53,53,54,54,55,1,57,57,58,58,59},
    {28,5,5,1,28,7,7,8,8,9,28,35,35,36,36,37,1,56,56,57,57,58,1,60,60,61,61,62},
    {6,5,5,1,5,14,14,15,15,16,5,36,36,37,37,38,1,58,58,59,59,60,1,62,62,63,63,64},
    {6,5,5,1,5,14,14,15,15,16,5,36,36,37,37,38,1,62,62,63,63,64,1,58,58,59,59,60},
    {6,5,5,1,5,29,29,30,30,31,5,50,50,51,51,52,1,63,63,64,64,65,1,67,67,68,68,69},
    {6,5,5,1,5,12,12,13,13,14,5,34,34,35,35,36,1,56,56,57,57,58,1,60,60,61,61,62},
};

static const uint8_t *CSBoneProfile(int32_t count) {
    if (count == 61) return CSBoneEdges[0];
    if (count == 63) return CSBoneEdges[1];
    if (count == 64) return CSBoneEdges[2];
    if (count == 65 || count == 66) return CSBoneEdges[3];
    if (count == 70 || count == 71) return CSBoneEdges[4];
    if (count == 72) return CSBoneEdges[5];
    if (count == 73) return CSBoneEdges[6];
    if (count == 95) return CSBoneEdges[7];
    return CSBoneEdges[8];
}

struct CSBoneSample { uint8_t index; std::array<uint8_t, 0x2c> bytes; };
struct CSBoneState {
    uint64_t mesh = 0;
    uint64_t callback = 0;
    uint32_t flags = 0, key = 0;
    uint8_t registered = 0;
    uint8_t status = 0; // 1 missing mesh, 2 unregistered, 3 invalid array, 4 bounds, 5 unknown decoder, 6 plain, 7 XOR.
    struct { uint64_t data; int32_t count; int32_t capacity; } array = {0};
    std::array<uint8_t, 0x2c> component = {};
    std::vector<CSBoneSample> samples;
    const uint8_t *edges = nullptr;
};

static bool CSReadBoneState(CoreSetReadSession *session, uint64_t generation, uint64_t base,
                            uint64_t actor, CSBoneState *state, bool *present) {
    *present = false;
    if (!CSReadValue(session, generation, actor + 0x658, &state->mesh)) return false;
    if (!state->mesh) { state->status = 1; return true; }
    if (state->mesh < 0x100000000ULL || state->mesh > 0x8000000000ULL - 0x850) return false;
    // Native GetBoneTransform a3c4124 requires a registered component. Its
    // a3c4150..a3c41a0 uses the same verified read-only decoder as CSPosition.
    if (!CSReadValue(session, generation, state->mesh + 0xe0, &state->registered)) return false;
    if (!(state->registered & 4)) { state->status = 2; return true; }
    if (!CSRead(session, generation, state->mesh + 0x838, &state->array, sizeof(state->array))) return false;
    const auto &array = state->array;
    if (array.count < 0 || array.count > 256 || array.capacity < array.count ||
        array.capacity > 256 || (array.count && !array.data)) { state->status = 3; return true; }
    if (array.count < 6) { state->status = 3; return true; }
    if (array.data < 0x100000000ULL || array.data > 0x8000000000ULL - 256 * 0x30) { state->status = 3; return true; }
    state->edges = CSBoneProfile(array.count);
    for (unsigned edge = 0; edge < 28; ++edge)
        if (state->edges[edge] >= array.count) { state->status = 4; return true; }
    if (!CSReadValue(session, generation, state->mesh + 0x25c, &state->flags)) return false;
    state->status = 6;
    if ((state->flags & ((1u << 20) | (1u << 22))) == ((1u << 20) | (1u << 22))) {
        if (!CSReadValue(session, generation, base + CSPositionCallbackSlot, &state->callback)) return false;
        if (state->callback) {
            if (state->callback != base + CSPositionCallbackRVA) { state->status = 5; return true; }
            uint8_t block[0x30] = {};
            if (!CSRead(session, generation, state->mesh + 0x1f0, block, sizeof(block)) ||
                !CSReadValue(session, generation, base + CSPositionXORKeySlot, &state->key)) return false;
            CoreSet::decodePositionBlock(block, state->key);
            std::memcpy(state->component.data(), block, state->component.size());
            state->status = 7;
        }
    }
    if (state->status == 6 && !CSRead(session, generation, state->mesh + 0x1f0,
                                     state->component.data(), state->component.size())) return false;
    for (unsigned edge = 0; edge < 28; ++edge) {
        uint8_t index = state->edges[edge];
        if (std::any_of(state->samples.begin(), state->samples.end(),
                        [index](const CSBoneSample &sample) { return sample.index == index; })) continue;
        CSBoneSample sample = {index, {}};
        if (!CSRead(session, generation, array.data + (uint64_t)index * 0x30,
                    sample.bytes.data(), sample.bytes.size())) return false;
        state->samples.push_back(sample);
    }
    *present = true;
    return true;
}

@interface CoreSetBoneSegment ()
@property(nonatomic) CGPoint start;
@property(nonatomic) CGPoint end;
@end
@implementation CoreSetBoneSegment @end

@interface CoreSetGrenadePredictionSegment ()
@property(nonatomic) UIColor *color;
@property(nonatomic) double shadowLineWidth;
@property(nonatomic) double lineWidth;
@end
@implementation CoreSetGrenadePredictionSegment @end

static NSArray<CoreSetBoneSegment *> *CSProjectBones(const CSBoneState &state,
                                                     CSCamera camera, CGSize size) {
    CoreSet::Transform component = {};
    std::memcpy(&component, state.component.data(), state.component.size());
    CGPoint points[256] = {};
    for (const CSBoneSample &sample : state.samples) {
        CoreSet::Transform bone = {};
        std::memcpy(&bone, sample.bytes.data(), sample.bytes.size());
        CSVector world = {0};
        if (!CoreSet::transformPoint(component, bone.translation, &world) ||
            !CSProject(camera, world, size, &points[sample.index])) return @[];
    }
    NSMutableArray<CoreSetBoneSegment *> *segments = [NSMutableArray arrayWithCapacity:14];
    for (unsigned edge = 0; edge < 28; edge += 2) {
        CoreSetBoneSegment *segment = [CoreSetBoneSegment new];
        segment.start = points[state.edges[edge]];
        segment.end = points[state.edges[edge + 1]];
        [segments addObject:segment];
    }
    return segments;
}

static bool CSProjectBoneHead(const CSBoneState &state, CSCamera camera, CGSize size,
                              CGPoint *point, uint8_t *index) {
    *point = CGPointZero;
    if (!CoreSet::referenceBoneHeadIndex(state.array.count, index)) return false;
    const auto sample = std::find_if(state.samples.begin(), state.samples.end(),
        [index](const CSBoneSample &entry) { return entry.index == *index; });
    if (sample == state.samples.end()) return false;
    CoreSet::Transform component = {}, bone = {};
    std::memcpy(&component, state.component.data(), state.component.size());
    std::memcpy(&bone, sample->bytes.data(), sample->bytes.size());
    CSVector world = {};
    return CoreSet::transformPoint(component, bone.translation, &world) &&
        CSProject(camera, world, size, point) && point->x >= 0 && point->x <= size.width &&
        point->y >= 0 && point->y <= size.height;
}

@interface CoreSetPlayerMark ()
@property(nonatomic) uint64_t actorAddress;
@property(nonatomic) uint8_t healthStatusCode;
@property(nonatomic, copy, nullable) NSString *weaponName;
@property(nonatomic) uint32_t weaponID;
@property(nonatomic, copy, nullable) NSString *playerName;
@property(nonatomic) uint32_t teamID;
@property(nonatomic) float health;
@property(nonatomic) float maximumHealth;
@property(nonatomic) BOOL bot;
@property(nonatomic) CGPoint center;
@property(nonatomic) CGPoint head;
@property(nonatomic) NSNumber *headBoneIndex;
@property(nonatomic) CGPoint feet;
@property(nonatomic) double distanceUnitsDividedBy100;
@property(nonatomic) NSArray<CoreSetBoneSegment *> *boneSegments;
@property(nonatomic) BOOL onScreen;
@property(nonatomic) CGPoint indicatorProjection;
@property(nonatomic) CGPoint radarCameraDelta;
@property(nonatomic) NSNumber *warningServerYawDegrees;
@property(nonatomic) NSNumber *warningYawDegrees;
@property(nonatomic) CoreSetWarningYawSource warningYawSource;
@end
@implementation CoreSetPlayerMark @end

@interface CoreSetGrenadeMark ()
@property(nonatomic) CGPoint point;
@property(nonatomic) double distanceUnitsDividedBy100;
@property(nonatomic) NSNumber *countdownSeconds;
@property(nonatomic) NSArray<CoreSetGrenadePredictionSegment *> *predictionSegments;
@property(nonatomic) BOOL predictionEndpointPresent;
@property(nonatomic) CGPoint predictionEndpoint;
@property(nonatomic) CSVector motionPosition;
@property(nonatomic) uint64_t motionActor;
@property(nonatomic) uint64_t motionType;
@property(nonatomic) uint32_t motionNameIndex;
@property(nonatomic) uint32_t motionExplosionRaw;
@end
@implementation CoreSetGrenadeMark @end

@interface CoreSetPlayerSnapshot ()
@property(nonatomic) CSCamera motionCamera;
@property(nonatomic) uint64_t sessionGeneration;
@property(nonatomic) int32_t processID;
@property(nonatomic) uint64_t imageBase;
@property(nonatomic, copy) NSUUID *snapshotID;
@property(nonatomic) NSArray<CoreSetPlayerMark *> *marks;
@property(nonatomic) NSArray<CoreSetGrenadeMark *> *grenadeMarks;
@property(nonatomic) NSUInteger observedPlayerCount;
@property(nonatomic) NSUInteger observedBotCount;
@property(nonatomic) double cameraYawDegrees;
@property(nonatomic) double cameraPitchDegrees;
@property(nonatomic) double cameraFieldOfViewDegrees;
@property(nonatomic) BOOL battleInputsPresent;
@property(nonatomic) uint64_t controllerAddress;
@property(nonatomic) uint64_t localActorAddress;
@property(nonatomic) BOOL localADS;
@property(nonatomic) BOOL localFiring;
@property(nonatomic) float controlPitchDegrees;
@property(nonatomic) float controlYawDegrees;
@property(nonatomic) double captureStartedMonotonicSeconds;
@property(nonatomic) double captureCompletedMonotonicSeconds;
@property(nonatomic, copy) NSString *readSemanticDiagnostic;
@end
@implementation CoreSetPlayerSnapshot @end

@implementation CoreSetGrenadeMotionTracker {
    CoreSet::GrenadeMotionTracker _history;
}
- (BOOL)clear {
    NSAssert(NSThread.isMainThread, @"motion history is main-thread confined");
    _history.clear();
    return _history.size() == 0;
}
- (void)decorateSnapshot:(CoreSetPlayerSnapshot *)snapshot canvasSize:(CGSize)size nativeScale:(double)scale {
    NSAssert(NSThread.isMainThread, @"motion history is main-thread confined");
    for (CoreSetGrenadeMark *mark in snapshot.grenadeMarks) {
        mark.predictionSegments = @[]; mark.predictionEndpointPresent = NO; mark.predictionEndpoint = CGPointZero;
    }
    const CoreSet::GrenadeMotionContext context = {snapshot.sessionGeneration, snapshot.imageBase, snapshot.processID};
    NSUInteger status[8] = {}, projected = 0, segmentCount = 0, endpoints = 0, budgetSkipped = 0;
    if (!std::isfinite(scale) || scale <= 0 || scale > 8 || !std::isfinite(size.width) ||
        !std::isfinite(size.height) || size.width <= 0 || size.height <= 0 ||
        !_history.beginFrame(context, snapshot.captureCompletedMonotonicSeconds)) {
        _history.clear(); status[3] = 1;
    } else {
        for (CoreSetGrenadeMark *mark in snapshot.grenadeMarks) {
            if (!mark.countdownSeconds) continue; // Only typed, valid-lifecycle, end-reread clock candidates.
            const CoreSet::GrenadeMotionIdentity identity = {mark.motionActor, mark.motionType,
                mark.motionNameIndex, mark.motionExplosionRaw};
            const auto motion = _history.sample(context, identity, mark.motionPosition,
                                                 snapshot.captureCompletedMonotonicSeconds);
            ++status[unsigned(motion.status)];
            if (motion.status != CoreSet::GrenadeMotionStatus::ready) continue;
            if (projected >= 64) { ++budgetSkipped; continue; }
            const float remaining = mark.countdownSeconds.floatValue;
            CGPoint previous = mark.point;
            bool previousValid = true, anySegment = false;
            NSMutableArray<CoreSetGrenadePredictionSegment *> *segments = [NSMutableArray arrayWithCapacity:28];
            for (unsigned step = 1; step <= 28; ++step) {
                CSVector world = {};
                CGPoint point = CGPointZero;
                const bool valid = CoreSet::referenceGrenadePrediction(mark.motionPosition, motion.velocity,
                    remaining, step, &world) && CSProject(snapshot.motionCamera, world, size, &point) &&
                    point.x > 0 && point.x < size.width && point.y > 0 && point.y < size.height;
                if (valid && previousValid) {
                    const float fraction = float(step) / 28.0f;
                    const unsigned green = unsigned(std::fma(fraction, 95.0f, 105.0f));
                    const unsigned alpha = unsigned(std::fma(fraction, -115.0f, 235.0f));
                    CoreSetGrenadePredictionSegment *segment = [CoreSetGrenadePredictionSegment new];
                    segment.start = previous; segment.end = point;
                    segment.color = [UIColor colorWithRed:1 green:green / 255.0 blue:72 / 255.0 alpha:alpha / 255.0];
                    segment.shadowLineWidth = std::max(scale * 4.2, 3.5) / scale;
                    segment.lineWidth = std::max(scale * 2.2, 1.8) / scale;
                    [segments addObject:segment]; anySegment = true;
                }
                previousValid = valid;
                if (valid) previous = point;
            }
            mark.predictionSegments = [segments copy];
            if (anySegment) { ++projected; segmentCount += segments.count; }
            if (anySegment && previousValid) {
                mark.predictionEndpointPresent = YES; mark.predictionEndpoint = previous; ++endpoints;
            }
        }
    }
    snapshot.readSemanticDiagnostic = [snapshot.readSemanticDiagnostic stringByAppendingFormat:
        @" grenadeMotion=reference-local-prediction motionTime=local-monotonic motionEntries=%lu motionWarm=%lu motionReady=%lu motionContextRejected=%lu motionClockRejected=%lu motionSpeedRejected=%lu motionStale=%lu motionExpired=%lu motionCapacityRejected=%lu motionProjected=%lu motionSegments=%lu motionEndpoints=%lu motionBudgetSkipped=%lu motionCircle=screen-pixels-not-blast-radius",
        (unsigned long)_history.size(), (unsigned long)status[0], (unsigned long)status[1], (unsigned long)status[2],
        (unsigned long)status[3], (unsigned long)status[4], (unsigned long)status[5], (unsigned long)status[6],
        (unsigned long)status[7], (unsigned long)projected, (unsigned long)segmentCount, (unsigned long)endpoints,
        (unsigned long)budgetSkipped];
}
@end

BOOL CoreSetRadarPoint(CGPoint cameraMinusActor, double cameraYawDegrees,
                       double radius, double detectionDistance, CGPoint center, CGPoint *output) {
    if (!output) return NO;
    CoreSet::Point point = {0, 0};
    if (!CoreSet::radarPoint({cameraMinusActor.x, cameraMinusActor.y}, cameraYawDegrees,
                             radius, detectionDistance, {center.x, center.y}, &point)) return NO;
    *output = CGPointMake(point.x, point.y);
    return YES;
}

BOOL CoreSetWarningAngleMatches(CGPoint cameraMinusActor, double serverYawDegrees) {
    return CoreSet::warningAngleMatches(cameraMinusActor.x, cameraMinusActor.y,
                                        serverYawDegrees);
}

NSString *CoreSetReferencePlayerDistanceText(double distance) {
    const std::string text = CoreSet::referencePlayerDistanceText(distance);
    return text.empty() ? nil : [NSString stringWithUTF8String:text.c_str()];
}

BOOL CoreSetReferencePlayerRay(CGSize size, double nativeScale, CGPoint head,
                               CGPoint *origin, CGPoint *endpoint) {
    if (!origin || !endpoint) return NO;
    *origin = CGPointZero; *endpoint = CGPointZero;
    CoreSet::Point start = {}, end = {};
    if (!CoreSet::referencePlayerRay(size.width, size.height, nativeScale,
                                     {head.x, head.y}, &start, &end)) return NO;
    *origin = CGPointMake(start.x, start.y); *endpoint = CGPointMake(end.x, end.y);
    return YES;
}

NSString *CoreSetReferenceWarningText(NSString *playerName, BOOL bot, NSString *weaponName,
                                       uint32_t weaponID, double distance) {
    const std::string text = CoreSet::referenceWarningText(playerName.UTF8String, bot,
        weaponName.UTF8String, weaponID, distance);
    return text.empty() ? nil : [NSString stringWithUTF8String:text.c_str()];
}

@implementation CoreSetPlayerCollector
+ (NSString *)lastCaptureDiagnostic {
    return [NSString stringWithUTF8String:CSLastCaptureDiagnostic.c_str()];
}
+ (CoreSetPlayerSnapshot *)capture:(CoreSetReadSession *)session canvasSize:(CGSize)size {
    return [self capture:session canvasSize:size playerBones:NO botBones:NO
       boneDistanceLimit:0 includeOffscreen:NO includeRadar:NO];
}
+ (CoreSetPlayerSnapshot *)capture:(CoreSetReadSession *)session canvasSize:(CGSize)size
                          playerBones:(BOOL)playerBones botBones:(BOOL)botBones
                 boneDistanceLimit:(double)boneDistanceLimit includeOffscreen:(BOOL)includeOffscreen
                     includeRadar:(BOOL)includeRadar {
    return [self capture:session canvasSize:size playerBones:playerBones botBones:botBones
        boneDistanceLimit:boneDistanceLimit includeOffscreen:includeOffscreen
        includeRadar:includeRadar includeBattleInputs:NO];
}
+ (CoreSetPlayerSnapshot *)capture:(CoreSetReadSession *)session canvasSize:(CGSize)size
                          playerBones:(BOOL)playerBones botBones:(BOOL)botBones
                 boneDistanceLimit:(double)boneDistanceLimit includeOffscreen:(BOOL)includeOffscreen
                     includeRadar:(BOOL)includeRadar includeBattleInputs:(BOOL)includeBattleInputs {
    return [self capture:session canvasSize:size playerBones:playerBones botBones:botBones
        boneDistanceLimit:boneDistanceLimit includeOffscreen:includeOffscreen
        includeRadar:includeRadar includeBattleInputs:includeBattleInputs
        playerWeaponText:NO botWeaponText:NO];
}
+ (CoreSetPlayerSnapshot *)capture:(CoreSetReadSession *)session canvasSize:(CGSize)size
                          playerBones:(BOOL)playerBones botBones:(BOOL)botBones
                 boneDistanceLimit:(double)boneDistanceLimit includeOffscreen:(BOOL)includeOffscreen
                     includeRadar:(BOOL)includeRadar includeBattleInputs:(BOOL)includeBattleInputs
                playerWeaponText:(BOOL)playerWeaponText botWeaponText:(BOOL)botWeaponText {
    return [self capture:session canvasSize:size playerBones:playerBones botBones:botBones
        boneDistanceLimit:boneDistanceLimit includeOffscreen:includeOffscreen
        includeRadar:includeRadar includeBattleInputs:includeBattleInputs
        playerWeaponText:playerWeaponText botWeaponText:botWeaponText includeGrenadeWarning:NO];
}
+ (CoreSetPlayerSnapshot *)capture:(CoreSetReadSession *)session canvasSize:(CGSize)size
                          playerBones:(BOOL)playerBones botBones:(BOOL)botBones
                 boneDistanceLimit:(double)boneDistanceLimit includeOffscreen:(BOOL)includeOffscreen
                     includeRadar:(BOOL)includeRadar includeBattleInputs:(BOOL)includeBattleInputs
                playerWeaponText:(BOOL)playerWeaponText botWeaponText:(BOOL)botWeaponText
        includeGrenadeWarning:(BOOL)includeGrenadeWarning {
    return [self capture:session canvasSize:size playerBones:playerBones botBones:botBones
        boneDistanceLimit:boneDistanceLimit includeOffscreen:includeOffscreen
        includeRadar:includeRadar includeBattleInputs:includeBattleInputs
        playerWeaponText:playerWeaponText botWeaponText:botWeaponText
        includeGrenadeWarning:includeGrenadeWarning includeCounts:NO];
}
+ (CoreSetPlayerSnapshot *)capture:(CoreSetReadSession *)session canvasSize:(CGSize)size
                          playerBones:(BOOL)playerBones botBones:(BOOL)botBones
                 boneDistanceLimit:(double)boneDistanceLimit includeOffscreen:(BOOL)includeOffscreen
                     includeRadar:(BOOL)includeRadar includeBattleInputs:(BOOL)includeBattleInputs
                playerWeaponText:(BOOL)playerWeaponText botWeaponText:(BOOL)botWeaponText
        includeGrenadeWarning:(BOOL)includeGrenadeWarning includeCounts:(BOOL)includeCounts {
    return [self capture:session canvasSize:size playerBones:playerBones botBones:botBones
        boneDistanceLimit:boneDistanceLimit includeOffscreen:includeOffscreen
        includeRadar:includeRadar includeBattleInputs:includeBattleInputs
        playerWeaponText:playerWeaponText botWeaponText:botWeaponText
        includeGrenadeWarning:includeGrenadeWarning includeCounts:includeCounts
        playerInformation:NO botInformation:NO];
}
+ (CoreSetPlayerSnapshot *)capture:(CoreSetReadSession *)session canvasSize:(CGSize)size
                          playerBones:(BOOL)playerBones botBones:(BOOL)botBones
                 boneDistanceLimit:(double)boneDistanceLimit includeOffscreen:(BOOL)includeOffscreen
                     includeRadar:(BOOL)includeRadar includeBattleInputs:(BOOL)includeBattleInputs
                playerWeaponText:(BOOL)playerWeaponText botWeaponText:(BOOL)botWeaponText
        includeGrenadeWarning:(BOOL)includeGrenadeWarning includeCounts:(BOOL)includeCounts
           playerInformation:(BOOL)playerInformation botInformation:(BOOL)botInformation {
    return [self capture:session canvasSize:size playerBones:playerBones botBones:botBones
        boneDistanceLimit:boneDistanceLimit includeOffscreen:includeOffscreen
        includeRadar:includeRadar includeBattleInputs:includeBattleInputs
        playerWeaponText:playerWeaponText botWeaponText:botWeaponText
        includeGrenadeWarning:includeGrenadeWarning includeCounts:includeCounts
        playerInformation:playerInformation botInformation:botInformation includeWarningYaw:NO];
}
+ (CoreSetPlayerSnapshot *)capture:(CoreSetReadSession *)session canvasSize:(CGSize)size
                          playerBones:(BOOL)playerBones botBones:(BOOL)botBones
                 boneDistanceLimit:(double)boneDistanceLimit includeOffscreen:(BOOL)includeOffscreen
                     includeRadar:(BOOL)includeRadar includeBattleInputs:(BOOL)includeBattleInputs
                playerWeaponText:(BOOL)playerWeaponText botWeaponText:(BOOL)botWeaponText
        includeGrenadeWarning:(BOOL)includeGrenadeWarning includeCounts:(BOOL)includeCounts
           playerInformation:(BOOL)playerInformation botInformation:(BOOL)botInformation
           includeWarningYaw:(BOOL)includeWarningYaw {
    return [self capture:session canvasSize:size playerBones:playerBones botBones:botBones
        boneDistanceLimit:boneDistanceLimit includeOffscreen:includeOffscreen
        includeRadar:includeRadar includeBattleInputs:includeBattleInputs
        playerWeaponText:playerWeaponText botWeaponText:botWeaponText
        includeGrenadeWarning:includeGrenadeWarning includeCounts:includeCounts
        playerInformation:playerInformation botInformation:botInformation
        includeWarningYaw:includeWarningYaw maximumDrawDistance:0];
}
+ (CoreSetPlayerSnapshot *)capture:(CoreSetReadSession *)session canvasSize:(CGSize)size
                          playerBones:(BOOL)playerBones botBones:(BOOL)botBones
                 boneDistanceLimit:(double)boneDistanceLimit includeOffscreen:(BOOL)includeOffscreen
                     includeRadar:(BOOL)includeRadar includeBattleInputs:(BOOL)includeBattleInputs
                playerWeaponText:(BOOL)playerWeaponText botWeaponText:(BOOL)botWeaponText
        includeGrenadeWarning:(BOOL)includeGrenadeWarning includeCounts:(BOOL)includeCounts
           playerInformation:(BOOL)playerInformation botInformation:(BOOL)botInformation
           includeWarningYaw:(BOOL)includeWarningYaw maximumDrawDistance:(double)maximumDrawDistance {
    CSLastCaptureDiagnostic = "request-validation";
    const double captureStartedAt = CACurrentMediaTime();
    if (!session.ready || session.capabilities != 1 || !std::isfinite(size.width) ||
        !std::isfinite(size.height) || size.width <= 0 || size.height <= 0 ||
        !std::isfinite(boneDistanceLimit) || boneDistanceLimit < 0 ||
        !std::isfinite(maximumDrawDistance) || maximumDrawDistance < 0 ||
        (maximumDrawDistance != 0 && (maximumDrawDistance < 1 || maximumDrawDistance > 1000))) return nil;
    CSLastCaptureDiagnostic = "identity-initial";
    uint64_t generation = session.generation, base = session.imageBase;
    int32_t pid = session.processID;
    if (!base || pid <= 0 || base > UINT64_MAX - CSGameStateClassSlot) return nil;
    CSLastCaptureDiagnostic = "root-world";
    uint64_t world = 0, wanted = 0;
    if (!CSReadValue(session, generation, base + CSWorldSlot, &world) ||
        !CSUserPointerValid(world)) return nil;
    // Target UClass is retained only as a diagnostic observation. Core v1.7's
    // player branch never places this gate before its field-order filters.
    const bool wantedObserved =
        CSReadValue(session, generation, base + CSCharacterClassSlot, &wanted) &&
        CSUserPointerValid(wanted);
    if (!wantedObserved) wanted = 0;
    CSLastCaptureDiagnostic = "root-name-pool";
    uint64_t namePool = 0;
    uint32_t nameCount = 0;
    bool collectGrenades = includeGrenadeWarning;
    if (collectGrenades &&
        (!CSReadValue(session, generation, base + 0x11fba198, &namePool) || !namePool ||
         namePool < 0x100000000ULL || namePool > 0x8000000000ULL - 0x1404 ||
         !CSReadValue(session, generation, namePool + 0x1400, &nameCount) ||
         !nameCount || nameCount > 0xa00000)) collectGrenades = false;
    CSLastCaptureDiagnostic = "root-world-netdriver";
    uint64_t driver = 0, connection = 0, controller = 0, local = 0, manager = 0;
    if (!CSReadValue(session, generation, world + 0xc0, &driver) ||
        !CSUserPointerValid(driver)) return nil;
    CSLastCaptureDiagnostic = "root-netdriver-serverconnection";
    if (!CSReadValue(session, generation, driver + 0x88, &connection) ||
        !CSUserPointerValid(connection)) return nil;
    CSLastCaptureDiagnostic = "root-connection-playercontroller";
    if (!CSReadValue(session, generation, connection + 0x30, &controller) ||
        !CSUserPointerValid(controller)) return nil;
    // Core v1.7 resolves PlayerCameraManager before its local character.
    CSLastCaptureDiagnostic = "root-controller-camera-manager";
    if (!CSReadValue(session, generation, controller + 0x680, &manager) ||
        !CSUserPointerValid(manager)) return nil;
    CSLastCaptureDiagnostic = "root-controller-local-character";
    if (!CSReadValue(session, generation, controller + 0x3540, &local) ||
        !CSUserPointerValid(local)) return nil;
    CSLastCaptureDiagnostic = "local-team";
    uint32_t localTeam = 0;
    if (local > UINT64_MAX - 0xb7c ||
        !CSReadValue(session, generation, local + 0xb78, &localTeam) ||
        localTeam < 1 || localTeam > 100) return nil;
    CSLastCaptureDiagnostic = "root-level";
    uint64_t level = 0, cluster = 0;
    if (!CSReadValue(session, generation, world + 0xb8, &level) ||
        !CSUserPointerValid(level)) return nil;
    CSLastCaptureDiagnostic = "root-actor-array-core17-primary-or-level-fallback";
    CSActorArrayState array = {};
    const char *actorArrayFailure = nullptr;
    const CSActorArraySource actorArraySource =
        CSReadCoreActorArray(session, generation, level, &cluster, &array, &actorArrayFailure);
    if (actorArraySource == CSActorArraySource::unavailable) {
        CSLastCaptureDiagnostic = actorArrayFailure;
        return nil;
    }
    CSLastCaptureDiagnostic = "camera-candidate";
    CSCamera camera = {0};
    bool cameraFound = false;
    uint64_t cameraOffset = 0;
    for (uint64_t offset : {UINT64_C(0x650), UINT64_C(0x14b0), UINT64_C(0x2320)}) {
        CSCamera candidate = {0};
        if (CSRead(session, generation, manager + offset, &candidate, sizeof(candidate)) &&
            CSCameraValid(candidate)) { camera = candidate; cameraFound = true; cameraOffset = offset; break; }
    }
    if (!cameraFound) return nil;
    CSLastCaptureDiagnostic = "local-position";
    CSVector localPosition = {0};
    bool hasLocalPosition = false;
    if (!CSPosition(session, generation, base, local, &localPosition, &hasLocalPosition) ||
        !hasLocalPosition) return nil;
    CSLastCaptureDiagnostic = "battle-input-initial";
    uint8_t localADS = 0, localFiring = 0;
    float controlRotation[2] = {0};
    if (includeBattleInputs &&
        (local < 0x100000000ULL || local > 0x8000000000ULL - 0x2751 ||
         controller < 0x100000000ULL || controller > 0x8000000000ULL - 0x628 ||
         !CSReadValue(session, generation, local + 0x1848, &localADS) ||
         !CSReadValue(session, generation, local + 0x2750, &localFiring) ||
         !CSRead(session, generation, controller + 0x620, controlRotation, sizeof(controlRotation)) ||
         !std::isfinite(controlRotation[0]) || !std::isfinite(controlRotation[1]) ||
         std::fabs(controlRotation[0]) > 360 || std::fabs(controlRotation[1]) > 360)) return nil;
    CSLastCaptureDiagnostic = "actor-scan";
    NSMutableArray<CoreSetPlayerMark *> *marks = [NSMutableArray array];
    NSMutableArray<CoreSetGrenadeMark *> *grenadeMarks = [NSMutableArray array];
    NSUInteger observedPlayerCount = 0, observedBotCount = 0;
    NSUInteger observedZeroHealthLastBreath = 0;
    NSUInteger grenadeCandidates = 0, grenadePositionPresent = 0;
    NSUInteger grenadeTyped = 0, grenadeCountdowns = 0, grenadeLifecycleSuppressed = 0, grenadeActorWorldMismatch = 0;
    uint64_t eliteProjectileClass = 0, gameStateClass = 0;
    if (collectGrenades &&
        (!CSReadValue(session, generation, base + CSEliteProjectileClassSlot, &eliteProjectileClass) ||
         !CSReadValue(session, generation, base + CSGameStateClassSlot, &gameStateClass)))
        collectGrenades = false;
    CSGrenadeClockObservation grenadeClock;
    bool grenadeClockRead = false;
    NSUInteger warningPrimaryValid = 0, warningPrimaryInvalid = 0;
    NSUInteger warningFallbackRead = 0, warningFallbackValid = 0, warningUnavailable = 0;
    NSUInteger boneRequested = 0, bonePresent = 0, bonePlain = 0, boneDecoded = 0;
    NSUInteger boneUnavailable[6] = {};
    NSUInteger boneHeadKnownProfile = 0, boneHeadProjected = 0, boneHeadUnknownProfile = 0;
    NSUInteger nameRequested = 0, namePresent = 0, weaponRequested = 0, weaponKnown = 0;
    std::vector<uint64_t> pointers(CSActorPointerBatch);
    struct ObservedActor {
        uint64_t address;
        uint64_t weapon;
        uint32_t weaponID;
        uint64_t namePointer;
        std::array<uint16_t, 16> nameRaw;
        uint32_t warningYawRaw;
        uint32_t warningFallbackRaw;
        NSUInteger markIndex;
        bool weaponObserved, nameObserved, warningYawObserved, warningFallbackObserved;
    };
    std::vector<ObservedActor> observedActors;
    struct ObservedCount { uint64_t address; };
    std::vector<ObservedCount> observedCounts;
    struct ObservedGrenade {
        uint64_t address; uint32_t nameIndex; CSVector position;
        uint64_t type, outer; uint32_t explosionRaw; uint8_t flags;
        bool timerObserved; NSUInteger markIndex;
    };
    std::vector<ObservedGrenade> observedGrenades;
    std::unordered_map<uint32_t, bool> grenadeNames;
    auto nameRead = [session, generation](uint64_t address, void *output, size_t length) {
        return CSRead(session, generation, address, output, length);
    };
    struct ObservedBone { uint64_t actor; NSUInteger markIndex; };
    std::vector<ObservedBone> observedBones;
    std::unordered_map<uint64_t, bool> characterClassCache;
    std::unordered_map<uint64_t, bool> grenadeClassCache;
    NSUInteger nonzeroActors = 0;
    NSUInteger coreAddressValid = 0, coreSpeedRead = 0, coreSpeedFinite = 0, coreSpeedMatched = 0;
    NSUInteger coreNotLocal = 0, coreTeamRead = 0, coreTeamRange = 0, coreEnemyTeam = 0;
    NSUInteger coreStatePointerValid = 0, coreStateFlagsRead = 0, coreStateBit20Clear = 0;
    NSUInteger coreLifecycleRead = 0, coreLifecyclePass = 0, coreHealthRead = 0, coreHealthPass = 0;
    NSUInteger coreRootValid = 0, coreMeshValid = 0, coreAIRead = 0, coreAccepted = 0;
    NSUInteger classObserved = 0, classMatched = 0, classMismatched = 0, classReadFailed = 0;
    bool localInActorArray = false;
    for (int32_t start = 0; start < array.count; start += CSActorPointerBatch) {
        int32_t batch = std::min<int32_t>(CSActorPointerBatch, array.count - start);
        if (!CSRead(session, generation, array.data + (uint64_t)start * 8,
                    pointers.data(), (size_t)batch * 8)) {
            // Core v1.7 falls back from its bulk pointer copy to individual
            // elements. Preserve that semantic while keeping normal reads at
            // the transport's maximum bounded chunk size.
            for (int32_t index = 0; index < batch; ++index) {
                if (!CSReadValue(session, generation,
                                 array.data + (uint64_t)(start + index) * 8,
                                 &pointers[(size_t)index])) return nil;
            }
        }
        for (int32_t index = 0; index < batch; ++index) {
            uint64_t actor = pointers[(size_t)index];
            if (!actor) continue;
            ++nonzeroActors;
            if (!CSUserPointerValid(actor)) continue;
            ++coreAddressValid;
            if (actor == local) localInActorArray = true;

            // Core v1.7 exact branch order, 0x1000d5460..0x1000d549c:
            // float32 DefaultSpeedValue(+0x10bc), finite, |value-479.5| < 0.1.
            float coreSpeed = 0;
            const bool speedRead = CSReadValue(session, generation, actor + 0x10bc, &coreSpeed);
            if (speedRead) {
                ++coreSpeedRead;
                if (std::isfinite(coreSpeed)) ++coreSpeedFinite;
            }
            const bool corePlayerProfile = speedRead && CSCorePlayerSpeedMatches(coreSpeed);
            if (corePlayerProfile) ++coreSpeedMatched;

            // Core's non-player-profile branch performs the grenade name path;
            // it does not fall through to the player filters below.
            if (!corePlayerProfile) {
              if (collectGrenades) {
                uint32_t nameIndex = 0;
                bool grenade = false;
                const bool nameIndexReady = CSReadValue(session, generation, actor + 0x18, &nameIndex);
                if (nameIndexReady) {
                    auto cached = grenadeNames.find(nameIndex);
                    if (cached != grenadeNames.end()) grenade = cached->second;
                    else if (grenadeNames.size() < 8192) {
                        std::string name;
                        auto status = CoreSet::readMaterialBaseName(nameRead, actor, namePool, &name, base);
                        if (status != CoreSet::NameReadStatus::readFailure) {
                            grenade = status == CoreSet::NameReadStatus::ok &&
                                name.find("ojGrenade_BP_C") != std::string::npos;
                            grenadeNames.emplace(nameIndex, grenade);
                        }
                    }
                }
                if (grenade) {
                    ++grenadeCandidates;
                    uint64_t grenadeClass = 0, grenadeOuter = 0;
                    uint32_t explosionRaw = 0;
                    uint8_t grenadeFlags = 0;
                    bool timerObserved = false;
                    if (eliteProjectileClass) {
                        bool typed = false;
                        if (!CSReadValue(session, generation, actor + 0x10, &grenadeClass) || !grenadeClass) continue;
                        auto cached = grenadeClassCache.find(grenadeClass);
                        if (cached != grenadeClassCache.end()) typed = cached->second;
                        else {
                            if (!CSClassTypeIsChildOf(session, generation, grenadeClass,
                                                      eliteProjectileClass, &typed)) continue;
                            grenadeClassCache.emplace(grenadeClass, typed);
                        }
                        if (typed) {
                            ++grenadeTyped;
                            if (!CSReadValue(session, generation, actor + 0x20, &grenadeOuter) ||
                                !CSReadValue(session, generation, actor + 0x7fd, &grenadeFlags) ||
                                !CSReadValue(session, generation, actor + 0x88c, &explosionRaw)) continue;
                            timerObserved = grenadeOuter == level;
                            if (!timerObserved) ++grenadeActorWorldMismatch;
                            if (!(grenadeFlags & 8) || (grenadeFlags & 4)) {
                                ++grenadeLifecycleSuppressed; continue;
                            }
                        }
                    }
                    CSVector grenadePosition = {0};
                    bool present = false;
                    if (!CSPosition(session, generation, base, actor, &grenadePosition, &present)) continue;
                    if (present) {
                        ++grenadePositionPresent;
                        CGPoint point = CGPointZero;
                        double dx = (double)grenadePosition.x - localPosition.x;
                        double dy = (double)grenadePosition.y - localPosition.y;
                        double dz = (double)grenadePosition.z - localPosition.z;
                        double distance = std::sqrt(dx * dx + dy * dy + dz * dz) / 100.0;
                        if (!std::isfinite(distance)) continue;
                        if (CSProject(camera, grenadePosition, size, &point) &&
                            point.x >= 0 && point.x <= size.width &&
                            point.y >= 0 && point.y <= size.height) {
                            if (grenadeMarks.count >= 256) {
                                collectGrenades = false;
                                continue;
                            }
                            CoreSetGrenadeMark *mark = [CoreSetGrenadeMark new];
                            mark.point = point; mark.distanceUnitsDividedBy100 = distance;
                            mark.predictionSegments = @[];
                            mark.motionPosition = grenadePosition; mark.motionActor = actor;
                            mark.motionType = grenadeClass; mark.motionNameIndex = nameIndex;
                            mark.motionExplosionRaw = explosionRaw;
                            if (timerObserved && !grenadeClockRead) {
                                grenadeClockRead = CSReadGrenadeClock(session, generation, base, world,
                                    level, gameStateClass, &grenadeClock);
                            }
                            const NSUInteger markIndex = grenadeMarks.count;
                            [grenadeMarks addObject:mark];
                            observedGrenades.push_back({actor, nameIndex, grenadePosition, grenadeClass,
                                grenadeOuter, explosionRaw, grenadeFlags, timerObserved, markIndex});
                        }
                    }
                }
              }
              continue;
            }

            // 0x1000d54a0..0x1000d54a8: self exclusion occurs only after
            // DefaultSpeedValue identifies the Core player-profile branch.
            if (actor == local) continue;
            ++coreNotLocal;

            // 0x1000d54ac..0x1000d54d8: uint32 team, valid 1...100,
            // and different from the local character's team.
            uint32_t team = 0;
            if (!CSReadValue(session, generation, actor + 0xb78, &team)) continue;
            ++coreTeamRead;
            if (team < 1 || team > 100) continue;
            ++coreTeamRange;
            if (team == localTeam) continue;
            ++coreEnemyTeam;

            // 0x1000d54e0..0x1000d5544: read an 8-byte state owner at
            // +0x1700, then its leading uint32 flags; bit20 and status byte 4
            // both reject the candidate.
            uint64_t coreState = 0;
            if (!CSReadValue(session, generation, actor + 0x1700, &coreState) ||
                !CSUserPointerValid(coreState)) continue;
            ++coreStatePointerValid;
            uint32_t coreStateFlags = 0;
            if (!CSReadValue(session, generation, coreState, &coreStateFlags)) continue;
            ++coreStateFlagsRead;
            if (coreStateFlags & (1u << 20)) continue;
            ++coreStateBit20Clear;

            uint8_t status = 0;
            if (!CSReadValue(session, generation, actor + 0x3be0, &status)) continue;
            ++coreLifecycleRead;
            if (status == 4) continue;
            ++coreLifecyclePass;

            // 0x1000d5548..0x1000d55d8: two float32 reads. Health must be
            // finite/nonnegative; maximum must be finite/positive; Core allows
            // health through maximum*1.5 rather than imposing health<=maximum.
            float health = 0, maximum = 0;
            if (!CSReadValue(session, generation, actor + 0x1060, &health) ||
                !CSReadValue(session, generation, actor + 0x1068, &maximum)) continue;
            ++coreHealthRead;
            if (!CSCorePlayerHealthMatches(health, maximum)) continue;
            ++coreHealthPass;

            // 0x1000d55dc..0x1000d563c: both 8-byte component pointers must
            // be present and in the target user range before bIsAI is read.
            uint64_t rootComponent = 0, meshComponent = 0;
            if (!CSReadValue(session, generation, actor + 0x260, &rootComponent) ||
                !CSUserPointerValid(rootComponent)) continue;
            ++coreRootValid;
            if (!CSReadValue(session, generation, actor + 0x658, &meshComponent) ||
                !CSUserPointerValid(meshComponent)) continue;
            ++coreMeshValid;

            // 0x1000d5640..0x1000d568c: bIsAI is exactly one byte.
            uint8_t ai = 0;
            if (!CSReadValue(session, generation, actor + 0xb94, &ai)) continue;
            ++coreAIRead;
            ++coreAccepted;

            // Optional target-build UClass observation. It is deliberately
            // diagnostic-only and cannot remove a Core-qualified candidate.
            if (wantedObserved) {
                uint64_t actorClass = 0;
                if (CSReadValue(session, generation, actor + 0x10, &actorClass) &&
                    CSUserPointerValid(actorClass)) {
                    ++classObserved;
                    bool character = false;
                    auto cached = characterClassCache.find(actorClass);
                    if (cached != characterClassCache.end()) character = cached->second;
                    else if (CSClassTypeIsChildOf(session, generation, actorClass, wanted, &character))
                        characterClassCache.emplace(actorClass, character);
                    else { ++classReadFailed; actorClass = 0; }
                    if (actorClass) {
                        if (character) ++classMatched; else ++classMismatched;
                    }
                } else ++classReadFailed;
            }

            uint32_t warningYawRaw = 0;
            if (includeWarningYaw &&
                !CSReadValue(session, generation, actor + 0x2758, &warningYawRaw)) continue;
            const uint8_t countStatus = status;
            const bool countEligible = includeCounts && CoreSet::playerCountEligible(health, maximum, countStatus);
            if (health == 0 && !countEligible) continue;
            CSVector position = {0};
            bool present = false;
            if (!CSPosition(session, generation, base, actor, &position, &present)) continue;
            if (!present) continue;
            double dx = (double)position.x - localPosition.x;
            double dy = (double)position.y - localPosition.y;
            double dz = (double)position.z - localPosition.z;
            double distance = std::sqrt(dx * dx + dy * dy + dz * dz) / 100.0;
            if (!std::isfinite(distance)) continue;
            // Core filters player/bot world marks before either count branch.
            // Radar and grenade paths use separate limits and remain on their own overloads.
            if (maximumDrawDistance != 0 && distance > maximumDrawDistance) continue;
            uint32_t warningFallbackRaw = 0;
            bool warningFallbackObserved = false;
            if (includeWarningYaw && !CoreSet::warningYawRawValid(warningYawRaw)) {
                // Actor.ReplicatedMovement.Rotation.Yaw, target descriptor chain:
                // 1107bbb70(+168) -> 11083e2d0(+24) -> 1103e7118(+4).
                if (!CSReadValue(session, generation, actor + 0x190, &warningFallbackRaw)) continue;
                warningFallbackObserved = true;
            }
            if (countEligible) {
                if (ai) ++observedBotCount; else ++observedPlayerCount;
                observedCounts.push_back({actor});
                if (health == 0) ++observedZeroHealthLastBreath;
            }
            if (health == 0) continue; // Count-only; never promote zero health into world marks/radar/battle input.
            const bool wantsInformation = ai ? botInformation : playerInformation;
            const bool wantsWeapon = ai ? (botWeaponText || botInformation) :
                (playerWeaponText || playerInformation);
            uint64_t weapon = 0;
            uint32_t weaponID = 0;
            if (wantsWeapon && !CSWeaponID(session, generation, actor, &weapon, &weaponID)) {
                weapon = 0; weaponID = 0;
            }
            CSVector head = position, feet = position;
            head.z += 90; feet.z -= 90;
            CGPoint centerPoint = CGPointZero, headPoint = CGPointZero, feetPoint = CGPointZero;
            bool projectedCenter = CSProject(camera, position, size, &centerPoint);
            bool projectedHead = CSProject(camera, head, size, &headPoint);
            bool projectedFeet = CSProject(camera, feet, size, &feetPoint);
            bool onScreen = projectedCenter && centerPoint.x >= 0 && centerPoint.x <= size.width &&
                centerPoint.y >= 0 && centerPoint.y <= size.height;
            if (onScreen && (!projectedHead || !projectedFeet) && !includeRadar) continue;
            CGPoint indicator = CGPointZero;
            if (!onScreen && !includeRadar && (!includeOffscreen ||
                !CSProjectIndicator(camera, position, size, &indicator))) continue;
            uint64_t namePointer = 0;
            std::array<uint16_t, 16> nameRaw = {};
            NSString *playerName = nil;
            if (wantsInformation && !CSPlayerName(session, generation, actor,
                                                   &namePointer, &nameRaw, &playerName)) {
                namePointer = 0; nameRaw.fill(0); playerName = nil;
            }
            if (wantsInformation) { ++nameRequested; if (playerName.length) ++namePresent; }
            CoreSetPlayerMark *mark = [CoreSetPlayerMark new];
            mark.actorAddress = actor; mark.bot = ai != 0;
            mark.healthStatusCode = status;
            mark.playerName = playerName; mark.teamID = team;
            mark.health = health; mark.maximumHealth = maximum;
            if (wantsWeapon) {
                ++weaponRequested;
                mark.weaponID = weaponID;
                const char *name = CoreSet::weaponNameForCanonicalID(weaponID);
                if (name) { mark.weaponName = [NSString stringWithUTF8String:name]; ++weaponKnown; }
            }
            mark.center = centerPoint; mark.head = headPoint;
            mark.feet = feetPoint; mark.distanceUnitsDividedBy100 = distance;
            mark.onScreen = onScreen; mark.indicatorProjection = indicator;
            mark.radarCameraDelta = CGPointMake((double)camera.location.x - position.x,
                                                (double)camera.location.y - position.y);
            if (includeWarningYaw) {
                float yaw = 0;
                if (CoreSet::warningYawRawValid(warningYawRaw, &yaw)) {
                    mark.warningServerYawDegrees = @(yaw);
                    ++warningPrimaryValid;
                } else ++warningPrimaryInvalid;
                if (warningFallbackObserved) ++warningFallbackRead;
                const CoreSet::WarningYawSelection selected = CoreSet::selectWarningYaw(
                    warningYawRaw, warningFallbackObserved, warningFallbackRaw);
                if (selected.valid) {
                    mark.warningYawDegrees = @(selected.degrees);
                    const bool fallback = selected.source == CoreSet::WarningYawSource::replicatedMovement;
                    mark.warningYawSource = fallback ? CoreSetWarningYawSourceReplicatedMovement :
                        CoreSetWarningYawSourceServerControlRotation;
                    if (fallback) ++warningFallbackValid;
                } else ++warningUnavailable;
            }
            mark.boneSegments = @[];
            if (onScreen && (ai ? botBones : playerBones) &&
                (boneDistanceLimit == 0 || distance <= boneDistanceLimit) &&
                observedBones.size() < CSMaxBoneActors) {
                CSBoneState bones;
                bool present = false;
                ++boneRequested;
                if (!CSReadBoneState(session, generation, base, actor, &bones, &present)) {
                    present = false;
                }
                if (present) {
                    ++bonePresent;
                    if (bones.status == 7) ++boneDecoded; else ++bonePlain;
                    mark.boneSegments = CSProjectBones(bones, camera, size);
                    uint8_t headIndex = 0;
                    if (CoreSet::referenceBoneHeadIndex(bones.array.count, &headIndex)) {
                        ++boneHeadKnownProfile;
                        CGPoint top = CGPointZero;
                        if (CSProjectBoneHead(bones, camera, size, &top, &headIndex)) {
                            mark.head = top; mark.headBoneIndex = @(headIndex);
                            ++boneHeadProjected;
                        }
                    } else ++boneHeadUnknownProfile;
                    observedBones.push_back({actor, marks.count});
                } else if (bones.status < 6) ++boneUnavailable[bones.status];
            }
            if (marks.count >= CSMaxRenderedMarks) return nil;
            [marks addObject:mark];
            observedActors.push_back({actor, weapon, weaponID, namePointer, nameRaw,
                                      warningYawRaw, warningFallbackRaw,
                                      marks.count - 1, wantsWeapon, wantsInformation,
                                      includeWarningYaw, warningFallbackObserved});
        }
    }
    if (actorArraySource == CSActorArraySource::levelFallback &&
        (!localInActorArray || coreAccepted == 0)) {
        CSLastCaptureDiagnostic = "fallback-semantic-unconfirmed localInActorArray=" +
            std::to_string(localInActorArray ? 1 : 0) + " coreAccepted=" +
            std::to_string(coreAccepted) + " speedMatched=" + std::to_string(coreSpeedMatched);
        return nil;
    }
    CSLastCaptureDiagnostic = "stability-roots";
    uint64_t worldAfter = 0, levelAfter = 0, clusterAfter = 0, controllerAfter = 0;
    uint64_t managerAfter = 0, localAfter = 0;
    uint32_t localTeamAfter = 0;
    CSCamera cameraAfter = {0};
    CSVector localPositionAfter = {0};
    bool hasLocalPositionAfter = false;
    CSActorArrayState arrayAfter = {};
    CSActorArraySource actorArraySourceAfter = CSActorArraySource::unavailable;
    const char *actorArrayFailureAfter = nullptr;
    if (!CSReadValue(session, generation, base + CSWorldSlot, &worldAfter) || worldAfter != world ||
        !CSReadValue(session, generation, world + 0xb8, &levelAfter) || levelAfter != level) return nil;
    actorArraySourceAfter = CSReadCoreActorArray(session, generation, levelAfter,
                                                 &clusterAfter, &arrayAfter,
                                                 &actorArrayFailureAfter);
    if (actorArraySourceAfter == CSActorArraySource::unavailable) {
        if (std::strcmp(actorArrayFailureAfter,
                        "root-actor-array-core17-fallback-read-failed") == 0)
            CSLastCaptureDiagnostic = "stability-actor-array-core17-fallback-read-failed";
        else if (std::strcmp(actorArrayFailureAfter,
                             "root-actor-array-core17-fallback-count-invalid") == 0)
            CSLastCaptureDiagnostic = "stability-actor-array-core17-fallback-count-invalid";
        else if (std::strcmp(actorArrayFailureAfter,
                             "root-actor-array-core17-fallback-data-invalid") == 0)
            CSLastCaptureDiagnostic = "stability-actor-array-core17-fallback-data-invalid";
        else
            CSLastCaptureDiagnostic = "stability-actor-array-core17-unavailable";
        return nil;
    }
    if (actorArraySourceAfter != actorArraySource ||
        (actorArraySource == CSActorArraySource::primary && clusterAfter != cluster) ||
        arrayAfter.data != array.data ||
        !CSReadValue(session, generation, connection + 0x30, &controllerAfter) ||
        controllerAfter != controller || !session.ready || session.generation != generation ||
        !CSReadValue(session, generation, controller + 0x3540, &localAfter) || localAfter != local ||
        !CSReadValue(session, generation, controller + 0x680, &managerAfter) || managerAfter != manager ||
        !CSRead(session, generation, manager + cameraOffset, &cameraAfter, sizeof(cameraAfter)) ||
        !CSCameraValid(cameraAfter) ||
        !CSPosition(session, generation, base, local, &localPositionAfter, &hasLocalPositionAfter) ||
        !hasLocalPositionAfter ||
        !CSReadValue(session, generation, local + 0xb78, &localTeamAfter) || localTeamAfter != localTeam ||
        session.processID != pid || session.imageBase != base) return nil;
    CSLastCaptureDiagnostic = "stability-optional-roots";
    NSMutableIndexSet *invalidGrenadeMarks = [NSMutableIndexSet indexSet];
    if (collectGrenades) {
        uint64_t poolAfter = 0;
        uint32_t countAfter = 0;
        if (!CSReadValue(session, generation, base + 0x11fba198, &poolAfter) || poolAfter != namePool ||
            !CSReadValue(session, generation, namePool + 0x1400, &countAfter) ||
            countAfter < nameCount || countAfter > 0xa00000) {
            collectGrenades = false;
            if (grenadeMarks.count)
                [invalidGrenadeMarks addIndexesInRange:NSMakeRange(0, grenadeMarks.count)];
        }
    }
    CSLastCaptureDiagnostic = "stability-actor-membership";
    std::unordered_set<uint64_t> currentActors;
    currentActors.reserve((size_t)arrayAfter.count);
    for (int32_t start = 0; start < arrayAfter.count; start += CSActorPointerBatch) {
        int32_t batch = std::min<int32_t>(CSActorPointerBatch, arrayAfter.count - start);
        if (!CSRead(session, generation, arrayAfter.data + (uint64_t)start * 8,
                    pointers.data(), (size_t)batch * 8)) {
            for (int32_t index = 0; index < batch; ++index) {
                if (!CSReadValue(session, generation,
                                 arrayAfter.data + (uint64_t)(start + index) * 8,
                                 &pointers[(size_t)index])) return nil;
            }
        }
        for (int32_t index = 0; index < batch; ++index)
            if (pointers[(size_t)index]) currentActors.insert(pointers[(size_t)index]);
    }
    const bool localInActorArrayAfter = currentActors.find(local) != currentActors.end();
    if (actorArraySource == CSActorArraySource::levelFallback && !localInActorArrayAfter) {
        CSLastCaptureDiagnostic = "fallback-semantic-unstable localInActorArray=1 localInActorArrayAfter=0";
        return nil;
    }
    // Membership enumeration can dominate a kernel-mapped capture. Refresh the
    // camera/local origin after it, then bound the remaining projection window
    // so a slow first pass cannot be reported as a current rendered frame.
    CSLastCaptureDiagnostic = "stability-final-projection-roots";
    if (!CSRead(session, generation, manager + cameraOffset, &cameraAfter, sizeof(cameraAfter)) ||
        !CSCameraValid(cameraAfter) ||
        !CSPosition(session, generation, base, local, &localPositionAfter, &hasLocalPositionAfter) ||
        !hasLocalPositionAfter) return nil;
    const double finalReprojectionStartedAt = CACurrentMediaTime();
    CSLastCaptureDiagnostic = "stability-player-actors";
    NSMutableIndexSet *invalidActorMarks = [NSMutableIndexSet indexSet];
    for (const ObservedActor &actor : observedActors) {
        if (currentActors.find(actor.address) == currentActors.end()) {
            [invalidActorMarks addIndex:actor.markIndex];
            continue;
        }
        CSCorePlayerState current;
        CSVector position = {0};
        bool present = false;
        uint64_t weapon = 0;
        uint32_t weaponID = 0;
        uint64_t namePointer = 0;
        std::array<uint16_t, 16> nameRaw = {};
        NSString *name = nil;
        uint32_t warningYawRaw = 0;
        uint32_t warningFallbackRaw = 0;
        if (!CSReadCorePlayerState(session, generation, actor.address, local, localTeam, &current) ||
            current.health == 0 ||
            !CSPosition(session, generation, base, actor.address, &position, &present) || !present) {
            [invalidActorMarks addIndex:actor.markIndex];
            continue;
        }
        const double dx = (double)position.x - localPositionAfter.x;
        const double dy = (double)position.y - localPositionAfter.y;
        const double dz = (double)position.z - localPositionAfter.z;
        const double distance = std::sqrt(dx * dx + dy * dy + dz * dz) / 100.0;
        if (!std::isfinite(distance) ||
            (maximumDrawDistance != 0 && distance > maximumDrawDistance)) {
            [invalidActorMarks addIndex:actor.markIndex];
            continue;
        }
        CSVector head = position, feet = position;
        head.z += 90; feet.z -= 90;
        CGPoint centerPoint = CGPointZero, headPoint = CGPointZero, feetPoint = CGPointZero;
        const bool projectedCenter = CSProject(cameraAfter, position, size, &centerPoint);
        const bool projectedHead = CSProject(cameraAfter, head, size, &headPoint);
        const bool projectedFeet = CSProject(cameraAfter, feet, size, &feetPoint);
        const bool onScreen = projectedCenter && centerPoint.x >= 0 && centerPoint.x <= size.width &&
            centerPoint.y >= 0 && centerPoint.y <= size.height;
        CGPoint indicator = CGPointZero;
        if ((onScreen && (!projectedHead || !projectedFeet) && !includeRadar) ||
            (!onScreen && !includeRadar &&
             (!includeOffscreen || !CSProjectIndicator(cameraAfter, position, size, &indicator)))) {
            [invalidActorMarks addIndex:actor.markIndex];
            continue;
        }
        CoreSetPlayerMark *mark = marks[actor.markIndex];
        mark.bot = current.ai != 0;
        mark.healthStatusCode = current.status;
        mark.teamID = current.team;
        mark.health = current.health;
        mark.maximumHealth = current.maximum;
        mark.center = centerPoint;
        mark.head = headPoint;
        mark.feet = feetPoint;
        mark.distanceUnitsDividedBy100 = distance;
        mark.onScreen = onScreen;
        mark.indicatorProjection = indicator;
        mark.radarCameraDelta = CGPointMake((double)cameraAfter.location.x - position.x,
                                            (double)cameraAfter.location.y - position.y);
        if (actor.weaponObserved) {
            if (!CSWeaponID(session, generation, actor.address, &weapon, &weaponID)) {
                mark.weaponID = 0;
                mark.weaponName = nil;
            } else if (weapon != actor.weapon || weaponID != actor.weaponID) {
                mark.weaponID = weaponID;
                const char *weaponName = CoreSet::weaponNameForCanonicalID(weaponID);
                mark.weaponName = weaponName ? [NSString stringWithUTF8String:weaponName] : nil;
            }
        }
        if (actor.nameObserved) {
            if (!CSPlayerName(session, generation, actor.address, &namePointer, &nameRaw, &name))
                mark.playerName = nil;
            else if (namePointer != actor.namePointer || nameRaw != actor.nameRaw)
                mark.playerName = name;
        }
        if (actor.warningYawObserved) {
            if (!CSReadValue(session, generation, actor.address + 0x2758, &warningYawRaw)) {
                mark.warningServerYawDegrees = nil;
                mark.warningYawDegrees = nil;
                mark.warningYawSource = CoreSetWarningYawSourceNone;
                continue;
            }
            bool fallbackObserved = false;
            if (!CoreSet::warningYawRawValid(warningYawRaw) || actor.warningFallbackObserved) {
                fallbackObserved = CSReadValue(session, generation, actor.address + 0x190,
                                                &warningFallbackRaw);
            }
            mark.warningServerYawDegrees = nil;
            mark.warningYawDegrees = nil;
            mark.warningYawSource = CoreSetWarningYawSourceNone;
            float serverYaw = 0;
            if (CoreSet::warningYawRawValid(warningYawRaw, &serverYaw))
                mark.warningServerYawDegrees = @(serverYaw);
            const CoreSet::WarningYawSelection selected = CoreSet::selectWarningYaw(
                warningYawRaw, fallbackObserved, warningFallbackRaw);
            if (selected.valid) {
                mark.warningYawDegrees = @(selected.degrees);
                mark.warningYawSource = selected.source == CoreSet::WarningYawSource::replicatedMovement ?
                    CoreSetWarningYawSourceReplicatedMovement : CoreSetWarningYawSourceServerControlRotation;
            }
        }
    }
    CSLastCaptureDiagnostic = "stability-count-actors";
    observedPlayerCount = 0;
    observedBotCount = 0;
    observedZeroHealthLastBreath = 0;
    for (const ObservedCount &count : observedCounts) {
        if (currentActors.find(count.address) == currentActors.end()) continue;
        CSCorePlayerState current;
        CSVector position = {0};
        bool present = false;
        if (!CSReadCorePlayerState(session, generation, count.address, local, localTeam, &current) ||
            !CoreSet::playerCountEligible(current.health, current.maximum, current.status) ||
            !CSPosition(session, generation, base, count.address, &position, &present) || !present) continue;
        const double dx = (double)position.x - localPositionAfter.x;
        const double dy = (double)position.y - localPositionAfter.y;
        const double dz = (double)position.z - localPositionAfter.z;
        const double distance = std::sqrt(dx * dx + dy * dy + dz * dz) / 100.0;
        if (!std::isfinite(distance) ||
            (maximumDrawDistance != 0 && distance > maximumDrawDistance)) continue;
        if (current.ai) ++observedBotCount; else ++observedPlayerCount;
        if (current.health == 0) ++observedZeroHealthLastBreath;
    }
    CSLastCaptureDiagnostic = "stability-grenades";
    for (ObservedGrenade &grenade : observedGrenades) {
        if (currentActors.find(grenade.address) == currentActors.end()) {
            [invalidGrenadeMarks addIndex:grenade.markIndex];
            continue;
        }
        uint32_t nameIndex = 0;
        CSVector position = {0};
        bool present = false;
        std::string name;
        uint64_t type = 0, outer = 0;
        uint32_t explosionRaw = 0;
        uint8_t flags = 0;
        if (!CSReadValue(session, generation, grenade.address + 0x18, &nameIndex)) {
            [invalidGrenadeMarks addIndex:grenade.markIndex];
            continue;
        }
        const CoreSet::NameReadStatus nameStatus =
            CoreSet::readMaterialBaseName(nameRead, grenade.address, namePool, &name, base);
        if (nameStatus == CoreSet::NameReadStatus::readFailure) {
            [invalidGrenadeMarks addIndex:grenade.markIndex];
            continue;
        }
        if (nameIndex != grenade.nameIndex || nameStatus != CoreSet::NameReadStatus::ok ||
            name.find("ojGrenade_BP_C") == std::string::npos) {
            [invalidGrenadeMarks addIndex:grenade.markIndex];
            continue;
        }
        if (!CSPosition(session, generation, base, grenade.address, &position, &present)) {
            [invalidGrenadeMarks addIndex:grenade.markIndex];
            continue;
        }
        if (!present) {
            [invalidGrenadeMarks addIndex:grenade.markIndex];
            continue;
        }
        const double dx = (double)position.x - localPositionAfter.x;
        const double dy = (double)position.y - localPositionAfter.y;
        const double dz = (double)position.z - localPositionAfter.z;
        const double distance = std::sqrt(dx * dx + dy * dy + dz * dz) / 100.0;
        CGPoint point = CGPointZero;
        if (!std::isfinite(distance) || !CSProject(cameraAfter, position, size, &point) ||
            point.x < 0 || point.x > size.width || point.y < 0 || point.y > size.height) {
            [invalidGrenadeMarks addIndex:grenade.markIndex];
            continue;
        }
        CoreSetGrenadeMark *mark = grenadeMarks[grenade.markIndex];
        mark.point = point;
        mark.distanceUnitsDividedBy100 = distance;
        mark.motionPosition = position;
        if (grenade.timerObserved) {
            if (!CSReadValue(session, generation, grenade.address + 0x10, &type) ||
                !CSReadValue(session, generation, grenade.address + 0x20, &outer) ||
                !CSReadValue(session, generation, grenade.address + 0x7fd, &flags) ||
                !CSReadValue(session, generation, grenade.address + 0x88c, &explosionRaw)) {
                [invalidGrenadeMarks addIndex:grenade.markIndex];
                continue;
            }
            if (type != grenade.type || outer != grenade.outer || !(flags & 8) || (flags & 4)) {
                [invalidGrenadeMarks addIndex:grenade.markIndex];
                continue;
            }
            grenade.flags = flags;
            grenade.explosionRaw = explosionRaw;
            mark.motionExplosionRaw = explosionRaw;
        }
    }
    if (collectGrenades) {
        uint64_t eliteClassAfter = 0, gameStateClassAfter = 0;
        const bool grenadeRootsStable =
            CSReadValue(session, generation, base + CSEliteProjectileClassSlot, &eliteClassAfter) &&
            eliteClassAfter == eliteProjectileClass &&
            CSReadValue(session, generation, base + CSGameStateClassSlot, &gameStateClassAfter) &&
            gameStateClassAfter == gameStateClass;
        if (!grenadeRootsStable) {
            if (grenadeMarks.count)
                [invalidGrenadeMarks addIndexesInRange:NSMakeRange(0, grenadeMarks.count)];
        } else if (grenadeClockRead) {
            CSGrenadeClockObservation after;
            const bool clockRead = CSReadGrenadeClock(session, generation, base, world,
                                                       level, gameStateClass, &after);
            const bool clockStable = clockRead && after.gameState == grenadeClock.gameState &&
                after.type == grenadeClock.type && after.outer == grenadeClock.outer &&
                after.vtable == grenadeClock.vtable && after.getter == grenadeClock.getter &&
                after.present && after.worldTime >= grenadeClock.worldTime &&
                after.worldTime - grenadeClock.worldTime <= 0.45;
            if (clockStable) {
                for (const ObservedGrenade &grenade : observedGrenades) {
                    if (!grenade.timerObserved || [invalidGrenadeMarks containsIndex:grenade.markIndex]) continue;
                    float explosion = 0, countdown = 0;
                    std::memcpy(&explosion, &grenade.explosionRaw, sizeof(explosion));
                    if (CoreSet::grenadeCountdownSeconds(explosion, after.worldTime, after.delta, grenade.flags, &countdown)) {
                        grenadeMarks[grenade.markIndex].countdownSeconds = @(countdown);
                        ++grenadeCountdowns;
                    }
                }
            } else {
                for (const ObservedGrenade &grenade : observedGrenades)
                    if (grenade.timerObserved) [invalidGrenadeMarks addIndex:grenade.markIndex];
            }
        }
    }
    CSLastCaptureDiagnostic = "stability-bones";
    for (const ObservedBone &bone : observedBones) {
        if ([invalidActorMarks containsIndex:bone.markIndex] ||
            currentActors.find(bone.actor) == currentActors.end()) continue;
        CoreSetPlayerMark *mark = marks[bone.markIndex];
        CSBoneState after;
        bool present = false;
        const bool boneRead = CSReadBoneState(session, generation, base, bone.actor, &after, &present);
        if (!boneRead || !present) {
            mark.boneSegments = @[];
            mark.headBoneIndex = nil;
            continue;
        }
        mark.boneSegments = CSProjectBones(after, cameraAfter, size);
        uint8_t headIndex = 0;
        CGPoint top = CGPointZero;
        if (CoreSet::referenceBoneHeadIndex(after.array.count, &headIndex) &&
            CSProjectBoneHead(after, cameraAfter, size, &top, &headIndex)) {
            mark.head = top;
            mark.headBoneIndex = @(headIndex);
        } else {
            mark.headBoneIndex = nil;
        }
    }
    CSLastCaptureDiagnostic = "stability-battle-inputs";
    if (includeBattleInputs) {
        uint8_t adsAfter = 0, firingAfter = 0;
        float rotationAfter[2] = {0};
        if (!CSReadValue(session, generation, local + 0x1848, &adsAfter) ||
            !CSReadValue(session, generation, local + 0x2750, &firingAfter) ||
            !CSRead(session, generation, controller + 0x620, rotationAfter, sizeof(rotationAfter)) ||
            !std::isfinite(rotationAfter[0]) || !std::isfinite(rotationAfter[1]) ||
            std::fabs(rotationAfter[0]) > 360 || std::fabs(rotationAfter[1]) > 360) return nil;
        localADS = adsAfter;
        localFiring = firingAfter;
        controlRotation[0] = rotationAfter[0];
        controlRotation[1] = rotationAfter[1];
    }
    if (invalidActorMarks.count) [marks removeObjectsAtIndexes:invalidActorMarks];
    if (invalidGrenadeMarks.count) [grenadeMarks removeObjectsAtIndexes:invalidGrenadeMarks];
    NSUInteger producedPlayerMarks = 0, producedBotMarks = 0;
    for (CoreSetPlayerMark *mark in marks) {
        if (mark.bot) ++producedBotMarks; else ++producedPlayerMarks;
    }
    if (!includeBattleInputs && !includeCounts && marks.count == 0 && grenadeMarks.count == 0) {
        CSLastCaptureDiagnostic = "no-renderable-output coreAccepted=" +
            std::to_string(coreAccepted) + " localInActorArray=" +
            std::to_string(localInActorArray ? 1 : 0);
        return nil;
    }
    const double captureCompletedAt = CACurrentMediaTime();
    const double finalReprojectionAge = captureCompletedAt - finalReprojectionStartedAt;
    if (!std::isfinite(finalReprojectionAge) || finalReprojectionAge < 0 ||
        finalReprojectionAge > 0.45) {
        CSLastCaptureDiagnostic = "final-reprojection-stale age=" +
            std::to_string(finalReprojectionAge) + " limit=0.45";
        return nil;
    }
    CSLastCaptureDiagnostic = "identity-final";
    if (!session.ready || session.generation != generation) return nil;
    CoreSetPlayerSnapshot *snapshot = [CoreSetPlayerSnapshot new];
    snapshot.sessionGeneration = generation; snapshot.processID = pid;
    snapshot.imageBase = base; snapshot.snapshotID = [NSUUID UUID];
    snapshot.cameraYawDegrees = cameraAfter.rotation.y;
    snapshot.motionCamera = cameraAfter;
    snapshot.cameraPitchDegrees = cameraAfter.rotation.x;
    snapshot.cameraFieldOfViewDegrees = cameraAfter.fov;
    snapshot.battleInputsPresent = includeBattleInputs;
    if (includeBattleInputs) {
        snapshot.controllerAddress = controller;
        snapshot.localActorAddress = local;
        snapshot.localADS = localADS != 0;
        snapshot.localFiring = localFiring != 0;
        snapshot.controlPitchDegrees = controlRotation[0];
        snapshot.controlYawDegrees = controlRotation[1];
    }
    snapshot.captureStartedMonotonicSeconds = captureStartedAt;
    snapshot.captureCompletedMonotonicSeconds = captureCompletedAt;
    snapshot.marks = [marks copy];
    snapshot.grenadeMarks = [grenadeMarks copy];
    snapshot.observedPlayerCount = observedPlayerCount;
    snapshot.observedBotCount = observedBotCount;
    snapshot.readSemanticDiagnostic = [NSString stringWithFormat:
        @"candidateCounts=capture-pass actorArraySource=%s displayFields=final-reprojected detailCounters=initial-filter-plus-final-output actors=%d nonzero=%lu addressValid=%lu speedRead=%lu speedFinite=%lu speedMatched=%lu notLocal=%lu teamRead=%lu teamRange=%lu enemyTeam=%lu statePointer=%lu stateFlags=%lu stateBit20Clear=%lu lifecycleRead=%lu lifecyclePass=%lu healthRead=%lu healthPass=%lu rootValid=%lu meshValid=%lu aiRead=%lu coreAccepted=%lu localInActorArray=%d localInActorArrayAfter=%d uclassWantedObserved=%d classObserved=%lu classMatched=%lu classMismatched=%lu classReadFailed=%lu marks=%lu producedPlayers=%lu producedBots=%lu players=%lu bots=%lu zeroHealthLastBreath=%lu countScope=positive-health-or-last-breath-enemy-draw-range countParity=partial "
         "grenadeRequested=%d grenadeCandidates=%lu grenadePosition=%lu grenadeOnscreen=%lu "
         "grenadeClassKnown=%d gameStateClassKnown=%d grenadeTyped=%lu grenadeCountdowns=%lu grenadeLifecycleSuppressed=%lu grenadeActorWorldMismatch=%lu grenadeClockKnown=%d grenadeClockStatus=%u "
         "grenadeTimer=target-server-clock-clamped grenadeRadius=unproven grenadeAnimation=local-prediction-partial "
         "warningRequested=%d warningPrimaryValid=%lu warningPrimaryInvalid=%lu warningFallbackRead=%lu warningFallbackValid=%lu "
         "warningUnavailable=%lu warningFallbackOwner=actor-replicated-movement-rotation-yaw "
         "boneRequested=%lu bonePresent=%lu bonePlain=%lu boneDecoded=%lu boneMissing=%lu boneUnregistered=%lu boneArrayInvalid=%lu boneBounds=%lu boneDecoderUnknown=%lu "
         "boneHeadKnownProfile=%lu boneHeadProjected=%lu boneHeadUnknownProfile=%lu headScope=requested-bones-only headParity=partial "
         "networkFreshness=unproven captureStability=stable-identity-plus-bounded-dynamic-reread grenadeAnimationScope=local-position-history grenadeRadiusGap=no-verified-elite-blast-field "
         "nameRequested=%lu namePresent=%lu weaponRequested=%lu weaponKnown=%lu informationLayout=local-subset informationGap=native-font-icons-and-anchors "
         "captureDuration=%.3f finalReprojectionAge=%.3f freshnessBasis=final-reprojected",
        actorArraySource == CSActorArraySource::primary ? "core17-primary" : "core17-level-a0-a8-fallback",
        array.count, (unsigned long)nonzeroActors, (unsigned long)coreAddressValid,
        (unsigned long)coreSpeedRead, (unsigned long)coreSpeedFinite, (unsigned long)coreSpeedMatched,
        (unsigned long)coreNotLocal, (unsigned long)coreTeamRead, (unsigned long)coreTeamRange,
        (unsigned long)coreEnemyTeam, (unsigned long)coreStatePointerValid,
        (unsigned long)coreStateFlagsRead, (unsigned long)coreStateBit20Clear,
        (unsigned long)coreLifecycleRead, (unsigned long)coreLifecyclePass,
        (unsigned long)coreHealthRead, (unsigned long)coreHealthPass,
        (unsigned long)coreRootValid, (unsigned long)coreMeshValid,
        (unsigned long)coreAIRead, (unsigned long)coreAccepted,
        localInActorArray, localInActorArrayAfter, wantedObserved,
        (unsigned long)classObserved, (unsigned long)classMatched,
        (unsigned long)classMismatched, (unsigned long)classReadFailed,
        (unsigned long)marks.count, (unsigned long)producedPlayerMarks,
        (unsigned long)producedBotMarks, (unsigned long)observedPlayerCount,
        (unsigned long)observedBotCount, (unsigned long)observedZeroHealthLastBreath,
        includeGrenadeWarning, (unsigned long)grenadeCandidates,
        (unsigned long)grenadePositionPresent, (unsigned long)grenadeMarks.count,
        eliteProjectileClass != 0, gameStateClass != 0,
        (unsigned long)grenadeTyped, (unsigned long)grenadeCountdowns, (unsigned long)grenadeLifecycleSuppressed,
        (unsigned long)grenadeActorWorldMismatch,
        grenadeClock.present, unsigned(grenadeClock.status),
        includeWarningYaw, (unsigned long)warningPrimaryValid, (unsigned long)warningPrimaryInvalid,
        (unsigned long)warningFallbackRead, (unsigned long)warningFallbackValid, (unsigned long)warningUnavailable,
        (unsigned long)boneRequested, (unsigned long)bonePresent, (unsigned long)bonePlain, (unsigned long)boneDecoded,
        (unsigned long)boneUnavailable[1], (unsigned long)boneUnavailable[2], (unsigned long)boneUnavailable[3],
        (unsigned long)boneUnavailable[4], (unsigned long)boneUnavailable[5],
        (unsigned long)boneHeadKnownProfile, (unsigned long)boneHeadProjected, (unsigned long)boneHeadUnknownProfile,
        (unsigned long)nameRequested, (unsigned long)namePresent,
        (unsigned long)weaponRequested, (unsigned long)weaponKnown,
        snapshot.captureCompletedMonotonicSeconds - captureStartedAt, finalReprojectionAge];
    CSLastCaptureDiagnostic = "ready";
    return snapshot;
}
@end
