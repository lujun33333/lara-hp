#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Read-transport-only gate for the known device/build/offset tuple. The live
// kernel UUID is read twice, pinned with kernel_base for this process, and
// revalidated if DarkSword later reports a different kernel base. This does not
// install or enable the target-write profile registry.
@interface CoreSetKernelReadProfile : NSObject
+ (BOOL)matchesCurrentKernel;
+ (NSString *)lastFailure;
@end

NS_ASSUME_NONNULL_END
