#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Internal, one-shot registry. No profile is installed in the shipped source.
// A future reviewed build must provide exact kernel UUID, OS build, device,
// and all offsets used by vmmapremotepage/vmcreateshmemwithobj.
@interface CoreSetKernelWriteProfile : NSObject
@property(nonatomic, copy, readonly) NSUUID *kernelUUID;
@property(nonatomic, copy, readonly) NSString *osBuild;
@property(nonatomic, copy, readonly) NSString *device;
@property(nonatomic, copy, readonly) NSDictionary<NSString *, NSNumber *> *offsets;
- (instancetype)initWithKernelUUID:(NSUUID *)kernelUUID
                           osBuild:(NSString *)osBuild device:(NSString *)device
                           offsets:(NSDictionary<NSString *, NSNumber *> *)offsets;
@end

@interface CoreSetKernelWriteProfileRegistry : NSObject
+ (BOOL)installAuditedProfile:(CoreSetKernelWriteProfile *)profile;
+ (BOOL)matchesCurrentKernel;
// Read-only evidence. Observed offsets are not an audited profile and never
// cause installation, exploit startup, or target-page mapping.
+ (NSDictionary<NSString *, id> *)diagnosticSnapshot;
@end

NS_ASSUME_NONNULL_END
