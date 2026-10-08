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
// Low eight bytes of c4af8 result+0x8, staged by c3318 as c571c's next
// sample key. This is a float bit-pattern key, not an actor address.
@property(nonatomic, readonly) uint64_t geometrySampleKey;
+ (nullable CoreSetPlayerMark *)selectFromSnapshot:(CoreSetPlayerSnapshot *)snapshot
    radius:(double)radius maximumDistance:(double)maximumDistance includeBots:(BOOL)includeBots
    NS_SWIFT_NAME(select(snapshot:radius:maximumDistance:includeBots:));
+ (nullable CoreSetPlayerMark *)selectFromSnapshot:(CoreSetPlayerSnapshot *)snapshot
    radius:(double)radius maximumDistance:(double)maximumDistance includeBots:(BOOL)includeBots
    lockSameTarget:(BOOL)lockSameTarget previousActor:(uint64_t)previousActor
    NS_SWIFT_NAME(select(snapshot:radius:maximumDistance:includeBots:lockSameTarget:previousActor:));
+ (nullable CoreSetPlayerMark *)selectFromSnapshot:(CoreSetPlayerSnapshot *)snapshot point:(NSInteger)point
    radius:(double)radius maximumDistance:(double)maximumDistance includeBots:(BOOL)includeBots
    excludeKnocked:(BOOL)excludeKnocked
    lockSameTarget:(BOOL)lockSameTarget previousActor:(uint64_t)previousActor
    NS_SWIFT_NAME(select(snapshot:point:radius:maximumDistance:includeBots:excludeKnocked:lockSameTarget:previousActor:));
+ (nullable CoreSetWorldPoint *)fallbackTargetForMark:(CoreSetPlayerMark *)mark point:(NSInteger)point
    NS_SWIFT_NAME(fallbackTarget(mark:point:));
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
    target:(CoreSetWorldPoint *)target actor:(uint64_t)actor publicationID:(NSUUID *)publicationID
    now:(double)now currentPitch:(float)currentPitch currentYaw:(float)currentYaw
    strength:(float)strength smoothingSeconds:(float)smoothingSeconds
    curveSelector:(float)curveSelector horizontalSpeed:(float)horizontalSpeed
    verticalSpeed:(float)verticalSpeed predictionMilliseconds:(double)predictionMilliseconds
    residualGain:(float)residualGain minimumGain:(float)minimumGain
    deadzoneRatio:(float)deadzoneRatio minimumDeadzone:(float)minimumDeadzone
    NS_SWIFT_NAME(plan(camera:target:actor:publicationID:now:currentPitch:currentYaw:strength:smoothingSeconds:curveSelector:horizontalSpeed:verticalSpeed:predictionMilliseconds:residualGain:minimumGain:deadzoneRatio:minimumDeadzone:));
@end

@interface CoreSetV17ActionDelta : NSObject
@property(nonatomic, readonly) float pitch;
@property(nonatomic, readonly) float yaw;
@property(nonatomic, readonly) float aimPitch;
@property(nonatomic, readonly) float aimYaw;
@property(nonatomic, readonly) float recoilPitch;
@property(nonatomic, readonly) float recoilYaw;
@end

// One serial-worker instance mirrors c416c -> c571c -> c2d34 -> c2e24/c2e28.
// It produces a local merged delta only; it neither chooses +0x620/+0x828 nor
// owns a target write transaction.
@interface CoreSetV17RecoilDynamics : NSObject
- (void)reset;
- (nullable CoreSetV17ActionDelta *)planSnapshot:(CoreSetPlayerSnapshot *)snapshot
    aimPitch:(float)aimPitch aimYaw:(float)aimYaw geometrySampleKey:(uint64_t)geometrySampleKey
    verticalEnabled:(BOOL)verticalEnabled verticalStrength:(float)verticalStrength
    stopWhenNotFiring:(BOOL)stopWhenNotFiring horizontalEnabled:(BOOL)horizontalEnabled
    horizontalStrength:(float)horizontalStrength
    NS_SWIFT_NAME(plan(snapshot:aimPitch:aimYaw:geometrySampleKey:verticalEnabled:verticalStrength:stopWhenNotFiring:horizontalEnabled:horizontalStrength:));
// Core only feeds prior s13 after the input route's accepted/zero-draft path.
- (void)observeCommittedAimPitch:(float)aimPitch inputRoute:(BOOL)inputRoute
    recoilEnabled:(BOOL)recoilEnabled aimActive:(BOOL)aimActive
    acceptedFirstAxis:(BOOL)acceptedFirstAxis bothZeroDraft:(BOOL)bothZeroDraft
    NS_SWIFT_NAME(observeCommitted(aimPitch:inputRoute:recoilEnabled:aimActive:acceptedFirstAxis:bothZeroDraft:));
@end

// Production wrapper for c1f90/c3714/c3754/c3838 plus the closed merge
// predecessor rule. A committed checked-write maps to the sink result low bit;
// inputPaused supplies the observed w20=0 predecessor.
@interface CoreSetV17ActionRouteDynamics : NSObject
- (void)reset;
- (BOOL)useControlRotationWithRecoilEnabled:(BOOL)recoilEnabled
    inputPaused:(BOOL)inputPaused
    NS_SWIFT_NAME(useControlRotation(recoilEnabled:inputPaused:));
- (void)observeCommittedWithW20:(BOOL)w20 NS_SWIFT_NAME(observeCommitted(w20:));
@end
@interface CoreSetBasicAimTriggerState : NSObject
- (void)reset;
- (BOOL)updateMode:(NSInteger)mode ads:(BOOL)ads firing:(BOOL)firing now:(double)now
    NS_SWIFT_NAME(update(mode:ads:firing:now:));
- (BOOL)permitsAt:(double)now NS_SWIFT_NAME(permits(now:));
@end

// Single-transaction component reused by the v1.7 aim path.
// Each instance permits one explicit submission. Default kernel profile gates
// stay intact: this API does not install a profile or grant write capability.
@interface CoreSetIsolatedWriteProbe : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)initWithLiveValidator:(CoreSetProbeLiveValidator)validator;
// ControlRotation and RotationInput slots; First/Second/Both select pitch/yaw.
// Deltas must be finite, within Core's 720 deg/s * 50 ms maximum step, and zero for an unselected axis. Old bytes
// come from the immutable complete battle snapshot, not a caller-supplied buffer.
// Any submission failure also consumes this instance's single attempt.
- (CoreSetTargetWriteResult *)submitSnapshot:(CoreSetPlayerSnapshot *)snapshot
    requestToken:(NSUUID *)requestToken hostGeneration:(uint64_t)hostGeneration
    configRevision:(uint64_t)configRevision lane:(CoreSetTargetWriteLane)lane
    slot:(CoreSetTargetWriteSlot)slot
    axis:(CoreSetTargetWriteAxis)axis
    pitchDelta:(float)pitchDelta yawDelta:(float)yawDelta
    NS_SWIFT_NAME(submit(snapshot:requestToken:hostGeneration:configRevision:lane:slot:axis:pitchDelta:yawDelta:));
// Synchronously revoke, drain, disconnect; stopped instances never resume.
- (CoreSetTargetWriteCleanupResult *)stop;
@end

NS_ASSUME_NONNULL_END

