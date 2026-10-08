#import <UIKit/UIKit.h>
#import "CoreSetReadSession.h"

NS_ASSUME_NONNULL_BEGIN

@interface CoreSetMaterialMark : NSObject
@property(nonatomic, readonly) NSInteger recordIndex;
@property(nonatomic, readonly) CGPoint point;
@property(nonatomic, readonly) double distanceUnitsDividedBy100;
@property(nonatomic, copy, readonly, nullable) NSString *crateLevelLabel;
@property(nonatomic, readonly, nullable) NSNumber *escapeBoxChildrenCount;
// Independently observed InteractiveTreasureBox.bSyncHasBeenOpened byte.
// Not substituted for Core's Children.Num==1 filter, or a network freshness proof.
@property(nonatomic, readonly, nullable) NSNumber *interactiveTreasureBoxSyncOpened;
@property(nonatomic, readonly, nullable) NSNumber *vehicleHPPercent;
@property(nonatomic, readonly, nullable) NSNumber *vehicleFuelPercent;
@end

@interface CoreSetMetroArmorMark : NSObject
@property(nonatomic, readonly) CGPoint point;
@property(nonatomic, copy, readonly, nullable) NSString *headLabel;
@property(nonatomic, copy, readonly, nullable) NSString *armorLabel;
@end

@interface CoreSetMaterialSnapshot : NSObject
@property(nonatomic, readonly) uint64_t sessionGeneration;
@property(nonatomic, readonly) int32_t processID;
@property(nonatomic, readonly) uint64_t imageBase;
@property(nonatomic, readonly) uint32_t localWeaponID;
@property(nonatomic, copy, readonly) NSUUID *snapshotID;
@property(nonatomic, readonly) NSArray<CoreSetMaterialMark *> *marks;
@property(nonatomic, readonly) NSArray<CoreSetMetroArmorMark *> *metroMarks;
@property(nonatomic, readonly) double captureCompletedMonotonicSeconds;
@property(nonatomic, copy, readonly) NSString *readSemanticDiagnostic;
@end

@interface CoreSetMaterialCollector : NSObject
// Nil is an incomplete or identity-changed read, never an empty valid frame.
// Pattern order is Core v1.7 constructor order, not a game ItemDefineID table.
+ (nullable CoreSetMaterialSnapshot *)capture:(CoreSetReadSession *)session
                                  canvasSize:(CGSize)canvasSize
                                    patterns:(NSArray<NSString *> *)patterns
                           includeArmedState:(BOOL)includeArmedState
                          includeCrateLevel:(BOOL)includeCrateLevel
                         includeVehicleStatus:(BOOL)includeVehicleStatus
                           includeMetroArmor:(BOOL)includeMetroArmor
                  includeHideOpenedCrates:(BOOL)includeHideOpenedCrates;
@end

NS_ASSUME_NONNULL_END
