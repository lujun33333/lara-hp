#import "CoreSetPlayerSnapshot.h"
#import "CoreSetTargetWriteSession.h"

NS_ASSUME_NONNULL_BEGIN

// The test host must independently observe current PID/base/read generation/
// controller AND active request/host generation/config revision. Never return
// YES merely by comparing the supplied arguments with themselves or cached data.
// Called synchronously on the probe worker, repeatedly before/after the write.
// Must not call probe submit/stop recursively or synchronously wait on the UI.
typedef BOOL (^CoreSetProbeLiveValidator)(CoreSetActionInputAuthority *captured,
    NSUUID *requestToken, uint64_t hostGeneration, uint64_t configRevision);

@interface CoreSetBasicAimDelta : NSObject
@property(nonatomic, readonly) float pitch;
@property(nonatomic, readonly) float yaw;
// Low eight bytes of c4af8 result+0x8, staged by c3318 as c571c's next
// sample key. This is a float bit-pattern key, not an actor address.
@property(nonatomic, readonly) uint64_t geometrySampleKey;
// Core c4af8 result+0x38/+0x3c/+0x40.  Present only when the selected
// scene's C+0x17c prediction interval is positive; this remains a local
// calculated world point and grants no target-write authority.
@property(nonatomic, strong, readonly, nullable) CoreSetWorldPoint *predictedWorldPoint;
+ (double)circleRadiusForCanvasWidth:(double)width height:(double)height size:(NSInteger)size
    NS_SWIFT_NAME(circleRadius(canvasWidth:height:size:));
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

@interface CoreSetV17AimConfiguration : NSObject
@property(nonatomic, readonly) NSInteger maximumDistance;
@property(nonatomic, readonly) float lockThreshold;
@property(nonatomic, readonly) NSInteger confirmationFrames;
@property(nonatomic, readonly) double takeoverPauseSeconds;
- (nullable instancetype)initWithStoredScene:(NSInteger)storedScene
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
           customTakeoverPauseMilliseconds:(NSInteger)customTakeoverPauseMilliseconds
    NS_SWIFT_NAME(init(storedScene:storedLockStrength:customValuesPresent:customMaximumDistance:customStrength:customSmoothing:customConfirmationFrames:customHorizontalSpeed:customVerticalSpeed:customPredictionMilliseconds:customLockThreshold:customTakeoverPauseMilliseconds:));
@end

@interface CoreSetV17AimDynamics : NSObject
- (void)reset;
- (BOOL)rememberTarget:(CoreSetWorldPoint *)target actor:(uint64_t)actor
    generation:(uint64_t)generation now:(double)now;
- (nullable CoreSetWorldPoint *)cachedTargetForGeneration:(uint64_t)generation
    now:(double)now stateClear:(BOOL)stateClear
    NS_SWIFT_NAME(cachedTarget(generation:now:stateClear:));
- (BOOL)permitsTakeoverPitch:(float)pitch yaw:(float)yaw
    configuration:(CoreSetV17AimConfiguration *)configuration now:(double)now
    NS_SWIFT_NAME(permitsTakeover(pitch:yaw:configuration:now:));
- (nullable CoreSetBasicAimDelta *)planFromCamera:(CoreSetWorldPoint *)camera
    target:(CoreSetWorldPoint *)target actor:(uint64_t)actor publicationID:(NSUUID *)publicationID
    now:(double)now currentPitch:(float)currentPitch currentYaw:(float)currentYaw
    configuration:(CoreSetV17AimConfiguration *)configuration
    NS_SWIFT_NAME(plan(camera:target:actor:publicationID:now:currentPitch:currentYaw:configuration:));
- (nullable CoreSetBasicAimDelta *)planCandidate:(CoreSetActionCandidateRecord *)candidate
    input:(CoreSetActionInputAuthority *)input
    configuration:(CoreSetV17AimConfiguration *)configuration
    NS_SWIFT_NAME(plan(candidate:input:configuration:));
@end

