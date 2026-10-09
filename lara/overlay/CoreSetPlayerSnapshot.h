#import <UIKit/UIKit.h>
#import "CoreSetReadSession.h"
#import "CoreSetBattlePublication.h"

NS_ASSUME_NONNULL_BEGIN

@class CoreSetPlayerSnapshot;

@interface CoreSetWorldPoint : NSObject
@property(nonatomic, readonly) float x;
@property(nonatomic, readonly) float y;
@property(nonatomic, readonly) float z;
+ (instancetype)pointWithX:(float)x y:(float)y z:(float)z;
@end

@interface CoreSetBoneSegment : NSObject
@property(nonatomic, readonly) CGPoint start;
@property(nonatomic, readonly) CGPoint end;
@end

@interface CoreSetGrenadePredictionSegment : CoreSetBoneSegment
@property(nonatomic, readonly) UIColor *color;
@property(nonatomic, readonly) double shadowLineWidth;
@property(nonatomic, readonly) double lineWidth;
@end

typedef NS_ENUM(NSInteger, CoreSetWarningYawSource) {
    CoreSetWarningYawSourceNone = 0,
    CoreSetWarningYawSourceServerControlRotation = 1,
    CoreSetWarningYawSourceReplicatedMovement = 2,
};

@interface CoreSetPlayerMark : NSObject
@property(nonatomic, readonly) uint64_t actorAddress;
@property(nonatomic, readonly, nullable) CoreSetWorldPoint *actorWorldPosition;
@property(nonatomic, readonly) uint8_t healthStatusCode;
@property(nonatomic, readonly) uint32_t referenceStateWord;
@property(nonatomic, readonly) uint8_t referenceFlag14;
@property(nonatomic, readonly) BOOL downedKnown;
@property(nonatomic, readonly) BOOL downed;
// Core-local candidate record +0x1e0/+0x1ec producers both copy the selected
// profile's first bone. These are candidate-record fields, not actor offsets.
@property(nonatomic, readonly, nullable) CoreSetWorldPoint *referenceAnchor1e0WorldPosition;
@property(nonatomic, readonly, nullable) CoreSetWorldPoint *referenceAnchor1ecWorldPosition;
@property(nonatomic, copy, readonly, nullable) NSString *weaponName;
@property(nonatomic, readonly) uint32_t weaponID;
@property(nonatomic, copy, readonly, nullable) NSString *playerName;
@property(nonatomic, readonly) uint32_t teamID;
@property(nonatomic, readonly) float health;
@property(nonatomic, readonly) float maximumHealth;
@property(nonatomic, readonly) BOOL bot;
@property(nonatomic, readonly) CGPoint center;
@property(nonatomic, readonly) CGPoint head;
// Exact first projected draw-record point consumed from Core record +0x30/+0x34.
// It is produced from the same profile row[0] world point as candidate +0x1e0.
@property(nonatomic, readonly) BOOL informationAnchorPresent;
@property(nonatomic, readonly) CGPoint informationAnchor;
// Present only when the already requested bone capture supplies a known
// reference profile and a projected, end-reread top anchor. Otherwise root+90.
@property(nonatomic, readonly, nullable) NSNumber *headBoneIndex;
@property(nonatomic, readonly) CGPoint feet;
@property(nonatomic, readonly) double distanceUnitsDividedBy100;
@property(nonatomic, readonly) NSArray<CoreSetBoneSegment *> *boneSegments;
@property(nonatomic, readonly) BOOL onScreen;
@property(nonatomic, readonly) CGPoint indicatorProjection;
@property(nonatomic, readonly) CGPoint radarCameraDelta;
// Core's primary server-rotation yaw only; nil for non-finite/out-of-range
// values. This is not a promise that the current controller is aiming here.
@property(nonatomic, readonly, nullable) NSNumber *warningServerYawDegrees;
// Reference primary/fallback selection with an explicit reflected owner.
// Neither source proves current controller aim or network replication freshness.
@property(nonatomic, readonly, nullable) NSNumber *warningYawDegrees;
@property(nonatomic, readonly) CoreSetWarningYawSource warningYawSource;
@end

