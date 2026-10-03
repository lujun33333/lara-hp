#import "CoreSetMaterialSnapshot.h"
#import "CoreSetMaterialName.h"
#import "CoreSetMetroArmorNames.h"
#import "CoreSetVehicleStatus.h"
#import "CoreSetPlayerProjection.h"
#import <algorithm>
#import <cmath>
#import <cstring>
#import <string>
#import <unordered_map>
#import <unordered_set>
#import <vector>

static constexpr uint64_t CSMWorldSlot = 0x1148b608;
static constexpr uint64_t CSMNamePoolSlot = 0x11fba198;
static constexpr uint64_t CSMPositionCallbackSlot = 0x1146b3e8;
static constexpr uint64_t CSMPositionCallbackRVA = 0x76526bc;
static constexpr uint64_t CSMPositionXORKeySlot = 0x110712dc;
static constexpr uint64_t CSMVehicleClassSlot = 0x11c71920;
static constexpr uint64_t CSMVehicleComponentClassSlot = 0x11cbcbd8;
static constexpr uint64_t CSMCharacterClassSlot = 0x11c2b598;
static constexpr int32_t CSMMaxActors = 50000;
static constexpr NSUInteger CSMMaxMarks = 8192;

static bool CSMAddress(uint64_t address, size_t length) {
    return address >= 0x100000000ULL && address < 0x8000000000ULL &&
           length && address <= 0x8000000000ULL - length;
}
static bool CSMRead(CoreSetReadSession *session, uint64_t generation,
                    uint64_t address, void *output, size_t length) {
    if (!CSMAddress(address, length)) return false;
    size_t done = 0;
    return [session readAt:address to:output length:length generation:generation
            completedBytes:&done error:nullptr] && done == length;
}
template <typename T> static bool CSMReadValue(CoreSetReadSession *session, uint64_t generation,
                                                uint64_t address, T *value) {
    return CSMRead(session, generation, address, value, sizeof(T));
}
static bool CSMFinite(CoreSet::Vec3 point) {
    return std::isfinite(point.x) && std::isfinite(point.y) && std::isfinite(point.z) &&
           std::fabs(point.x) < 1.0e9f && std::fabs(point.y) < 1.0e9f &&
           std::fabs(point.z) < 1.0e9f;
}
static bool CSMCameraValid(const CoreSet::Camera &camera) {
    return CSMFinite(camera.location) && CSMFinite(camera.rotation) &&
           std::fabs(camera.rotation.x) <= 360 && std::fabs(camera.rotation.y) <= 360 &&
           std::fabs(camera.rotation.z) <= 360 && std::isfinite(camera.fov) &&
           camera.fov > 1 && camera.fov < 170;
}
static bool CSMLocalWeapon(CoreSetReadSession *session, uint64_t generation,
                           uint64_t local, uint64_t *weapon, uint32_t *weaponID) {
    *weapon = 0; *weaponID = 0;
    if (!CSMReadValue(session, generation, local + 0x1170, weapon)) return false;
    if (!*weapon) return true;
    return CSMAddress(*weapon, 0xdd4) &&
        CSMReadValue(session, generation, *weapon + 0xdd0, weaponID);
}
static bool CSMClassIsChildOf(CoreSetReadSession *session, uint64_t generation,
                              uint64_t type, uint64_t wanted, bool *result) {
    for (unsigned depth = 0; depth < 64 && type; ++depth) {
        if (type == wanted) { *result = true; return true; }
        if (!CSMReadValue(session, generation, type + 0x30, &type)) return false;
    }
    if (type) return false;
    *result = false;
    return true;
}
struct CSMVehicleObservation {
    uint64_t component = 0;
    float hpMax = 0, hp = 0, fuelMax = 0, fuel = 0;
    bool vehicleType = false, componentType = false;
};
static bool CSMVehicle(CoreSetReadSession *session, uint64_t generation,
                       uint64_t actor, uint64_t type, uint64_t vehicleClass,
                       uint64_t componentClass,
                       CSMVehicleObservation *observation) {
    *observation = {};
    if (!CSMClassIsChildOf(session, generation, type, vehicleClass,
                           &observation->vehicleType)) return false;
    if (!observation->vehicleType) return true;
    // STExtraVehicleBase.VehicleCommon points at VehicleCommonComponent.
    if (!CSMAddress(actor, 0xc08) ||
        !CSMReadValue(session, generation, actor + 0xc00, &observation->component)) return false;
    if (!observation->component) return true;
    if (!CSMAddress(observation->component, 0x220)) return false;
    uint64_t componentType = 0;
    if (!CSMReadValue(session, generation, observation->component + 0x10, &componentType) ||
        !CSMClassIsChildOf(session, generation, componentType, componentClass,
                           &observation->componentType)) return false;
    if (!observation->componentType) return true;
    if (!CSMReadValue(session, generation, observation->component + 0x1f4, &observation->hpMax) ||
        !CSMReadValue(session, generation, observation->component + 0x1f8, &observation->hp) ||
        !CSMReadValue(session, generation, observation->component + 0x218, &observation->fuelMax) ||
        !CSMReadValue(session, generation, observation->component + 0x21c, &observation->fuel))
        return false;
    return true;
}
struct CSMAvatarArray { uint64_t data; int32_t count; int32_t capacity; };
struct CSMChildrenArray { uint64_t data; int32_t count; int32_t capacity; };
static bool CSMChildren(CoreSetReadSession *session, uint64_t generation,
                        uint64_t actor, CSMChildrenArray *children) {
    *children = {};
    if (!CSMAddress(actor, 0x260) ||
        !CSMRead(session, generation, actor + 0x250, children, sizeof(*children))) return false;
    return children->count >= 0 && children->count <= CSMMaxActors &&
           children->capacity >= children->count && children->capacity <= CSMMaxActors &&
           (!children->count || (children->data &&
                                  CSMAddress(children->data, size_t(children->count) * 8)));
}
struct CSMMetroObservation {
    CSMAvatarArray array = {};
    float health = 0, healthMax = 0;
    uint32_t headID = 0, armorID = 0;
    bool characterType = false, hasSlots = false;
};
static bool CSMMetro(CoreSetReadSession *session, uint64_t generation,
                     uint64_t actor, uint64_t type, uint64_t characterClass,
                     CSMMetroObservation *observation) {
    *observation = {};
    if (!CSMClassIsChildOf(session, generation, type, characterClass,
                           &observation->characterType)) return false;
    if (!observation->characterType) return true;
    if (!CSMAddress(actor, 0x51a8) ||
        !CSMReadValue(session, generation, actor + 0x1060, &observation->health) ||
        !CSMReadValue(session, generation, actor + 0x1068, &observation->healthMax) ||
        !CSMRead(session, generation, actor + 0x5198, &observation->array,
                 sizeof(observation->array))) return false;
    const CSMAvatarArray &array = observation->array;
    if (array.count < 0 || array.count > 1024 || array.capacity < array.count ||
        array.capacity > 1024 || (array.count && !array.data)) return false;
    if (array.count < 11) return true;
    if (!CSMAddress(array.data, size_t(array.count) * 0x38)) return false;
    if (!CSMReadValue(session, generation, array.data + 9 * 0x38 + 4,
                      &observation->headID) ||
        !CSMReadValue(session, generation, array.data + 10 * 0x38 + 4,
                      &observation->armorID)) return false;
    observation->hasSlots = true;
    return true;
}
static bool CSMPosition(CoreSetReadSession *session, uint64_t generation, uint64_t base,
                        uint64_t actor, CoreSet::Vec3 *position, bool *present) {
    *present = false;
    uint64_t component = 0;
    if (!CSMReadValue(session, generation, actor + 0x260, &component)) return false;
    if (!component) return true;
    if (!CSMAddress(component, 0x290)) return false;
    uint32_t flags = 0;
    if (!CSMReadValue(session, generation, component + 0x25c, &flags)) return false;
    if ((flags & ((1u << 20) | (1u << 22))) == ((1u << 20) | (1u << 22))) {
        uint64_t callback = 0;
        if (!CSMReadValue(session, generation, base + CSMPositionCallbackSlot, &callback)) return false;
        if (callback) {
            if (callback != base + CSMPositionCallbackRVA) return false;
            uint8_t block[0x30] = {0};
            uint32_t key = 0;
            if (!CSMRead(session, generation, component + 0x1f0, block, sizeof(block)) ||
                !CSMReadValue(session, generation, base + CSMPositionXORKeySlot, &key)) return false;
            CoreSet::decodePositionBlock(block, key);
            std::memcpy(position, block + 0x10, sizeof(*position));
            *present = CSMFinite(*position);
            return true;
        }
    }
    if (!CSMRead(session, generation, component + 0x200, position, sizeof(*position))) return false;
    *present = CSMFinite(*position);
    return true;
}

