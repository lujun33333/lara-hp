#import "CoreSetHUDHost.h"

@class RemoteCall;
NS_ASSUME_NONNULL_BEGIN

// Both hosting transports own draw/icon/menu source contexts. Core mode uses
// SBSAccessibilityWindowHostingController; the compatibility transport mirrors
// the same three contexts into SpringBoard through the existing RemoteCall.
// No RemoteCall is created or destroyed here. Failed cleanup retains handles
// and makes the capability unavailable until an explicit retry succeeds.
@interface CoreSetRemoteHostingAdapter : NSObject <CoreSetHUDHostingAdapter>
@property(nonatomic, readonly) BOOL cleanupPending;
@property(nonatomic, readonly) BOOL sessionIdentityReady;
@property(nonatomic, copy, readonly, nullable) NSString *sessionIdentityFailureReason;
@property(nonatomic, readonly) uint64_t hostGeneration;
+ (BOOL)isCoreHostingAvailable NS_SWIFT_NAME(isCoreHostingAvailable());
// Cached results from the existing readback path; never starts another remote call.
- (NSString *)hostingDiagnosticSnapshot;
- (nullable instancetype)initWithCoreHosting:(BOOL)coreHosting NS_SWIFT_NAME(init(coreHosting:));
- (instancetype)initWithRemoteCall:(RemoteCall *)remoteCall NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (void)prepareForHostGeneration:(uint64_t)generation;
@end

NS_ASSUME_NONNULL_END
