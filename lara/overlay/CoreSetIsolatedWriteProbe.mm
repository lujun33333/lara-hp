#import "CoreSetIsolatedWriteProbe.h"
#import <QuartzCore/QuartzCore.h>
#include "CoreSetSingleAttemptGate.h"
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
@interface CoreSetV17AimDynamics () {
    CoreSet::ActionCandidateMotionState _motion;
    CoreSet::ActionGeometryClockState _geometry;
    CoreSet::ActionTakeoverState _takeover;
    CSAimDropoutHold _dropout;
}
@end
@implementation CoreSetV17AimDynamics
- (void)reset { _motion = {}; _geometry = {}; _takeover = {}; _dropout.reset(); }
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
- (BOOL)permitsTakeoverPitch:(float)pitch yaw:(float)yaw threshold:(float)threshold
    confirmationFrames:(NSInteger)confirmationFrames pauseSeconds:(double)pauseSeconds now:(double)now {
    CoreSet::ActionTakeoverObservation observed;
    const float magnitude = std::hypot(pitch, yaw);
    return CoreSet::referenceActionTakeover(_takeover, true, false, magnitude, threshold,
        (int)confirmationFrames, (int)std::lround(pauseSeconds * 1000.0), now, &observed) &&
        observed.aimAllowed && observed.mergePredecessor == CoreSet::ActionMergePredecessor::inputDirect;
}
- (CoreSetBasicAimDelta *)planFromCamera:(CoreSetWorldPoint *)camera
    target:(CoreSetWorldPoint *)target actor:(uint64_t)actor publicationID:(NSUUID *)publicationID
    now:(double)now currentPitch:(float)currentPitch currentYaw:(float)currentYaw
    strength:(float)strength smoothingSeconds:(float)smoothingSeconds
    curveSelector:(float)curveSelector horizontalSpeed:(float)horizontalSpeed
    verticalSpeed:(float)verticalSpeed predictionMilliseconds:(double)predictionMilliseconds
    residualGain:(float)residualGain minimumGain:(float)minimumGain
    deadzoneRatio:(float)deadzoneRatio minimumDeadzone:(float)minimumDeadzone {
    if (!camera || !target || !publicationID || !std::isfinite(now) || now < 0) return nil;
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
    tuning.compensation = {strength, smoothingSeconds, curveSelector,
        {horizontalSpeed, verticalSpeed}, residualGain, minimumGain};
    tuning.predictionMilliseconds = (float)predictionMilliseconds;
    tuning.deadzoneRatio = deadzoneRatio;
    tuning.minimumDeadzone = minimumDeadzone;
    CoreSet::ActionGeometryObservation observed;
    if (!CoreSet::referenceActionGeometry(_geometry, input, tuning, &observed) || !observed.valid) return nil;
    uint64_t sampleKey = 0;
    std::memcpy(&sampleKey, observed.numerical.data(), sizeof(sampleKey));
    CoreSetBasicAimDelta *result = [CoreSetBasicAimDelta new];
    result.pitch = observed.numerical[5]; result.yaw = observed.numerical[4];
    result.geometrySampleKey = sampleKey;
    return result;
}
@end

