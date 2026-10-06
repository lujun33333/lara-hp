#import <UIKit/UIKit.h>
#import "CoreSetReadSession.h"

NS_ASSUME_NONNULL_BEGIN

// Observed world coordinates, in the same units used by the projection code.
@interface CoreSetWorldPoint : NSObject
@property(nonatomic, readonly) float x;
@property(nonatomic, readonly) float y;
@property(nonatomic, readonly) float z;
+ (instancetype)pointWithX:(float)x y:(float)y z:(float)z;
@end

// Raw mesh index, not an inferred anatomical label. screenPoint is projected
// from worldPosition with this snapshot's camera and canvasSize.
@interface CoreSetBoneWorldPoint : NSObject
@property(nonatomic, readonly) NSUInteger boneIndex;
@property(nonatomic, readonly) NSUInteger boneCount;
@property(nonatomic, readonly) CoreSetWorldPoint *worldPosition;
@property(nonatomic, readonly) CGPoint screenPoint;
@end

@interface CoreSetBoneSegment : NSObject
@property(nonatomic, readonly) CGPoint start;
@property(nonatomic, readonly) CGPoint end;
@end

@interface CoreSetPlayerMark : NSObject
@property(nonatomic, readonly) uint64_t actorAddress;
@property(nonatomic, readonly, nullable) CoreSetWorldPoint *actorWorldPosition;
@property(nonatomic, readonly) NSArray<CoreSetBoneWorldPoint *> *boneWorldPoints;
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
@property(nonatomic, readonly) CGPoint feet;
@property(nonatomic, readonly) double distanceUnitsDividedBy100;
@property(nonatomic, readonly) NSArray<CoreSetBoneSegment *> *boneSegments;
@property(nonatomic, readonly) BOOL onScreen;
@property(nonatomic, readonly) CGPoint indicatorProjection;
@property(nonatomic, readonly) CGPoint radarCameraDelta;
// Core's primary server-rotation yaw only; nil for non-finite/out-of-range
// values. This is not a promise that the current controller is aiming here.
@property(nonatomic, readonly, nullable) NSNumber *warningServerYawDegrees;
@end

@interface CoreSetGrenadeMark : NSObject
@property(nonatomic, readonly) CGPoint point;
@property(nonatomic, readonly) double distanceUnitsDividedBy100;
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
@property(nonatomic, readonly) float controlPitchDegrees;
@property(nonatomic, readonly) float controlYawDegrees;
// Same-frame RotationInput read from controller+0x828/+0x82c and independently
// re-read at capture completion. This is takeover magnitude input, not a write route.
@property(nonatomic, readonly) float rotationInputPitch;
@property(nonatomic, readonly) float rotationInputYaw;
@property(nonatomic, readonly) double captureCompletedMonotonicSeconds;
@end

@interface CoreSetPlayerCollector : NSObject
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

NS_ASSUME_NONNULL_END
