#import "CoreSetPlayerSnapshot.h"
#import "CoreSetPlayerProjection.h"
#import "CoreSetWeaponNames.h"
#import "CoreSetMaterialName.h"
#import "CoreSetWarningProjection.h"
#import "CoreSetReadDisplaySemantics.h"
#import "CoreSetGrenadeClock.h"
#import "CoreSetPlayerCount.h"
#import "CoreSetBoneHead.h"
#import "CoreSetBoneArray.h"
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
static constexpr size_t CSCaptureReadPageSize = 0x4000;
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

struct CSCaptureReadPage {
    uint64_t address = 0;
    std::array<uint8_t, CSCaptureReadPageSize> bytes = {};
};
using CSCaptureReadCache = std::vector<CSCaptureReadPage>;

// The kernel transport maps and releases one 16 KiB target page per read. A
// Core player touches the same few pages repeatedly, so retain only copied page
// bytes for one actor validation. No Mach mapping or cross-capture state is kept.
static bool CSCaptureRead(CoreSetReadSession *session, uint64_t generation,
                          uint64_t address, void *output, size_t length,
                          CSCaptureReadCache *cache) {
    if (!cache || !output || !length || address > UINT64_MAX - length) return false;
    const uint64_t page = address & ~(uint64_t)(CSCaptureReadPageSize - 1);
    const size_t offset = (size_t)(address - page);
    if (length > CSCaptureReadPageSize - offset) return CSRead(session, generation, address, output, length);
    auto found = std::find_if(cache->begin(), cache->end(), [page](const CSCaptureReadPage &entry) {
        return entry.address == page;
    });
    if (found == cache->end()) {
        cache->emplace_back();
        CSCaptureReadPage &entry = cache->back();
        entry.address = page;
        if (!CSRead(session, generation, page, entry.bytes.data(), entry.bytes.size())) {
            cache->pop_back();
            return false;
        }
        found = cache->end() - 1;
    }
    std::memcpy(output, found->bytes.data() + offset, length);
    return true;
}

