#import <UIKit/UIKit.h>
#import "CoreSetReadSession.h"

NS_ASSUME_NONNULL_BEGIN

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
// Raw reflected HealthStatus byte, only when battleInputsPresent is true;
// enum values are not mapped to knocked/downed until independently proven.
@property(nonatomic, readonly) uint8_t healthStatusCode;
@property(nonatomic, copy, readonly, nullable) NSString *weaponName;
@property(nonatomic, readonly) uint32_t weaponID;
@property(nonatomic, copy, readonly, nullable) NSString *playerName;
@property(nonatomic, readonly) uint32_t teamID;
@property(nonatomic, readonly) float health;
@property(nonatomic, readonly) float maximumHealth;
@property(nonatomic, readonly) BOOL bot;
@property(nonatomic, readonly) CGPoint center;
@property(nonatomic, readonly) CGPoint head;
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
@property(nonatomic, readonly) double cameraFieldOfViewDegrees;
// Populated only by the explicit battle-input capture overload. These are
// observed inputs, not an aim plan or permission to write to the target.
@property(nonatomic, readonly) BOOL battleInputsPresent;
@property(nonatomic, readonly) uint64_t controllerAddress;
@property(nonatomic, readonly) uint64_t localActorAddress;
@property(nonatomic, readonly) BOOL localADS;
@property(nonatomic, readonly) BOOL localFiring;
@property(nonatomic, readonly) float controlPitchDegrees;
@property(nonatomic, readonly) float controlYawDegrees;
// Start time is diagnostic duration evidence. Consumers use the completion
// time for delivery freshness because the collector revalidates identity,
// roots, membership and observed fields immediately before publishing.
@property(nonatomic, readonly) double captureStartedMonotonicSeconds;
@property(nonatomic, readonly) double captureCompletedMonotonicSeconds;
// Counts of already-read fields, never raw names/addresses or a parity claim.
@property(nonatomic, copy, readonly) NSString *readSemanticDiagnostic;
@end

// Main-thread, bounded local history. No target reads or function calls.
@interface CoreSetGrenadeMotionTracker : NSObject
- (void)decorateSnapshot:(CoreSetPlayerSnapshot *)snapshot canvasSize:(CGSize)canvasSize
             nativeScale:(double)nativeScale NS_SWIFT_NAME(decorate(_:canvasSize:nativeScale:));
- (BOOL)clear;
@end

@interface CoreSetPlayerCollector : NSObject
// Per-thread failure stage for the immediately preceding capture call. The
// value contains no target addresses or field contents and is intended only
// for distinguishing semantic/local validation from transport failures.
+ (NSString *)lastCaptureDiagnostic;
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
