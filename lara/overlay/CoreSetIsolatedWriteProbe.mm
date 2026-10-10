#import "CoreSetIsolatedWriteProbe.h"
#import <QuartzCore/QuartzCore.h>
#include "CoreSetSerialActionGate.h"
#include "CoreSetActionCompensationState.h"
#include "CoreSetActionCyclePlan.h"
#include "CoreSetActionSelectionState.h"
#include "CoreSetActionRouteState.h"
#include "CoreSetAimDeltaPlan.h"
#include "CoreSetPlayerProjection.h"
#include "CoreSetRecoilStateMachine.h"
#include <atomic>
#include <cmath>
#include <cfloat>
#include <climits>
#include <cstring>

static char CSProbeQueueKey;
namespace {
class CSAimDropoutHold {
public:
    void reset() { actor_ = generation_ = 0; lastSeconds_ = -1; point_ = {}; }
    bool publish(uint64_t actor, uint64_t generation, CoreSet::AimWorldPoint point, double now) {
        if (!actor || !generation || !std::isfinite(point.x) || !std::isfinite(point.y) ||
            !std::isfinite(point.z) || !std::isfinite(now) || now < 0) { reset(); return false; }
        actor_ = actor; generation_ = generation; point_ = point; lastSeconds_ = now; return true;
    }
    bool reuse(uint64_t generation, double now, bool stateClear,
               uint64_t *actor, CoreSet::AimWorldPoint *point) const {
        if (!actor || !point || !stateClear || !actor_ || generation != generation_ ||
            !std::isfinite(now) || now < lastSeconds_ || now - lastSeconds_ > 0.075000001) return false;
        *actor = actor_; *point = point_; return true;
    }
private:
    uint64_t actor_ = 0, generation_ = 0;
    double lastSeconds_ = -1;
    CoreSet::AimWorldPoint point_{};
};
}
@interface CoreSetBasicAimTriggerState () {
    CoreSet::ActionTriggerLatch _latch;
    CoreSet::ActionTriggerObservation _last;
}
@end
@interface CoreSetBasicAimDelta ()
@property(nonatomic) float pitch;
@property(nonatomic) float yaw;
@property(nonatomic) float aimPitch;
@property(nonatomic) float aimYaw;
@property(nonatomic) float recoilPitch;
@property(nonatomic) float recoilYaw;
@property(nonatomic) uint64_t geometrySampleKey;
@property(nonatomic, strong, nullable) CoreSetWorldPoint *predictedWorldPoint;
@end
@implementation CoreSetBasicAimTriggerState
- (void)reset { _latch.reset(); _last = {}; }
- (BOOL)updateMode:(NSInteger)mode ads:(BOOL)ads firing:(BOOL)firing now:(double)now {
    if (mode < 0 || mode > 3) { [self reset]; return NO; }
    return _latch.observe(true, static_cast<CoreSet::AimTrigger>(mode), ads ? 1 : 0,
                          firing ? 1 : 0, now, &_last) && _last.aimActive;
}
- (BOOL)permitsAt:(double)now {
    return std::isfinite(now) && now >= 0 && now < _last.deadlineSeconds;
}
@end
@implementation CoreSetBasicAimDelta
+ (double)circleRadiusForCanvasWidth:(double)width height:(double)height size:(NSInteger)size {
    if (size < INT_MIN || size > INT_MAX) return 0;
    return CoreSet::aimCircleRadius(width, height, (int)size);
}
+ (CoreSetPlayerMark *)selectFromSnapshot:(CoreSetPlayerSnapshot *)snapshot point:(NSInteger)point
    radius:(double)radius maximumDistance:(double)maximumDistance includeBots:(BOOL)includeBots
    excludeKnocked:(BOOL)excludeKnocked
    lockSameTarget:(BOOL)lockSameTarget previousActor:(uint64_t)previousActor {
    if (!snapshot.battleInputsPresent || !snapshot.cameraWorldPosition || point < 0 || point > 2) return nil;
    CoreSet::Camera camera{};
    camera.location = {snapshot.cameraWorldPosition.x, snapshot.cameraWorldPosition.y, snapshot.cameraWorldPosition.z};
    camera.rotation = {(float)snapshot.cameraPitchDegrees, (float)snapshot.cameraYawDegrees,
                       (float)snapshot.cameraRollDegrees};
    camera.fov = (float)snapshot.cameraFieldOfViewDegrees;
    CoreSetPlayerMark *ordinary = nil;
    CoreSetPlayerMark *sticky = nil;
    float bestPixels = FLT_MAX;
    for (CoreSetPlayerMark *mark in snapshot.marks) {
        CoreSetWorldPoint *target = [self fallbackTargetForMark:mark point:point];
        const uint8_t bone58 = mark.referenceAnchor1e0WorldPosition &&
            mark.referenceAnchor1ecWorldPosition ? 1 : 0;
        CoreSet::ActionReferenceActorGate gate{mark.referenceStateWord, mark.referenceFlag14,
            (uint8_t)(mark.bot ? 1 : 0), bone58, mark.health,
            (float)mark.distanceUnitsDividedBy100, (int)maximumDistance, includeBots, excludeKnocked};
        if (!target || !CoreSet::referenceActionActorEligible(gate)) continue;
        CoreSet::Point screen{};
        if (!CoreSet::project(camera, {target.x, target.y, target.z}, snapshot.canvasSize.width,
                              snapshot.canvasSize.height, &screen)) continue;
        const auto rank = CoreSet::referenceActionScreenRank(screen.x, screen.y,
            snapshot.canvasSize.width, snapshot.canvasSize.height, (float)radius, bestPixels,
            lockSameTarget, previousActor, mark.actorAddress);
        if (rank.stickyMatched) sticky = mark;
        if (rank.ordinaryUpdated) { ordinary = mark; bestPixels = rank.bestPixels; }
    }
    return sticky ?: ordinary;
}
+ (CoreSetPlayerMark *)selectFromSnapshot:(CoreSetPlayerSnapshot *)snapshot
    radius:(double)radius maximumDistance:(double)maximumDistance includeBots:(BOOL)includeBots
    lockSameTarget:(BOOL)lockSameTarget previousActor:(uint64_t)previousActor {
    return [self selectFromSnapshot:snapshot point:0 radius:radius maximumDistance:maximumDistance
        includeBots:includeBots excludeKnocked:NO lockSameTarget:lockSameTarget
        previousActor:previousActor];
}
+ (CoreSetPlayerMark *)selectFromSnapshot:(CoreSetPlayerSnapshot *)snapshot
    radius:(double)radius maximumDistance:(double)maximumDistance includeBots:(BOOL)includeBots {
    return [self selectFromSnapshot:snapshot point:0 radius:radius maximumDistance:maximumDistance
        includeBots:includeBots excludeKnocked:NO lockSameTarget:NO previousActor:0];
}
+ (CoreSetWorldPoint *)fallbackTargetForMark:(CoreSetPlayerMark *)mark point:(NSInteger)point {
    if (!mark.actorWorldPosition || point < 0 || point > 2) return nil;
    CoreSet::AimWorldPoint root{mark.actorWorldPosition.x, mark.actorWorldPosition.y,
                                mark.actorWorldPosition.z};
    CoreSet::AimWorldPoint anchor1e0{}, anchor1ec{}, result{};
    const bool bones = mark.referenceAnchor1e0WorldPosition && mark.referenceAnchor1ecWorldPosition;
    if (bones) {
        anchor1e0 = {mark.referenceAnchor1e0WorldPosition.x,
                     mark.referenceAnchor1e0WorldPosition.y,
                     mark.referenceAnchor1e0WorldPosition.z};
        anchor1ec = {mark.referenceAnchor1ecWorldPosition.x,
                     mark.referenceAnchor1ecWorldPosition.y,
                     mark.referenceAnchor1ecWorldPosition.z};
    }
    if (!CoreSet::referenceActionWorldPoint((int)point, bones ? 1 : 0, root,
                                             anchor1e0, anchor1ec, &result)) return nil;
    return [CoreSetWorldPoint pointWithX:result.x y:result.y z:result.z];
}
@end