// A future original upstream provider must supply these same-cycle records.
// No provider is currently bound; nil is unavailable, never an input-route
// fallback. Records are observations and do not grant target write authority.
typedef struct {
    uint64_t cycle;
    int32_t configID27Value;
    // resultGate: 0 = c3150 exact-one; 1 = c3698 low-bit.
    // lifecycle: 0 none, 1 ID27 restore, 2 scene clear, 3 reset with count,
    // 4 reset without count.
    uint8_t present, currentAimActive, forceInput, recoilEnabled, w20, resultGate, lifecycle;
} CoreSetNativeActionRouteInputRecord;
typedef struct {
    uint64_t cycle;
    uint64_t packedStatus;
    uint8_t present, w20, resultGate;
} CoreSetNativeActionRouteFeedbackRecord;

@interface CoreSetV17ActionRouteDecision : NSObject
@property(nonatomic, readonly) BOOL resolved;
@property(nonatomic, readonly) BOOL aimAllowed;
// 1 = c2e20 control fallthrough/+0x620; 2 = c3918/c3990 input route/+0x828.
@property(nonatomic, readonly) NSInteger slotRaw;
@property(nonatomic, readonly) NSInteger predecessorRaw;
@end

@interface CoreSetV17ActionRouteProducer : NSObject
@property(nonatomic, readonly) BOOL originalProviderBound;
@property(nonatomic, readonly) NSString *unresolvedReason;
- (void)reset;
- (nullable CoreSetV17ActionRouteDecision *)resolveAimPitch:(float)pitch yaw:(float)yaw
    configuration:(CoreSetV17AimConfiguration *)configuration now:(double)now
    nativeInput:(const CoreSetNativeActionRouteInputRecord * _Nullable)nativeInput
    NS_SWIFT_NAME(resolveAim(pitch:yaw:configuration:now:nativeInput:));
- (nullable CoreSetV17ActionRouteDecision *)resolveRecoilOnlyWithNativeInput:
    (const CoreSetNativeActionRouteInputRecord * _Nullable)nativeInput
    NS_SWIFT_NAME(resolveRecoilOnly(nativeInput:));
- (BOOL)observeNativeFeedback:(const CoreSetNativeActionRouteFeedbackRecord *)feedback;
@end

@interface CoreSetV17ActionDelta : NSObject
@property(nonatomic, readonly) float pitch;
@property(nonatomic, readonly) float yaw;
@property(nonatomic, readonly) float aimPitch;
@property(nonatomic, readonly) float aimYaw;
@property(nonatomic, readonly) float recoilPitch;
@property(nonatomic, readonly) float recoilYaw;
@end

@interface CoreSetV17RecoilConfiguration : NSObject
- (nullable instancetype)initWithEnabled:(BOOL)enabled
                         verticalEnabled:(BOOL)verticalEnabled
                  verticalStrengthPercent:(NSInteger)verticalStrengthPercent
                       stopWhenNotFiring:(BOOL)stopWhenNotFiring
                       horizontalEnabled:(BOOL)horizontalEnabled
                horizontalStrengthPercent:(NSInteger)horizontalStrengthPercent
    NS_SWIFT_NAME(init(enabled:verticalEnabled:verticalStrengthPercent:stopWhenNotFiring:horizontalEnabled:horizontalStrengthPercent:));
@end

// One serial-worker instance mirrors c416c -> c571c -> c2d34 -> c2e24/c2e28.
// It produces a local merged delta only; it neither chooses +0x620/+0x828 nor
// owns a target write transaction.
@interface CoreSetV17RecoilDynamics : NSObject
- (void)reset;
- (nullable CoreSetV17ActionDelta *)planSnapshot:(CoreSetPlayerSnapshot *)snapshot
    aimPitch:(float)aimPitch aimYaw:(float)aimYaw geometrySampleKey:(uint64_t)geometrySampleKey
    configuration:(nullable CoreSetV17RecoilConfiguration *)configuration
    NS_SWIFT_NAME(plan(snapshot:aimPitch:aimYaw:geometrySampleKey:configuration:));