@interface CoreSetGrenadeMark : NSObject
@property(nonatomic, readonly) CGPoint point;
@property(nonatomic, readonly) double distanceUnitsDividedBy100;
// Seconds (0,10], only for a typed EliteProjectile and verified target clock.
@property(nonatomic, readonly, nullable) NSNumber *countdownSeconds;
// Local display prediction, never a collision result or a world blast radius.
@property(nonatomic, readonly) NSArray<CoreSetGrenadePredictionSegment *> *predictionSegments;
@property(nonatomic, readonly) BOOL predictionEndpointPresent;
@property(nonatomic, readonly) CGPoint predictionEndpoint;
@end

// Core v1.7 c3c3c's validated local action record. The two tokens are
// target-object identities used only by c416c's local continuity state; none
// of these values is a writable target slot.
@interface CoreSetRecoilPostSample : NSObject
@property(nonatomic, readonly) uint64_t key;
@property(nonatomic, readonly) uint64_t ownerToken;
@property(nonatomic, readonly) uint8_t active;
@property(nonatomic, readonly) float value0;
@property(nonatomic, readonly) float value1;
@property(nonatomic, readonly) float value2;
@property(nonatomic, readonly) float value3;
@property(nonatomic, readonly) float value4;
@property(nonatomic, readonly) float value5;
@end

@interface CoreSetPlayerSnapshot : NSObject
@property(nonatomic, readonly) uint64_t sessionGeneration;
@property(nonatomic, readonly) int32_t processID;
@property(nonatomic, readonly) uint64_t imageBase;
@property(nonatomic, copy, readonly) NSUUID *snapshotID;
@property(nonatomic, readonly) NSArray<CoreSetPlayerMark *> *marks;
@property(nonatomic, readonly) NSArray<CoreSetGrenadeMark *> *grenadeMarks;
@property(nonatomic, readonly) NSUInteger observedPlayerCount;
@property(nonatomic, readonly) NSUInteger observedBotCount;
@property(nonatomic, readonly) double cameraYawDegrees;
@property(nonatomic, readonly) double cameraPitchDegrees;
@property(nonatomic, readonly) double cameraRollDegrees;
@property(nonatomic, readonly) double cameraFieldOfViewDegrees;
// Populated only by the explicit battle-input capture overload. These are
// observed inputs, not an aim plan or permission to write to the target.
@property(nonatomic, readonly) BOOL battleInputsPresent;
@property(nonatomic, readonly, nullable) CoreSetWorldPoint *cameraWorldPosition;
@property(nonatomic, readonly, nullable) CoreSetWorldPoint *localWorldPosition;
@property(nonatomic, readonly) CGSize canvasSize;
@property(nonatomic, readonly) uint64_t controllerAddress;
@property(nonatomic, readonly) uint64_t localActorAddress;
@property(nonatomic, readonly) BOOL localADS;
@property(nonatomic, readonly) BOOL localFiring;
@property(nonatomic, readonly) uint8_t localFiringRaw;
@property(nonatomic, readonly) float controlPitchDegrees;
@property(nonatomic, readonly) float controlYawDegrees;
@property(nonatomic, readonly) float rotationInputPitch;
@property(nonatomic, readonly) float rotationInputYaw;
// Present only when the exact c3b24/c3c3c input reads succeed in the final
// battle-input stability pass. The binding is this read publication's nonzero
// 32-bit generation, matching c416c/c571c's context role.
@property(nonatomic, readonly) BOOL recoilInputsPresent;
@property(nonatomic, readonly) uint32_t recoilBinding;
@property(nonatomic, readonly, nullable) CoreSetRecoilPostSample *recoilPostSample;
@property(nonatomic, readonly) float recoilFirstWeight;
@property(nonatomic, readonly) float recoilFirstBindingScale;
@property(nonatomic, readonly) float recoilSecondWeight;
@property(nonatomic, readonly) float recoilSecondBindingScale;
// Start time is diagnostic duration evidence. Consumers use the completion
// time for delivery freshness because the collector revalidates identity,
// roots, membership and observed fields immediately before publishing.
@property(nonatomic, readonly) double captureStartedMonotonicSeconds;
@property(nonatomic, readonly) double captureCompletedMonotonicSeconds;
@property(nonatomic, readonly) BOOL bot;
@property(nonatomic, readonly) double distanceMeters;
// Counts of already-read fields, never raw names/addresses or a parity claim.
@property(nonatomic, copy, readonly) NSString *readSemanticDiagnostic;
@end