@interface CoreSetV17AimConfiguration ()
@property(nonatomic) NSInteger maximumDistance;
@property(nonatomic) float lockThreshold;
@property(nonatomic) NSInteger confirmationFrames;
@property(nonatomic) double takeoverPauseSeconds;
@property(nonatomic) float strength;
@property(nonatomic) float smoothingSeconds;
@property(nonatomic) float horizontalSpeed;
@property(nonatomic) float verticalSpeed;
@property(nonatomic) double predictionMilliseconds;
@property(nonatomic) float residualGain;
@property(nonatomic) float minimumGain;
@property(nonatomic) float deadzoneRatio;
@property(nonatomic) float minimumDeadzone;
@end

@implementation CoreSetV17AimConfiguration
- (instancetype)initWithStoredScene:(NSInteger)storedScene
                  storedLockStrength:(NSInteger)storedLockStrength
                 customValuesPresent:(BOOL)customValuesPresent
               customMaximumDistance:(NSInteger)customMaximumDistance
                      customStrength:(NSInteger)customStrength
                     customSmoothing:(NSInteger)customSmoothing
            customConfirmationFrames:(NSInteger)customConfirmationFrames
               customHorizontalSpeed:(NSInteger)customHorizontalSpeed
                 customVerticalSpeed:(NSInteger)customVerticalSpeed
        customPredictionMilliseconds:(NSInteger)customPredictionMilliseconds
                 customLockThreshold:(NSInteger)customLockThreshold
   customTakeoverPauseMilliseconds:(NSInteger)customTakeoverPauseMilliseconds {
    const NSInteger values[] = {storedScene, storedLockStrength, customMaximumDistance,
        customStrength, customSmoothing, customConfirmationFrames, customHorizontalSpeed,
        customVerticalSpeed, customPredictionMilliseconds, customLockThreshold,
        customTakeoverPauseMilliseconds};
    for (NSInteger value : values) if (value < INT_MIN || value > INT_MAX) return nil;
    CoreSet::ActionCustomSceneInput custom;
    custom.allNinePresent = customValuesPresent;
    custom.maximumDistance = (int)customMaximumDistance;
    custom.strength = (int)customStrength;
    custom.smoothing = (int)customSmoothing;
    custom.confirmationFrames = (int)customConfirmationFrames;
    custom.horizontalSpeed = (int)customHorizontalSpeed;
    custom.verticalSpeed = (int)customVerticalSpeed;
    custom.predictionMilliseconds = (int)customPredictionMilliseconds;
    custom.lockThreshold = (int)customLockThreshold;
    custom.pauseMilliseconds = (int)customTakeoverPauseMilliseconds;
    CoreSet::ActionScenePlan plan;
    CoreSet::AimSceneCompensationValues compensation;
    if (!CoreSet::planActionScene((int)storedScene, (int)storedLockStrength, custom, &plan) ||
        !CoreSet::aimSceneCompensationValues((int)storedScene, &compensation)) return nil;
    if ((self = [super init])) {
        _maximumDistance = plan.scene.maximumDistance;
        _lockThreshold = (float)plan.tuning.lockThreshold01;
        _confirmationFrames = plan.lock.confirmationFrames;
        _takeoverPauseSeconds = plan.lock.pauseMilliseconds / 1000.0;
        _strength = (float)plan.tuning.strength01;
        _smoothingSeconds = (float)plan.tuning.smoothingStep;
        _horizontalSpeed = (float)plan.tuning.horizontalDegreesPerSecond;
        _verticalSpeed = (float)plan.tuning.verticalDegreesPerSecond;
        _predictionMilliseconds = plan.tuning.predictionMilliseconds;
        _residualGain = compensation.residualGain;
        _minimumGain = compensation.minimumGain;
        _deadzoneRatio = compensation.deadzoneRatio;
        _minimumDeadzone = compensation.minimumDeadzone;
    }
    return self;
}
@end