- (nullable CoreSetV17ActionDelta *)planInput:(CoreSetActionInputAuthority *)input
    aimPitch:(float)aimPitch aimYaw:(float)aimYaw geometrySampleKey:(uint64_t)geometrySampleKey
    configuration:(nullable CoreSetV17RecoilConfiguration *)configuration
    NS_SWIFT_NAME(plan(input:aimPitch:aimYaw:geometrySampleKey:configuration:));
// Core only feeds prior s13 after the input route's accepted/zero-draft path.
- (void)observeAimFeedbackWithPitch:(float)aimPitch inputRoute:(BOOL)inputRoute
    recoilEnabled:(BOOL)recoilEnabled aimActive:(BOOL)aimActive
    acceptedFirstAxis:(BOOL)acceptedFirstAxis bothZeroDraft:(BOOL)bothZeroDraft
    NS_SWIFT_NAME(observeAimFeedback(pitch:inputRoute:recoilEnabled:aimActive:acceptedFirstAxis:bothZeroDraft:));
@end

@interface CoreSetBasicAimTriggerState : NSObject
- (void)reset;
- (BOOL)updateMode:(NSInteger)mode ads:(BOOL)ads firing:(BOOL)firing now:(double)now
    NS_SWIFT_NAME(update(mode:ads:firing:now:));
- (BOOL)permitsAt:(double)now NS_SWIFT_NAME(permits(now:));
@end

// Persistent serial action worker reused by the v1.7 aim/recoil path. Each
// submission gets a fresh snapshot authority lease; the mapped write session
// remains alive until stop. This API does not install a kernel profile.
@interface CoreSetIsolatedWriteProbe : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)initWithLiveValidator:(CoreSetProbeLiveValidator)validator;
- (instancetype)initWithReadSession:(CoreSetReadSession *)readSession
                       liveValidator:(CoreSetProbeLiveValidator)validator
    NS_SWIFT_NAME(init(readSession:liveValidator:));
// ControlRotation and RotationInput slots; First/Second/Both select pitch/yaw.
// Deltas must be finite, within Core's 720 deg/s * 50 ms maximum step, and zero for an unselected axis. Old bytes
// come from the immutable complete battle snapshot, not a caller-supplied buffer.
// A failed submission revokes only that snapshot lease; later fresh snapshots
// may submit again while the worker identity remains current.
- (CoreSetTargetWriteResult *)submitSnapshot:(CoreSetPlayerSnapshot *)snapshot
    requestToken:(NSUUID *)requestToken hostGeneration:(uint64_t)hostGeneration
    configRevision:(uint64_t)configRevision lane:(CoreSetTargetWriteLane)lane
    slot:(CoreSetTargetWriteSlot)slot
    axis:(CoreSetTargetWriteAxis)axis
    pitchDelta:(float)pitchDelta yawDelta:(float)yawDelta
    NS_SWIFT_NAME(submit(snapshot:requestToken:hostGeneration:configRevision:lane:slot:axis:pitchDelta:yawDelta:));
- (CoreSetTargetWriteResult *)submitAuthority:(CoreSetActionInputAuthority *)authority
    requestToken:(NSUUID *)requestToken hostGeneration:(uint64_t)hostGeneration
    configRevision:(uint64_t)configRevision lane:(CoreSetTargetWriteLane)lane
    slot:(CoreSetTargetWriteSlot)slot axis:(CoreSetTargetWriteAxis)axis
    pitchDelta:(float)pitchDelta yawDelta:(float)yawDelta
    NS_SWIFT_NAME(submit(authority:requestToken:hostGeneration:configRevision:lane:slot:axis:pitchDelta:yawDelta:));
// Synchronously revoke, drain, disconnect; stopped instances never resume.
- (CoreSetTargetWriteCleanupResult *)stop;
@end

NS_ASSUME_NONNULL_END
