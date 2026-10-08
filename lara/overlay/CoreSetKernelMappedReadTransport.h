#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Private target-byte read transport used only by CoreSetReadSession when the
// task port is unavailable. Its exact-profile-gated alias setup changes kernel
// metadata, but it never exposes a mapped address or target-byte write API.
@interface CoreSetKernelMappedReadTransport : NSObject
@property(nonatomic, readonly) int32_t processID;
@property(nonatomic, copy, readonly) NSString *lastError;

- (nullable instancetype)initWithKernelProcess:(uint64_t)kernelProcess
                                    expectedPID:(int32_t)expectedPID;
- (BOOL)identityValid;
- (uint64_t)findImageWithUUID:(const uint8_t[16])uuid;
- (BOOL)imageAt:(uint64_t)address matchesUUID:(const uint8_t[16])uuid;
- (BOOL)readAt:(uint64_t)address
             to:(void *)destination
         length:(size_t)length
 completedBytes:(size_t *)completedBytes;
// Returns NO only when a temporary alias could not be fully released. In that
// case the object retains its cleanup state so a later call can retry.
- (BOOL)disconnect;
@end

NS_ASSUME_NONNULL_END