@interface CoreSetV17AimDynamics () {
    CoreSet::ActionCandidateMotionState _motion;
    CoreSet::ActionGeometryClockState _geometry;
    CSAimDropoutHold _dropout;
}
@end
@implementation CoreSetV17AimDynamics
- (void)reset { _motion = {}; _geometry = {}; _dropout.reset(); }
- (BOOL)rememberTarget:(CoreSetWorldPoint *)target actor:(uint64_t)actor
    generation:(uint64_t)generation now:(double)now {
    return target && _dropout.publish(actor, generation, {target.x, target.y, target.z}, now);
}
- (CoreSetWorldPoint *)cachedTargetForGeneration:(uint64_t)generation
    now:(double)now stateClear:(BOOL)stateClear {
    uint64_t actor = 0; CoreSet::AimWorldPoint point{};
    if (!_dropout.reuse(generation, now, stateClear, &actor, &point)) return nil;
    return [CoreSetWorldPoint pointWithX:point.x y:point.y z:point.z];
}
- (BOOL)permitsTakeoverPitch:(float)pitch yaw:(float)yaw
    configuration:(CoreSetV17AimConfiguration *)configuration now:(double)now {
    if (!configuration) return NO;
    // Compatibility helper for older callers. The production route owner is
    // CoreSetV17ActionRouteProducer below.
    CoreSet::ActionTakeoverState state;
    CoreSet::ActionTakeoverObservation observed;
    const float magnitude = std::hypot(pitch, yaw);
    return CoreSet::referenceActionTakeover(state, true, false, magnitude,
        configuration.lockThreshold, (int)configuration.confirmationFrames,
        (int)std::lround(configuration.takeoverPauseSeconds * 1000.0), now, &observed) &&
        observed.aimAllowed && observed.mergePredecessor == CoreSet::ActionMergePredecessor::inputDirect;
}
- (CoreSetBasicAimDelta *)planFromCamera:(CoreSetWorldPoint *)camera
    target:(CoreSetWorldPoint *)target actor:(uint64_t)actor publicationID:(NSUUID *)publicationID
    now:(double)now currentPitch:(float)currentPitch currentYaw:(float)currentYaw
    configuration:(CoreSetV17AimConfiguration *)configuration {
    if (!camera || !target || !publicationID || !configuration ||
        !std::isfinite(now) || now < 0) return nil;
    uuid_t bytes{}; [publicationID getUUIDBytes:bytes];
    uint64_t first = 0, second = 0;
    std::memcpy(&first, bytes, sizeof(first));
    std::memcpy(&second, bytes + sizeof(first), sizeof(second));
    const uint64_t publication = (first ^ second) ?: 1;
    const CoreSet::AimWorldPoint targetPoint{target.x, target.y, target.z};
    const CoreSet::AimWorldPoint cameraPoint{camera.x, camera.y, camera.z};
    if (!CoreSet::referenceActionCandidateMotion(_motion, actor, publication, now,
                                                  targetPoint, cameraPoint)) return nil;
    CoreSet::ActionGeometryInput input;
    input.key = actor;
    input.monotonicNanoseconds = (uint64_t)std::llround(now * 1000000000.0);
    input.camera = {camera.x, camera.y, camera.z};
    input.target = {target.x, target.y, target.z};
    input.relativeVelocity = {_motion.relativeVelocity.x, _motion.relativeVelocity.y,
                              _motion.relativeVelocity.z};
    input.velocityPresent = _motion.velocityPresent;
    input.currentAngles = {currentYaw, currentPitch};
    CoreSet::ActionGeometryTuning tuning;
    tuning.compensation = {configuration.strength, configuration.smoothingSeconds,
        configuration.lockThreshold, {configuration.horizontalSpeed, configuration.verticalSpeed},
        configuration.residualGain, configuration.minimumGain};
    tuning.predictionMilliseconds = (float)configuration.predictionMilliseconds;
    tuning.deadzoneRatio = configuration.deadzoneRatio;
    tuning.minimumDeadzone = configuration.minimumDeadzone;
    CoreSet::ActionGeometryObservation observed;
    if (!CoreSet::referenceActionGeometry(_geometry, input, tuning, &observed) || !observed.valid) return nil;
    uint64_t sampleKey = 0;
    std::memcpy(&sampleKey, observed.numerical.data(), sizeof(sampleKey));
    CoreSetBasicAimDelta *result = [CoreSetBasicAimDelta new];
    result.pitch = observed.numerical[5]; result.yaw = observed.numerical[4];
    result.geometrySampleKey = sampleKey;
    if (configuration.predictionMilliseconds >= 1.0 &&
        std::isfinite(observed.numerical[11]) &&
        std::isfinite(observed.numerical[12]) &&
        std::isfinite(observed.numerical[13])) {
        // Native c4af8 publishes its compensated point from result
        // +0x38/+0x3c/+0x40; ActionGeometryObservation preserves those exact
        // slots as numerical[11...13].
        result.predictedWorldPoint = [CoreSetWorldPoint
            pointWithX:observed.numerical[11]
            y:observed.numerical[12]
            z:observed.numerical[13]];
    }
    return result;
}
- (CoreSetBasicAimDelta *)planCandidate:(CoreSetActionCandidateRecord *)candidate
    input:(CoreSetActionInputAuthority *)input
    configuration:(CoreSetV17AimConfiguration *)configuration {
    if (!candidate || !input || !configuration || !candidate.raw.valid ||
        !candidate.raw.candidateKey || !candidate.raw.publicationSerial ||
        candidate.sessionGeneration != input.sessionGeneration ||
        candidate.processID != input.processID || candidate.imageBase != input.imageBase ||
        candidate.controllerAddress != input.controllerAddress ||
        ![candidate.snapshotID isEqual:input.snapshotID]) return nil;
    const auto raw = candidate.raw;
    const double now = input.captureCompletedMonotonicSeconds;
    const CoreSet::AimWorldPoint target{raw.target[0], raw.target[1], raw.target[2]};
    const CoreSet::AimWorldPoint camera{raw.camera[0], raw.camera[1], raw.camera[2]};
    if (!CoreSet::referenceActionCandidateMotion(_motion, raw.candidateKey,
            raw.publicationSerial, now, target, camera)) return nil;
    CoreSet::ActionGeometryInput geometry;
    geometry.key = raw.candidateKey;
    geometry.monotonicNanoseconds = (uint64_t)std::llround(now * 1000000000.0);
    geometry.camera = {camera.x, camera.y, camera.z};
    geometry.target = {target.x, target.y, target.z};
    geometry.relativeVelocity = {_motion.relativeVelocity.x, _motion.relativeVelocity.y,
                                 _motion.relativeVelocity.z};
    geometry.velocityPresent = _motion.velocityPresent;
    geometry.currentAngles = {input.controlYawDegrees, input.controlPitchDegrees};
    CoreSet::ActionGeometryTuning tuning;
    tuning.compensation = {configuration.strength, configuration.smoothingSeconds,
        configuration.lockThreshold, {configuration.horizontalSpeed, configuration.verticalSpeed},
        configuration.residualGain, configuration.minimumGain};
    tuning.predictionMilliseconds = (float)configuration.predictionMilliseconds;
    tuning.deadzoneRatio = configuration.deadzoneRatio;
    tuning.minimumDeadzone = configuration.minimumDeadzone;
    CoreSet::ActionGeometryObservation observed;
    if (!CoreSet::referenceActionGeometry(_geometry, geometry, tuning, &observed) || !observed.valid) return nil;
    uint64_t sampleKey = 0;
    std::memcpy(&sampleKey, observed.numerical.data(), sizeof(sampleKey));
    CoreSetBasicAimDelta *result = [CoreSetBasicAimDelta new];
    result.pitch = observed.numerical[5]; result.yaw = observed.numerical[4];
    result.geometrySampleKey = sampleKey;
    if (configuration.predictionMilliseconds >= 1.0 &&
        std::isfinite(observed.numerical[11]) && std::isfinite(observed.numerical[12]) &&
        std::isfinite(observed.numerical[13])) {
        result.predictedWorldPoint = [CoreSetWorldPoint pointWithX:observed.numerical[11]
            y:observed.numerical[12] z:observed.numerical[13]];
    }
    return result;
}
@end