// Main-thread, bounded local history. No target reads or function calls.
@interface CoreSetGrenadeMotionTracker : NSObject
- (void)decorateSnapshot:(CoreSetPlayerSnapshot *)snapshot canvasSize:(CGSize)canvasSize
             nativeScale:(double)nativeScale NS_SWIFT_NAME(decorate(_:canvasSize:nativeScale:));
- (BOOL)clear;
@end

@interface CoreSetActionCandidateRecord : NSObject
@property(nonatomic, readonly) CoreSetActionCandidateRawRecord raw;
@property(nonatomic, readonly) uint64_t sessionGeneration;
@property(nonatomic, readonly) int32_t processID;
@property(nonatomic, readonly) uint64_t imageBase;
@property(nonatomic, readonly) uint64_t controllerAddress;
@property(nonatomic, copy, readonly) NSUUID *snapshotID;
@property(nonatomic, readonly) double captureCompletedMonotonicSeconds;
@property(nonatomic, readonly) BOOL bot;
@property(nonatomic, readonly) double distanceMeters;
@property(nonatomic, readonly) CGPoint screenPoint;
@property(nonatomic, readonly) CGSize canvasSize;
@property(nonatomic, readonly) double cameraPitchDegrees;
@property(nonatomic, readonly) double cameraYawDegrees;
@property(nonatomic, readonly) double cameraRollDegrees;
@property(nonatomic, readonly) double cameraFieldOfViewDegrees;
@end

@interface CoreSetActionCandidatePublicationStore : NSObject
- (nullable CoreSetActionCandidateRecord *)publishCandidateKey:(uint64_t)candidateKey
    target:(CoreSetWorldPoint *)target camera:(CoreSetWorldPoint *)camera
    bestPixels:(double)bestPixels radius:(double)radius screenPoint:(CGPoint)screenPoint
    canvasSize:(CGSize)canvasSize cameraPitch:(double)cameraPitch cameraYaw:(double)cameraYaw
    cameraRoll:(double)cameraRoll cameraFOV:(double)cameraFOV
    bot:(BOOL)bot distanceMeters:(double)distanceMeters
    sessionGeneration:(uint64_t)sessionGeneration processID:(int32_t)processID
    imageBase:(uint64_t)imageBase controller:(uint64_t)controller
    snapshotID:(NSUUID *)snapshotID capturedAt:(double)capturedAt;
- (nullable CoreSetActionCandidateRecord *)publishMissingForSessionGeneration:(uint64_t)sessionGeneration
    processID:(int32_t)processID imageBase:(uint64_t)imageBase controller:(uint64_t)controller
    snapshotID:(NSUUID *)snapshotID capturedAt:(double)capturedAt;
- (nullable CoreSetActionCandidateRecord *)copyRecord;
- (void)clear;
@end