@interface CoreSetMaterialMark ()
@property(nonatomic) NSInteger recordIndex;
@property(nonatomic) CGPoint point;
@property(nonatomic) double distanceUnitsDividedBy100;
@property(nonatomic, copy) NSString *crateLevelLabel;
@property(nonatomic) NSNumber *escapeBoxChildrenCount;
@property(nonatomic) NSNumber *vehicleHPPercent;
@property(nonatomic) NSNumber *vehicleFuelPercent;
@end
@implementation CoreSetMaterialMark @end

@interface CoreSetMetroArmorMark ()
@property(nonatomic) CGPoint point;
@property(nonatomic, copy) NSString *headLabel;
@property(nonatomic, copy) NSString *armorLabel;
@end
@implementation CoreSetMetroArmorMark @end

@interface CoreSetMaterialSnapshot ()
@property(nonatomic) uint64_t sessionGeneration;
@property(nonatomic) int32_t processID;
@property(nonatomic) uint64_t imageBase;
@property(nonatomic) uint32_t localWeaponID;
@property(nonatomic, copy) NSUUID *snapshotID;
@property(nonatomic) NSArray<CoreSetMaterialMark *> *marks;
@property(nonatomic) NSArray<CoreSetMetroArmorMark *> *metroMarks;
@end
@implementation CoreSetMaterialSnapshot @end