@interface CoreSetV17ActionRouteDecision ()
@property(nonatomic) BOOL resolved;
@property(nonatomic) BOOL aimAllowed;
@property(nonatomic) NSInteger slotRaw;
@property(nonatomic) NSInteger predecessorRaw;
@end
@implementation CoreSetV17ActionRouteDecision @end

@interface CoreSetV17ActionRouteProducer () {
    CoreSet::NativeActionRouteProducer _producer;
}
@end
@implementation CoreSetV17ActionRouteProducer
- (BOOL)originalProviderBound { return NO; }
- (NSString *)unresolvedReason {
    return @"Core 原始 upstream predicate / c5ad8 byte1 / w20 provider 未绑定，动作路由不可用";
}
- (void)reset { _producer.reset(); }
- (CoreSetV17ActionRouteDecision *)decision:(CoreSet::NativeActionRouteDecision)route {
    if (!route.resolved) return nil;
    CoreSetV17ActionRouteDecision *decision = [CoreSetV17ActionRouteDecision new];
    decision.resolved = true;
    decision.aimAllowed = route.takeover.aimAllowed;
    decision.slotRaw = route.slot == CoreSet::TargetActionSlot::controlRotation ? 1 : 2;
    decision.predecessorRaw = (NSInteger)route.takeover.mergePredecessor;
    return decision;
}
- (BOOL)readNativeInput:(const CoreSetNativeActionRouteInputRecord *)source
                  into:(CoreSet::NativeActionRouteInput *)input {
    if (!source || !input || source->present != 1 || source->currentAimActive > 1 ||
        source->forceInput > 1 || source->recoilEnabled > 1 || source->w20 > 1 ||
        source->resultGate > 1 || source->lifecycle > 4) return NO;
    *input = {true, source->cycle, source->currentAimActive != 0,
        source->forceInput != 0, source->recoilEnabled != 0, source->w20 != 0,
        static_cast<CoreSet::RouteResultGate>(source->resultGate),
        static_cast<CoreSet::RouteLifecycleEvent>(source->lifecycle),
        source->configID27Value};
    return YES;
}
- (CoreSetV17ActionRouteDecision *)resolveAimPitch:(float)pitch yaw:(float)yaw
    configuration:(CoreSetV17AimConfiguration *)configuration now:(double)now
    nativeInput:(const CoreSetNativeActionRouteInputRecord *)nativeInput {
    CoreSet::NativeActionRouteInput native;
    if (!configuration || ![self readNativeInput:nativeInput into:&native]) return nil;
    CoreSet::NativeActionRouteDecision route;
    const float magnitude = std::hypot(pitch, yaw);
    if (!_producer.resolve(native, magnitude,
        configuration.lockThreshold, (int)configuration.confirmationFrames,
        (int)std::lround(configuration.takeoverPauseSeconds * 1000.0), now, &route)) return nil;
    return [self decision:route];
}
- (CoreSetV17ActionRouteDecision *)resolveRecoilOnlyWithNativeInput:
    (const CoreSetNativeActionRouteInputRecord *)nativeInput {
    // Its original predecessor remains an upstream observation, not a constant.
    // Recoil-only has no active Aim takeover; its scalar tuning is irrelevant.
    CoreSet::NativeActionRouteInput native;
    if (![self readNativeInput:nativeInput into:&native] || native.currentAimActive) return nil;
    CoreSet::NativeActionRouteDecision route;
    if (!_producer.resolveInactive(native, &route)) return nil;
    return [self decision:route];
}
- (BOOL)observeNativeFeedback:(const CoreSetNativeActionRouteFeedbackRecord *)feedback {
    if (!feedback || feedback->present != 1 || feedback->w20 > 1 || feedback->resultGate > 1) return NO;
    CoreSet::NativeActionRouteFeedback native{true, feedback->cycle,
        feedback->packedStatus, feedback->w20 != 0,
        static_cast<CoreSet::RouteResultGate>(feedback->resultGate)};
    return _producer.observeNativeFeedback(native);
}
@end