// Immutable action-only publication. It deliberately contains no marks,
// screen points or full CoreSetPlayerSnapshot reference.
@interface CoreSetActionInputAuthority : NSObject
@property(nonatomic, readonly) CoreSetActionInputAuthorityRawRecord raw;
@property(nonatomic, readonly) uint64_t sessionGeneration;
@property(nonatomic, readonly) int32_t processID;
@property(nonatomic, readonly) uint64_t imageBase;
@property(nonatomic, copy, readonly) NSUUID *snapshotID;
@property(nonatomic, readonly) double captureStartedMonotonicSeconds;
@property(nonatomic, readonly) double captureCompletedMonotonicSeconds;
@property(nonatomic, readonly) uint64_t controllerAddress;
@property(nonatomic, readonly) uint64_t localActorAddress;
@property(nonatomic, readonly) BOOL localADS;
@property(nonatomic, readonly) BOOL localFiring;
@property(nonatomic, readonly) uint8_t localFiringRaw;
@property(nonatomic, readonly) float controlPitchDegrees;
@property(nonatomic, readonly) float controlYawDegrees;
@property(nonatomic, readonly) float rotationInputPitch;
@property(nonatomic, readonly) float rotationInputYaw;
@property(nonatomic, readonly) BOOL recoilInputsPresent;
@property(nonatomic, readonly) uint32_t recoilBinding;
@property(nonatomic, strong, readonly, nullable) CoreSetRecoilPostSample *recoilPostSample;
@property(nonatomic, readonly) float recoilFirstWeight;
@property(nonatomic, readonly) float recoilFirstBindingScale;
@property(nonatomic, readonly) float recoilSecondWeight;
@property(nonatomic, readonly) float recoilSecondBindingScale;
// c2e24 predecessor authority is unresolved. Never infer the current slot
// from localFiringRaw.
@property(nonatomic, readonly) BOOL routeAuthorityResolved;
// 1 = controller +0x620, 2 = controller +0x828; -1 while unresolved.
@property(nonatomic, readonly) NSInteger resolvedActionSlotRaw;
+ (nullable instancetype)authorityWithSnapshot:(CoreSetPlayerSnapshot *)snapshot;
@end

@interface CoreSetPlayerCollector : NSObject
// Per-thread failure stage for the immediately preceding capture call. The
// value contains no target addresses or field contents and is intended only
// for distinguishing semantic/local validation from transport failures.
+ (NSString *)lastCaptureDiagnostic;
// Freshly re-reads the exact world -> net driver -> connection -> controller
// and controller -> local actor chain. This is a bounded identity check for a
// captured battle snapshot; it neither publishes a frame nor writes target data.
+ (BOOL)validateLiveIdentity:(CoreSetReadSession *)session
                    snapshot:(CoreSetPlayerSnapshot *)snapshot
    NS_SWIFT_NAME(validateLiveIdentity(_:snapshot:));
+ (BOOL)validateLiveAuthority:(CoreSetReadSession *)session
                    authority:(CoreSetActionInputAuthority *)authority
    NS_SWIFT_NAME(validateLiveAuthority(_:authority:));
// Nil means no complete, identity-stable capture; it must never be interpreted
// as an empty successful frame. No remote function calls or writes occur.
+ (nullable CoreSetPlayerSnapshot *)capture:(CoreSetReadSession *)session
                              canvasSize:(CGSize)canvasSize;
+ (nullable CoreSetPlayerSnapshot *)capture:(CoreSetReadSession *)session
                              canvasSize:(CGSize)canvasSize
                              playerBones:(BOOL)playerBones
                                 botBones:(BOOL)botBones
                        boneDistanceLimit:(double)boneDistanceLimit
                         includeOffscreen:(BOOL)includeOffscreen
                             includeRadar:(BOOL)includeRadar;
+ (nullable CoreSetPlayerSnapshot *)capture:(CoreSetReadSession *)session
                              canvasSize:(CGSize)canvasSize
                              playerBones:(BOOL)playerBones
                                 botBones:(BOOL)botBones
                        boneDistanceLimit:(double)boneDistanceLimit
                         includeOffscreen:(BOOL)includeOffscreen
                             includeRadar:(BOOL)includeRadar
                     includeBattleInputs:(BOOL)includeBattleInputs;