@interface CoreSetV17ActionDelta ()
@property(nonatomic) float pitch;
@property(nonatomic) float yaw;
@end
@implementation CoreSetV17ActionDelta @end

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
    verticalEnabled:(BOOL)verticalEnabled verticalStrength:(float)verticalStrength
    stopWhenNotFiring:(BOOL)stopWhenNotFiring horizontalEnabled:(BOOL)horizontalEnabled
    horizontalStrength:(float)horizontalStrength {
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
    CoreSet::ActionPostTuning tuning;
    tuning.firstStrength = verticalEnabled ? verticalStrength : 0;
    tuning.firstLimit = 1.5f;
    tuning.deadzone = 0.0005000000237487257f;
    tuning.firstWeight = snapshot.recoilFirstWeight;
    tuning.firstBindingScale = snapshot.recoilFirstBindingScale;
    tuning.quietFrameLimit = 6;
    tuning.continueLocalTail = verticalEnabled && !stopWhenNotFiring;
    tuning.secondStrength = horizontalEnabled ? horizontalStrength : 0;
    tuning.secondLimitScale = 1.0f;
    tuning.secondWeight = snapshot.recoilSecondWeight;
    tuning.secondBindingScale = snapshot.recoilSecondBindingScale;
    CoreSet::ActionPostObservation post;
    if (!CoreSet::referenceActionPostState(_post, record, tuning,
                                            snapshot.recoilBinding, &post)) {
        _raw = {};
        return finish(0, 0);
    }

    float rawCombined = 0;
    if (verticalEnabled && _previousGeometrySampleKey && _previousControlPresent) {
        CoreSet::RecoilRawInput input;
        input.firing = snapshot.localFiring;
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
- (void)observeCommittedAimPitch:(float)aimPitch inputRoute:(BOOL)inputRoute
    recoilEnabled:(BOOL)recoilEnabled aimActive:(BOOL)aimActive
    acceptedFirstAxis:(BOOL)acceptedFirstAxis bothZeroDraft:(BOOL)bothZeroDraft {
    _priorAimPitch = CoreSet::referenceActionPriorAimFeedback(_priorAimPitch, aimPitch,
        inputRoute, recoilEnabled, aimActive, acceptedFirstAxis, bothZeroDraft);
}
@end

@interface CoreSetV17ActionRouteDynamics () {
    CoreSet::ActionRouteState _state;
}
@end
@implementation CoreSetV17ActionRouteDynamics
- (void)reset { _state = {}; }
- (BOOL)useControlRotationWithRecoilEnabled:(BOOL)recoilEnabled inputPaused:(BOOL)inputPaused {
    // c35f0/c35f8 is the only live control predecessor: mode flag set,
    // alternate clear, recoil master enabled, and not the paused input path.
    return recoilEnabled && !inputPaused && _state.modeFlag && !_state.alternate;
}
- (void)observeCommittedWithW20:(BOOL)w20 {
    _state.observeResult(1, CoreSet::RouteResultGate::lowBit, w20);
}
@end
static CoreSetTargetWriteResult *CSProbeFailure(NSString *reason, BOOL pending) {
    return [[CoreSetTargetWriteResult alloc] initWithCommitted:NO pending:pending
        completedBytes:0 reason:reason];
}

// Separate authority owner avoids a writer -> probe -> writer retain cycle.
@interface CSProbeAuthority : NSObject <CoreSetTargetWriteAuthority> {
@public
    CoreSet::SingleAttemptGate gate;
    CoreSet::ActionContext context;
    std::atomic<bool> stopping;
}
@property(nonatomic, copy) CoreSetProbeLiveValidator validator;
@property(nonatomic, strong, nullable) CoreSetPlayerSnapshot *snapshot;
@property(nonatomic, strong, nullable) NSUUID *token;
@end

@implementation CSProbeAuthority
- (instancetype)init { if ((self = [super init])) stopping.store(false); return self; }
- (BOOL)live {
    return !stopping.load() && self.validator && self.snapshot && self.token &&
        self.validator(self.snapshot, self.token, context.hostGeneration, context.configRevision) &&
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
    BOOL _submitted;
}
- (CoreSetTargetWriteResult *)submitSnapshot:(CoreSetPlayerSnapshot *)snapshot
    requestToken:(NSUUID *)requestToken hostGeneration:(uint64_t)hostGeneration
    configRevision:(uint64_t)configRevision lane:(CoreSetTargetWriteLane)lane
    slot:(CoreSetTargetWriteSlot)slot
    axis:(CoreSetTargetWriteAxis)axis pitch:(float)pitch yaw:(float)yaw;
@end

@implementation CoreSetIsolatedWriteProbe
- (instancetype)initWithLiveValidator:(CoreSetProbeLiveValidator)validator {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("coreset.isolated.single.write", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_queue, &CSProbeQueueKey, (__bridge void *)self, NULL);
        _authority = [CSProbeAuthority new];
        _authority.validator = validator;
        _writer = [[CoreSetTargetWriteSession alloc] initWithRequestAuthority:_authority];
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
    if (dispatch_get_specific(&CSProbeQueueKey) == (__bridge void *)self)
        return CSProbeFailure(@"recursive probe submission rejected", _writer.pendingCleanup);
    __block CoreSetTargetWriteResult *result;
    dispatch_sync(_queue, ^{
        if (self->_authority->stopping.load() || self->_submitted) {
            result = CSProbeFailure(@"probe stopped or single attempt already consumed", self->_writer.pendingCleanup);
            return;
        }
        self->_submitted = YES;
        const BOOL first = axis == CoreSetTargetWriteAxisFirst || axis == CoreSetTargetWriteAxisBoth;
        const BOOL second = axis == CoreSetTargetWriteAxisSecond || axis == CoreSetTargetWriteAxisBoth;
        if (!snapshot || !requestToken || !snapshot.battleInputsPresent ||
            (lane != CoreSetTargetWriteLaneAim && lane != CoreSetTargetWriteLaneRecoil) ||
            (slot != CoreSetTargetWriteSlotControlRotation && slot != CoreSetTargetWriteSlotRotationInput) ||
            (!first && !second) || !std::isfinite(pitch) || !std::isfinite(yaw) ||
            (std::fabs(pitch) > 36 || std::fabs(yaw) > 36) ||
            (!first && pitch != 0) || (!second && yaw != 0) ||
            (pitch == 0 && yaw == 0) ||
            !std::isfinite(snapshot.controlPitchDegrees) || !std::isfinite(snapshot.controlYawDegrees) ||
            !std::isfinite(snapshot.rotationInputPitch) || !std::isfinite(snapshot.rotationInputYaw) ||
            std::fabs(snapshot.controlPitchDegrees) > 360 || std::fabs(snapshot.controlYawDegrees) > 360 ||
            std::fabs(snapshot.rotationInputPitch) > 360 || std::fabs(snapshot.rotationInputYaw) > 360) {
            result = CSProbeFailure(@"invalid complete battle snapshot, axis or bounded nonzero delta", NO);
            return;
        }
        self->_authority.snapshot = snapshot;
        self->_authority.token = requestToken;
        auto &context = self->_authority->context;
        context.pid = snapshot.processID; context.imageBase = snapshot.imageBase;
        context.readGeneration = snapshot.sessionGeneration; context.controller = snapshot.controllerAddress;
        context.hostGeneration = hostGeneration; context.configRevision = configRevision;
        context.lane = lane;
        context.slot = slot; context.axis = axis;
        [requestToken getUUIDBytes:context.requestToken.data()];
        [snapshot.snapshotID getUUIDBytes:context.snapshotID.data()];
        if (![self->_authority live] || !self->_authority->gate.begin(context, context,
            snapshot.captureCompletedMonotonicSeconds, CACurrentMediaTime())) {
            result = CSProbeFailure(@"live request/target validation rejected or snapshot expired", NO);
        } else {
            const float oldValues[2] = {
                slot == CoreSetTargetWriteSlotControlRotation ? snapshot.controlPitchDegrees : snapshot.rotationInputPitch,
                slot == CoreSetTargetWriteSlotControlRotation ? snapshot.controlYawDegrees : snapshot.rotationInputYaw
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
                    requestToken:requestToken snapshotID:snapshot.snapshotID
                    expectedOld:[NSData dataWithBytes:oldValues + index length:length]
                    newValue:[NSData dataWithBytes:newValues + index length:length]];
            }
        }
        self->_authority->gate.finish();
        self->_authority.snapshot = nil; self->_authority.token = nil;
    });
    return result;
}
- (CoreSetTargetWriteCleanupResult *)stop {
    _authority->stopping.store(true); // Repeated writer authority checks reject late work.
    __block CoreSetTargetWriteCleanupResult *result;
    void (^cleanup)(void) = ^{
        self->_authority->gate.stop();
        self->_authority.snapshot = nil; self->_authority.token = nil;
        result = [self->_writer disconnect];
    };
    if (dispatch_get_specific(&CSProbeQueueKey) == (__bridge void *)self) {
        // A live validator must not recurse into stop. Report incomplete rather
        // than disconnecting under an in-flight writer transaction.
        return [[CoreSetTargetWriteCleanupResult alloc] initWithReadTaskPortReleased:NO
            mappedAliasReleased:NO generationAdvanced:NO noInFlight:NO
            targetEffectsResolved:NO];
    }
    dispatch_sync(_queue, cleanup);
    return result;
}
- (void)dealloc { _authority->stopping.store(true); [_writer disconnect]; }
@end