@interface CoreSetV17ActionDelta ()
@property(nonatomic) float pitch;
@property(nonatomic) float yaw;
@property(nonatomic) float aimPitch;
@property(nonatomic) float aimYaw;
@property(nonatomic) float recoilPitch;
@property(nonatomic) float recoilYaw;
@end
@implementation CoreSetV17ActionDelta @end

@interface CoreSetV17RecoilConfiguration ()
@property(nonatomic) BOOL verticalEnabled;
@property(nonatomic) float verticalStrength;
@property(nonatomic) BOOL stopWhenNotFiring;
@property(nonatomic) BOOL horizontalEnabled;
@property(nonatomic) float horizontalStrength;
@end

@implementation CoreSetV17RecoilConfiguration
- (instancetype)initWithEnabled:(BOOL)enabled
                 verticalEnabled:(BOOL)verticalEnabled
          verticalStrengthPercent:(NSInteger)verticalStrengthPercent
               stopWhenNotFiring:(BOOL)stopWhenNotFiring
               horizontalEnabled:(BOOL)horizontalEnabled
        horizontalStrengthPercent:(NSInteger)horizontalStrengthPercent {
    if (verticalStrengthPercent < INT_MIN || verticalStrengthPercent > INT_MAX ||
        horizontalStrengthPercent < INT_MIN || horizontalStrengthPercent > INT_MAX) return nil;
    CoreSet::RecoilConfiguration configuration;
    if (!CoreSet::planRecoilConfiguration(enabled, verticalEnabled,
            (int)verticalStrengthPercent, stopWhenNotFiring, horizontalEnabled,
            (int)horizontalStrengthPercent, &configuration)) return nil;
    if ((self = [super init])) {
        _verticalEnabled = configuration.verticalEnabled;
        _verticalStrength = configuration.verticalStrength;
        _stopWhenNotFiring = configuration.stopWhenNotFiring;
        _horizontalEnabled = configuration.horizontalEnabled;
        _horizontalStrength = configuration.horizontalStrength;
    }
    return self;
}
@end

@interface CoreSetV17RecoilDynamics () {
    CoreSet::ActionPostState _post;
    CoreSet::RecoilRawState _raw;
    uint64_t _previousGeometrySampleKey;
    float _previousControlPitch;
    float _priorAimPitch;
    bool _previousControlPresent;
}
@end

