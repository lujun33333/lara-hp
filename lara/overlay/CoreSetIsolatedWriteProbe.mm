#import "CoreSetIsolatedWriteProbe.h"
#import <QuartzCore/QuartzCore.h>
#include "CoreSetSingleAttemptGate.h"
#include "CoreSetBasicAimGeometry.h"
#include "CoreSetPlayerProjection.h"
#include <atomic>
#include <cmath>

static char CSProbeQueueKey;
@interface CoreSetBasicAimTriggerState () { CoreSet::BasicAimTriggerHold _hold; }
@end
@interface CoreSetBasicAimDelta ()
@property(nonatomic) float pitch;
@property(nonatomic) float yaw;
@end
@implementation CoreSetBasicAimTriggerState
- (void)reset { _hold.reset(); }
- (BOOL)updateMode:(NSInteger)mode ads:(BOOL)ads firing:(BOOL)firing now:(double)now {
    if (mode < 0 || mode > 3) { _hold.reset(); return NO; }
    return _hold.update((int)mode, ads, firing, now);
}
- (BOOL)permitsAt:(double)now { return _hold.permits(now); }
@end
@implementation CoreSetBasicAimDelta
+ (CoreSetPlayerMark *)selectFromSnapshot:(CoreSetPlayerSnapshot *)snapshot point:(NSInteger)point
    radius:(double)radius maximumDistance:(double)maximumDistance includeBots:(BOOL)includeBots
    lockSameTarget:(BOOL)lockSameTarget previousActor:(uint64_t)previousActor {
    if (!snapshot.battleInputsPresent || !snapshot.cameraWorldPosition || (point != 0 && point != 2)) return nil;
    CoreSet::Camera camera{};
    camera.location = {snapshot.cameraWorldPosition.x, snapshot.cameraWorldPosition.y, snapshot.cameraWorldPosition.z};
    camera.rotation = {(float)snapshot.cameraPitchDegrees, (float)snapshot.cameraYawDegrees,
                       (float)snapshot.cameraRollDegrees};
    camera.fov = (float)snapshot.cameraFieldOfViewDegrees;
    std::vector<CoreSet::BasicAimCandidate> candidates;
    for (CoreSetPlayerMark *mark in snapshot.marks) {
        CoreSetWorldPoint *target = [self fallbackTargetForMark:mark point:point];
        CoreSet::Point screen{};
        const bool projected = target && CoreSet::project(camera, {target.x, target.y, target.z},
            snapshot.canvasSize.width, snapshot.canvasSize.height, &screen);
        candidates.push_back({mark.actorAddress, (bool)mark.bot, projected, target != nil,
            mark.distanceUnitsDividedBy100, screen.x, screen.y});
    }
    const size_t index = CoreSet::basicAimSelectLocked(candidates, snapshot.canvasSize.width,
        snapshot.canvasSize.height, radius, maximumDistance, includeBots, lockSameTarget, previousActor);
    return index < snapshot.marks.count ? snapshot.marks[index] : nil;
}
+ (BOOL)triggerMode:(NSInteger)mode ads:(BOOL)ads firing:(BOOL)firing {
    if (mode < 0 || mode > 3) return NO;
    return CoreSet::basicAimTrigger((int)mode, ads, firing);
}
+ (CoreSetPlayerMark *)selectFromSnapshot:(CoreSetPlayerSnapshot *)snapshot
    radius:(double)radius maximumDistance:(double)maximumDistance includeBots:(BOOL)includeBots
    lockSameTarget:(BOOL)lockSameTarget previousActor:(uint64_t)previousActor {
    if (!snapshot.battleInputsPresent) return nil;
    std::vector<CoreSet::BasicAimCandidate> candidates;
    for (CoreSetPlayerMark *mark in snapshot.marks) {
        candidates.push_back({mark.actorAddress, (bool)mark.bot, (bool)mark.onScreen,
            mark.actorWorldPosition != nil, mark.distanceUnitsDividedBy100, mark.center.x, mark.center.y});
    }
    const size_t index = CoreSet::basicAimSelectLocked(candidates, snapshot.canvasSize.width,
        snapshot.canvasSize.height, radius, maximumDistance, includeBots,
        lockSameTarget, previousActor);
    return index < snapshot.marks.count ? snapshot.marks[index] : nil;
}
+ (CoreSetPlayerMark *)selectFromSnapshot:(CoreSetPlayerSnapshot *)snapshot
    radius:(double)radius maximumDistance:(double)maximumDistance includeBots:(BOOL)includeBots {
    if (!snapshot.battleInputsPresent) return nil;
    std::vector<CoreSet::BasicAimCandidate> candidates;
    for (CoreSetPlayerMark *mark in snapshot.marks) {
        candidates.push_back({mark.actorAddress, (bool)mark.bot, (bool)mark.onScreen,
            mark.actorWorldPosition != nil, mark.distanceUnitsDividedBy100, mark.center.x, mark.center.y});
    }
    const size_t index = CoreSet::basicAimSelect(candidates, snapshot.canvasSize.width,
        snapshot.canvasSize.height, radius, maximumDistance, includeBots);
    return index < snapshot.marks.count ? snapshot.marks[index] : nil;
}
+ (CoreSetBasicAimDelta *)planFromCamera:(CoreSetWorldPoint *)camera
    target:(CoreSetWorldPoint *)target currentPitch:(float)currentPitch currentYaw:(float)currentYaw {
    CoreSet::BasicAimStep step;
    if (!camera || !target || !CoreSet::basicAimStep({camera.x, camera.y, camera.z},
        {target.x, target.y, target.z}, currentPitch, currentYaw, &step)) return nil;
    CoreSetBasicAimDelta *result = [CoreSetBasicAimDelta new];
    result.pitch = step.pitch; result.yaw = step.yaw; return result;
}
+ (CoreSetWorldPoint *)fallbackTargetForMark:(CoreSetPlayerMark *)mark point:(NSInteger)point {
    if (!mark.actorWorldPosition || (point != 0 && point != 2)) return nil;
    const float z = mark.actorWorldPosition.z + (point == 2 ? 25.0f : 30.0f);
    return [CoreSetWorldPoint pointWithX:mark.actorWorldPosition.x y:mark.actorWorldPosition.y z:z];
}
+ (BOOL)validateCaptured:(CoreSetPlayerSnapshot *)captured live:(CoreSetPlayerSnapshot *)live
    actor:(uint64_t)actor point:(NSInteger)point radius:(double)radius
    maximumDistance:(double)maximumDistance includeBots:(BOOL)includeBots
    lockSameTarget:(BOOL)lockSameTarget previousActor:(uint64_t)previousActor
    expectedTarget:(CoreSetWorldPoint *)expectedTarget {
    if (!captured || !live || !expectedTarget || !captured.cameraWorldPosition || !live.cameraWorldPosition) return NO;
    const float capturedInputs[2] = {captured.rotationInputPitch, captured.rotationInputYaw};
    const float liveInputs[2] = {live.rotationInputPitch, live.rotationInputYaw};
    const float capturedControl[2] = {captured.controlPitchDegrees, captured.controlYawDegrees};
    const float liveControl[2] = {live.controlPitchDegrees, live.controlYawDegrees};
    const float capturedCamera[3] = {captured.cameraWorldPosition.x, captured.cameraWorldPosition.y, captured.cameraWorldPosition.z};
    const float liveCamera[3] = {live.cameraWorldPosition.x, live.cameraWorldPosition.y, live.cameraWorldPosition.z};
    if (captured.processID != live.processID || captured.imageBase != live.imageBase ||
        captured.sessionGeneration != live.sessionGeneration || captured.controllerAddress != live.controllerAddress ||
        captured.localActorAddress != live.localActorAddress || captured.localADS != live.localADS ||
        captured.localFiring != live.localFiring ||
        std::memcmp(capturedInputs, liveInputs, sizeof(capturedInputs)) != 0 ||
        std::memcmp(capturedControl, liveControl, sizeof(capturedControl)) != 0 ||
        std::memcmp(capturedCamera, liveCamera, sizeof(capturedCamera)) != 0 ||
        captured.cameraPitchDegrees != live.cameraPitchDegrees || captured.cameraYawDegrees != live.cameraYawDegrees ||
        captured.cameraRollDegrees != live.cameraRollDegrees || captured.cameraFieldOfViewDegrees != live.cameraFieldOfViewDegrees) return NO;
    CoreSetPlayerMark *selected = [self selectFromSnapshot:live point:point radius:radius
        maximumDistance:maximumDistance includeBots:includeBots lockSameTarget:lockSameTarget
        previousActor:previousActor];
    CoreSetWorldPoint *target = selected ? [self fallbackTargetForMark:selected point:point] : nil;
    if (!selected || !target || selected.actorAddress != actor) return NO;
    const float expected[3] = {expectedTarget.x, expectedTarget.y, expectedTarget.z};
    const float observed[3] = {target.x, target.y, target.z};
    return std::memcmp(expected, observed, sizeof(expected)) == 0;
}
@end
@interface CoreSetV17AimDynamics () {
    CoreSet::BasicAimRuntimeState _state;
    CoreSet::BasicAimTakeoverGate _takeover;
    CoreSet::BasicAimDropoutHold _dropout;
}
@end
@implementation CoreSetV17AimDynamics
- (void)reset { _state.reset(); _takeover.reset(); _dropout.reset(); }
- (BOOL)rememberTarget:(CoreSetWorldPoint *)target actor:(uint64_t)actor
    generation:(uint64_t)generation now:(double)now {
    return target && _dropout.publish(actor, generation, {target.x, target.y, target.z}, now);
}
- (CoreSetWorldPoint *)cachedTargetForGeneration:(uint64_t)generation
    now:(double)now stateClear:(BOOL)stateClear {
    uint64_t actor = 0; CoreSet::BasicAimPoint point{};
    if (!_dropout.reuse(generation, now, stateClear, &actor, &point)) return nil;
    return [CoreSetWorldPoint pointWithX:point.x y:point.y z:point.z];
}
- (BOOL)permitsTakeoverPitch:(float)pitch yaw:(float)yaw threshold:(float)threshold
    confirmationFrames:(NSInteger)confirmationFrames pauseSeconds:(double)pauseSeconds now:(double)now {
    const double magnitude = std::hypot((double)pitch, (double)yaw);
    return _takeover.update(magnitude, threshold, (int)confirmationFrames, pauseSeconds, now);
}
- (CoreSetBasicAimDelta *)planFromCamera:(CoreSetWorldPoint *)camera
    target:(CoreSetWorldPoint *)target actor:(uint64_t)actor generation:(uint64_t)generation
    now:(double)now currentPitch:(float)currentPitch currentYaw:(float)currentYaw
    strength:(float)strength smoothingSeconds:(float)smoothingSeconds
    pitchSpeed:(float)pitchSpeed yawSpeed:(float)yawSpeed {
    CoreSet::BasicAimStep step;
    CoreSet::BasicAimTuning tuning{strength, smoothingSeconds, pitchSpeed, yawSpeed};
    if (!camera || !target || !CoreSet::basicAimDynamicStep(
        {camera.x, camera.y, camera.z}, {target.x, target.y, target.z},
        currentPitch, currentYaw, actor, generation, now, tuning, &_state, &step)) return nil;
    CoreSetBasicAimDelta *result = [CoreSetBasicAimDelta new];
    result.pitch = step.pitch; result.yaw = step.yaw; return result;
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
    configRevision:(uint64_t)configRevision axis:(CoreSetTargetWriteAxis)axis
    pitchDelta:(float)pitchDelta yawDelta:(float)yawDelta {
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
            (!first && !second) || !std::isfinite(pitchDelta) || !std::isfinite(yawDelta) ||
            std::fabs(pitchDelta) > 1 || std::fabs(yawDelta) > 1 ||
            (!first && pitchDelta != 0) || (!second && yawDelta != 0) ||
            (pitchDelta == 0 && yawDelta == 0) ||
            !std::isfinite(snapshot.controlPitchDegrees) || !std::isfinite(snapshot.controlYawDegrees) ||
            std::fabs(snapshot.controlPitchDegrees) > 360 || std::fabs(snapshot.controlYawDegrees) > 360) {
            result = CSProbeFailure(@"invalid complete battle snapshot, axis or bounded nonzero delta", NO);
            return;
        }
        self->_authority.snapshot = snapshot;
        self->_authority.token = requestToken;
        auto &context = self->_authority->context;
        context.pid = snapshot.processID; context.imageBase = snapshot.imageBase;
        context.readGeneration = snapshot.sessionGeneration; context.controller = snapshot.controllerAddress;
        context.hostGeneration = hostGeneration; context.configRevision = configRevision;
        context.lane = CoreSetTargetWriteLaneAim;
        context.slot = CoreSetTargetWriteSlotControlRotation; context.axis = axis;
        [requestToken getUUIDBytes:context.requestToken.data()];
        [snapshot.snapshotID getUUIDBytes:context.snapshotID.data()];
        if (![self->_authority live] || !self->_authority->gate.begin(context, context,
            snapshot.captureCompletedMonotonicSeconds, CACurrentMediaTime())) {
            result = CSProbeFailure(@"live request/target validation rejected or snapshot expired", NO);
        } else {
            const float oldValues[2] = {snapshot.controlPitchDegrees, snapshot.controlYawDegrees};
            const float newValues[2] = {snapshot.controlPitchDegrees + pitchDelta,
                                      snapshot.controlYawDegrees + yawDelta};
            const size_t index = axis == CoreSetTargetWriteAxisSecond ? 1 : 0;
            const size_t length = axis == CoreSetTargetWriteAxisBoth ? sizeof(oldValues) : sizeof(float);
            if (std::fabs(newValues[0]) > 360 || std::fabs(newValues[1]) > 360) {
                result = CSProbeFailure(@"probe output outside bounded rotation range", NO);
            } else {
                result = [self->_writer writeControllerActionForPID:context.pid imageBase:context.imageBase
                    controller:context.controller lane:CoreSetTargetWriteLaneAim
                    slot:CoreSetTargetWriteSlotControlRotation axis:axis generation:context.readGeneration
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
            mappedAliasReleased:NO generationAdvanced:NO backendClean:NO
            noUnresolvedState:NO targetWriteAttempted:YES noInFlight:NO];
    }
    dispatch_sync(_queue, cleanup);
    return result;
}
- (void)dealloc { _authority->stopping.store(true); [_writer disconnect]; }
@end