+ (nullable CoreSetPlayerSnapshot *)capture:(CoreSetReadSession *)session
                              canvasSize:(CGSize)canvasSize
                              playerBones:(BOOL)playerBones
                                 botBones:(BOOL)botBones
                        boneDistanceLimit:(double)boneDistanceLimit
                         includeOffscreen:(BOOL)includeOffscreen
                             includeRadar:(BOOL)includeRadar
                     includeBattleInputs:(BOOL)includeBattleInputs
                        playerWeaponText:(BOOL)playerWeaponText
                           botWeaponText:(BOOL)botWeaponText;
+ (nullable CoreSetPlayerSnapshot *)capture:(CoreSetReadSession *)session
                              canvasSize:(CGSize)canvasSize
                              playerBones:(BOOL)playerBones
                                 botBones:(BOOL)botBones
                        boneDistanceLimit:(double)boneDistanceLimit
                         includeOffscreen:(BOOL)includeOffscreen
                             includeRadar:(BOOL)includeRadar
                     includeBattleInputs:(BOOL)includeBattleInputs
                        playerWeaponText:(BOOL)playerWeaponText
                           botWeaponText:(BOOL)botWeaponText
                   includeGrenadeWarning:(BOOL)includeGrenadeWarning;
+ (nullable CoreSetPlayerSnapshot *)capture:(CoreSetReadSession *)session
                              canvasSize:(CGSize)canvasSize
                              playerBones:(BOOL)playerBones
                                 botBones:(BOOL)botBones
                        boneDistanceLimit:(double)boneDistanceLimit
                         includeOffscreen:(BOOL)includeOffscreen
                             includeRadar:(BOOL)includeRadar
                     includeBattleInputs:(BOOL)includeBattleInputs
                        playerWeaponText:(BOOL)playerWeaponText
                           botWeaponText:(BOOL)botWeaponText
                   includeGrenadeWarning:(BOOL)includeGrenadeWarning
                           includeCounts:(BOOL)includeCounts;
+ (nullable CoreSetPlayerSnapshot *)capture:(CoreSetReadSession *)session
                              canvasSize:(CGSize)canvasSize
                              playerBones:(BOOL)playerBones
                                 botBones:(BOOL)botBones
                        boneDistanceLimit:(double)boneDistanceLimit
                         includeOffscreen:(BOOL)includeOffscreen
                             includeRadar:(BOOL)includeRadar
                     includeBattleInputs:(BOOL)includeBattleInputs
                        playerWeaponText:(BOOL)playerWeaponText
                           botWeaponText:(BOOL)botWeaponText
                   includeGrenadeWarning:(BOOL)includeGrenadeWarning
                           includeCounts:(BOOL)includeCounts
                      playerInformation:(BOOL)playerInformation
                         botInformation:(BOOL)botInformation;
+ (nullable CoreSetPlayerSnapshot *)capture:(CoreSetReadSession *)session
                              canvasSize:(CGSize)canvasSize
                              playerBones:(BOOL)playerBones
                                 botBones:(BOOL)botBones
                        boneDistanceLimit:(double)boneDistanceLimit
                         includeOffscreen:(BOOL)includeOffscreen
                             includeRadar:(BOOL)includeRadar
                     includeBattleInputs:(BOOL)includeBattleInputs
                        playerWeaponText:(BOOL)playerWeaponText
                           botWeaponText:(BOOL)botWeaponText
                   includeGrenadeWarning:(BOOL)includeGrenadeWarning
                           includeCounts:(BOOL)includeCounts
                      playerInformation:(BOOL)playerInformation
                         botInformation:(BOOL)botInformation
                       includeWarningYaw:(BOOL)includeWarningYaw;
