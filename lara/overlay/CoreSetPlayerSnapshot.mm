#import "CoreSetPlayerSnapshot.h"
#import "CoreSetPlayerProjection.h"
#import "CoreSetWeaponNames.h"
#import "CoreSetMaterialName.h"
#import "CoreSetWarningProjection.h"
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
                             uint64_t actor, uint64_t wanted, bool *isChild) {
    uint64_t type = 0;
    if (!CSReadValue(session, generation, actor + 0x10, &type)) return false;
    for (unsigned depth = 0; depth < 64 && type; ++depth) {
        if (type == wanted) { *isChild = true; return true; }
        if (!CSReadValue(session, generation, type + 0x30, &type)) return false;
    }
    if (type != 0) return false; // Cyclic or unexpectedly deep superclass chain.
    *isChild = false;
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
    struct { uint64_t data; int32_t count; int32_t capacity; } array = {0};
    std::array<uint8_t, 0x2c> component = {};
    std::vector<CSBoneSample> samples;
    const uint8_t *edges = nullptr;
};

static bool CSReadBoneState(CoreSetReadSession *session, uint64_t generation,
                            uint64_t actor, CSBoneState *state, bool *present) {
    *present = false;
    if (!CSReadValue(session, generation, actor + 0x658, &state->mesh)) return false;
    if (!state->mesh) return true;
    if (state->mesh < 0x100000000ULL || state->mesh > 0x8000000000ULL - 0x850) return false;
    if (!CSRead(session, generation, state->mesh + 0x838, &state->array, sizeof(state->array))) return false;
    const auto &array = state->array;
    if (array.count < 0 || array.count > 256 || array.capacity < array.count ||
        array.capacity > 256 || (array.count && !array.data)) return true;
    if (array.count < 6) return true;
    if (array.data < 0x100000000ULL || array.data > 0x8000000000ULL - 256 * 0x30) return true;
    state->edges = CSBoneProfile(array.count);
    for (unsigned edge = 0; edge < 28; ++edge) if (state->edges[edge] >= array.count) return true;
    if (!CSRead(session, generation, state->mesh + 0x1f0,
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
    if (left.mesh != right.mesh || std::memcmp(&left.array, &right.array, sizeof(left.array)) != 0 ||
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

@interface CoreSetWorldPoint ()
@property(nonatomic) float x;
@property(nonatomic) float y;
@property(nonatomic) float z;
@end
@implementation CoreSetWorldPoint
+ (instancetype)pointWithX:(float)x y:(float)y z:(float)z {
    CoreSetWorldPoint *point = [CoreSetWorldPoint new];
    point.x = x; point.y = y; point.z = z; return point;
}
@end

@interface CoreSetBoneWorldPoint ()
@property(nonatomic) NSUInteger boneIndex;
@property(nonatomic) NSUInteger boneCount;
@property(nonatomic, strong) CoreSetWorldPoint *worldPosition;
@property(nonatomic) CGPoint screenPoint;
@end
@implementation CoreSetBoneWorldPoint @end

static CoreSetWorldPoint *CSWorldPoint(CSVector value) {
    CoreSetWorldPoint *point = [CoreSetWorldPoint new];
    point.x = value.x; point.y = value.y; point.z = value.z;
    return point;
}

static NSArray<CoreSetBoneSegment *> *CSProjectBones(const CSBoneState &state,
                                                     CSCamera camera, CGSize size,
                                                     NSArray<CoreSetBoneWorldPoint *> **worldPoints) {
    if (worldPoints) *worldPoints = @[];
    CoreSet::Transform component = {};
    std::memcpy(&component, state.component.data(), state.component.size());
    CGPoint points[256] = {};
    NSMutableArray<CoreSetBoneWorldPoint *> *captured = [NSMutableArray array];
    for (const CSBoneSample &sample : state.samples) {
        CoreSet::Transform bone = {};
        std::memcpy(&bone, sample.bytes.data(), sample.bytes.size());
        CSVector world = {0};
        if (!CoreSet::transformPoint(component, bone.translation, &world) ||
            !CSProject(camera, world, size, &points[sample.index])) return @[];
        if (worldPoints) {
            CoreSetBoneWorldPoint *point = [CoreSetBoneWorldPoint new];
            point.boneIndex = sample.index; point.boneCount = state.array.count;
            point.worldPosition = CSWorldPoint(world);
            point.screenPoint = points[sample.index];
            [captured addObject:point];
        }
    }
    NSMutableArray<CoreSetBoneSegment *> *segments = [NSMutableArray arrayWithCapacity:14];
    for (unsigned edge = 0; edge < 28; edge += 2) {
        CoreSetBoneSegment *segment = [CoreSetBoneSegment new];
        segment.start = points[state.edges[edge]];
        segment.end = points[state.edges[edge + 1]];
        [segments addObject:segment];
    }
    if (worldPoints) *worldPoints = [captured copy];
    return segments;
}

@interface CoreSetPlayerMark ()
@property(nonatomic) uint64_t actorAddress;
@property(nonatomic, strong, nullable) CoreSetWorldPoint *actorWorldPosition;
@property(nonatomic, copy) NSArray<CoreSetBoneWorldPoint *> *boneWorldPoints;
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
@property(nonatomic) CGPoint feet;
@property(nonatomic) double distanceUnitsDividedBy100;
@property(nonatomic) NSArray<CoreSetBoneSegment *> *boneSegments;
@property(nonatomic) BOOL onScreen;
@property(nonatomic) CGPoint indicatorProjection;
@property(nonatomic) CGPoint radarCameraDelta;
@property(nonatomic) NSNumber *warningServerYawDegrees;
@end
@implementation CoreSetPlayerMark @end

@interface CoreSetGrenadeMark ()
@property(nonatomic) CGPoint point;
@property(nonatomic) double distanceUnitsDividedBy100;
@end
@implementation CoreSetGrenadeMark @end

@interface CoreSetPlayerSnapshot ()
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
@property(nonatomic) double cameraRollDegrees;
@property(nonatomic) double cameraFieldOfViewDegrees;
@property(nonatomic) BOOL battleInputsPresent;
@property(nonatomic, strong, nullable) CoreSetWorldPoint *cameraWorldPosition;
@property(nonatomic, strong, nullable) CoreSetWorldPoint *localWorldPosition;
@property(nonatomic) CGSize canvasSize;
@property(nonatomic) uint64_t controllerAddress;
@property(nonatomic) uint64_t localActorAddress;
@property(nonatomic) BOOL localADS;
@property(nonatomic) BOOL localFiring;
@property(nonatomic) float controlPitchDegrees;
@property(nonatomic) float controlYawDegrees;
@property(nonatomic) float rotationInputPitch;
@property(nonatomic) float rotationInputYaw;
@property(nonatomic) double captureCompletedMonotonicSeconds;
@end
@implementation CoreSetPlayerSnapshot @end

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
    if (!base || pid <= 0 || base > UINT64_MAX - 0x11fba198) return nil;
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
    float controlRotation[2] = {0}, rotationInput[2] = {0};
    if (includeBattleInputs &&
        (local < 0x100000000ULL || local > 0x8000000000ULL - 0x2751 ||
         controller < 0x100000000ULL || controller > 0x8000000000ULL - 0x830 ||
         !CSReadValue(session, generation, local + 0x1848, &localADS) ||
         !CSReadValue(session, generation, local + 0x2750, &localFiring) ||
         !CSRead(session, generation, controller + 0x620, controlRotation, sizeof(controlRotation)) ||
         !CSRead(session, generation, controller + 0x828, rotationInput, sizeof(rotationInput)) ||
         !std::isfinite(controlRotation[0]) || !std::isfinite(controlRotation[1]) ||
         !std::isfinite(rotationInput[0]) || !std::isfinite(rotationInput[1]) ||
         std::fabs(controlRotation[0]) > 360 || std::fabs(controlRotation[1]) > 360)) return nil;
    NSMutableArray<CoreSetPlayerMark *> *marks = [NSMutableArray array];
    NSMutableArray<CoreSetGrenadeMark *> *grenadeMarks = [NSMutableArray array];
    NSUInteger observedPlayerCount = 0, observedBotCount = 0;
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
        bool weaponObserved, nameObserved, warningYawObserved;
    };
    std::vector<ObservedActor> observedActors;
    struct ObservedCount { uint64_t address; CSVector position; float health, maximum; uint32_t team; uint8_t ai; };
    std::vector<ObservedCount> observedCounts;
    struct ObservedGrenade { uint64_t address; uint32_t nameIndex; CSVector position; };
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
                    CSVector grenadePosition = {0};
                    bool present = false;
                    if (!CSPosition(session, generation, base, actor, &grenadePosition, &present)) return nil;
                    if (present) {
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
                            [grenadeMarks addObject:mark];
                            observedGrenades.push_back({actor, nameIndex, grenadePosition});
                        }
                    }
                    continue;
                }
            }
            bool character = false;
            if (!CSClassIsChildOf(session, generation, actor, wanted, &character)) return nil;
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
            if (!std::isfinite(health) || !std::isfinite(maximum) ||
                maximum <= 0 || health <= 0 || health > maximum) continue;
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
            if (includeCounts) {
                if (ai) ++observedBotCount; else ++observedPlayerCount;
                observedCounts.push_back({actor, position, health, maximum, team, ai});
            }
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
            CoreSetPlayerMark *mark = [CoreSetPlayerMark new];
            mark.actorAddress = actor; mark.bot = ai != 0;
            if (includeBattleInputs) mark.actorWorldPosition = CSWorldPoint(position);
            mark.boneWorldPoints = @[];
            mark.healthStatusCode = status;
            mark.playerName = playerName; mark.teamID = team;
            mark.health = health; mark.maximumHealth = maximum;
            if (wantsWeapon) {
                mark.weaponID = weaponID;
                const char *name = CoreSet::weaponNameForCanonicalID(weaponID);
                if (name) mark.weaponName = [NSString stringWithUTF8String:name];
            }
            mark.center = centerPoint; mark.head = headPoint;
            mark.feet = feetPoint; mark.distanceUnitsDividedBy100 = distance;
            mark.onScreen = onScreen; mark.indicatorProjection = indicator;
            mark.radarCameraDelta = CGPointMake((double)camera.location.x - position.x,
                                                (double)camera.location.y - position.y);
            if (includeWarningYaw) {
                float yaw = 0;
                std::memcpy(&yaw, &warningYawRaw, sizeof(yaw));
                if (std::isfinite(yaw) && std::fabs(yaw) <= 360.0f)
                    mark.warningServerYawDegrees = @(yaw);
            }
            mark.boneSegments = @[];
            const bool wantsDrawBones = (ai ? botBones : playerBones) &&
                (boneDistanceLimit == 0 || distance <= boneDistanceLimit);
            if (onScreen && (wantsDrawBones || includeBattleInputs)) {
                if (observedBones.size() >= CSMaxBoneActors) return nil;
                CSBoneState bones;
                bool present = false;
                if (!CSReadBoneState(session, generation, actor, &bones, &present)) return nil;
                if (present) {
                    NSArray<CoreSetBoneWorldPoint *> *worldPoints = @[];
                    NSArray<CoreSetBoneSegment *> *segments = CSProjectBones(bones, camera, size,
                        includeBattleInputs ? &worldPoints : nullptr);
                    if (wantsDrawBones) mark.boneSegments = segments;
                    if (includeBattleInputs) mark.boneWorldPoints = worldPoints;
                    observedBones.push_back({actor, std::move(bones)});
                }
            }
            if (marks.count >= CSMaxRenderedMarks) return nil;
            [marks addObject:mark];
            observedActors.push_back({actor, position, health, maximum,
                                      weapon, weaponID, namePointer, nameRaw,
                                      team, ai, status, warningYawRaw,
                                      wantsWeapon, wantsInformation, includeWarningYaw});
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
        if (!CSReadValue(session, generation, actor.address + 0x1060, &health) ||
            !CSReadValue(session, generation, actor.address + 0x1068, &maximum) ||
            !CSReadValue(session, generation, actor.address + 0xb94, &ai) ||
            !CSReadValue(session, generation, actor.address + 0xb78, &team) ||
            (includeBattleInputs &&
             !CSReadValue(session, generation, actor.address + 0x3be0, &status)) ||
            (actor.warningYawObserved &&
             (!CSReadValue(session, generation, actor.address + 0x2758, &warningYawRaw) ||
              warningYawRaw != actor.warningYawRaw)) ||
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
        uint32_t team = 0;
        CSVector position = {0};
        bool present = false;
        if (!CSReadValue(session, generation, count.address + 0x1060, &health) ||
            !CSReadValue(session, generation, count.address + 0x1068, &maximum) ||
            !CSReadValue(session, generation, count.address + 0xb94, &ai) ||
            !CSReadValue(session, generation, count.address + 0xb78, &team) ||
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
        if (!CSReadValue(session, generation, grenade.address + 0x18, &nameIndex) ||
            nameIndex != grenade.nameIndex ||
            CoreSet::readMaterialBaseName(nameRead, grenade.address, namePool, &name, base) !=
                CoreSet::NameReadStatus::ok ||
            name.find("ojGrenade_BP_C") == std::string::npos ||
            !CSPosition(session, generation, base, grenade.address, &position, &present) ||
            !present || std::memcmp(&position, &grenade.position, sizeof(position)) != 0) return nil;
    }
    for (const ObservedBone &bone : observedBones) {
        CSBoneState after;
        bool present = false;
        if (!CSReadBoneState(session, generation, bone.actor, &after, &present) ||
            !present || !CSBoneStatesEqual(bone.state, after)) return nil;
    }
    if (includeBattleInputs) {
        uint8_t adsAfter = 0, firingAfter = 0;
        float rotationAfter[2] = {0}, rotationInputAfter[2] = {0};
        if (!CSReadValue(session, generation, local + 0x1848, &adsAfter) ||
            !CSReadValue(session, generation, local + 0x2750, &firingAfter) ||
            !CSRead(session, generation, controller + 0x620, rotationAfter, sizeof(rotationAfter)) ||
            !CSRead(session, generation, controller + 0x828, rotationInputAfter, sizeof(rotationInputAfter)) ||
            adsAfter != localADS || firingAfter != localFiring ||
            std::memcmp(controlRotation, rotationAfter, sizeof(controlRotation)) != 0 ||
            std::memcmp(rotationInput, rotationInputAfter, sizeof(rotationInput)) != 0) return nil;
    }
    if (!session.ready || session.generation != generation) return nil;
    CoreSetPlayerSnapshot *snapshot = [CoreSetPlayerSnapshot new];
    snapshot.sessionGeneration = generation; snapshot.processID = pid;
    snapshot.imageBase = base; snapshot.snapshotID = [NSUUID UUID];
    snapshot.cameraYawDegrees = camera.rotation.y;
    snapshot.cameraPitchDegrees = camera.rotation.x;
    snapshot.cameraRollDegrees = camera.rotation.z;
    snapshot.cameraFieldOfViewDegrees = camera.fov;
    snapshot.battleInputsPresent = includeBattleInputs;
    snapshot.canvasSize = size;
    if (includeBattleInputs) {
        snapshot.cameraWorldPosition = CSWorldPoint(camera.location);
        snapshot.localWorldPosition = CSWorldPoint(localPosition);
        snapshot.controllerAddress = controller;
        snapshot.localActorAddress = local;
        snapshot.localADS = localADS != 0;
        snapshot.localFiring = localFiring != 0;
        snapshot.controlPitchDegrees = controlRotation[0];
        snapshot.controlYawDegrees = controlRotation[1];
        snapshot.rotationInputPitch = rotationInput[0];
        snapshot.rotationInputYaw = rotationInput[1];
    }
    snapshot.captureCompletedMonotonicSeconds = CACurrentMediaTime();
    snapshot.marks = [marks copy];
    snapshot.grenadeMarks = [grenadeMarks copy];
    snapshot.observedPlayerCount = observedPlayerCount;
    snapshot.observedBotCount = observedBotCount;
    return snapshot;
}
@end