@implementation CoreSetV17RecoilDynamics
- (void)reset {
    _post = {};
    _raw = {};
    _previousGeometrySampleKey = 0;
    _previousControlPitch = 0;
    _priorAimPitch = 0;
    _previousControlPresent = false;
}
- (CoreSetV17ActionDelta *)planSnapshot:(CoreSetPlayerSnapshot *)snapshot
    aimPitch:(float)aimPitch aimYaw:(float)aimYaw geometrySampleKey:(uint64_t)geometrySampleKey
    configuration:(CoreSetV17RecoilConfiguration *)configuration {
    const BOOL verticalEnabled = configuration.verticalEnabled;
    const float verticalStrength = configuration.verticalStrength;
    const BOOL stopWhenNotFiring = configuration ? configuration.stopWhenNotFiring : YES;
    const BOOL horizontalEnabled = configuration.horizontalEnabled;
    const float horizontalStrength = configuration.horizontalStrength;
    if (!snapshot.battleInputsPresent ||
        !std::isfinite(aimPitch) || !std::isfinite(aimYaw) ||
        !std::isfinite(verticalStrength) || verticalStrength < 0 || verticalStrength > 1 ||
        !std::isfinite(horizontalStrength) || horizontalStrength < 0 || horizontalStrength > 1)
        return nil;
    const auto finish = [&](float recoilPitch, float recoilYaw) -> CoreSetV17ActionDelta * {
        CoreSet::AimDeltaPlan merged;
        const bool mergedOK = CoreSet::mergeAimRecoilDeltas(
            aimPitch, aimYaw, recoilPitch, recoilYaw, &merged);
        _previousGeometrySampleKey = geometrySampleKey;
        _previousControlPitch = snapshot.controlPitchDegrees;
        _previousControlPresent = std::isfinite(_previousControlPitch);
        if (!mergedOK) return nil;
        CoreSetV17ActionDelta *result = [CoreSetV17ActionDelta new];
        result.pitch = merged.pitch;
        result.yaw = merged.yaw;
        result.aimPitch = aimPitch;
        result.aimYaw = aimYaw;
        result.recoilPitch = recoilPitch;
        result.recoilYaw = recoilYaw;
        return result;
    };
    if (!snapshot.recoilInputsPresent || !snapshot.recoilPostSample || !snapshot.recoilBinding) {
        _post = {};
        _raw = {};
        return finish(0, 0);
    }
    CoreSetRecoilPostSample *sample = snapshot.recoilPostSample;
    CoreSet::ActionPostRecord record{true, sample.key, sample.ownerToken, sample.active,
        {sample.value0, sample.value1, sample.value2, sample.value3, sample.value4, sample.value5}};
    CoreSet::RecoilConfiguration nativeConfiguration{verticalEnabled, verticalStrength,
        static_cast<bool>(stopWhenNotFiring), horizontalEnabled, horizontalStrength};
    CoreSet::ActionPostTuning tuning;
    if (!CoreSet::referenceActionRecoilPostTuning(nativeConfiguration,
            snapshot.recoilFirstWeight, snapshot.recoilFirstBindingScale,
            snapshot.recoilSecondWeight, snapshot.recoilSecondBindingScale, &tuning)) {
        _post = {}; _raw = {}; return nil;
    }
    CoreSet::ActionPostObservation post;
    if (!CoreSet::referenceActionPostState(_post, record, tuning,
                                            snapshot.recoilBinding, &post)) {
        _raw = {};
        return finish(0, 0);
    }

    float rawCombined = 0;
    if (verticalEnabled && _previousGeometrySampleKey && _previousControlPresent) {
        CoreSet::RecoilRawInput input;
        input.firing = (snapshot.localFiringRaw & 1) != 0;
        input.readValid = true;
        input.sampleKey = _previousGeometrySampleKey;
        input.binding = snapshot.recoilBinding;
        input.currentPitch = _previousControlPitch;
        input.priorAimPitch = _priorAimPitch;
        input.strength01 = verticalStrength;
        CoreSet::RecoilRawResult raw;
        if (CoreSet::stepRecoilRawState(&_raw, input, &raw)) rawCombined = raw.combined;
    } else {
        _raw = {};
    }
    const float postPitch = post.values[2];
    const float recoilPitch = verticalEnabled
        ? CoreSet::referenceActionRecoilCallerMerge(postPitch, rawCombined, verticalStrength) : 0;
    const float recoilYaw = horizontalEnabled ? post.values[5] : 0;
    return finish(recoilPitch, recoilYaw);
}
- (CoreSetV17ActionDelta *)planInput:(CoreSetActionInputAuthority *)input
    aimPitch:(float)aimPitch aimYaw:(float)aimYaw geometrySampleKey:(uint64_t)geometrySampleKey
    configuration:(CoreSetV17RecoilConfiguration *)configuration {
    const BOOL verticalEnabled = configuration.verticalEnabled;
    const float verticalStrength = configuration.verticalStrength;
    const BOOL stopWhenNotFiring = configuration ? configuration.stopWhenNotFiring : YES;
    const BOOL horizontalEnabled = configuration.horizontalEnabled;
    const float horizontalStrength = configuration.horizontalStrength;
    if (!input || !std::isfinite(aimPitch) || !std::isfinite(aimYaw) ||
        !std::isfinite(verticalStrength) || verticalStrength < 0 || verticalStrength > 1 ||
        !std::isfinite(horizontalStrength) || horizontalStrength < 0 || horizontalStrength > 1) return nil;
    const auto finish = [&](float recoilPitch, float recoilYaw) -> CoreSetV17ActionDelta * {
        CoreSet::AimDeltaPlan merged;
        const bool mergedOK = CoreSet::mergeAimRecoilDeltas(aimPitch, aimYaw, recoilPitch, recoilYaw, &merged);
        _previousGeometrySampleKey = geometrySampleKey;
        _previousControlPitch = input.controlPitchDegrees;
        _previousControlPresent = std::isfinite(_previousControlPitch);
        if (!mergedOK) return nil;
        CoreSetV17ActionDelta *result = [CoreSetV17ActionDelta new];
        result.pitch = merged.pitch; result.yaw = merged.yaw;
        result.aimPitch = aimPitch; result.aimYaw = aimYaw;
        result.recoilPitch = recoilPitch; result.recoilYaw = recoilYaw;
        return result;
    };
    if (!input.recoilInputsPresent || !input.recoilPostSample || !input.recoilBinding) {
        _post = {}; _raw = {}; return finish(0, 0);
    }
    CoreSetRecoilPostSample *sample = input.recoilPostSample;
    CoreSet::ActionPostRecord record{true, sample.key, sample.ownerToken, sample.active,
        {sample.value0, sample.value1, sample.value2, sample.value3, sample.value4, sample.value5}};
    CoreSet::RecoilConfiguration nativeConfiguration{verticalEnabled, verticalStrength,
        static_cast<bool>(stopWhenNotFiring), horizontalEnabled, horizontalStrength};
    CoreSet::ActionPostTuning tuning;
    if (!CoreSet::referenceActionRecoilPostTuning(nativeConfiguration,
            input.recoilFirstWeight, input.recoilFirstBindingScale,
            input.recoilSecondWeight, input.recoilSecondBindingScale, &tuning)) {
        _post = {}; _raw = {}; return nil;
    }
    CoreSet::ActionPostObservation post;
    if (!CoreSet::referenceActionPostState(_post, record, tuning, input.recoilBinding, &post)) {
        _raw = {}; return finish(0, 0);
    }
    float rawCombined = 0;
    if (verticalEnabled && _previousGeometrySampleKey && _previousControlPresent) {
        CoreSet::RecoilRawInput rawInput;
        rawInput.firing = (input.localFiringRaw & 1) != 0; rawInput.readValid = true;
        rawInput.sampleKey = _previousGeometrySampleKey; rawInput.binding = input.recoilBinding;
        rawInput.currentPitch = _previousControlPitch; rawInput.priorAimPitch = _priorAimPitch;
        rawInput.strength01 = verticalStrength;
        CoreSet::RecoilRawResult raw;
        if (CoreSet::stepRecoilRawState(&_raw, rawInput, &raw)) rawCombined = raw.combined;
    } else { _raw = {}; }
    const float recoilPitch = verticalEnabled ? CoreSet::referenceActionRecoilCallerMerge(
        post.values[2], rawCombined, verticalStrength) : 0;
    const float recoilYaw = horizontalEnabled ? post.values[5] : 0;
    return finish(recoilPitch, recoilYaw);
}
- (void)observeAimFeedbackWithPitch:(float)aimPitch inputRoute:(BOOL)inputRoute
    recoilEnabled:(BOOL)recoilEnabled aimActive:(BOOL)aimActive
    acceptedFirstAxis:(BOOL)acceptedFirstAxis bothZeroDraft:(BOOL)bothZeroDraft {
    _priorAimPitch = CoreSet::referenceActionPriorAimFeedback(_priorAimPitch, aimPitch,
        inputRoute, recoilEnabled, aimActive, acceptedFirstAxis, bothZeroDraft);
}
@end