+ (nullable CoreSetPlayerSnapshot *)capture:(CoreSetReadSession *)session
                              canvasSize:(CGSize)canvasSize
                              playerBones:(BOOL)playerBones
                                 botBones:(BOOL)botBones
                        boneDistanceLimit:(double)boneDistanceLimit
                         includeOffscreen:(BOOL)includeOffscreen
                             includeRadar:(BOOL)includeRadar
                     includeBattleInputs:(BOOL)includeBattleInputs
                        playerWeaponText:(BOOL)playerWeaponText
                           botWeaponText:(BOOL)botWeaponText
                   includeGrenadeWarning:(BOOL)includeGrenadeWarning
                           includeCounts:(BOOL)includeCounts
                      playerInformation:(BOOL)playerInformation
                         botInformation:(BOOL)botInformation
                       includeWarningYaw:(BOOL)includeWarningYaw
                    maximumDrawDistance:(double)maximumDrawDistance;
// Refreshes only live camera/root geometry for an identity-stable roster.
// Static metadata is retained from the full scan; every returned screen point
// is recomputed from current target reads and a new snapshot identity.
+ (nullable CoreSetPlayerSnapshot *)refreshGeometryForSnapshot:(CoreSetPlayerSnapshot *)snapshot
                                                       session:(CoreSetReadSession *)session
                                                    canvasSize:(CGSize)canvasSize
                                               includeOffscreen:(BOOL)includeOffscreen
                                           maximumDrawDistance:(double)maximumDrawDistance
    NS_SWIFT_NAME(refreshGeometry(for:session:canvasSize:includeOffscreen:maximumDrawDistance:));
// Reprojects the latest identity-stable world geometry with the current target
// camera. No actor fields or roots are reread on this presentation path.
+ (nullable CoreSetPlayerSnapshot *)reprojectPresentationForSnapshot:(CoreSetPlayerSnapshot *)snapshot
                                                             session:(CoreSetReadSession *)session
                                                          canvasSize:(CGSize)canvasSize
                                                     includeOffscreen:(BOOL)includeOffscreen
                                                 maximumDrawDistance:(double)maximumDrawDistance
    NS_SWIFT_NAME(reprojectPresentation(for:session:canvasSize:includeOffscreen:maximumDrawDistance:));
// Fast action path over an immutable, identity-stable producer publication.
// The action session may have its own generation; process/image plus initial
// and final roots bind the publication to that independent session. A zero targetActor
// reprojects cached candidate world points with the current camera and refreshes
// exact battle inputs. A nonzero targetActor additionally rereads only that
// actor's state, root position and physical bones. Producer battle inputs are
// neither required nor copied. No actor-array scan occurs.
+ (nullable CoreSetPlayerSnapshot *)refreshActionForSnapshot:(CoreSetPlayerSnapshot *)snapshot
                                                  targetActor:(uint64_t)targetActor
                                                      session:(CoreSetReadSession *)session
                                                   canvasSize:(CGSize)canvasSize
                                          maximumDrawDistance:(double)maximumDrawDistance
    NS_SWIFT_NAME(refreshAction(for:targetActor:session:canvasSize:maximumDrawDistance:));
@end

// Pure local projection of an already captured, identity-stable camera delta.
FOUNDATION_EXPORT BOOL CoreSetRadarPoint(CGPoint cameraMinusActor, double cameraYawDegrees,
                                          double radius, double detectionDistance,
                                          CGPoint center, CGPoint *output);
FOUNDATION_EXPORT BOOL CoreSetWarningAngleMatches(CGPoint cameraMinusActor,
                                                   double serverYawDegrees);
FOUNDATION_EXPORT NSString * _Nullable CoreSetReferencePlayerDistanceText(double distance);
FOUNDATION_EXPORT NSString * _Nullable CoreSetReferenceWarningText(
    NSString * _Nullable playerName, BOOL bot, NSString * _Nullable weaponName,
    uint32_t weaponID, double distance);
FOUNDATION_EXPORT BOOL CoreSetReferencePlayerRay(CGSize canvasSize, double nativeScale,
    CGPoint head, CGPoint *origin, CGPoint *endpoint);

NS_ASSUME_NONNULL_END
