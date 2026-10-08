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
static constexpr size_t CSMaxBoneActors = 256;
static constexpr NSUInteger CSMaxRenderedMarks = 8192;

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

static bool CSBoneStatesEqual(const CSBoneState &left, const CSBoneState &right) {
    if (left.mesh != right.mesh || left.registered != right.registered || left.flags != right.flags ||
        left.callback != right.callback || left.key != right.key || left.status != right.status ||
        std::memcmp(&left.array, &right.array, sizeof(left.array)) != 0 ||
        left.component != right.component || left.samples.size() != right.samples.size()) return false;
    for (size_t index = 0; index < left.samples.size(); ++index)
        if (left.samples[index].index != right.samples[index].index ||
            left.samples[index].bytes != right.samples[index].bytes) return false;
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
    if (!session.ready || session.capabilities != 1 || !std::isfinite(size.width) ||
        !std::isfinite(size.height) || size.width <= 0 || size.height <= 0 ||
        !std::isfinite(boneDistanceLimit) || boneDistanceLimit < 0 ||
        !std::isfinite(maximumDrawDistance) || maximumDrawDistance < 0 ||
        (maximumDrawDistance != 0 && (maximumDrawDistance < 1 || maximumDrawDistance > 1000))) return nil;
    uint64_t generation = session.generation, base = session.imageBase;
    int32_t pid = session.processID;
    if (!base || pid <= 0 || base > UINT64_MAX - CSGameStateClassSlot) return nil;
    uint64_t world = 0, wanted = 0;
    if (!CSReadValue(session, generation, base + CSWorldSlot, &world) || !world ||
        !CSReadValue(session, generation, base + CSCharacterClassSlot, &wanted) || !wanted) return nil;
    uint64_t namePool = 0;
    uint32_t nameCount = 0;
    if (includeGrenadeWarning &&
        (!CSReadValue(session, generation, base + 0x11fba198, &namePool) || !namePool ||
         namePool < 0x100000000ULL || namePool > 0x8000000000ULL - 0x1404 ||
         !CSReadValue(session, generation, namePool + 0x1400, &nameCount) ||
         !nameCount || nameCount > 0xa00000)) return nil;
    uint64_t level = 0, cluster = 0;
    if (!CSReadValue(session, generation, world + 0xb8, &level) || !level ||
        !CSReadValue(session, generation, level + 0xe0, &cluster) || !cluster) return nil;
    struct { uint64_t data; int32_t count; int32_t capacity; } array = {0};
    if (!CSRead(session, generation, cluster + 0x28, &array, sizeof(array)) ||
        array.count < 0 || array.count > CSMaxActors || array.capacity < array.count ||
        array.capacity > CSMaxActors || (array.count && !array.data)) return nil;
    uint64_t driver = 0, connection = 0, controller = 0, local = 0, manager = 0;
    if (!CSReadValue(session, generation, world + 0xc0, &driver) || !driver ||
        !CSReadValue(session, generation, driver + 0x88, &connection) || !connection ||
        !CSReadValue(session, generation, connection + 0x30, &controller) || !controller ||
        !CSReadValue(session, generation, controller + 0x3540, &local) || !local ||
        !CSReadValue(session, generation, controller + 0x680, &manager) || !manager) return nil;
    CSCamera camera = {0};
    bool cameraFound = false;
    uint64_t cameraOffset = 0;
    for (uint64_t offset : {UINT64_C(0x650), UINT64_C(0x14b0), UINT64_C(0x2320)}) {
        CSCamera candidate = {0};
        if (CSRead(session, generation, manager + offset, &candidate, sizeof(candidate)) &&
            CSCameraValid(candidate)) { camera = candidate; cameraFound = true; cameraOffset = offset; break; }
    }
    if (!cameraFound) return nil;
    CSVector localPosition = {0};
    bool hasLocalPosition = false;
    if (!CSPosition(session, generation, base, local, &localPosition, &hasLocalPosition) ||
        !hasLocalPosition) return nil;
    uint32_t localTeam = 0;
    if (local > UINT64_MAX - 0xb7c ||
        !CSReadValue(session, generation, local + 0xb78, &localTeam) ||
        localTeam < 1 || localTeam > 100) return nil;
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
    NSMutableArray<CoreSetPlayerMark *> *marks = [NSMutableArray array];
    NSMutableArray<CoreSetGrenadeMark *> *grenadeMarks = [NSMutableArray array];
    NSUInteger observedPlayerCount = 0, observedBotCount = 0;
    NSUInteger observedZeroHealthLastBreath = 0;
    NSUInteger grenadeCandidates = 0, grenadePositionPresent = 0;
    NSUInteger grenadeTyped = 0, grenadeCountdowns = 0, grenadeLifecycleSuppressed = 0, grenadeActorWorldMismatch = 0;
    uint64_t eliteProjectileClass = 0, gameStateClass = 0;
    if (includeGrenadeWarning &&
        (!CSReadValue(session, generation, base + CSEliteProjectileClassSlot, &eliteProjectileClass) ||
         !CSReadValue(session, generation, base + CSGameStateClassSlot, &gameStateClass))) return nil;
    CSGrenadeClockObservation grenadeClock;
    bool grenadeClockRead = false;
    NSUInteger warningPrimaryValid = 0, warningPrimaryInvalid = 0;
    NSUInteger warningFallbackRead = 0, warningFallbackValid = 0, warningUnavailable = 0;
    NSUInteger boneRequested = 0, bonePresent = 0, bonePlain = 0, boneDecoded = 0;
    NSUInteger boneUnavailable[6] = {};
    NSUInteger boneHeadKnownProfile = 0, boneHeadProjected = 0, boneHeadUnknownProfile = 0;
    NSUInteger nameRequested = 0, namePresent = 0, weaponRequested = 0, weaponKnown = 0;
    uint64_t pointers[512];
    std::vector<uint64_t> observedPointers;
    observedPointers.reserve((size_t)array.count);
    struct ObservedActor {
        uint64_t address;
        CSVector position;
        float health, maximum;
        uint64_t weapon;
        uint32_t weaponID;
        uint64_t namePointer;
        std::array<uint16_t, 16> nameRaw;
        uint32_t team;
        uint8_t ai, status;
        uint32_t warningYawRaw;
        uint32_t warningFallbackRaw;
        uint64_t warningActorClass;
        bool weaponObserved, nameObserved, warningYawObserved, warningFallbackObserved;
    };
    std::vector<ObservedActor> observedActors;
    struct ObservedCount { uint64_t address, type; CSVector position; float health, maximum; uint32_t team; uint8_t ai, status; };
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
    struct ObservedBone { uint64_t actor; CSBoneState state; };
    std::vector<ObservedBone> observedBones;
    for (int32_t start = 0; start < array.count; start += 512) {
        int32_t batch = std::min<int32_t>(512, array.count - start);
        if (!CSRead(session, generation, array.data + (uint64_t)start * 8,
                    pointers, (size_t)batch * 8)) return nil;
        observedPointers.insert(observedPointers.end(), pointers, pointers + batch);
        for (int32_t index = 0; index < batch; ++index) {
            uint64_t actor = pointers[index];
            if (!actor || actor == local) continue;
            if (includeGrenadeWarning) {
                if (actor > UINT64_MAX - 0x20) return nil;
                uint32_t nameIndex = 0;
                if (!CSReadValue(session, generation, actor + 0x18, &nameIndex)) return nil;
                bool grenade = false;
                auto cached = grenadeNames.find(nameIndex);
                if (cached != grenadeNames.end()) grenade = cached->second;
                else {
                    if (grenadeNames.size() >= 8192) return nil;
                    std::string name;
                    auto status = CoreSet::readMaterialBaseName(nameRead, actor, namePool, &name, base);
                    if (status == CoreSet::NameReadStatus::readFailure) return nil;
                    grenade = status == CoreSet::NameReadStatus::ok &&
                        name.find("ojGrenade_BP_C") != std::string::npos;
                    grenadeNames.emplace(nameIndex, grenade);
                }
                if (grenade) {
                    ++grenadeCandidates;
                    uint64_t grenadeClass = 0, grenadeOuter = 0;
                    uint32_t explosionRaw = 0;
                    uint8_t grenadeFlags = 0;
                    bool timerObserved = false;
                    if (eliteProjectileClass) {
                        bool typed = false;
                        if (!CSClassIsChildOf(session, generation, actor, eliteProjectileClass, &typed, &grenadeClass)) return nil;
                        if (typed) {
                            ++grenadeTyped;
                            if (!CSReadValue(session, generation, actor + 0x20, &grenadeOuter) ||
                                !CSReadValue(session, generation, actor + 0x7fd, &grenadeFlags) ||
                                !CSReadValue(session, generation, actor + 0x88c, &explosionRaw)) return nil;
                            timerObserved = grenadeOuter == level;
                            if (!timerObserved) ++grenadeActorWorldMismatch;
                            if (!(grenadeFlags & 8) || (grenadeFlags & 4)) {
                                ++grenadeLifecycleSuppressed; continue;
                            }
                        }
                    }
                    CSVector grenadePosition = {0};
                    bool present = false;
                    if (!CSPosition(session, generation, base, actor, &grenadePosition, &present)) return nil;
                    if (present) {
                        ++grenadePositionPresent;
                        CGPoint point = CGPointZero;
                        double dx = (double)grenadePosition.x - localPosition.x;
                        double dy = (double)grenadePosition.y - localPosition.y;
                        double dz = (double)grenadePosition.z - localPosition.z;
                        double distance = std::sqrt(dx * dx + dy * dy + dz * dz) / 100.0;
                        if (!std::isfinite(distance)) return nil;
                        if (CSProject(camera, grenadePosition, size, &point) &&
                            point.x >= 0 && point.x <= size.width &&
                            point.y >= 0 && point.y <= size.height) {
                            if (grenadeMarks.count >= 256) return nil;
                            CoreSetGrenadeMark *mark = [CoreSetGrenadeMark new];
                            mark.point = point; mark.distanceUnitsDividedBy100 = distance;
                            mark.predictionSegments = @[];
                            mark.motionPosition = grenadePosition; mark.motionActor = actor;
                            mark.motionType = grenadeClass; mark.motionNameIndex = nameIndex;
                            mark.motionExplosionRaw = explosionRaw;
                            if (timerObserved && !grenadeClockRead) {
                                if (!CSReadGrenadeClock(session, generation, base, world, level, gameStateClass, &grenadeClock)) return nil;
                                grenadeClockRead = true;
                            }
                            const NSUInteger markIndex = grenadeMarks.count;
                            [grenadeMarks addObject:mark];
                            observedGrenades.push_back({actor, nameIndex, grenadePosition, grenadeClass,
                                grenadeOuter, explosionRaw, grenadeFlags, timerObserved, markIndex});
                        }
                    }
                    continue;
                }
            }
            bool character = false;
            uint64_t actorClass = 0;
            if (!CSClassIsChildOf(session, generation, actor, wanted, &character, &actorClass)) return nil;
            if (!character) continue;
            uint32_t team = 0;
            if (actor > UINT64_MAX - 0xb7c ||
                !CSReadValue(session, generation, actor + 0xb78, &team)) return nil;
            if (team < 1 || team > 100 || team == localTeam) continue;
            float health = 0, maximum = 0;
            uint8_t ai = 0, status = 0;
            if (!CSReadValue(session, generation, actor + 0x1060, &health) ||
                !CSReadValue(session, generation, actor + 0x1068, &maximum) ||
                !CSReadValue(session, generation, actor + 0xb94, &ai)) return nil;
            if (includeBattleInputs &&
                (actor < 0x100000000ULL || actor > 0x8000000000ULL - 0x3be1 ||
                 !CSReadValue(session, generation, actor + 0x3be0, &status))) return nil;
            uint32_t warningYawRaw = 0;
            if (includeWarningYaw &&
                !CSReadValue(session, generation, actor + 0x2758, &warningYawRaw)) return nil;
            uint8_t countStatus = 0;
            if (includeCounts && !CSReadValue(session, generation, actor + 0x3be0, &countStatus)) return nil;
            if (!std::isfinite(health) || !std::isfinite(maximum) ||
                maximum <= 0 || health < 0 || health > maximum) continue;
            const bool countEligible = includeCounts && CoreSet::playerCountEligible(health, maximum, countStatus);
            if (health == 0 && !countEligible) continue;
            CSVector position = {0};
            bool present = false;
            if (!CSPosition(session, generation, base, actor, &position, &present)) return nil;
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
                if (!CSReadValue(session, generation, actor + 0x190, &warningFallbackRaw)) return nil;
                warningFallbackObserved = true;
            }
            if (countEligible) {
                if (ai) ++observedBotCount; else ++observedPlayerCount;
                observedCounts.push_back({actor, actorClass, position, health, maximum, team, ai, countStatus});
                if (health == 0) ++observedZeroHealthLastBreath;
            }
            if (health == 0) continue; // Count-only; never promote zero health into world marks/radar/battle input.
            const bool wantsInformation = ai ? botInformation : playerInformation;
            const bool wantsWeapon = ai ? (botWeaponText || botInformation) :
                (playerWeaponText || playerInformation);
            uint64_t weapon = 0;
            uint32_t weaponID = 0;
            if (wantsWeapon && !CSWeaponID(session, generation, actor, &weapon, &weaponID)) return nil;
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
                                                   &namePointer, &nameRaw, &playerName)) return nil;
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
                (boneDistanceLimit == 0 || distance <= boneDistanceLimit)) {
                if (observedBones.size() >= CSMaxBoneActors) return nil;
                CSBoneState bones;
                bool present = false;
                ++boneRequested;
                if (!CSReadBoneState(session, generation, base, actor, &bones, &present)) return nil;
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
                    observedBones.push_back({actor, std::move(bones)});
                } else if (bones.status < 6) ++boneUnavailable[bones.status];
            }
            if (marks.count >= CSMaxRenderedMarks) return nil;
            [marks addObject:mark];
            observedActors.push_back({actor, position, health, maximum,
                                      weapon, weaponID, namePointer, nameRaw,
                                      team, ai, status, warningYawRaw, warningFallbackRaw, actorClass,
                                      wantsWeapon, wantsInformation, includeWarningYaw, warningFallbackObserved});
        }
    }
    uint64_t worldAfter = 0, levelAfter = 0, clusterAfter = 0, controllerAfter = 0;
    uint64_t managerAfter = 0, classAfter = 0, localAfter = 0;
    uint32_t localTeamAfter = 0;
    CSCamera cameraAfter = {0};
    CSVector localPositionAfter = {0};
    bool hasLocalPositionAfter = false;
    decltype(array) arrayAfter = {0};
    if (!CSReadValue(session, generation, base + CSWorldSlot, &worldAfter) || worldAfter != world ||
        !CSReadValue(session, generation, world + 0xb8, &levelAfter) || levelAfter != level ||
        !CSReadValue(session, generation, level + 0xe0, &clusterAfter) || clusterAfter != cluster ||
        !CSRead(session, generation, cluster + 0x28, &arrayAfter, sizeof(arrayAfter)) ||
        std::memcmp(&array, &arrayAfter, sizeof(array)) != 0 ||
        !CSReadValue(session, generation, connection + 0x30, &controllerAfter) ||
        controllerAfter != controller || !session.ready || session.generation != generation ||
        !CSReadValue(session, generation, base + CSCharacterClassSlot, &classAfter) || classAfter != wanted ||
        !CSReadValue(session, generation, controller + 0x3540, &localAfter) || localAfter != local ||
        !CSReadValue(session, generation, controller + 0x680, &managerAfter) || managerAfter != manager ||
        !CSRead(session, generation, manager + cameraOffset, &cameraAfter, sizeof(cameraAfter)) ||
        std::memcmp(&camera, &cameraAfter, sizeof(camera)) != 0 ||
        !CSPosition(session, generation, base, local, &localPositionAfter, &hasLocalPositionAfter) ||
        !hasLocalPositionAfter || std::memcmp(&localPosition, &localPositionAfter, sizeof(localPosition)) != 0 ||
        !CSReadValue(session, generation, local + 0xb78, &localTeamAfter) || localTeamAfter != localTeam ||
        session.processID != pid || session.imageBase != base) return nil;
    if (includeGrenadeWarning) {
        uint64_t poolAfter = 0;
        uint32_t countAfter = 0;
        if (!CSReadValue(session, generation, base + 0x11fba198, &poolAfter) || poolAfter != namePool ||
            !CSReadValue(session, generation, namePool + 0x1400, &countAfter) || countAfter != nameCount)
            return nil;
    }
    for (int32_t start = 0; start < array.count; start += 512) {
        int32_t batch = std::min<int32_t>(512, array.count - start);
        if (!CSRead(session, generation, array.data + (uint64_t)start * 8,
                    pointers, (size_t)batch * 8) ||
            std::memcmp(pointers, observedPointers.data() + start, (size_t)batch * 8) != 0) return nil;
    }
    for (const ObservedActor &actor : observedActors) {
        float health = 0, maximum = 0;
        uint8_t ai = 0, status = 0;
        uint32_t team = 0;
        CSVector position = {0};
        bool present = false;
        uint64_t weapon = 0;
        uint32_t weaponID = 0;
        uint64_t namePointer = 0;
        std::array<uint16_t, 16> nameRaw = {};
        NSString *name = nil;
        uint32_t warningYawRaw = 0;
        uint32_t warningFallbackRaw = 0;
        uint64_t warningActorClass = 0;
        if (!CSReadValue(session, generation, actor.address + 0x1060, &health) ||
            !CSReadValue(session, generation, actor.address + 0x1068, &maximum) ||
            !CSReadValue(session, generation, actor.address + 0xb94, &ai) ||
            !CSReadValue(session, generation, actor.address + 0xb78, &team) ||
            (includeBattleInputs &&
             !CSReadValue(session, generation, actor.address + 0x3be0, &status)) ||
            (actor.warningYawObserved &&
             (!CSReadValue(session, generation, actor.address + 0x10, &warningActorClass) ||
              warningActorClass != actor.warningActorClass ||
              !CSReadValue(session, generation, actor.address + 0x2758, &warningYawRaw) ||
              warningYawRaw != actor.warningYawRaw)) ||
            (actor.warningFallbackObserved &&
             (!CSReadValue(session, generation, actor.address + 0x190, &warningFallbackRaw) ||
              warningFallbackRaw != actor.warningFallbackRaw)) ||
            !CSPosition(session, generation, base, actor.address, &position, &present) ||
            !present || health != actor.health || maximum != actor.maximum ||
            ai != actor.ai || status != actor.status || team != actor.team ||
            std::memcmp(&position, &actor.position, sizeof(position)) != 0 ||
            (actor.weaponObserved &&
             (!CSWeaponID(session, generation, actor.address, &weapon, &weaponID) ||
              weapon != actor.weapon || weaponID != actor.weaponID)) ||
            (actor.nameObserved &&
             (!CSPlayerName(session, generation, actor.address, &namePointer, &nameRaw, &name) ||
              namePointer != actor.namePointer || nameRaw != actor.nameRaw))) return nil;
    }
    for (const ObservedCount &count : observedCounts) {
        float health = 0, maximum = 0;
        uint8_t ai = 0;
        uint8_t status = 0;
        uint64_t type = 0;
        uint32_t team = 0;
        CSVector position = {0};
        bool present = false;
        if (!CSReadValue(session, generation, count.address + 0x1060, &health) ||
            !CSReadValue(session, generation, count.address + 0x1068, &maximum) ||
            !CSReadValue(session, generation, count.address + 0xb94, &ai) ||
            !CSReadValue(session, generation, count.address + 0xb78, &team) ||
            !CSReadValue(session, generation, count.address + 0x10, &type) || type != count.type ||
            !CSReadValue(session, generation, count.address + 0x3be0, &status) || status != count.status ||
            !CSPosition(session, generation, base, count.address, &position, &present) ||
            !present || health != count.health || maximum != count.maximum ||
            ai != count.ai || team != count.team ||
            std::memcmp(&position, &count.position, sizeof(position)) != 0) return nil;
    }
    for (const ObservedGrenade &grenade : observedGrenades) {
        uint32_t nameIndex = 0;
        CSVector position = {0};
        bool present = false;
        std::string name;
        uint64_t type = 0, outer = 0;
        uint32_t explosionRaw = 0;
        uint8_t flags = 0;
        if (!CSReadValue(session, generation, grenade.address + 0x18, &nameIndex) ||
            nameIndex != grenade.nameIndex ||
            CoreSet::readMaterialBaseName(nameRead, grenade.address, namePool, &name, base) !=
                CoreSet::NameReadStatus::ok ||
            name.find("ojGrenade_BP_C") == std::string::npos ||
            !CSPosition(session, generation, base, grenade.address, &position, &present) ||
            !present || std::memcmp(&position, &grenade.position, sizeof(position)) != 0 ||
            (grenade.timerObserved &&
             (!CSReadValue(session, generation, grenade.address + 0x10, &type) || type != grenade.type ||
              !CSReadValue(session, generation, grenade.address + 0x20, &outer) || outer != grenade.outer ||
              !CSReadValue(session, generation, grenade.address + 0x7fd, &flags) || flags != grenade.flags ||
              !CSReadValue(session, generation, grenade.address + 0x88c, &explosionRaw) ||
              explosionRaw != grenade.explosionRaw))) return nil;
    }
    if (includeGrenadeWarning) {
        uint64_t eliteClassAfter = 0, gameStateClassAfter = 0;
        if (!CSReadValue(session, generation, base + CSEliteProjectileClassSlot, &eliteClassAfter) ||
            eliteClassAfter != eliteProjectileClass ||
            !CSReadValue(session, generation, base + CSGameStateClassSlot, &gameStateClassAfter) ||
            gameStateClassAfter != gameStateClass) return nil;
        if (grenadeClockRead) {
            CSGrenadeClockObservation after;
            if (!CSReadGrenadeClock(session, generation, base, world, level, gameStateClass, &after) ||
                after.gameState != grenadeClock.gameState || after.type != grenadeClock.type ||
                after.outer != grenadeClock.outer || after.vtable != grenadeClock.vtable ||
                after.getter != grenadeClock.getter || after.present != grenadeClock.present || after.status != grenadeClock.status ||
                (after.present &&
                 (std::memcmp(&after.delta, &grenadeClock.delta, sizeof(after.delta)) != 0 ||
                  after.worldTime < grenadeClock.worldTime || after.worldTime - grenadeClock.worldTime > 0.25))) return nil;
            if (after.present) {
                for (const ObservedGrenade &grenade : observedGrenades) {
                    if (!grenade.timerObserved) continue;
                    float explosion = 0, countdown = 0;
                    std::memcpy(&explosion, &grenade.explosionRaw, sizeof(explosion));
                    if (CoreSet::grenadeCountdownSeconds(explosion, after.worldTime, after.delta, grenade.flags, &countdown)) {
                        grenadeMarks[grenade.markIndex].countdownSeconds = @(countdown);
                        ++grenadeCountdowns;
                    }
                }
            }
        }
    }
    for (const ObservedBone &bone : observedBones) {
        CSBoneState after;
        bool present = false;
        if (!CSReadBoneState(session, generation, base, bone.actor, &after, &present) ||
            !present || !CSBoneStatesEqual(bone.state, after)) return nil;
    }
    if (includeBattleInputs) {
        uint8_t adsAfter = 0, firingAfter = 0;
        float rotationAfter[2] = {0};
        if (!CSReadValue(session, generation, local + 0x1848, &adsAfter) ||
            !CSReadValue(session, generation, local + 0x2750, &firingAfter) ||
            !CSRead(session, generation, controller + 0x620, rotationAfter, sizeof(rotationAfter)) ||
            adsAfter != localADS || firingAfter != localFiring ||
            std::memcmp(controlRotation, rotationAfter, sizeof(controlRotation)) != 0) return nil;
    }
    if (!session.ready || session.generation != generation) return nil;
    CoreSetPlayerSnapshot *snapshot = [CoreSetPlayerSnapshot new];
    snapshot.sessionGeneration = generation; snapshot.processID = pid;
    snapshot.imageBase = base; snapshot.snapshotID = [NSUUID UUID];
    snapshot.cameraYawDegrees = camera.rotation.y;
    snapshot.motionCamera = camera;
    snapshot.cameraPitchDegrees = camera.rotation.x;
    snapshot.cameraFieldOfViewDegrees = camera.fov;
    snapshot.battleInputsPresent = includeBattleInputs;
    if (includeBattleInputs) {
        snapshot.controllerAddress = controller;
        snapshot.localActorAddress = local;
        snapshot.localADS = localADS != 0;
        snapshot.localFiring = localFiring != 0;
        snapshot.controlPitchDegrees = controlRotation[0];
        snapshot.controlYawDegrees = controlRotation[1];
    }
    snapshot.captureCompletedMonotonicSeconds = CACurrentMediaTime();
    snapshot.marks = [marks copy];
    snapshot.grenadeMarks = [grenadeMarks copy];
    snapshot.observedPlayerCount = observedPlayerCount;
    snapshot.observedBotCount = observedBotCount;
    snapshot.readSemanticDiagnostic = [NSString stringWithFormat:
        @"candidateCounts=capture-pass displayFields=end-reread actors=%d marks=%lu players=%lu bots=%lu zeroHealthLastBreath=%lu countScope=positive-health-or-last-breath-enemy-draw-range countParity=partial "
         "grenadeRequested=%d grenadeCandidates=%lu grenadePosition=%lu grenadeOnscreen=%lu "
         "grenadeClassKnown=%d gameStateClassKnown=%d grenadeTyped=%lu grenadeCountdowns=%lu grenadeLifecycleSuppressed=%lu grenadeActorWorldMismatch=%lu grenadeClockKnown=%d grenadeClockStatus=%u "
         "grenadeTimer=target-server-clock-clamped grenadeRadius=unproven grenadeAnimation=local-prediction-partial "
         "warningRequested=%d warningPrimaryValid=%lu warningPrimaryInvalid=%lu warningFallbackRead=%lu warningFallbackValid=%lu "
         "warningUnavailable=%lu warningFallbackOwner=actor-replicated-movement-rotation-yaw "
         "boneRequested=%lu bonePresent=%lu bonePlain=%lu boneDecoded=%lu boneMissing=%lu boneUnregistered=%lu boneArrayInvalid=%lu boneBounds=%lu boneDecoderUnknown=%lu "
         "boneHeadKnownProfile=%lu boneHeadProjected=%lu boneHeadUnknownProfile=%lu headScope=requested-bones-only headParity=partial "
         "networkFreshness=unproven captureStability=end-reread grenadeAnimationScope=local-position-history grenadeRadiusGap=no-verified-elite-blast-field "
         "nameRequested=%lu namePresent=%lu weaponRequested=%lu weaponKnown=%lu informationLayout=local-subset informationGap=native-font-icons-and-anchors",
        array.count, (unsigned long)marks.count, (unsigned long)observedPlayerCount,
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
        (unsigned long)weaponRequested, (unsigned long)weaponKnown];
    return snapshot;
}
@end