static CoreSetTargetWriteResult *CSProbeFailure(NSString *reason, BOOL pending) {
    return [[CoreSetTargetWriteResult alloc] initWithCommitted:NO pending:pending
        completedBytes:0 reason:reason];
}

// Separate authority owner avoids a writer -> probe -> writer retain cycle.
@interface CSProbeAuthority : NSObject <CoreSetTargetWriteAuthority> {
@public
    CoreSet::SerialActionGate gate;
    CoreSet::ActionContext context;
    std::atomic<bool> stopping;
}
@property(nonatomic, copy) CoreSetProbeLiveValidator validator;
@property(nonatomic, strong, nullable) CoreSetActionInputAuthority *input;
@property(nonatomic, strong, nullable) NSUUID *token;
@end

@implementation CSProbeAuthority
- (instancetype)init { if ((self = [super init])) stopping.store(false); return self; }
- (BOOL)live {
    return !stopping.load() && self.validator && self.input && self.token &&
        self.validator(self.input, self.token, context.hostGeneration, context.configRevision) &&
        !stopping.load();
}
- (BOOL)authorizesPID:(int32_t)pid imageBase:(uint64_t)imageBase
    generation:(uint64_t)generation controller:(uint64_t)controller
    lane:(CoreSetTargetWriteLane)lane slot:(CoreSetTargetWriteSlot)slot
    axis:(CoreSetTargetWriteAxis)axis requestToken:(NSUUID *)requestToken snapshotID:(NSUUID *)snapshotID {
    if (![self live]) return NO;
    CoreSet::ActionContext requested = context;
    requested.pid = pid; requested.imageBase = imageBase;
    requested.readGeneration = generation; requested.controller = controller;
    requested.lane = lane; requested.slot = slot; requested.axis = axis;
    [requestToken getUUIDBytes:requested.requestToken.data()];
    [snapshotID getUUIDBytes:requested.snapshotID.data()];
    return gate.authorizes(requested, context, CACurrentMediaTime());
}
@end

@interface CoreSetIsolatedWriteProbe () {
    dispatch_queue_t _queue;
    CSProbeAuthority *_authority;
    CoreSetTargetWriteSession *_writer;
}
- (CoreSetTargetWriteResult *)submitSnapshot:(CoreSetPlayerSnapshot *)snapshot
    requestToken:(NSUUID *)requestToken hostGeneration:(uint64_t)hostGeneration
    configRevision:(uint64_t)configRevision lane:(CoreSetTargetWriteLane)lane
    slot:(CoreSetTargetWriteSlot)slot
    axis:(CoreSetTargetWriteAxis)axis pitch:(float)pitch yaw:(float)yaw;
- (CoreSetTargetWriteResult *)submitAuthority:(CoreSetActionInputAuthority *)authority
    requestToken:(NSUUID *)requestToken hostGeneration:(uint64_t)hostGeneration
    configRevision:(uint64_t)configRevision lane:(CoreSetTargetWriteLane)lane
    slot:(CoreSetTargetWriteSlot)slot axis:(CoreSetTargetWriteAxis)axis
    pitch:(float)pitch yaw:(float)yaw;
@end

