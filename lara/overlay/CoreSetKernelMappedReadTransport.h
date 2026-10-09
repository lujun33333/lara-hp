#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Private target-byte read transport used only by CoreSetReadSession when the
// task port is unavailable. It walks the target pmap and reads translated
// physical pages through the SPTM physical aperture; no target or kernel write
// primitive is exposed or used.
@interface CoreSetKernelMappedReadTransport : NSObject
@property(nonatomic, readonly) int32_t processID;
@property(nonatomic, copy, readonly) NSString *lastError;

+ (NSString *)lastInitializationError;

- (nullable instancetype)initWithKernelProcess:(uint64_t)kernelProcess
                                    expectedPID:(int32_t)expectedPID;
- (BOOL)identityValid;
- (uint64_t)findImageWithUUID:(const uint8_t[16])uuid;
- (BOOL)imageAt:(uint64_t)address matchesUUID:(const uint8_t[16])uuid;
- (BOOL)readAt:(uint64_t)address
             to:(void *)destination
         length:(size_t)length
 completedBytes:(size_t *)completedBytes;
// The page-table transport owns no temporary mappings or Mach ports.
- (BOOL)disconnect;
@end

NS_ASSUME_NONNULL_END
