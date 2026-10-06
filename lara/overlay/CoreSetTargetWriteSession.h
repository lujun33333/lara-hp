#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint8_t, CoreSetTargetWriteLane) {
    CoreSetTargetWriteLaneAim = 1, CoreSetTargetWriteLaneRecoil = 2
};
typedef NS_ENUM(uint8_t, CoreSetTargetWriteSlot) {
    CoreSetTargetWriteSlotControlRotation = 1,
    CoreSetTargetWriteSlotRotationInput = 2
};
typedef NS_ENUM(uint8_t, CoreSetTargetWriteAxis) {
    CoreSetTargetWriteAxisFirst = 1,
    CoreSetTargetWriteAxisSecond = 2,
    CoreSetTargetWriteAxisBoth = 3
};

// No mapped-page backend is enabled until its device/kernel profile, independent
// target readback, and cleanup have been verified for build 15915.
@interface CoreSetTargetWriteCleanupResult : NSObject
@property(nonatomic, readonly) BOOL readTaskPortReleased;
@property(nonatomic, readonly) BOOL mappedAliasReleased;
@property(nonatomic, readonly) BOOL generationAdvanced;
@property(nonatomic, readonly) BOOL noInFlight;
@property(nonatomic, readonly) BOOL backendClean;
@property(nonatomic, readonly) BOOL noUnresolvedState;
@property(nonatomic, readonly) BOOL targetWriteAttempted;
@property(nonatomic, readonly) BOOL resourcesReleased;
// Complete transport cleanup is distinct from restoring previously written bytes.
@property(nonatomic, readonly) BOOL complete;
@property(nonatomic, readonly) BOOL mayReportRestored;
- (instancetype)initWithReadTaskPortReleased:(BOOL)readTaskPortReleased
                         mappedAliasReleased:(BOOL)mappedAliasReleased
                          generationAdvanced:(BOOL)generationAdvanced
                                backendClean:(BOOL)backendClean
                           noUnresolvedState:(BOOL)noUnresolvedState
                        targetWriteAttempted:(BOOL)targetWriteAttempted
                                  noInFlight:(BOOL)noInFlight;
@end

@interface CoreSetTargetWriteResult : NSObject
@property(nonatomic, readonly) BOOL committed;
@property(nonatomic, readonly) BOOL pending;
@property(nonatomic, readonly) size_t completedBytes;
@property(nonatomic, copy, readonly) NSString *reason;
- (instancetype)initWithCommitted:(BOOL)committed pending:(BOOL)pending
                  completedBytes:(size_t)completedBytes reason:(NSString *)reason;
@end

@protocol CoreSetTargetWriteAuthority <NSObject>
// Must validate the current active consumer request and captured snapshot,
// not merely echo the arguments received by the writer.
- (BOOL)authorizesPID:(int32_t)pid imageBase:(uint64_t)imageBase
           generation:(uint64_t)generation controller:(uint64_t)controller
                 lane:(CoreSetTargetWriteLane)lane
                 slot:(CoreSetTargetWriteSlot)slot axis:(CoreSetTargetWriteAxis)axis
         requestToken:(NSUUID *)requestToken snapshotID:(NSUUID *)snapshotID;
@end

@interface CoreSetTargetWriteSession : NSObject
@property(nonatomic, readonly) BOOL ready;
@property(nonatomic, readonly) uint64_t capabilities; // Bit 1 = verified target write; currently 0.
@property(nonatomic, readonly) uint64_t generation;
@property(nonatomic, readonly) BOOL pendingCleanup;
// The default initializer installs no authority and cannot perform a write.
- (instancetype)initWithRequestAuthority:(nullable id<CoreSetTargetWriteAuthority>)authority;
// Typed build-15915 slots only: controller +0x620/+0x624 or +0x828/+0x82c.
// Axis selects a four-byte float or an eight-byte pair. No general UVA API.
- (CoreSetTargetWriteResult *)writeControllerActionForPID:(int32_t)pid
    imageBase:(uint64_t)imageBase controller:(uint64_t)controller
    lane:(CoreSetTargetWriteLane)lane slot:(CoreSetTargetWriteSlot)slot
    axis:(CoreSetTargetWriteAxis)axis
    generation:(uint64_t)generation requestToken:(NSUUID *)requestToken
    snapshotID:(NSUUID *)snapshotID expectedOld:(NSData *)expectedOld
    newValue:(NSData *)newValue;
- (CoreSetTargetWriteCleanupResult *)disconnect;
@end

NS_ASSUME_NONNULL_END