@implementation CoreSetIsolatedWriteProbe
- (instancetype)initWithLiveValidator:(CoreSetProbeLiveValidator)validator {
    if (!validator) return nil;
    if ((self = [super init])) {
        _queue = dispatch_queue_create("coreset.isolated.single.write", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_queue, &CSProbeQueueKey, (__bridge void *)self, NULL);
        _authority = [CSProbeAuthority new];
        _authority.validator = validator;
        _writer = [[CoreSetTargetWriteSession alloc] initWithRequestAuthority:_authority];
    }
    return self;
}
- (instancetype)initWithReadSession:(CoreSetReadSession *)readSession
                       liveValidator:(CoreSetProbeLiveValidator)validator {
    if (!readSession || !validator) return nil;
    if ((self = [super init])) {
        _queue = dispatch_queue_create("coreset.isolated.single.write", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_queue, &CSProbeQueueKey, (__bridge void *)self, NULL);
        _authority = [CSProbeAuthority new];
        _authority.validator = validator;
        _writer = [[CoreSetTargetWriteSession alloc] initWithRequestAuthority:_authority
                                                                  readSession:readSession];
    }
    return self;
}
- (CoreSetTargetWriteResult *)submitSnapshot:(CoreSetPlayerSnapshot *)snapshot
    requestToken:(NSUUID *)requestToken hostGeneration:(uint64_t)hostGeneration
    configRevision:(uint64_t)configRevision lane:(CoreSetTargetWriteLane)lane
    slot:(CoreSetTargetWriteSlot)slot
    axis:(CoreSetTargetWriteAxis)axis pitchDelta:(float)pitchDelta yawDelta:(float)yawDelta {
    return [self submitSnapshot:snapshot requestToken:requestToken hostGeneration:hostGeneration
        configRevision:configRevision lane:lane slot:slot axis:axis pitch:pitchDelta yaw:yawDelta];
}
- (CoreSetTargetWriteResult *)submitSnapshot:(CoreSetPlayerSnapshot *)snapshot
    requestToken:(NSUUID *)requestToken hostGeneration:(uint64_t)hostGeneration
    configRevision:(uint64_t)configRevision lane:(CoreSetTargetWriteLane)lane
    slot:(CoreSetTargetWriteSlot)slot
    axis:(CoreSetTargetWriteAxis)axis pitch:(float)pitch yaw:(float)yaw {
    CoreSetActionInputAuthority *authority = [CoreSetActionInputAuthority authorityWithSnapshot:snapshot];
    return [self submitAuthority:authority requestToken:requestToken hostGeneration:hostGeneration
        configRevision:configRevision lane:lane slot:slot axis:axis pitch:pitch yaw:yaw];
}
- (CoreSetTargetWriteResult *)submitAuthority:(CoreSetActionInputAuthority *)authority
    requestToken:(NSUUID *)requestToken hostGeneration:(uint64_t)hostGeneration
    configRevision:(uint64_t)configRevision lane:(CoreSetTargetWriteLane)lane
    slot:(CoreSetTargetWriteSlot)slot axis:(CoreSetTargetWriteAxis)axis
    pitchDelta:(float)pitchDelta yawDelta:(float)yawDelta {
    return [self submitAuthority:authority requestToken:requestToken hostGeneration:hostGeneration
        configRevision:configRevision lane:lane slot:slot axis:axis pitch:pitchDelta yaw:yawDelta];
}
- (CoreSetTargetWriteResult *)submitAuthority:(CoreSetActionInputAuthority *)authority
    requestToken:(NSUUID *)requestToken hostGeneration:(uint64_t)hostGeneration
    configRevision:(uint64_t)configRevision lane:(CoreSetTargetWriteLane)lane
    slot:(CoreSetTargetWriteSlot)slot axis:(CoreSetTargetWriteAxis)axis
    pitch:(float)pitch yaw:(float)yaw {
    if (dispatch_get_specific(&CSProbeQueueKey) == (__bridge void *)self)
        return CSProbeFailure(@"recursive probe submission rejected", _writer.pendingCleanup);
    __block CoreSetTargetWriteResult *result;
    dispatch_sync(_queue, ^{
        if (self->_authority->stopping.load()) {
            result = CSProbeFailure(@"action worker stopped", self->_writer.pendingCleanup);
            return;
        }
        const BOOL first = axis == CoreSetTargetWriteAxisFirst || axis == CoreSetTargetWriteAxisBoth;
        const BOOL second = axis == CoreSetTargetWriteAxisSecond || axis == CoreSetTargetWriteAxisBoth;
        if (!authority || !requestToken ||
            (lane != CoreSetTargetWriteLaneAim && lane != CoreSetTargetWriteLaneRecoil) ||
            (slot != CoreSetTargetWriteSlotControlRotation && slot != CoreSetTargetWriteSlotRotationInput) ||
            (!first && !second) || !std::isfinite(pitch) || !std::isfinite(yaw) ||
            (std::fabs(pitch) > 36 || std::fabs(yaw) > 36) ||
            (!first && pitch != 0) || (!second && yaw != 0) ||
            (pitch == 0 && yaw == 0) ||
            !std::isfinite(authority.controlPitchDegrees) || !std::isfinite(authority.controlYawDegrees) ||
            !std::isfinite(authority.rotationInputPitch) || !std::isfinite(authority.rotationInputYaw) ||
            std::fabs(authority.controlPitchDegrees) > 360 || std::fabs(authority.controlYawDegrees) > 360 ||
            std::fabs(authority.rotationInputPitch) > 360 || std::fabs(authority.rotationInputYaw) > 360) {
            result = CSProbeFailure(@"invalid complete battle snapshot, axis or bounded nonzero delta", NO);
            return;
        }
        self->_authority.input = authority;
        self->_authority.token = requestToken;
        auto &context = self->_authority->context;
        context.pid = authority.processID; context.imageBase = authority.imageBase;
        context.readGeneration = authority.sessionGeneration; context.controller = authority.controllerAddress;
        context.hostGeneration = hostGeneration; context.configRevision = configRevision;
        context.lane = lane;
        context.slot = slot; context.axis = axis;
        [requestToken getUUIDBytes:context.requestToken.data()];
        [authority.snapshotID getUUIDBytes:context.snapshotID.data()];
        if (![self->_authority live] || !self->_authority->gate.begin(context, context,
            authority.captureCompletedMonotonicSeconds, CACurrentMediaTime())) {
            result = CSProbeFailure(@"live request/target validation rejected, busy or snapshot expired", NO);
        } else {
            const float oldValues[2] = {
                slot == CoreSetTargetWriteSlotControlRotation ? authority.controlPitchDegrees : authority.rotationInputPitch,
                slot == CoreSetTargetWriteSlotControlRotation ? authority.controlYawDegrees : authority.rotationInputYaw
            };
            const float newValues[2] = {oldValues[0] + pitch, oldValues[1] + yaw};
            const size_t index = axis == CoreSetTargetWriteAxisSecond ? 1 : 0;
            const size_t length = axis == CoreSetTargetWriteAxisBoth ? sizeof(oldValues) : sizeof(float);
            if (std::fabs(newValues[0]) > 360 || std::fabs(newValues[1]) > 360) {
                result = CSProbeFailure(@"probe output outside bounded rotation range", NO);
            } else {
                result = [self->_writer writeControllerActionForPID:context.pid imageBase:context.imageBase
                    controller:context.controller lane:lane
                    slot:slot axis:axis generation:context.readGeneration
                    requestToken:requestToken snapshotID:authority.snapshotID
                    expectedOld:[NSData dataWithBytes:oldValues + index length:length]
                    newValue:[NSData dataWithBytes:newValues + index length:length]];
            }
        }
        self->_authority->gate.finish();
        self->_authority.input = nil; self->_authority.token = nil;
    });
    return result;
}
- (CoreSetTargetWriteCleanupResult *)stop {
    _authority->stopping.store(true); // Repeated writer authority checks reject late work.
    __block CoreSetTargetWriteCleanupResult *result;
    void (^cleanup)(void) = ^{
        self->_authority->gate.stop();
        self->_authority.input = nil; self->_authority.token = nil;
        result = [self->_writer disconnect];
    };
    if (dispatch_get_specific(&CSProbeQueueKey) == (__bridge void *)self) {
        // A live validator must not recurse into stop. Report incomplete rather
        // than disconnecting under an in-flight writer transaction.
        return [[CoreSetTargetWriteCleanupResult alloc] initWithReadTaskPortReleased:NO
            mappedAliasReleased:NO generationAdvanced:NO noInFlight:NO
            targetEffectsResolved:NO targetEffectsAbandoned:NO];
    }
    dispatch_sync(_queue, cleanup);
    return result;
}
- (void)dealloc { _authority->stopping.store(true); [_writer disconnect]; }
@end
