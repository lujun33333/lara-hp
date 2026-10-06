#import "CoreSetPlayerSnapshot.h"
#import "CoreSetTargetWriteSession.h"

NS_ASSUME_NONNULL_BEGIN

// The test host must independently observe current PID/base/read generation/
// controller AND active request/host generation/config revision. Never return
// YES merely by comparing the supplied arguments with themselves or cached data.
// Called synchronously on the probe worker, repeatedly before/after the write.
// Must not call probe submit/stop recursively or synchronously wait on the UI.
typedef BOOL (^CoreSetProbeLiveValidator)(CoreSetPlayerSnapshot *captured,
    NSUUID *requestToken, uint64_t hostGeneration, uint64_t configRevision);

@interface CoreSetBasicAimDelta : NSObject
@property(nonatomic, readonly) float pitch;
@property(nonatomic, readonly) float yaw;
+ (BOOL)triggerMode:(NSInteger)mode ads:(BOOL)ads firing:(BOOL)firing
    NS_SWIFT_NAME(trigger(mode:ads:firing:));
+ (nullable CoreSetPlayerMark *)selectFromSnapshot:(CoreSetPlayerSnapshot *)snapshot
    radius:(double)radius maximumDistance:(double)maximumDistance includeBots:(BOOL)includeBots
    NS_SWIFT_NAME(select(snapshot:radius:maximumDistance:includeBots:));
+ (nullable CoreSetPlayerMark *)selectFromSnapshot:(CoreSetPlayerSnapshot *)snapshot
    radius:(double)radius maximumDistance:(double)maximumDistance includeBots:(BOOL)includeBots
    lockSameTarget:(BOOL)lockSameTarget previousActor:(uint64_t)previousActor
    NS_SWIFT_NAME(select(snapshot:radius:maximumDistance:includeBots:lockSameTarget:previousActor:));
+ (nullable CoreSetPlayerMark *)selectFromSnapshot:(CoreSetPlayerSnapshot *)snapshot point:(NSInteger)point
    radius:(double)radius maximumDistance:(double)maximumDistance includeBots:(BOOL)includeBots
    lockSameTarget:(BOOL)lockSameTarget previousActor:(uint64_t)previousActor
    NS_SWIFT_NAME(select(snapshot:point:radius:maximumDistance:includeBots:lockSameTarget:previousActor:));
+ (nullable CoreSetBasicAimDelta *)planFromCamera:(CoreSetWorldPoint *)camera
    target:(CoreSetWorldPoint *)target currentPitch:(float)currentPitch currentYaw:(float)currentYaw
    NS_SWIFT_NAME(plan(camera:target:currentPitch:currentYaw:));
+ (nullable CoreSetWorldPoint *)fallbackTargetForMark:(CoreSetPlayerMark *)mark point:(NSInteger)point
    NS_SWIFT_NAME(fallbackTarget(mark:point:));
+ (BOOL)validateCaptured:(CoreSetPlayerSnapshot *)captured live:(CoreSetPlayerSnapshot *)live
    actor:(uint64_t)actor point:(NSInteger)point radius:(double)radius
    maximumDistance:(double)maximumDistance includeBots:(BOOL)includeBots
    lockSameTarget:(BOOL)lockSameTarget previousActor:(uint64_t)previousActor
    expectedTarget:(CoreSetWorldPoint *)expectedTarget
    NS_SWIFT_NAME(validate(captured:live:actor:point:radius:maximumDistance:includeBots:lockSameTarget:previousActor:expectedTarget:));
@end
@interface CoreSetV17AimDynamics : NSObject
- (void)reset;
- (BOOL)rememberTarget:(CoreSetWorldPoint *)target actor:(uint64_t)actor
    generation:(uint64_t)generation now:(double)now;
- (nullable CoreSetWorldPoint *)cachedTargetForGeneration:(uint64_t)generation
    now:(double)now stateClear:(BOOL)stateClear
    NS_SWIFT_NAME(cachedTarget(generation:now:stateClear:));
- (BOOL)permitsTakeoverPitch:(float)pitch yaw:(float)yaw threshold:(float)threshold
    confirmationFrames:(NSInteger)confirmationFrames pauseSeconds:(double)pauseSeconds now:(double)now
    NS_SWIFT_NAME(permitsTakeover(pitch:yaw:threshold:confirmationFrames:pauseSeconds:now:));
- (nullable CoreSetBasicAimDelta *)planFromCamera:(CoreSetWorldPoint *)camera
    target:(CoreSetWorldPoint *)target actor:(uint64_t)actor generation:(uint64_t)generation
    now:(double)now currentPitch:(float)currentPitch currentYaw:(float)currentYaw
    strength:(float)strength smoothingSeconds:(float)smoothingSeconds
    pitchSpeed:(float)pitchSpeed yawSpeed:(float)yawSpeed
    NS_SWIFT_NAME(plan(camera:target:actor:generation:now:currentPitch:currentYaw:strength:smoothingSeconds:pitchSpeed:yawSpeed:));
@end
@interface CoreSetBasicAimTriggerState : NSObject
- (void)reset;
- (BOOL)updateMode:(NSInteger)mode ads:(BOOL)ads firing:(BOOL)firing now:(double)now
    NS_SWIFT_NAME(update(mode:ads:firing:now:));
- (BOOL)permitsAt:(double)now NS_SWIFT_NAME(permits(now:));
@end

// Single-transaction component reused by the verified v1.7 aim subset.
// Prediction, LOS/downed composition and the alternate +0x828 write route are
// outside this component until their target-side producers are closed.
// Each instance permits one explicit submission. Default kernel profile gates
// stay intact: this API does not install a profile or grant write capability.
@interface CoreSetIsolatedWriteProbe : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)initWithLiveValidator:(CoreSetProbeLiveValidator)validator;
// Only the primary ControlRotation slot; First/Second/Both select pitch/yaw.
// Deltas must be finite, <=1 degree, and zero for an unselected axis. Old bytes
// come from the immutable complete battle snapshot, not a caller-supplied buffer.
// Any submission failure also consumes this instance's single attempt.
- (CoreSetTargetWriteResult *)submitSnapshot:(CoreSetPlayerSnapshot *)snapshot
    requestToken:(NSUUID *)requestToken hostGeneration:(uint64_t)hostGeneration
    configRevision:(uint64_t)configRevision axis:(CoreSetTargetWriteAxis)axis
    pitchDelta:(float)pitchDelta yawDelta:(float)yawDelta
    NS_SWIFT_NAME(submit(snapshot:requestToken:hostGeneration:configRevision:axis:pitchDelta:yawDelta:));
// Synchronously revoke, drain, disconnect; stopped instances never resume.
- (CoreSetTargetWriteCleanupResult *)stop;
@end

NS_ASSUME_NONNULL_END