template <typename T> static bool CSCaptureReadValue(CoreSetReadSession *session,
                                                      uint64_t generation, uint64_t address,
                                                      T *value, CSCaptureReadCache *cache) {
    return CSCaptureRead(session, generation, address, value, sizeof(T), cache);
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

struct CSRecoilPostRaw {
    std::array<uint8_t, 0x94> bytes{};
};

struct CSRecoilInputState {
    bool present = false;
    uint64_t key = 0;
    uint64_t ownerToken = 0;
    uint8_t active = 0;
    std::array<float, 6> values{};
    std::array<float, 4> scales{};
};

static float CSFloatAt(const CSRecoilPostRaw &record, size_t offset) {
    float value = 0;
    std::memcpy(&value, record.bytes.data() + offset, sizeof(value));
    return value;
}

// Core v1.7 c2384..c242c and c3c3c..c40c0, with x26=controller and
// x23=local actor. A missing weapon/action chain is a valid unavailable recoil
// sample and must not invalidate the rest of the battle snapshot.
static bool CSCaptureRecoilInputs(CoreSetReadSession *session, uint64_t generation,
                                  uint64_t controller, uint64_t local, uint8_t firing,
                                  CSRecoilInputState *output) {
    if (!output) return false;
    *output = {};
    std::array<float, 4> scales{};
    if (!CSReadValue(session, generation, controller + 0x838, &scales[0]) ||
        !CSReadValue(session, generation, local + 0xbdc, &scales[1]) ||
        !CSReadValue(session, generation, controller + 0x834, &scales[2]) ||
        !CSReadValue(session, generation, local + 0xbe0, &scales[3])) return true;
    for (float value : scales)
        if (!std::isfinite(value) || std::fabs(value) > 16.0f) return true;

    uint64_t first = 0, owner = 0, key = 0, companion = 0;
    if (!CSReadValue(session, generation, local + 0x37a0, &first) ||
        !CSUserPointerValid(first) ||
        !CSReadValue(session, generation, first + 0x600, &owner) ||
        !CSUserPointerValid(owner) ||
        !CSReadValue(session, generation, owner + 0x2038, &key) ||
        !CSUserPointerValid(key) ||
        !CSReadValue(session, generation, owner + 0x2048, &companion) ||
        !CSUserPointerValid(companion)) return true;

    CSRecoilPostRaw raw;
    if (!CSRead(session, generation, key + 0x208, raw.bytes.data(), raw.bytes.size())) return true;
    const std::array<size_t, 6> offsets{0x00, 0x04, 0x08, 0x0c, 0x10, 0x4c};
    std::array<float, 6> values{};
    for (size_t index = 0; index < values.size(); ++index) {
        values[index] = CSFloatAt(raw, offsets[index]);
        if (!std::isfinite(values[index])) return true;
    }
    output->present = true;
    output->key = owner;
    output->ownerToken = key;
    output->active = firing;
    output->values = values;
    output->scales = scales;
    return true;
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
    // PawnStateRepSyncData.CurrentStatesMask.Array data pointer. Core reads
    // actor+0x1700 as a qword and then the leading uint32 from that storage.
    uint64_t stateMaskData = 0;
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
                                  CSCorePlayerState *state, CSCaptureReadCache *cache) {
    *state = {};
    if (!CSUserPointerValid(actor) ||
        !CSCaptureReadValue(session, generation, actor + 0x10bc, &state->speed, cache) ||
        !CSCorePlayerSpeedMatches(state->speed) || actor == local ||
        !CSCaptureReadValue(session, generation, actor + 0xb78, &state->team, cache) ||
        state->team < 1 || state->team > 100 || state->team == localTeam ||
        !CSCaptureReadValue(session, generation, actor + 0x1700, &state->stateMaskData, cache) ||
        !CSUserPointerValid(state->stateMaskData) ||
        !CSCaptureReadValue(session, generation, state->stateMaskData, &state->stateFlags, cache) ||
        (state->stateFlags & (1u << 20)) ||
        !CSCaptureReadValue(session, generation, actor + 0x3be0, &state->status, cache) ||
        state->status == 4 ||
        !CSCaptureReadValue(session, generation, actor + 0x1060, &state->health, cache) ||
        !CSCaptureReadValue(session, generation, actor + 0x1068, &state->maximum, cache) ||
        !CSCorePlayerHealthMatches(state->health, state->maximum) ||
        !CSCaptureReadValue(session, generation, actor + 0x260, &state->rootComponent, cache) ||
        !CSUserPointerValid(state->rootComponent) ||
        !CSCaptureReadValue(session, generation, actor + 0x658, &state->meshComponent, cache) ||
        !CSUserPointerValid(state->meshComponent) ||
        !CSCaptureReadValue(session, generation, actor + 0xb94, &state->ai, cache)) return false;
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

// Core d8210..d8230: status 1 (HasLastBreath) forces candidate flag14;
// otherwise flag14 is CurrentStatesMask bit19. Status 4 was rejected earlier.
static uint8_t CSReferenceFlag14(uint32_t stateFlags, uint8_t status) {
    return status == 1 ? 1 : (uint8_t)((stateFlags >> 19) & 1);
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
                       uint64_t actor, CSVector *position, bool *present,
                       CSCaptureReadCache *cache = nullptr, uint64_t knownComponent = 0) {
    *present = false;
    uint64_t component = knownComponent;
    const auto readValue = [&](uint64_t address, auto *value) {
        return cache ? CSCaptureReadValue(session, generation, address, value, cache) :
            CSReadValue(session, generation, address, value);
    };
    const auto readBytes = [&](uint64_t address, void *output, size_t length) {
        return cache ? CSCaptureRead(session, generation, address, output, length, cache) :
            CSRead(session, generation, address, output, length);
    };
    if (!component && !readValue(actor + 0x260, &component)) return false;
    if (!component) return true; // No invented zero-vector fallback.
    uint32_t flags = 0;
    if (!readValue(component + 0x25c, &flags)) return false;
    if ((flags & ((1u << 20) | (1u << 22))) == ((1u << 20) | (1u << 22))) {
        uint64_t callback = 0;
        if (!readValue(base + CSPositionCallbackSlot, &callback)) return false;
        if (callback) {
            if (callback != base + CSPositionCallbackRVA) return false;
            uint8_t block[0x30] = {0};
            uint32_t key = 0;
            if (!readBytes(component + 0x1f0, block, sizeof(block)) ||
                !readValue(base + CSPositionXORKeySlot, &key)) return false;
            CoreSet::decodePositionBlock(block, key);
            std::memcpy(position, block + 0x10, sizeof(*position));
            *present = CSFinite(*position);
            return true;
        }
    }
    if (!readBytes(component + 0x200, position, sizeof(*position))) return false;
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
using CSBoneArrayState = CoreSet::BoneArrayState;
struct CSBoneState {
    uint64_t mesh = 0;
    uint64_t callback = 0;
    uint32_t flags = 0, key = 0;
    uint8_t registered = 0;
    uint16_t arrayOffset = 0;
    bool arrayCountFromCapacity = false;
    uint8_t status = 0; // 1 missing mesh, 2 unregistered, 3 invalid array, 4 bounds, 5 unknown decoder, 6 plain, 7 XOR.
    CSBoneArrayState array = {0};
    std::array<uint8_t, 0x2c> component = {};
    std::vector<CSBoneSample> samples;
    const uint8_t *edges = nullptr;
};

static bool CSReadBoneState(CoreSetReadSession *session, uint64_t generation, uint64_t base,
                            uint64_t actor, CSBoneState *state, bool *present,
                            uint64_t knownMesh = 0) {
    *present = false;
    CSCaptureReadCache cache;
    cache.reserve(6);
    state->mesh = knownMesh;
    if (!state->mesh &&
        !CSCaptureReadValue(session, generation, actor + 0x658, &state->mesh, &cache)) return false;
    if (!state->mesh) { state->status = 1; return true; }
    if (state->mesh < 0x100000000ULL || state->mesh > 0x8000000000ULL - 0x850) return false;
    // Native GetBoneTransform a3c4124 requires a registered component. Its
    // a3c4150..a3c41a0 uses the same verified read-only decoder as CSPosition.
    if (!CSCaptureReadValue(session, generation, state->mesh + 0xe0, &state->registered, &cache)) return false;
    if (!(state->registered & 4)) { state->status = 2; return true; }
    if (!CSCaptureRead(session, generation, state->mesh + 0x838, &state->array,
                       sizeof(state->array), &cache)) return false;
    state->arrayOffset = 0x838;
    if (!CoreSet::normalizeBoneArray(&state->array, &state->arrayCountFromCapacity)) {
        // Core v1.7 e3394 retries the adjacent TArray header after the primary
        // ComponentSpaceTransforms header fails its data/Num/Max contract.
        CSBoneArrayState fallback = {};
        if (!CSCaptureRead(session, generation, state->mesh + 0x848, &fallback,
                           sizeof(fallback), &cache)) return false;
        bool fallbackCountFromCapacity = false;
        if (!CoreSet::normalizeBoneArray(&fallback, &fallbackCountFromCapacity)) {
            state->status = 3;
            return true;
        }
        state->array = fallback;
        state->arrayOffset = 0x848;
        state->arrayCountFromCapacity = fallbackCountFromCapacity;
    }
    const auto &array = state->array;
    state->edges = CSBoneProfile(array.count);
    for (unsigned edge = 0; edge < 28; ++edge)
        if (state->edges[edge] >= array.count) { state->status = 4; return true; }
    if (!CSCaptureReadValue(session, generation, state->mesh + 0x25c, &state->flags, &cache)) return false;
    state->status = 6;
    if ((state->flags & ((1u << 20) | (1u << 22))) == ((1u << 20) | (1u << 22))) {
        if (!CSCaptureReadValue(session, generation, base + CSPositionCallbackSlot,
                                &state->callback, &cache)) return false;
        if (state->callback) {
            if (state->callback != base + CSPositionCallbackRVA) { state->status = 5; return true; }
            uint8_t block[0x30] = {};
            if (!CSCaptureRead(session, generation, state->mesh + 0x1f0,
                               block, sizeof(block), &cache) ||
                !CSCaptureReadValue(session, generation, base + CSPositionXORKeySlot,
                                    &state->key, &cache)) return false;
            CoreSet::decodePositionBlock(block, state->key);
            std::memcpy(state->component.data(), block, state->component.size());
            state->status = 7;
        }
    }
    if (state->status == 6 &&
        !CSCaptureRead(session, generation, state->mesh + 0x1f0,
                       state->component.data(), state->component.size(), &cache)) return false;
    std::vector<uint8_t> transforms((size_t)array.count * 0x30);
    if (!CSRead(session, generation, array.data, transforms.data(), transforms.size())) return false;
    // Core d8ba8 selects the profile's first index and d94a8..d94c4 copies
    // that same transformed point into candidate +0x1e0 and +0x1ec.
    for (unsigned edge = 0; edge < 28; ++edge) {
        uint8_t index = state->edges[edge];
        if (std::any_of(state->samples.begin(), state->samples.end(),
                        [index](const CSBoneSample &sample) { return sample.index == index; })) continue;
        CSBoneSample sample = {index, {}};
        std::memcpy(sample.bytes.data(), transforms.data() + (size_t)index * 0x30,
                    sample.bytes.size());
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

static CoreSetWorldPoint *CSBoneWorldPoint(const CSBoneState &state, uint8_t index) {
    const auto sample = std::find_if(state.samples.begin(), state.samples.end(),
        [index](const CSBoneSample &entry) { return entry.index == index; });
    if (sample == state.samples.end()) return nil;
    CoreSet::Transform component = {}, bone = {};
    std::memcpy(&component, state.component.data(), state.component.size());
    std::memcpy(&bone, sample->bytes.data(), sample->bytes.size());
    CSVector world = {};
    if (!CoreSet::transformPoint(component, bone.translation, &world) ||
        !std::isfinite(world.x) || !std::isfinite(world.y) || !std::isfinite(world.z)) return nil;
    return [CoreSetWorldPoint pointWithX:world.x y:world.y z:world.z];
}

@interface CoreSetWorldPoint ()
@property(nonatomic) float x;
@property(nonatomic) float y;
@property(nonatomic) float z;
@end
@implementation CoreSetWorldPoint
+ (instancetype)pointWithX:(float)x y:(float)y z:(float)z {
    CoreSetWorldPoint *point = [CoreSetWorldPoint new];
    point.x = x; point.y = y; point.z = z;
    return point;
}
@end

@interface CSBoneWorldSegment : NSObject
@property(nonatomic) CoreSetWorldPoint *start;
@property(nonatomic) CoreSetWorldPoint *end;
@end
@implementation CSBoneWorldSegment @end

static NSArray<CSBoneWorldSegment *> *CSBoneWorldSegments(const CSBoneState &state) {
    NSMutableArray<CSBoneWorldSegment *> *result = [NSMutableArray arrayWithCapacity:14];
    for (unsigned edge = 0; edge < 28; edge += 2) {
        CoreSetWorldPoint *start = CSBoneWorldPoint(state, state.edges[edge]);
        CoreSetWorldPoint *end = CSBoneWorldPoint(state, state.edges[edge + 1]);
        if (!start || !end) return @[];
        CSBoneWorldSegment *segment = [CSBoneWorldSegment new];
        segment.start = start; segment.end = end;
        [result addObject:segment];
    }
    return result;
}

static NSArray<CoreSetBoneSegment *> *CSProjectBoneWorldSegments(
    NSArray<CSBoneWorldSegment *> *segments, CSCamera camera, CGSize size) {
    NSMutableArray<CoreSetBoneSegment *> *result = [NSMutableArray arrayWithCapacity:segments.count];
    for (CSBoneWorldSegment *world in segments) {
        CGPoint start = CGPointZero, end = CGPointZero;
        const CSVector startWorld = {world.start.x, world.start.y, world.start.z};
        const CSVector endWorld = {world.end.x, world.end.y, world.end.z};
        if (!CSProject(camera, startWorld, size, &start) ||
            !CSProject(camera, endWorld, size, &end)) return @[];
        CoreSetBoneSegment *segment = [CoreSetBoneSegment new];
        segment.start = start; segment.end = end;
        [result addObject:segment];
    }
    return result;
}

@interface CoreSetPlayerMark ()
@property(nonatomic) uint64_t actorAddress;
@property(nonatomic) CoreSetWorldPoint *actorWorldPosition;
@property(nonatomic) uint8_t healthStatusCode;
@property(nonatomic) uint32_t referenceStateWord;
@property(nonatomic) uint8_t referenceFlag14;
@property(nonatomic) BOOL downedKnown;
@property(nonatomic) BOOL downed;
@property(nonatomic) CoreSetWorldPoint *referenceAnchor1e0WorldPosition;
@property(nonatomic) CoreSetWorldPoint *referenceAnchor1ecWorldPosition;
@property(nonatomic, copy, nullable) NSString *weaponName;
@property(nonatomic) uint32_t weaponID;
@property(nonatomic, copy, nullable) NSString *playerName;
@property(nonatomic) uint32_t teamID;
@property(nonatomic) float health;
@property(nonatomic) float maximumHealth;
@property(nonatomic) BOOL bot;
@property(nonatomic) CGPoint center;
@property(nonatomic) CGPoint head;
@property(nonatomic) BOOL informationAnchorPresent;
@property(nonatomic) CGPoint informationAnchor;
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
@property(nonatomic) uint64_t rosterRootComponent;
@property(nonatomic) uint64_t rosterMeshComponent;
@property(nonatomic) NSArray<CSBoneWorldSegment *> *boneWorldSegments;
@property(nonatomic, nullable) CoreSetWorldPoint *headWorldPosition;
@end
@implementation CoreSetPlayerMark @end

static void CSPublishAimAnchors(CoreSetPlayerMark *mark, const CSBoneState &state,
                                CSCamera camera, CGSize size) {
    if (!state.edges) {
        mark.referenceAnchor1e0WorldPosition = nil;
        mark.referenceAnchor1ecWorldPosition = nil;
        mark.informationAnchorPresent = NO;
        mark.informationAnchor = CGPointZero;
        return;
    }
    CoreSetWorldPoint *anchor = CSBoneWorldPoint(state, state.edges[0]);
    mark.referenceAnchor1e0WorldPosition = anchor;
    mark.referenceAnchor1ecWorldPosition = anchor;
    CGPoint projected = CGPointZero;
    if (anchor) {
        const CSVector world = {anchor.x, anchor.y, anchor.z};
        mark.informationAnchorPresent = CSProject(camera, world, size, &projected);
    } else mark.informationAnchorPresent = NO;
    mark.informationAnchor = mark.informationAnchorPresent ? projected : CGPointZero;
}

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
@interface CoreSetRecoilPostSample ()
@property(nonatomic) uint64_t key;
@property(nonatomic) uint64_t ownerToken;
@property(nonatomic) uint8_t active;
@property(nonatomic) float value0;
@property(nonatomic) float value1;
@property(nonatomic) float value2;
@property(nonatomic) float value3;
@property(nonatomic) float value4;
@property(nonatomic) float value5;
@end
@implementation CoreSetRecoilPostSample @end

@interface CoreSetPlayerSnapshot ()
@property(nonatomic) CSCamera motionCamera;
@property(nonatomic) uint64_t rosterWorldAddress;
@property(nonatomic) uint64_t rosterLevelAddress;
@property(nonatomic) uint64_t rosterControllerAddress;
@property(nonatomic) uint64_t rosterCameraManagerAddress;
@property(nonatomic) uint64_t rosterLocalActorAddress;
@property(nonatomic) uint32_t rosterLocalTeam;
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
@property(nonatomic) CoreSetWorldPoint *cameraWorldPosition;
@property(nonatomic) CoreSetWorldPoint *localWorldPosition;
@property(nonatomic) CGSize canvasSize;
@property(nonatomic) uint64_t controllerAddress;
@property(nonatomic) uint64_t localActorAddress;
@property(nonatomic) BOOL localADS;
@property(nonatomic) BOOL localFiring;
@property(nonatomic) uint8_t localFiringRaw;
@property(nonatomic) float controlPitchDegrees;
@property(nonatomic) float controlYawDegrees;
@property(nonatomic) float rotationInputPitch;
@property(nonatomic) float rotationInputYaw;
@property(nonatomic) BOOL recoilInputsPresent;
@property(nonatomic) uint32_t recoilBinding;
@property(nonatomic) CoreSetRecoilPostSample *recoilPostSample;
@property(nonatomic) float recoilFirstWeight;
@property(nonatomic) float recoilFirstBindingScale;
@property(nonatomic) float recoilSecondWeight;
@property(nonatomic) float recoilSecondBindingScale;
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

static CoreSetWorldPoint *CSTranslatedWorldPoint(CoreSetWorldPoint *point,
                                                  double dx, double dy, double dz) {
    if (!point) return nil;
    const double x = point.x + dx, y = point.y + dy, z = point.z + dz;
    if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(z)) return nil;
    return [CoreSetWorldPoint pointWithX:(float)x y:(float)y z:(float)z];
}

static CoreSetPlayerMark *CSRefreshPlayerMark(CoreSetPlayerMark *source,
                                               const CSCorePlayerState &state,
                                               CSVector position, CSVector localPosition,
                                               CSCamera camera, CGSize size,
                                               BOOL includeOffscreen,
                                               double maximumDrawDistance) {
    const double dx = (double)position.x - localPosition.x;
    const double dy = (double)position.y - localPosition.y;
    const double dz = (double)position.z - localPosition.z;
    const double distance = std::sqrt(dx * dx + dy * dy + dz * dz) / 100.0;
    if (!std::isfinite(distance) || state.health <= 0 ||
        (maximumDrawDistance != 0 && distance > maximumDrawDistance)) return nil;
    CSVector head = position, feet = position;
    head.z += 90; feet.z -= 90;
    CGPoint centerPoint = CGPointZero, headPoint = CGPointZero, feetPoint = CGPointZero;
    const bool projectedCenter = CSProject(camera, position, size, &centerPoint);
    const bool projectedHead = CSProject(camera, head, size, &headPoint);
    const bool projectedFeet = CSProject(camera, feet, size, &feetPoint);
    const bool onScreen = projectedCenter && centerPoint.x >= 0 && centerPoint.x <= size.width &&
        centerPoint.y >= 0 && centerPoint.y <= size.height;
    CGPoint indicator = CGPointZero;
    if ((onScreen && (!projectedHead || !projectedFeet)) ||
        (!onScreen && (!includeOffscreen ||
            !CSProjectIndicator(camera, position, size, &indicator)))) return nil;

    CoreSetPlayerMark *mark = [CoreSetPlayerMark new];
    mark.actorAddress = source.actorAddress;
    mark.actorWorldPosition = [CoreSetWorldPoint pointWithX:position.x y:position.y z:position.z];
    mark.healthStatusCode = state.status;
    mark.referenceStateWord = state.stateFlags;
    mark.referenceFlag14 = CSReferenceFlag14(state.stateFlags, state.status);
    mark.downedKnown = YES;
    mark.downed = (mark.referenceFlag14 & 1) != 0;
    mark.weaponName = source.weaponName; mark.weaponID = source.weaponID;
    mark.playerName = source.playerName; mark.teamID = state.team;
    mark.health = state.health; mark.maximumHealth = state.maximum;
    mark.bot = state.ai != 0;
    mark.center = centerPoint; mark.head = headPoint; mark.feet = feetPoint;
    mark.distanceUnitsDividedBy100 = distance;
    mark.onScreen = onScreen; mark.indicatorProjection = indicator;
    mark.radarCameraDelta = CGPointMake((double)camera.location.x - position.x,
                                        (double)camera.location.y - position.y);
    mark.warningServerYawDegrees = source.warningServerYawDegrees;
    mark.warningYawDegrees = source.warningYawDegrees;
    mark.warningYawSource = source.warningYawSource;
    mark.rosterRootComponent = state.rootComponent;
    mark.rosterMeshComponent = state.meshComponent;

    CoreSetWorldPoint *old = source.actorWorldPosition;
    const double translateX = old ? (double)position.x - old.x : 0;
    const double translateY = old ? (double)position.y - old.y : 0;
    const double translateZ = old ? (double)position.z - old.z : 0;
    mark.referenceAnchor1e0WorldPosition = CSTranslatedWorldPoint(
        source.referenceAnchor1e0WorldPosition, translateX, translateY, translateZ);
    mark.referenceAnchor1ecWorldPosition = CSTranslatedWorldPoint(
        source.referenceAnchor1ecWorldPosition, translateX, translateY, translateZ);
    CGPoint informationAnchor = CGPointZero;
    if (mark.referenceAnchor1e0WorldPosition) {
        const CSVector informationWorld = {mark.referenceAnchor1e0WorldPosition.x,
                                           mark.referenceAnchor1e0WorldPosition.y,
                                           mark.referenceAnchor1e0WorldPosition.z};
        mark.informationAnchorPresent = CSProject(camera, informationWorld, size,
                                                  &informationAnchor);
    }
    mark.informationAnchor = mark.informationAnchorPresent ? informationAnchor : CGPointZero;
    mark.headWorldPosition = CSTranslatedWorldPoint(
        source.headWorldPosition, translateX, translateY, translateZ);
    if (mark.headWorldPosition) {
        const CSVector headWorld = {mark.headWorldPosition.x, mark.headWorldPosition.y,
                                    mark.headWorldPosition.z};
        CGPoint projected = CGPointZero;
        if (CSProject(camera, headWorld, size, &projected)) {
            mark.head = projected; mark.headBoneIndex = source.headBoneIndex;
        }
    }
    NSMutableArray<CSBoneWorldSegment *> *worldSegments = [NSMutableArray arrayWithCapacity:source.boneWorldSegments.count];
    for (CSBoneWorldSegment *sourceSegment in source.boneWorldSegments) {
        CSBoneWorldSegment *segment = [CSBoneWorldSegment new];
        segment.start = CSTranslatedWorldPoint(sourceSegment.start, translateX, translateY, translateZ);
        segment.end = CSTranslatedWorldPoint(sourceSegment.end, translateX, translateY, translateZ);
        if (!segment.start || !segment.end) { [worldSegments removeAllObjects]; break; }
        [worldSegments addObject:segment];
    }
    mark.boneWorldSegments = [worldSegments copy];
    mark.boneSegments = CSProjectBoneWorldSegments(mark.boneWorldSegments, camera, size);
    return mark;
}

static bool CSRefreshActionBone(CoreSetReadSession *session, uint64_t generation,
                                uint64_t base, uint64_t actor, uint64_t mesh,
                                CSCamera camera, CGSize size, CoreSetPlayerMark *mark) {
    CSBoneState bone = {};
    bool present = false;
    if (!CSReadBoneState(session, generation, base, actor, &bone, &present, mesh) || !present)
        return false;
    mark.boneWorldSegments = CSBoneWorldSegments(bone);
    mark.boneSegments = CSProjectBoneWorldSegments(mark.boneWorldSegments, camera, size);
    CSPublishAimAnchors(mark, bone, camera, size);
    uint8_t headIndex = 0;
    CGPoint head = CGPointZero;
    if (CoreSet::referenceBoneHeadIndex(bone.array.count, &headIndex) &&
        CSProjectBoneHead(bone, camera, size, &head, &headIndex)) {
        mark.head = head;
        mark.headBoneIndex = @(headIndex);
        mark.headWorldPosition = CSBoneWorldPoint(bone, headIndex);
    } else {
        mark.headBoneIndex = nil;
        mark.headWorldPosition = nil;
    }
    return mark.referenceAnchor1e0WorldPosition != nil &&
        mark.referenceAnchor1ecWorldPosition != nil;
}

@implementation CoreSetPlayerCollector
+ (NSString *)lastCaptureDiagnostic {
    return [NSString stringWithUTF8String:CSLastCaptureDiagnostic.c_str()];
}
+ (BOOL)validateLiveIdentity:(CoreSetReadSession *)session snapshot:(CoreSetPlayerSnapshot *)snapshot {
    if (!session || !snapshot || !snapshot.battleInputsPresent || !snapshot.controllerAddress ||
        !snapshot.localActorAddress || ![session connect] ||
        session.processID != snapshot.processID || session.imageBase != snapshot.imageBase ||
        session.generation != snapshot.sessionGeneration ||
        session.imageBase > UINT64_MAX - CSWorldSlot) return NO;
    const uint64_t generation = snapshot.sessionGeneration;
    uint64_t world = 0, driver = 0, connection = 0, controller = 0, local = 0;
    return CSReadValue(session, generation, session.imageBase + CSWorldSlot, &world) &&
        CSUserPointerValid(world) && world <= UINT64_MAX - 0xc0 &&
        CSReadValue(session, generation, world + 0xc0, &driver) &&
        CSUserPointerValid(driver) && driver <= UINT64_MAX - 0x88 &&
        CSReadValue(session, generation, driver + 0x88, &connection) &&
        CSUserPointerValid(connection) && connection <= UINT64_MAX - 0x30 &&
        CSReadValue(session, generation, connection + 0x30, &controller) &&
        controller == snapshot.controllerAddress && controller <= UINT64_MAX - 0x3540 &&
        CSReadValue(session, generation, controller + 0x3540, &local) &&
        local == snapshot.localActorAddress;
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
    float controlRotation[2] = {0}, rotationInput[2] = {0};
    CSRecoilInputState recoilInputs;
    if (includeBattleInputs &&
        (local < 0x100000000ULL || local > 0x8000000000ULL - 0x37a8 ||
         controller < 0x100000000ULL || controller > 0x8000000000ULL - 0x83c ||
         !CSReadValue(session, generation, local + 0x1848, &localADS) ||
         !CSReadValue(session, generation, local + 0x2750, &localFiring) ||
         !CSRead(session, generation, controller + 0x620, controlRotation, sizeof(controlRotation)) ||
         !CSRead(session, generation, controller + 0x828, rotationInput, sizeof(rotationInput)) ||
         !std::isfinite(controlRotation[0]) || !std::isfinite(controlRotation[1]) ||
         !std::isfinite(rotationInput[0]) || !std::isfinite(rotationInput[1]) ||
         std::fabs(controlRotation[0]) > 360 || std::fabs(controlRotation[1]) > 360 ||
         std::fabs(rotationInput[0]) > 360 || std::fabs(rotationInput[1]) > 360)) return nil;
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
    NSUInteger boneArrayPrimary = 0, boneArrayFallback = 0, boneArrayCapacityRecovered = 0;
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

            uint64_t coreStateMaskData = 0;
            uint32_t coreStateFlags = 0;
            uint8_t status = 0;
            float health = 0, maximum = 0;
            uint64_t rootComponent = 0, meshComponent = 0;
            uint8_t ai = 0;
            // 0x1000d54e0..0x1000d5544: PawnStateRepSyncData is at +0x1700;
            // its CurrentStatesMask.Array data pointer is followed to the
            // leading uint32 state word. Bit20 and status byte 4 reject.
            if (!CSReadValue(session, generation, actor + 0x1700, &coreStateMaskData) ||
                !CSUserPointerValid(coreStateMaskData)) continue;
            ++coreStatePointerValid;
            if (!CSReadValue(session, generation, coreStateMaskData, &coreStateFlags)) continue;
            ++coreStateFlagsRead;
            if (coreStateFlags & (1u << 20)) continue;
            ++coreStateBit20Clear;
            if (!CSReadValue(session, generation, actor + 0x3be0, &status)) continue;
            ++coreLifecycleRead;
            if (status == 4) continue;
            ++coreLifecyclePass;
            if (!CSReadValue(session, generation, actor + 0x1060, &health) ||
                !CSReadValue(session, generation, actor + 0x1068, &maximum)) continue;
            ++coreHealthRead;
            if (!CSCorePlayerHealthMatches(health, maximum)) continue;
            ++coreHealthPass;
            if (!CSReadValue(session, generation, actor + 0x260, &rootComponent) ||
                !CSUserPointerValid(rootComponent)) continue;
            ++coreRootValid;
            if (!CSReadValue(session, generation, actor + 0x658, &meshComponent) ||
                !CSUserPointerValid(meshComponent)) continue;
            ++coreMeshValid;
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
            mark.rosterRootComponent = rootComponent;
            mark.rosterMeshComponent = meshComponent;
            mark.healthStatusCode = status;
            mark.referenceStateWord = coreStateFlags;
            mark.referenceFlag14 = CSReferenceFlag14(coreStateFlags, status);
            mark.downedKnown = YES;
            mark.downed = (mark.referenceFlag14 & 1) != 0;
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
            const bool wantsVisibleBones = ai ? botBones : playerBones;
            // Core's information record consumes the profile row[0] point even
            // when the separate skeleton toggle is off.  Capture that producer
            // for information without applying the skeleton-distance control.
            const bool wantsInformationAnchor = wantsInformation;
            if (onScreen && (wantsVisibleBones || wantsInformationAnchor) &&
                (wantsInformationAnchor || boneDistanceLimit == 0 || distance <= boneDistanceLimit) &&
                observedBones.size() < CSMaxBoneActors) {
                CSBoneState bones;
                bool present = false;
                ++boneRequested;
                if (!CSReadBoneState(session, generation, base, actor, &bones, &present)) {
                    present = false;
                }
                if (present) {
                    ++bonePresent;
                    if (bones.arrayOffset == 0x848) ++boneArrayFallback; else ++boneArrayPrimary;
                    if (bones.arrayCountFromCapacity) ++boneArrayCapacityRecovered;
                    if (bones.status == 7) ++boneDecoded; else ++bonePlain;
                    if (wantsVisibleBones) mark.boneSegments = CSProjectBones(bones, camera, size);
                    CSPublishAimAnchors(mark, bones, camera, size);
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
    const double finalValidationStartedAt = CACurrentMediaTime();
    CSLastCaptureDiagnostic = "stability-player-actors";
    NSMutableIndexSet *invalidActorMarks = [NSMutableIndexSet indexSet];
    struct CSFinalActorObservation { CSCorePlayerState state; CSVector position; double distance; };
    std::unordered_map<uint64_t, CSFinalActorObservation> finalActorObservations;
    finalActorObservations.reserve(observedActors.size());
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
        CSCaptureReadCache readCache;
        readCache.reserve(6);
        if (!CSReadCorePlayerState(session, generation, actor.address, local, localTeam,
                                   &current, &readCache) ||
            current.health == 0 ||
            !CSPosition(session, generation, base, actor.address, &position, &present, &readCache) ||
            !present) {
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
        finalActorObservations.emplace(actor.address,
            CSFinalActorObservation{current, position, distance});
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
        mark.referenceStateWord = current.stateFlags;
        mark.referenceFlag14 = CSReferenceFlag14(current.stateFlags, current.status);
        mark.downedKnown = YES;
        mark.downed = (mark.referenceFlag14 & 1) != 0;
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
    const double finalPlayersCompletedAt = CACurrentMediaTime();
    CSLastCaptureDiagnostic = "stability-count-actors";
    observedPlayerCount = 0;
    observedBotCount = 0;
    observedZeroHealthLastBreath = 0;
    for (const ObservedCount &count : observedCounts) {
        if (currentActors.find(count.address) == currentActors.end()) continue;
        CSCorePlayerState current;
        CSVector position = {0};
        bool present = false;
        double distance = 0;
        const auto cached = finalActorObservations.find(count.address);
        if (cached != finalActorObservations.end()) {
            current = cached->second.state;
            position = cached->second.position;
            distance = cached->second.distance;
            present = true;
        } else {
            CSCaptureReadCache readCache;
            readCache.reserve(6);
            if (!CSReadCorePlayerState(session, generation, count.address, local, localTeam,
                                       &current, &readCache) ||
                !CSPosition(session, generation, base, count.address, &position, &present,
                            &readCache) || !present) continue;
            const double dx = (double)position.x - localPositionAfter.x;
            const double dy = (double)position.y - localPositionAfter.y;
            const double dz = (double)position.z - localPositionAfter.z;
            distance = std::sqrt(dx * dx + dy * dy + dz * dz) / 100.0;
        }
        if (!CoreSet::playerCountEligible(current.health, current.maximum, current.status)) continue;
        if (!std::isfinite(distance) ||
            (maximumDrawDistance != 0 && distance > maximumDrawDistance)) continue;
        if (current.ai) ++observedBotCount; else ++observedPlayerCount;
        if (current.health == 0) ++observedZeroHealthLastBreath;
    }
    const double finalCountsCompletedAt = CACurrentMediaTime();
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
    const double finalGrenadesCompletedAt = CACurrentMediaTime();
    CSLastCaptureDiagnostic = "stability-bones";
    struct CSFinalBoneObservation { uint64_t actor; NSUInteger markIndex; CSBoneState state; };
    std::vector<CSFinalBoneObservation> finalBoneObservations;
    finalBoneObservations.reserve(observedBones.size());
    for (const ObservedBone &bone : observedBones) {
        if ([invalidActorMarks containsIndex:bone.markIndex] ||
            currentActors.find(bone.actor) == currentActors.end()) continue;
        CoreSetPlayerMark *mark = marks[bone.markIndex];
        CSBoneState after;
        bool present = false;
        const auto actorObservation = finalActorObservations.find(bone.actor);
        const uint64_t knownMesh = actorObservation == finalActorObservations.end() ? 0 :
            actorObservation->second.state.meshComponent;
        const bool boneRead = CSReadBoneState(session, generation, base, bone.actor,
                                               &after, &present, knownMesh);
        if (!boneRead || !present) {
            mark.boneSegments = @[];
            mark.boneWorldSegments = @[];
            mark.headBoneIndex = nil;
            mark.headWorldPosition = nil;
            mark.referenceAnchor1e0WorldPosition = nil;
            mark.referenceAnchor1ecWorldPosition = nil;
            mark.informationAnchorPresent = NO;
            mark.informationAnchor = CGPointZero;
            continue;
        }
        finalBoneObservations.push_back({bone.actor, bone.markIndex, std::move(after)});
        const CSBoneState &finalBone = finalBoneObservations.back().state;
        mark.boneWorldSegments = CSBoneWorldSegments(finalBone);
        mark.boneSegments = CSProjectBoneWorldSegments(mark.boneWorldSegments, cameraAfter, size);
        CSPublishAimAnchors(mark, finalBone, cameraAfter, size);
        uint8_t headIndex = 0;
        CGPoint top = CGPointZero;
        if (CoreSet::referenceBoneHeadIndex(finalBone.array.count, &headIndex) &&
            CSProjectBoneHead(finalBone, cameraAfter, size, &top, &headIndex)) {
            mark.head = top;
            mark.headBoneIndex = @(headIndex);
            mark.headWorldPosition = CSBoneWorldPoint(finalBone, headIndex);
        } else {
            mark.headBoneIndex = nil;
            mark.headWorldPosition = nil;
        }
    }
    const double finalBonesCompletedAt = CACurrentMediaTime();
    CSLastCaptureDiagnostic = "stability-battle-inputs";
    if (includeBattleInputs) {
        uint8_t adsAfter = 0, firingAfter = 0;
        float rotationAfter[2] = {0}, inputAfter[2] = {0};
        if (!CSReadValue(session, generation, local + 0x1848, &adsAfter) ||
            !CSReadValue(session, generation, local + 0x2750, &firingAfter) ||
            !CSRead(session, generation, controller + 0x620, rotationAfter, sizeof(rotationAfter)) ||
            !CSRead(session, generation, controller + 0x828, inputAfter, sizeof(inputAfter)) ||
            !std::isfinite(rotationAfter[0]) || !std::isfinite(rotationAfter[1]) ||
            !std::isfinite(inputAfter[0]) || !std::isfinite(inputAfter[1]) ||
            std::fabs(rotationAfter[0]) > 360 || std::fabs(rotationAfter[1]) > 360 ||
            std::fabs(inputAfter[0]) > 360 || std::fabs(inputAfter[1]) > 360) return nil;
        localADS = adsAfter;
        localFiring = firingAfter;
        controlRotation[0] = rotationAfter[0];
        controlRotation[1] = rotationAfter[1];
        rotationInput[0] = inputAfter[0];
        rotationInput[1] = inputAfter[1];
    }
    // All expensive identity, lifecycle, name, weapon and bone reads are now
    // complete. Refresh the camera/local origin once more and only time the
    // position rereads plus local projection that form the delivered geometry.
    CSLastCaptureDiagnostic = "stability-final-reprojection";
    if (!CSRead(session, generation, manager + cameraOffset, &cameraAfter, sizeof(cameraAfter)) ||
        !CSCameraValid(cameraAfter) ||
        !CSPosition(session, generation, base, local, &localPositionAfter, &hasLocalPositionAfter) ||
        !hasLocalPositionAfter) return nil;
    const double finalReprojectionStartedAt = CACurrentMediaTime();
    for (const ObservedActor &actor : observedActors) {
        if ([invalidActorMarks containsIndex:actor.markIndex]) continue;
        const auto validated = finalActorObservations.find(actor.address);
        if (validated == finalActorObservations.end()) {
            [invalidActorMarks addIndex:actor.markIndex];
            continue;
        }
        CSCaptureReadCache readCache;
        readCache.reserve(4);
        CSVector position = {0};
        bool present = false;
        if (!CSPosition(session, generation, base, actor.address, &position, &present, &readCache,
                        validated->second.state.rootComponent) ||
            !present) {
            [invalidActorMarks addIndex:actor.markIndex];
            continue;
        }
        const double dx = (double)position.x - localPositionAfter.x;
        const double dy = (double)position.y - localPositionAfter.y;
        const double dz = (double)position.z - localPositionAfter.z;
        const double distance = std::sqrt(dx * dx + dy * dy + dz * dz) / 100.0;
        CSVector head = position, feet = position;
        head.z += 90; feet.z -= 90;
        CGPoint centerPoint = CGPointZero, headPoint = CGPointZero, feetPoint = CGPointZero;
        const bool projectedCenter = CSProject(cameraAfter, position, size, &centerPoint);
        const bool projectedHead = CSProject(cameraAfter, head, size, &headPoint);
        const bool projectedFeet = CSProject(cameraAfter, feet, size, &feetPoint);
        const bool onScreen = projectedCenter && centerPoint.x >= 0 && centerPoint.x <= size.width &&
            centerPoint.y >= 0 && centerPoint.y <= size.height;
        CGPoint indicator = CGPointZero;
        if (!std::isfinite(distance) ||
            (maximumDrawDistance != 0 && distance > maximumDrawDistance) ||
            (onScreen && (!projectedHead || !projectedFeet) && !includeRadar) ||
            (!onScreen && !includeRadar &&
             (!includeOffscreen || !CSProjectIndicator(cameraAfter, position, size, &indicator)))) {
            [invalidActorMarks addIndex:actor.markIndex];
            continue;
        }
        CoreSetPlayerMark *mark = marks[actor.markIndex];
        mark.rosterRootComponent = validated->second.state.rootComponent;
        mark.rosterMeshComponent = validated->second.state.meshComponent;
        mark.actorWorldPosition = [CoreSetWorldPoint pointWithX:position.x y:position.y z:position.z];
        mark.center = centerPoint;
        mark.head = headPoint;
        mark.feet = feetPoint;
        mark.distanceUnitsDividedBy100 = distance;
        mark.onScreen = onScreen;
        mark.indicatorProjection = indicator;
        mark.radarCameraDelta = CGPointMake((double)cameraAfter.location.x - position.x,
                                            (double)cameraAfter.location.y - position.y);
    }
    for (ObservedGrenade &grenade : observedGrenades) {
        if ([invalidGrenadeMarks containsIndex:grenade.markIndex]) continue;
        CSCaptureReadCache readCache;
        readCache.reserve(4);
        CSVector position = {0};
        bool present = false;
        if (!CSPosition(session, generation, base, grenade.address, &position, &present, &readCache) ||
            !present) {
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
        grenade.position = position;
        CoreSetGrenadeMark *mark = grenadeMarks[grenade.markIndex];
        mark.point = point;
        mark.distanceUnitsDividedBy100 = distance;
        mark.motionPosition = position;
    }
    for (const CSFinalBoneObservation &bone : finalBoneObservations) {
        if ([invalidActorMarks containsIndex:bone.markIndex]) continue;
        CoreSetPlayerMark *mark = marks[bone.markIndex];
        mark.boneWorldSegments = CSBoneWorldSegments(bone.state);
        mark.boneSegments = CSProjectBoneWorldSegments(mark.boneWorldSegments, cameraAfter, size);
        CSPublishAimAnchors(mark, bone.state, cameraAfter, size);
        uint8_t headIndex = 0;
        CGPoint top = CGPointZero;
        if (CoreSet::referenceBoneHeadIndex(bone.state.array.count, &headIndex) &&
            CSProjectBoneHead(bone.state, cameraAfter, size, &top, &headIndex)) {
            mark.head = top;
            mark.headBoneIndex = @(headIndex);
            mark.headWorldPosition = CSBoneWorldPoint(bone.state, headIndex);
        } else {
            mark.headBoneIndex = nil;
            mark.headWorldPosition = nil;
        }
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
    // The actor pass can be comparatively expensive. Re-read all action slots
    // and the c3c3c record together immediately before the completion stamp so
    // the recoil record and its active bit belong to the same final sample.
    if (includeBattleInputs) {
        uint8_t adsAfter = 0, firingAfter = 0;
        float rotationAfter[2] = {0}, inputAfter[2] = {0};
        if (!CSReadValue(session, generation, local + 0x1848, &adsAfter) ||
            !CSReadValue(session, generation, local + 0x2750, &firingAfter) ||
            !CSRead(session, generation, controller + 0x620, rotationAfter, sizeof(rotationAfter)) ||
            !CSRead(session, generation, controller + 0x828, inputAfter, sizeof(inputAfter)) ||
            !std::isfinite(rotationAfter[0]) || !std::isfinite(rotationAfter[1]) ||
            !std::isfinite(inputAfter[0]) || !std::isfinite(inputAfter[1]) ||
            std::fabs(rotationAfter[0]) > 360 || std::fabs(rotationAfter[1]) > 360 ||
            std::fabs(inputAfter[0]) > 360 || std::fabs(inputAfter[1]) > 360 ||
            !CSCaptureRecoilInputs(session, generation, controller, local,
                                   firingAfter, &recoilInputs)) return nil;
        localADS = adsAfter;
        localFiring = firingAfter;
        controlRotation[0] = rotationAfter[0];
        controlRotation[1] = rotationAfter[1];
        rotationInput[0] = inputAfter[0];
        rotationInput[1] = inputAfter[1];
    }
    const double captureCompletedAt = CACurrentMediaTime();
    const double finalReprojectionAge = captureCompletedAt - finalReprojectionStartedAt;
    // This is roster production, not presentation. On mapped reads a complete
    // identity-stable roster can legitimately take longer than one display
    // frame. Rejecting it here left the presentation reprojector with no world
    // geometry at all. The Swift consumer never presents these producer-time
    // screen points directly; it first reprojects the retained world geometry
    // with a current camera sample.
    if (!std::isfinite(finalReprojectionAge) || finalReprojectionAge < 0) return nil;
    CSLastCaptureDiagnostic = "identity-final";
    uint64_t finalWorld = 0, finalLevel = 0, finalController = 0;
    uint64_t finalLocal = 0, finalManager = 0;
    if (!session.ready || session.generation != generation ||
        !CSReadValue(session, generation, base + CSWorldSlot, &finalWorld) || finalWorld != world ||
        !CSReadValue(session, generation, world + 0xb8, &finalLevel) || finalLevel != level ||
        !CSReadValue(session, generation, connection + 0x30, &finalController) || finalController != controller ||
        !CSReadValue(session, generation, controller + 0x3540, &finalLocal) || finalLocal != local ||
        !CSReadValue(session, generation, controller + 0x680, &finalManager) || finalManager != manager) return nil;
    CoreSetPlayerSnapshot *snapshot = [CoreSetPlayerSnapshot new];
    snapshot.sessionGeneration = generation; snapshot.processID = pid;
    snapshot.imageBase = base; snapshot.snapshotID = [NSUUID UUID];
    snapshot.rosterWorldAddress = world;
    snapshot.rosterLevelAddress = level;
    snapshot.rosterControllerAddress = controller;
    snapshot.rosterCameraManagerAddress = manager;
    snapshot.rosterLocalActorAddress = local;
    snapshot.rosterLocalTeam = localTeam;
    snapshot.cameraYawDegrees = cameraAfter.rotation.y;
    snapshot.motionCamera = cameraAfter;
    snapshot.cameraPitchDegrees = cameraAfter.rotation.x;
    snapshot.cameraRollDegrees = cameraAfter.rotation.z;
    snapshot.cameraFieldOfViewDegrees = cameraAfter.fov;
    snapshot.cameraWorldPosition = [CoreSetWorldPoint pointWithX:cameraAfter.location.x
        y:cameraAfter.location.y z:cameraAfter.location.z];
    snapshot.localWorldPosition = [CoreSetWorldPoint pointWithX:localPositionAfter.x
        y:localPositionAfter.y z:localPositionAfter.z];
    snapshot.canvasSize = size;
    snapshot.battleInputsPresent = includeBattleInputs;
    if (includeBattleInputs) {
        snapshot.controllerAddress = controller;
        snapshot.localActorAddress = local;
        snapshot.localADS = localADS != 0;
        snapshot.localFiring = localFiring != 0;
        snapshot.localFiringRaw = localFiring;
        snapshot.controlPitchDegrees = controlRotation[0];
        snapshot.controlYawDegrees = controlRotation[1];
        snapshot.rotationInputPitch = rotationInput[0];
        snapshot.rotationInputYaw = rotationInput[1];
        const uint32_t recoilBinding = (uint32_t)generation;
        snapshot.recoilInputsPresent = recoilInputs.present && recoilBinding != 0;
        snapshot.recoilBinding = snapshot.recoilInputsPresent ? recoilBinding : 0;
        if (snapshot.recoilInputsPresent) {
            CoreSetRecoilPostSample *sample = [CoreSetRecoilPostSample new];
            sample.key = recoilInputs.key;
            sample.ownerToken = recoilInputs.ownerToken;
            sample.active = recoilInputs.active;
            sample.value0 = recoilInputs.values[0];
            sample.value1 = recoilInputs.values[1];
            sample.value2 = recoilInputs.values[2];
            sample.value3 = recoilInputs.values[3];
            sample.value4 = recoilInputs.values[4];
            sample.value5 = recoilInputs.values[5];
            snapshot.recoilPostSample = sample;
            snapshot.recoilFirstWeight = recoilInputs.scales[0];
            snapshot.recoilFirstBindingScale = recoilInputs.scales[1];
            snapshot.recoilSecondWeight = recoilInputs.scales[2];
            snapshot.recoilSecondBindingScale = recoilInputs.scales[3];
        }
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
         "boneRequested=%lu bonePresent=%lu bonePlain=%lu boneDecoded=%lu boneArrayPrimary=%lu boneArrayFallback=%lu boneArrayCapacityRecovered=%lu boneMissing=%lu boneUnregistered=%lu boneArrayInvalid=%lu boneBounds=%lu boneDecoderUnknown=%lu "
         "boneHeadKnownProfile=%lu boneHeadProjected=%lu boneHeadUnknownProfile=%lu headScope=requested-bones-only headParity=partial "
         "networkFreshness=unproven captureStability=stable-identity-plus-bounded-dynamic-reread grenadeAnimationScope=local-position-history grenadeRadiusGap=no-verified-elite-blast-field "
         "nameRequested=%lu namePresent=%lu weaponRequested=%lu weaponKnown=%lu informationRecord=core17-first-projection scaleProducer=core17-frame-literal-1 botOrdinal=frame-local "
         "captureDuration=%.3f finalReprojectionAge=%.3f phasePlayers=%.3f phaseCounts=%.3f phaseGrenades=%.3f phaseBones=%.3f freshnessBasis=final-reprojected",
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
        (unsigned long)boneArrayPrimary, (unsigned long)boneArrayFallback,
        (unsigned long)boneArrayCapacityRecovered,
        (unsigned long)boneUnavailable[1], (unsigned long)boneUnavailable[2], (unsigned long)boneUnavailable[3],
        (unsigned long)boneUnavailable[4], (unsigned long)boneUnavailable[5],
        (unsigned long)boneHeadKnownProfile, (unsigned long)boneHeadProjected, (unsigned long)boneHeadUnknownProfile,
        (unsigned long)nameRequested, (unsigned long)namePresent,
        (unsigned long)weaponRequested, (unsigned long)weaponKnown,
         snapshot.captureCompletedMonotonicSeconds - captureStartedAt, finalReprojectionAge,
         finalPlayersCompletedAt - finalValidationStartedAt,
         finalCountsCompletedAt - finalPlayersCompletedAt,
         finalGrenadesCompletedAt - finalCountsCompletedAt,
         finalBonesCompletedAt - finalGrenadesCompletedAt];
    CSLastCaptureDiagnostic = "ready";
    return snapshot;
}

+ (CoreSetPlayerSnapshot *)refreshGeometryForSnapshot:(CoreSetPlayerSnapshot *)source
                                               session:(CoreSetReadSession *)session
                                            canvasSize:(CGSize)size
                                       includeOffscreen:(BOOL)includeOffscreen
                                   maximumDrawDistance:(double)maximumDrawDistance {
    if (!source || !session.ready || session.capabilities != 1 ||
        session.processID != source.processID || session.imageBase != source.imageBase ||
        !std::isfinite(size.width) || !std::isfinite(size.height) ||
        size.width <= 0 || size.height <= 0 ||
        !std::isfinite(maximumDrawDistance) || maximumDrawDistance < 0) return nil;
    const double startedAt = CACurrentMediaTime();
    const uint64_t generation = session.generation, base = session.imageBase;
    uint64_t world = 0, level = 0, manager = 0;
    if (!CSReadValue(session, generation, base + CSWorldSlot, &world) ||
        world != source.rosterWorldAddress ||
        !CSReadValue(session, generation, world + 0xb8, &level) ||
        level != source.rosterLevelAddress ||
        !CSReadValue(session, generation, source.rosterControllerAddress + 0x680, &manager) ||
        manager != source.rosterCameraManagerAddress) return nil;

    CSCamera camera = {};
    bool cameraFound = false;
    for (uint64_t offset : {UINT64_C(0x650), UINT64_C(0x14b0), UINT64_C(0x2320)}) {
        CSCamera candidate = {};
        if (CSRead(session, generation, manager + offset, &candidate, sizeof(candidate)) &&
            CSCameraValid(candidate)) { camera = candidate; cameraFound = true; break; }
    }
    if (!cameraFound) return nil;
    uint32_t localTeam = 0;
    CSVector localPosition = {};
    bool localPresent = false;
    if (!CSReadValue(session, generation, source.rosterLocalActorAddress + 0xb78, &localTeam) ||
        localTeam != source.rosterLocalTeam ||
        !CSPosition(session, generation, base, source.rosterLocalActorAddress,
                    &localPosition, &localPresent) || !localPresent) return nil;

    NSMutableArray<CoreSetPlayerMark *> *marks = [NSMutableArray arrayWithCapacity:source.marks.count];
    NSUInteger players = 0, bots = 0;
    for (CoreSetPlayerMark *oldMark in source.marks) {
        CSCaptureReadCache cache;
        cache.reserve(4);
        CSCorePlayerState state;
        if (!CSReadCorePlayerState(session, generation, oldMark.actorAddress,
                                   source.rosterLocalActorAddress, localTeam, &state, &cache) ||
            state.rootComponent != oldMark.rosterRootComponent ||
            state.meshComponent != oldMark.rosterMeshComponent) continue;
        CSVector position = {};
        bool present = false;
        if (!CSPosition(session, generation, base, oldMark.actorAddress, &position, &present,
                        &cache, state.rootComponent) || !present) continue;
        CoreSetPlayerMark *mark = CSRefreshPlayerMark(oldMark, state, position,
            localPosition, camera, size, includeOffscreen, maximumDrawDistance);
        if (!mark) continue;
        [marks addObject:mark];
        if (mark.bot) ++bots; else ++players;
    }

    NSMutableArray<CoreSetGrenadeMark *> *grenades = [NSMutableArray arrayWithCapacity:source.grenadeMarks.count];
    for (CoreSetGrenadeMark *oldMark in source.grenadeMarks) {
        CGPoint point = CGPointZero;
        const CSVector position = oldMark.motionPosition;
        const double dx = (double)position.x - localPosition.x;
        const double dy = (double)position.y - localPosition.y;
        const double dz = (double)position.z - localPosition.z;
        const double distance = std::sqrt(dx * dx + dy * dy + dz * dz) / 100.0;
        if (!std::isfinite(distance) || !CSProject(camera, position, size, &point) ||
            point.x < 0 || point.x > size.width || point.y < 0 || point.y > size.height) continue;
        CoreSetGrenadeMark *mark = [CoreSetGrenadeMark new];
        mark.point = point; mark.distanceUnitsDividedBy100 = distance;
        mark.countdownSeconds = oldMark.countdownSeconds;
        mark.predictionSegments = @[]; mark.predictionEndpointPresent = NO;
        mark.predictionEndpoint = CGPointZero;
        mark.motionPosition = position; mark.motionActor = oldMark.motionActor;
        mark.motionType = oldMark.motionType; mark.motionNameIndex = oldMark.motionNameIndex;
        mark.motionExplosionRaw = oldMark.motionExplosionRaw;
        [grenades addObject:mark];
    }
    const double completedAt = CACurrentMediaTime();
    if (!session.ready || session.generation != generation ||
        session.processID != source.processID || session.imageBase != base ||
        !std::isfinite(completedAt - startedAt) || completedAt - startedAt > 0.5) return nil;

    CoreSetPlayerSnapshot *snapshot = [CoreSetPlayerSnapshot new];
    snapshot.sessionGeneration = generation; snapshot.processID = source.processID;
    snapshot.imageBase = base; snapshot.snapshotID = [NSUUID UUID];
    snapshot.rosterWorldAddress = source.rosterWorldAddress;
    snapshot.rosterLevelAddress = source.rosterLevelAddress;
    snapshot.rosterControllerAddress = source.rosterControllerAddress;
    snapshot.rosterCameraManagerAddress = source.rosterCameraManagerAddress;
    snapshot.rosterLocalActorAddress = source.rosterLocalActorAddress;
    snapshot.rosterLocalTeam = source.rosterLocalTeam;
    snapshot.motionCamera = camera;
    snapshot.cameraYawDegrees = camera.rotation.y;
    snapshot.cameraPitchDegrees = camera.rotation.x;
    snapshot.cameraRollDegrees = camera.rotation.z;
    snapshot.cameraFieldOfViewDegrees = camera.fov;
    snapshot.cameraWorldPosition = [CoreSetWorldPoint pointWithX:camera.location.x
        y:camera.location.y z:camera.location.z];
    snapshot.localWorldPosition = [CoreSetWorldPoint pointWithX:localPosition.x
        y:localPosition.y z:localPosition.z];
    snapshot.canvasSize = size;
    snapshot.controllerAddress = source.controllerAddress;
    snapshot.localActorAddress = source.localActorAddress;
    snapshot.localADS = source.localADS; snapshot.localFiring = source.localFiring;
    snapshot.localFiringRaw = source.localFiringRaw;
    snapshot.controlPitchDegrees = source.controlPitchDegrees;
    snapshot.controlYawDegrees = source.controlYawDegrees;
    snapshot.rotationInputPitch = source.rotationInputPitch;
    snapshot.rotationInputYaw = source.rotationInputYaw;
    snapshot.marks = [marks copy]; snapshot.grenadeMarks = [grenades copy];
    snapshot.observedPlayerCount = players; snapshot.observedBotCount = bots;
    snapshot.captureStartedMonotonicSeconds = startedAt;
    snapshot.captureCompletedMonotonicSeconds = completedAt;
    snapshot.readSemanticDiagnostic = [NSString stringWithFormat:
        @"geometry-refresh roster=%@ rosterMarks=%lu marks=%lu players=%lu bots=%lu duration=%.3f camera=current actorRoots=current screenPoints=reprojected",
        source.snapshotID.UUIDString, (unsigned long)source.marks.count,
        (unsigned long)marks.count, (unsigned long)players, (unsigned long)bots,
        completedAt - startedAt];
    return snapshot;
}

+ (CoreSetPlayerSnapshot *)reprojectPresentationForSnapshot:(CoreSetPlayerSnapshot *)source
                                                      session:(CoreSetReadSession *)session
                                                   canvasSize:(CGSize)size
                                              includeOffscreen:(BOOL)includeOffscreen
                                          maximumDrawDistance:(double)maximumDrawDistance {
    if (!source || !session.ready || session.capabilities != 1 ||
        session.processID != source.processID || session.imageBase != source.imageBase ||
        !std::isfinite(size.width) || !std::isfinite(size.height) ||
        size.width <= 0 || size.height <= 0 ||
        !std::isfinite(maximumDrawDistance) || maximumDrawDistance < 0 ||
        !source.localWorldPosition) return nil;
    const double startedAt = CACurrentMediaTime();
    const uint64_t generation = session.generation, base = session.imageBase;
    uint64_t world = 0, manager = 0;
    if (!CSReadValue(session, generation, base + CSWorldSlot, &world) ||
        world != source.rosterWorldAddress ||
        !CSReadValue(session, generation, source.rosterControllerAddress + 0x680, &manager) ||
        manager != source.rosterCameraManagerAddress) return nil;

    CSCamera camera = {};
    bool cameraFound = false;
    uint64_t cameraOffset = 0;
    for (uint64_t offset : {UINT64_C(0x650), UINT64_C(0x14b0), UINT64_C(0x2320)}) {
        CSCamera candidate = {};
        if (CSRead(session, generation, manager + offset, &candidate, sizeof(candidate)) &&
            CSCameraValid(candidate)) {
            camera = candidate; cameraFound = true; cameraOffset = offset; break;
        }
    }
    if (!cameraFound) return nil;
    const CSVector localPosition = {source.localWorldPosition.x,
                                    source.localWorldPosition.y,
                                    source.localWorldPosition.z};
    if (!CSFinite(localPosition)) return nil;

    NSMutableArray<CoreSetPlayerMark *> *marks =
        [NSMutableArray arrayWithCapacity:source.marks.count];
    NSUInteger players = 0, bots = 0;
    for (CoreSetPlayerMark *oldMark in source.marks) {
        if (!oldMark.actorWorldPosition) continue;
        const CSVector position = {oldMark.actorWorldPosition.x,
                                   oldMark.actorWorldPosition.y,
                                   oldMark.actorWorldPosition.z};
        if (!CSFinite(position)) continue;
        CSCorePlayerState state = {};
        state.team = oldMark.teamID;
        state.stateFlags = oldMark.referenceStateWord;
        state.status = oldMark.healthStatusCode;
        state.health = oldMark.health;
        state.maximum = oldMark.maximumHealth;
        state.rootComponent = oldMark.rosterRootComponent;
        state.meshComponent = oldMark.rosterMeshComponent;
        state.ai = oldMark.bot ? 1 : 0;
        CoreSetPlayerMark *mark = CSRefreshPlayerMark(oldMark, state, position,
            localPosition, camera, size, includeOffscreen, maximumDrawDistance);
        if (!mark) continue;
        [marks addObject:mark];
        if (mark.bot) ++bots; else ++players;
    }

    NSMutableArray<CoreSetGrenadeMark *> *grenades =
        [NSMutableArray arrayWithCapacity:source.grenadeMarks.count];
    for (CoreSetGrenadeMark *oldMark in source.grenadeMarks) {
        CGPoint point = CGPointZero;
        const CSVector position = oldMark.motionPosition;
        const double dx = (double)position.x - localPosition.x;
        const double dy = (double)position.y - localPosition.y;
        const double dz = (double)position.z - localPosition.z;
        const double distance = std::sqrt(dx * dx + dy * dy + dz * dz) / 100.0;
        if (!std::isfinite(distance) || !CSProject(camera, position, size, &point) ||
            point.x < 0 || point.x > size.width || point.y < 0 || point.y > size.height) continue;
        CoreSetGrenadeMark *mark = [CoreSetGrenadeMark new];
        mark.point = point; mark.distanceUnitsDividedBy100 = distance;
        mark.countdownSeconds = oldMark.countdownSeconds;
        mark.predictionSegments = @[]; mark.predictionEndpointPresent = NO;
        mark.predictionEndpoint = CGPointZero;
        mark.motionPosition = position; mark.motionActor = oldMark.motionActor;
        mark.motionType = oldMark.motionType; mark.motionNameIndex = oldMark.motionNameIndex;
        mark.motionExplosionRaw = oldMark.motionExplosionRaw;
        [grenades addObject:mark];
    }
    const double completedAt = CACurrentMediaTime();
    if (!session.ready || session.generation != generation ||
        session.processID != source.processID || session.imageBase != base ||
        !std::isfinite(completedAt - startedAt) || completedAt - startedAt > 0.5) return nil;

    CoreSetPlayerSnapshot *snapshot = [CoreSetPlayerSnapshot new];
    snapshot.sessionGeneration = generation; snapshot.processID = source.processID;
    snapshot.imageBase = base; snapshot.snapshotID = [NSUUID UUID];
    snapshot.rosterWorldAddress = source.rosterWorldAddress;
    snapshot.rosterLevelAddress = source.rosterLevelAddress;
    snapshot.rosterControllerAddress = source.rosterControllerAddress;
    snapshot.rosterCameraManagerAddress = source.rosterCameraManagerAddress;
    snapshot.rosterLocalActorAddress = source.rosterLocalActorAddress;
    snapshot.rosterLocalTeam = source.rosterLocalTeam;
    snapshot.motionCamera = camera;
    snapshot.cameraYawDegrees = camera.rotation.y;
    snapshot.cameraPitchDegrees = camera.rotation.x;
    snapshot.cameraRollDegrees = camera.rotation.z;
    snapshot.cameraFieldOfViewDegrees = camera.fov;
    snapshot.cameraWorldPosition = [CoreSetWorldPoint pointWithX:camera.location.x
        y:camera.location.y z:camera.location.z];
    snapshot.localWorldPosition = source.localWorldPosition;
    snapshot.canvasSize = size;
    snapshot.controllerAddress = source.controllerAddress;
    snapshot.localActorAddress = source.localActorAddress;
    snapshot.localADS = source.localADS; snapshot.localFiring = source.localFiring;
    snapshot.localFiringRaw = source.localFiringRaw;
    snapshot.controlPitchDegrees = source.controlPitchDegrees;
    snapshot.controlYawDegrees = source.controlYawDegrees;
    snapshot.rotationInputPitch = source.rotationInputPitch;
    snapshot.rotationInputYaw = source.rotationInputYaw;
    snapshot.marks = [marks copy]; snapshot.grenadeMarks = [grenades copy];
    snapshot.observedPlayerCount = players; snapshot.observedBotCount = bots;
    snapshot.captureStartedMonotonicSeconds = startedAt;
    snapshot.captureCompletedMonotonicSeconds = completedAt;
    snapshot.readSemanticDiagnostic = [NSString stringWithFormat:
        @"presentation-reprojection source=%@ marks=%lu players=%lu bots=%lu duration=%.3f camera=current cameraOffset=0x%llx actorRoots=cached screenPoints=reprojected",
        source.snapshotID.UUIDString, (unsigned long)marks.count,
        (unsigned long)players, (unsigned long)bots, completedAt - startedAt,
        (unsigned long long)cameraOffset];
    return snapshot;
}

+ (CoreSetPlayerSnapshot *)refreshActionForSnapshot:(CoreSetPlayerSnapshot *)source
                                         targetActor:(uint64_t)targetActor
                                             session:(CoreSetReadSession *)session
                                          canvasSize:(CGSize)size
                                 maximumDrawDistance:(double)maximumDrawDistance {
    CSLastCaptureDiagnostic = "action-refresh-request";
    if (!source || !session.ready || session.capabilities != 1 ||
        session.processID != source.processID || session.imageBase != source.imageBase ||
        !std::isfinite(size.width) || !std::isfinite(size.height) ||
        size.width <= 0 || size.height <= 0 ||
        !std::isfinite(maximumDrawDistance) || maximumDrawDistance < 1 ||
        maximumDrawDistance > 1000) return nil;
    const double startedAt = CACurrentMediaTime();
    const uint64_t generation = session.generation, base = session.imageBase;
    uint64_t world = 0, level = 0, driver = 0, connection = 0;
    uint64_t controller = 0, local = 0, manager = 0;
    CSLastCaptureDiagnostic = "action-refresh-identity-initial";
    if (!CSReadValue(session, generation, base + CSWorldSlot, &world) ||
        world != source.rosterWorldAddress ||
        !CSReadValue(session, generation, world + 0xb8, &level) ||
        level != source.rosterLevelAddress ||
        !CSReadValue(session, generation, world + 0xc0, &driver) ||
        !CSUserPointerValid(driver) ||
        !CSReadValue(session, generation, driver + 0x88, &connection) ||
        !CSUserPointerValid(connection) ||
        !CSReadValue(session, generation, connection + 0x30, &controller) ||
        controller != source.rosterControllerAddress ||
        !CSReadValue(session, generation, controller + 0x3540, &local) ||
        local != source.rosterLocalActorAddress ||
        !CSReadValue(session, generation, controller + 0x680, &manager) ||
        manager != source.rosterCameraManagerAddress) return nil;

    uint32_t localTeam = 0;
    CSVector localPosition = {};
    bool localPresent = false;
    if (!CSReadValue(session, generation, local + 0xb78, &localTeam) ||
        localTeam != source.rosterLocalTeam ||
        !CSPosition(session, generation, base, local, &localPosition, &localPresent) ||
        !localPresent) return nil;

    CSCamera camera = {};
    bool cameraFound = false;
    uint64_t cameraOffset = 0;
    for (uint64_t offset : {UINT64_C(0x650), UINT64_C(0x14b0), UINT64_C(0x2320)}) {
        CSCamera candidate = {};
        if (CSRead(session, generation, manager + offset, &candidate, sizeof(candidate)) &&
            CSCameraValid(candidate)) {
            camera = candidate; cameraFound = true; cameraOffset = offset; break;
        }
    }
    if (!cameraFound) return nil;

    NSMutableArray<CoreSetPlayerMark *> *marks = [NSMutableArray arrayWithCapacity:
        targetActor ? 1 : source.marks.count];
    NSUInteger players = 0, bots = 0;
    bool targetFound = targetActor == 0;
    CSLastCaptureDiagnostic = targetActor ? "action-refresh-target" : "action-refresh-candidates";
    for (CoreSetPlayerMark *oldMark in source.marks) {
        if (targetActor && oldMark.actorAddress != targetActor) continue;
        CSCorePlayerState state = {};
        CSVector position = {};
        if (targetActor) {
            CSCaptureReadCache cache;
            cache.reserve(10);
            if (!CSReadCorePlayerState(session, generation, oldMark.actorAddress, local,
                                       localTeam, &state, &cache) ||
                state.rootComponent != oldMark.rosterRootComponent ||
                state.meshComponent != oldMark.rosterMeshComponent) return nil;
            bool present = false;
            if (!CSPosition(session, generation, base, oldMark.actorAddress, &position,
                            &present, &cache, state.rootComponent) || !present) return nil;
        } else {
            if (!oldMark.actorWorldPosition) continue;
            state.team = oldMark.teamID;
            state.stateFlags = oldMark.referenceStateWord;
            state.status = oldMark.healthStatusCode;
            state.health = oldMark.health;
            state.maximum = oldMark.maximumHealth;
            state.rootComponent = oldMark.rosterRootComponent;
            state.meshComponent = oldMark.rosterMeshComponent;
            state.ai = oldMark.bot ? 1 : 0;
            position = {oldMark.actorWorldPosition.x, oldMark.actorWorldPosition.y,
                        oldMark.actorWorldPosition.z};
        }
        CoreSetPlayerMark *mark = CSRefreshPlayerMark(oldMark, state, position,
            localPosition, camera, size, NO, maximumDrawDistance);
        if (!mark) {
            if (targetActor) return nil;
            continue;
        }
        if (targetActor && !CSRefreshActionBone(session, generation, base,
                oldMark.actorAddress, state.meshComponent, camera, size, mark)) return nil;
        [marks addObject:mark];
        targetFound = targetFound || oldMark.actorAddress == targetActor;
        if (mark.bot) ++bots; else ++players;
    }
    if (!targetFound || (targetActor && marks.count != 1)) return nil;

    // Bind action values to the completed geometry sample, rather than copying
    // the slow-roster inputs. Recoil absence remains a valid input publication.
    CSLastCaptureDiagnostic = "action-refresh-inputs-final";
    uint8_t localADS = 0, localFiring = 0;
    float controlRotation[2] = {}, rotationInput[2] = {};
    CSRecoilInputState recoilInputs;
    if (!CSReadValue(session, generation, local + 0x1848, &localADS) ||
        !CSReadValue(session, generation, local + 0x2750, &localFiring) ||
        !CSRead(session, generation, controller + 0x620,
                controlRotation, sizeof(controlRotation)) ||
        !CSRead(session, generation, controller + 0x828,
                rotationInput, sizeof(rotationInput)) ||
        !std::isfinite(controlRotation[0]) || !std::isfinite(controlRotation[1]) ||
        !std::isfinite(rotationInput[0]) || !std::isfinite(rotationInput[1]) ||
        std::fabs(controlRotation[0]) > 360 || std::fabs(controlRotation[1]) > 360 ||
        std::fabs(rotationInput[0]) > 360 || std::fabs(rotationInput[1]) > 360 ||
        !CSCaptureRecoilInputs(session, generation, controller, local,
                               localFiring, &recoilInputs)) return nil;

    uint64_t finalWorld = 0, finalLevel = 0, finalController = 0;
    uint64_t finalLocal = 0, finalManager = 0;
    CSLastCaptureDiagnostic = "action-refresh-identity-final";
    if (!session.ready || session.generation != generation ||
        !CSReadValue(session, generation, base + CSWorldSlot, &finalWorld) || finalWorld != world ||
        !CSReadValue(session, generation, world + 0xb8, &finalLevel) || finalLevel != level ||
        !CSReadValue(session, generation, connection + 0x30, &finalController) ||
        finalController != controller ||
        !CSReadValue(session, generation, controller + 0x3540, &finalLocal) || finalLocal != local ||
        !CSReadValue(session, generation, controller + 0x680, &finalManager) ||
        finalManager != manager) return nil;
    const double completedAt = CACurrentMediaTime();
    if (!std::isfinite(completedAt - startedAt) || completedAt < startedAt ||
        completedAt - startedAt > 0.45) return nil;

    CoreSetPlayerSnapshot *snapshot = [CoreSetPlayerSnapshot new];
    snapshot.sessionGeneration = generation; snapshot.processID = source.processID;
    snapshot.imageBase = base; snapshot.snapshotID = [NSUUID UUID];
    snapshot.rosterWorldAddress = world; snapshot.rosterLevelAddress = level;
    snapshot.rosterControllerAddress = controller;
    snapshot.rosterCameraManagerAddress = manager;
    snapshot.rosterLocalActorAddress = local; snapshot.rosterLocalTeam = localTeam;
    snapshot.motionCamera = camera;
    snapshot.cameraYawDegrees = camera.rotation.y;
    snapshot.cameraPitchDegrees = camera.rotation.x;
    snapshot.cameraRollDegrees = camera.rotation.z;
    snapshot.cameraFieldOfViewDegrees = camera.fov;
    snapshot.cameraWorldPosition = [CoreSetWorldPoint pointWithX:camera.location.x
        y:camera.location.y z:camera.location.z];
    snapshot.localWorldPosition = [CoreSetWorldPoint pointWithX:localPosition.x
        y:localPosition.y z:localPosition.z];
    snapshot.canvasSize = size;
    snapshot.battleInputsPresent = YES;
    snapshot.controllerAddress = controller; snapshot.localActorAddress = local;
    snapshot.localADS = localADS != 0; snapshot.localFiring = localFiring != 0;
    snapshot.localFiringRaw = localFiring;
    snapshot.controlPitchDegrees = controlRotation[0];
    snapshot.controlYawDegrees = controlRotation[1];
    snapshot.rotationInputPitch = rotationInput[0];
    snapshot.rotationInputYaw = rotationInput[1];
    const uint32_t recoilBinding = (uint32_t)generation;
    snapshot.recoilInputsPresent = recoilInputs.present && recoilBinding != 0;
    snapshot.recoilBinding = snapshot.recoilInputsPresent ? recoilBinding : 0;
    if (snapshot.recoilInputsPresent) {
        CoreSetRecoilPostSample *sample = [CoreSetRecoilPostSample new];
        sample.key = recoilInputs.key; sample.ownerToken = recoilInputs.ownerToken;
        sample.active = recoilInputs.active;
        sample.value0 = recoilInputs.values[0]; sample.value1 = recoilInputs.values[1];
        sample.value2 = recoilInputs.values[2]; sample.value3 = recoilInputs.values[3];
        sample.value4 = recoilInputs.values[4]; sample.value5 = recoilInputs.values[5];
        snapshot.recoilPostSample = sample;
        snapshot.recoilFirstWeight = recoilInputs.scales[0];
        snapshot.recoilFirstBindingScale = recoilInputs.scales[1];
        snapshot.recoilSecondWeight = recoilInputs.scales[2];
        snapshot.recoilSecondBindingScale = recoilInputs.scales[3];
    }
    snapshot.marks = [marks copy]; snapshot.grenadeMarks = @[];
    snapshot.observedPlayerCount = players; snapshot.observedBotCount = bots;
    snapshot.captureStartedMonotonicSeconds = startedAt;
    snapshot.captureCompletedMonotonicSeconds = completedAt;
    snapshot.readSemanticDiagnostic = [NSString stringWithFormat:
        @"action-refresh source=%@ target=0x%llx marks=%lu duration=%.3f actorArrayScan=0 camera=current inputs=current targetGeometry=%@ cameraOffset=0x%llx",
        source.snapshotID.UUIDString, (unsigned long long)targetActor,
        (unsigned long)marks.count, completedAt - startedAt,
        targetActor ? @"state-root-bones-current" : @"cached-world-reprojected",
        (unsigned long long)cameraOffset];
    CSLastCaptureDiagnostic = "ready-action-refresh";
    return snapshot;
}
@end