@implementation CoreSetMaterialCollector
+ (CoreSetMaterialSnapshot *)capture:(CoreSetReadSession *)session
                              canvasSize:(CGSize)size patterns:(NSArray<NSString *> *)patterns
                         includeArmedState:(BOOL)includeArmedState
                        includeCrateLevel:(BOOL)includeCrateLevel
                       includeVehicleStatus:(BOOL)includeVehicleStatus
                         includeMetroArmor:(BOOL)includeMetroArmor
                includeHideOpenedCrates:(BOOL)includeHideOpenedCrates {
    if (!session.ready || session.capabilities != 1 || patterns.count != 177 ||
        !std::isfinite(size.width) || !std::isfinite(size.height) ||
        size.width <= 0 || size.height <= 0) return nil;
    std::vector<std::string> keys;
    std::unordered_set<std::string> unique;
    keys.reserve(patterns.count);
    for (NSString *pattern in patterns) {
        const char *text = pattern.UTF8String;
        if (!text) return nil;
        std::string key(text);
        if (key.empty() || key.size() > 64 || !unique.insert(key).second ||
            !std::all_of(key.begin(), key.end(), [](unsigned char c) { return c >= 0x20 && c <= 0x7e; }))
            return nil;
        keys.push_back(std::move(key));
    }
    if (keys.front() != "BP_Rifle_AKM_Wrapper_C" || keys.back() != "Ammo_Bolt") return nil;
    uint64_t generation = session.generation, base = session.imageBase;
    int32_t pid = session.processID;
    if (!base || pid <= 0 || base > UINT64_MAX - CSMNamePoolSlot) return nil;
    uint64_t world = 0, pool = 0, level = 0, cluster = 0;
    if (!CSMReadValue(session, generation, base + CSMWorldSlot, &world) || !world ||
        !CSMReadValue(session, generation, base + CSMNamePoolSlot, &pool) || !pool ||
        !CSMAddress(world, 0x100) || !CSMAddress(pool, 0x1408) ||
        !CSMReadValue(session, generation, world + 0xb8, &level) || !level ||
        !CSMAddress(level, 0xe8) ||
        !CSMReadValue(session, generation, level + 0xe0, &cluster) || !cluster ||
        !CSMAddress(cluster, 0x40)) return nil;
    struct { uint64_t data; int32_t count; int32_t capacity; } actors = {0};
    uint32_t nameCount = 0;
    if (!CSMRead(session, generation, cluster + 0x28, &actors, sizeof(actors)) ||
        !CSMReadValue(session, generation, pool + 0x1400, &nameCount) ||
        actors.count < 0 || actors.count > CSMMaxActors || actors.capacity < actors.count ||
        actors.capacity > CSMMaxActors || (actors.count && !actors.data) ||
        (actors.count && !CSMAddress(actors.data, size_t(actors.count) * 8)) ||
        !nameCount || nameCount > 0xA00000) return nil;
    uint64_t driver = 0, connection = 0, controller = 0, local = 0, manager = 0;
    if (!CSMReadValue(session, generation, world + 0xc0, &driver) || !driver ||
        !CSMAddress(driver, 0x90) ||
        !CSMReadValue(session, generation, driver + 0x88, &connection) || !connection ||
        !CSMAddress(connection, 0x38) ||
        !CSMReadValue(session, generation, connection + 0x30, &controller) || !controller ||
        !CSMAddress(controller, 0x3548) ||
        !CSMReadValue(session, generation, controller + 0x3540, &local) || !local ||
        !CSMReadValue(session, generation, controller + 0x680, &manager) || !manager ||
        !CSMAddress(local, 0x280) || !CSMAddress(manager, 0x2360)) return nil;
    CoreSet::Camera camera = {};
    uint64_t cameraOffset = 0;
    for (uint64_t offset : {UINT64_C(0x650), UINT64_C(0x14b0), UINT64_C(0x2320)}) {
        CoreSet::Camera candidate = {};
        if (CSMRead(session, generation, manager + offset, &candidate, sizeof(candidate)) &&
            CSMCameraValid(candidate)) { camera = candidate; cameraOffset = offset; break; }
    }
    if (!cameraOffset) return nil;
    uint64_t localWeapon = 0;
    uint32_t localWeaponID = 0;
    if (includeArmedState &&
        !CSMLocalWeapon(session, generation, local, &localWeapon, &localWeaponID)) return nil;
    uint64_t vehicleClass = 0, componentClass = 0;
    if (includeVehicleStatus &&
        (!CSMReadValue(session, generation, base + CSMVehicleClassSlot, &vehicleClass) ||
         !CSMAddress(vehicleClass, 0x38) ||
         !CSMReadValue(session, generation, base + CSMVehicleComponentClassSlot, &componentClass) ||
         !CSMAddress(componentClass, 0x38))) return nil;
    uint64_t characterClass = 0;
    if (includeMetroArmor &&
        (!CSMReadValue(session, generation, base + CSMCharacterClassSlot, &characterClass) ||
         !CSMAddress(characterClass, 0x38))) return nil;
    CoreSet::Vec3 localPosition = {};
    bool present = false;
    if (!CSMPosition(session, generation, base, local, &localPosition, &present) || !present) return nil;
    NSMutableArray<CoreSetMaterialMark *> *marks = [NSMutableArray array];
    NSMutableArray<CoreSetMetroArmorMark *> *metroMarks = [NSMutableArray array];
    struct Observed { uint64_t address; uint32_t nameIndex; uint64_t type;
                      CoreSet::Vec3 position; size_t record; std::string level;
                      bool escapeBox; CSMChildrenArray children;
                      CSMVehicleObservation vehicle; };
    std::vector<uint64_t> observedPointers;
    std::vector<uint32_t> observedNames;
    std::vector<uint64_t> observedTypes;
    std::vector<Observed> observedMarks;
    struct ObservedMetro { uint64_t address; uint64_t type; CoreSet::Vec3 position;
                           CSMMetroObservation data; };
    std::vector<ObservedMetro> observedMetro;
    observedPointers.reserve(size_t(actors.count)); observedNames.reserve(size_t(actors.count));
    observedTypes.reserve(size_t(actors.count));
    struct NameMatch { int record; std::string level; bool escapeBox; };
    std::unordered_map<uint32_t, NameMatch> nameMatches;
    auto read = [session, generation](uint64_t address, void *output, size_t length) {
        return CSMRead(session, generation, address, output, length);
    };
    uint64_t batchPointers[512] = {};
    for (int32_t start = 0; start < actors.count; start += 512) {
        int32_t batch = std::min<int32_t>(512, actors.count - start);
        if (!CSMRead(session, generation, actors.data + uint64_t(start) * 8,
                     batchPointers, size_t(batch) * 8)) return nil;
        observedPointers.insert(observedPointers.end(), batchPointers, batchPointers + batch);
        for (int32_t i = 0; i < batch; ++i) {
            uint64_t actor = batchPointers[i];
            if (!actor || actor == local) {
                observedNames.push_back(0); observedTypes.push_back(0); continue;
            }
            if (!CSMAddress(actor, 0x280)) return nil;
            uint32_t nameIndex = 0;
            if (!CSMReadValue(session, generation, actor + 0x18, &nameIndex)) return nil;
            observedNames.push_back(nameIndex);
            uint64_t type = 0;
            if (includeMetroArmor &&
                (!CSMReadValue(session, generation, actor + 0x10, &type) ||
                 !CSMAddress(type, 0x38))) return nil;
            observedTypes.push_back(type);
            NameMatch nameMatch = {-1, {}, false};
            auto found = nameMatches.find(nameIndex);
            if (found != nameMatches.end()) nameMatch = found->second;
            else {
                if (nameMatches.size() >= 8192) return nil;
                std::string name;
                auto status = CoreSet::readMaterialBaseName(read, actor, pool, &name, base);
                if (status == CoreSet::NameReadStatus::readFailure) return nil;
                if (status == CoreSet::NameReadStatus::ok) {
                    size_t index = CoreSet::firstMaterialMatch(name, keys.data(), keys.size());
                    if (index < keys.size()) {
                        nameMatch.record = int(index);
                        nameMatch.escapeBox = name.find("EscapeBox") != std::string::npos;
                        if (includeCrateLevel)
                            nameMatch.level = CoreSet::escapeBoxLevelLabel(name);
                    }
                }
                nameMatches.emplace(nameIndex, nameMatch);
            }
            int match = nameMatch.record;
            if (includeMetroArmor) {
                CSMMetroObservation metro = {};
                if (!CSMMetro(session, generation, actor, type, characterClass, &metro)) return nil;
                if (metro.characterType && metro.hasSlots &&
                    std::isfinite(metro.health) && std::isfinite(metro.healthMax) &&
                    metro.health > 0 && metro.healthMax > 0 && metro.health <= metro.healthMax) {
                    const char *head = CoreSet::metroHeadLabel(metro.headID);
                    const char *armor = CoreSet::metroArmorLabel(metro.armorID);
                    if (head || armor) {
                        CoreSet::Vec3 metroPosition = {};
                        bool metroPositionPresent = false;
                        if (!CSMPosition(session, generation, base, actor, &metroPosition,
                                         &metroPositionPresent)) return nil;
                        CoreSet::Point projected = {};
                        if (metroPositionPresent &&
                            CoreSet::project(camera, metroPosition, size.width, size.height, &projected) &&
                            projected.x >= 0 && projected.y >= 0 &&
                            projected.x <= size.width && projected.y <= size.height) {
                            if (metroMarks.count >= CSMMaxMarks) return nil;
                            CoreSetMetroArmorMark *metroMark = [CoreSetMetroArmorMark new];
                            metroMark.point = CGPointMake(projected.x, projected.y);
                            if (head) metroMark.headLabel = [NSString stringWithUTF8String:head];
                            if (armor) metroMark.armorLabel = [NSString stringWithUTF8String:armor];
                            if ((head && !metroMark.headLabel) || (armor && !metroMark.armorLabel)) return nil;
                            [metroMarks addObject:metroMark];
                            observedMetro.push_back({actor, type, metroPosition, metro});
                        }
                    }
                }
            }
            if (match < 0) continue;
            if (!includeMetroArmor &&
                (!CSMReadValue(session, generation, actor + 0x10, &type) ||
                 !CSMAddress(type, 0x38))) return nil;
            CSMChildrenArray children = {};
            if (includeHideOpenedCrates && match >= 106 && match < 145 &&
                nameMatch.escapeBox && !CSMChildren(session, generation, actor, &children)) return nil;
            CSMVehicleObservation vehicle = {};
            if (includeVehicleStatus && match >= 29 && match < 77 &&
                !CSMVehicle(session, generation, actor, type, vehicleClass,
                            componentClass, &vehicle)) return nil;
            CoreSet::Vec3 position = {};
            bool hasPosition = false;
            if (!CSMPosition(session, generation, base, actor, &position, &hasPosition)) return nil;
            if (!hasPosition) continue;
            double dx = double(position.x) - localPosition.x;
            double dy = double(position.y) - localPosition.y;
            double dz = double(position.z) - localPosition.z;
            double distance = std::sqrt(dx * dx + dy * dy + dz * dz) / 100.0;
            CoreSet::Point point = {};
            if (!std::isfinite(distance) ||
                !CoreSet::project(camera, position, size.width, size.height, &point) ||
                point.x < 0 || point.y < 0 || point.x > size.width || point.y > size.height) continue;
            if (marks.count >= CSMMaxMarks) return nil;
            CoreSetMaterialMark *mark = [CoreSetMaterialMark new];
            mark.recordIndex = match; mark.point = CGPointMake(point.x, point.y);
            mark.distanceUnitsDividedBy100 = distance;
            if (!nameMatch.level.empty()) {
                mark.crateLevelLabel = [NSString stringWithUTF8String:nameMatch.level.c_str()];
                if (!mark.crateLevelLabel) return nil;
            }
            if (includeHideOpenedCrates && match >= 106 && match < 145 && nameMatch.escapeBox)
                mark.escapeBoxChildrenCount = @(children.count);
            if (vehicle.component && vehicle.componentType) {
                CoreSet::VehiclePercent hp = CoreSet::vehiclePercent(vehicle.hp, vehicle.hpMax, true);
                CoreSet::VehiclePercent fuel = CoreSet::vehiclePercent(vehicle.fuel, vehicle.fuelMax, false);
                if (hp.valid) mark.vehicleHPPercent = @(hp.value);
                if (fuel.valid) mark.vehicleFuelPercent = @(fuel.value);
            }
            [marks addObject:mark];
            observedMarks.push_back({actor, nameIndex, type, position, size_t(match), nameMatch.level,
                                     nameMatch.escapeBox, children, vehicle});
        }
    }
    uint64_t worldAfter = 0, poolAfter = 0, levelAfter = 0, clusterAfter = 0;
    uint64_t controllerAfter = 0, localAfter = 0, managerAfter = 0;
    uint32_t nameCountAfter = 0;
    decltype(actors) actorsAfter = {0};
    CoreSet::Camera cameraAfter = {};
    CoreSet::Vec3 localAfterPosition = {};
    bool localAfterPresent = false;
    uint64_t localWeaponAfter = 0;
    uint32_t localWeaponIDAfter = 0;
    uint64_t vehicleClassAfter = 0, componentClassAfter = 0, characterClassAfter = 0;
    if (!CSMReadValue(session, generation, base + CSMWorldSlot, &worldAfter) || worldAfter != world ||
        !CSMReadValue(session, generation, base + CSMNamePoolSlot, &poolAfter) || poolAfter != pool ||
        !CSMReadValue(session, generation, pool + 0x1400, &nameCountAfter) || nameCountAfter != nameCount ||
        !CSMReadValue(session, generation, world + 0xb8, &levelAfter) || levelAfter != level ||
        !CSMReadValue(session, generation, level + 0xe0, &clusterAfter) || clusterAfter != cluster ||
        !CSMRead(session, generation, cluster + 0x28, &actorsAfter, sizeof(actorsAfter)) ||
        std::memcmp(&actors, &actorsAfter, sizeof(actors)) != 0 ||
        !CSMReadValue(session, generation, connection + 0x30, &controllerAfter) || controllerAfter != controller ||
        !CSMReadValue(session, generation, controller + 0x3540, &localAfter) || localAfter != local ||
        !CSMReadValue(session, generation, controller + 0x680, &managerAfter) || managerAfter != manager ||
        !CSMRead(session, generation, manager + cameraOffset, &cameraAfter, sizeof(cameraAfter)) ||
        std::memcmp(&camera, &cameraAfter, sizeof(camera)) != 0 ||
        !CSMPosition(session, generation, base, local, &localAfterPosition, &localAfterPresent) ||
        !localAfterPresent || std::memcmp(&localPosition, &localAfterPosition, sizeof(localPosition)) != 0 ||
        (includeArmedState &&
         (!CSMLocalWeapon(session, generation, local, &localWeaponAfter, &localWeaponIDAfter) ||
          localWeaponAfter != localWeapon || localWeaponIDAfter != localWeaponID)) ||
        (includeVehicleStatus &&
         (!CSMReadValue(session, generation, base + CSMVehicleClassSlot, &vehicleClassAfter) ||
          vehicleClassAfter != vehicleClass ||
          !CSMReadValue(session, generation, base + CSMVehicleComponentClassSlot,
                        &componentClassAfter) || componentClassAfter != componentClass)) ||
        (includeMetroArmor &&
         (!CSMReadValue(session, generation, base + CSMCharacterClassSlot,
                        &characterClassAfter) || characterClassAfter != characterClass)) ||
        !session.ready || session.generation != generation || session.processID != pid ||
        session.imageBase != base) return nil;
    for (int32_t start = 0; start < actors.count; start += 512) {
        int32_t batch = std::min<int32_t>(512, actors.count - start);
        if (!CSMRead(session, generation, actors.data + uint64_t(start) * 8,
                     batchPointers, size_t(batch) * 8) ||
            std::memcmp(batchPointers, observedPointers.data() + start, size_t(batch) * 8) != 0) return nil;
        for (int32_t i = 0; i < batch; ++i) {
            uint64_t actor = batchPointers[i];
            if (!actor || actor == local) continue;
            uint32_t nameIndex = 0;
            if (!CSMReadValue(session, generation, actor + 0x18, &nameIndex) ||
                nameIndex != observedNames[size_t(start + i)]) return nil;
            if (includeMetroArmor) {
                uint64_t type = 0;
                if (!CSMReadValue(session, generation, actor + 0x10, &type) ||
                    type != observedTypes[size_t(start + i)]) return nil;
            }
        }
    }
    for (const Observed &item : observedMarks) {
        uint64_t type = 0;
        CoreSet::Vec3 position = {};
        bool hasPosition = false;
        std::string name;
        CSMVehicleObservation vehicleAfter = {};
        CSMChildrenArray childrenAfter = {};
        if (!CSMReadValue(session, generation, item.address + 0x10, &type) || type != item.type ||
            !CSMPosition(session, generation, base, item.address, &position, &hasPosition) ||
            !hasPosition || std::memcmp(&position, &item.position, sizeof(position)) != 0 ||
            CoreSet::readMaterialBaseName(read, item.address, pool, &name, base) != CoreSet::NameReadStatus::ok ||
            CoreSet::firstMaterialMatch(name, keys.data(), keys.size()) != item.record ||
            (includeCrateLevel && CoreSet::escapeBoxLevelLabel(name) != item.level) ||
            (includeHideOpenedCrates && item.record >= 106 && item.record < 145 &&
             ((name.find("EscapeBox") != std::string::npos) != item.escapeBox ||
              (item.escapeBox &&
               (!CSMChildren(session, generation, item.address, &childrenAfter) ||
                std::memcmp(&childrenAfter, &item.children, sizeof(childrenAfter)) != 0)))) ||
            (includeVehicleStatus && item.record >= 29 && item.record < 77 &&
             (!CSMVehicle(session, generation, item.address, type, vehicleClass,
                          componentClass, &vehicleAfter) ||
              vehicleAfter.component != item.vehicle.component ||
              vehicleAfter.vehicleType != item.vehicle.vehicleType ||
              vehicleAfter.componentType != item.vehicle.componentType ||
              vehicleAfter.hpMax != item.vehicle.hpMax || vehicleAfter.hp != item.vehicle.hp ||
              vehicleAfter.fuelMax != item.vehicle.fuelMax ||
              vehicleAfter.fuel != item.vehicle.fuel))) return nil;
    }
    for (const ObservedMetro &item : observedMetro) {
        CSMMetroObservation now = {};
        CoreSet::Vec3 position = {};
        bool positionPresent = false;
        uint64_t type = 0;
        if (!CSMReadValue(session, generation, item.address + 0x10, &type) || type != item.type ||
            !CSMMetro(session, generation, item.address, type, characterClass, &now) ||
            !now.characterType || !now.hasSlots ||
            std::memcmp(&now.array, &item.data.array, sizeof(now.array)) != 0 ||
            now.health != item.data.health || now.healthMax != item.data.healthMax ||
            now.headID != item.data.headID || now.armorID != item.data.armorID ||
            !CSMPosition(session, generation, base, item.address, &position, &positionPresent) ||
            !positionPresent || std::memcmp(&position, &item.position, sizeof(position)) != 0) return nil;
    }
    CoreSetMaterialSnapshot *snapshot = [CoreSetMaterialSnapshot new];
    snapshot.sessionGeneration = generation; snapshot.processID = pid;
    snapshot.imageBase = base; snapshot.snapshotID = [NSUUID UUID];
    snapshot.localWeaponID = localWeaponID;
    snapshot.marks = [marks copy];
    snapshot.metroMarks = [metroMarks copy];
    return snapshot;
}
@end
