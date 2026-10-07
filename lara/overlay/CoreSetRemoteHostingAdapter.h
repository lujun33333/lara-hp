#import "CoreSetHUDHost.h"

@class RemoteCall;
NS_ASSUME_NONNULL_BEGIN

// One instance owns at most one menu and one draw mirror in SpringBoard.
// No RemoteCall is created or destroyed here. Failed cleanup retains handles
// and makes the capability unavailable until an explicit retry succeeds.
@interface CoreSetRemoteHostingAdapter : NSObject <CoreSetHUDHostingAdapter>
@property(nonatomic, readonly) BOOL bothSurfacesObserved;
@property(nonatomic, readonly) BOOL cleanupPending;
@property(nonatomic, readonly) BOOL sessionIdentityReady;
@property(nonatomic, copy, readonly, nullable) NSString *sessionIdentityFailureReason;
@property(nonatomic, readonly) uint64_t hostGeneration;
// Cached results from the existing readback path; never starts another remote call.
- (NSString *)hostingDiagnosticSnapshot;
- (instancetype)initWithRemoteCall:(RemoteCall *)remoteCall NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (void)prepareForHostGeneration:(uint64_t)generation;
@end

NS_ASSUME_NONNULL_END
