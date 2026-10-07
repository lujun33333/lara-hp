#import "CoreSetHUDHost.h"

@class RemoteCall;
NS_ASSUME_NONNULL_BEGIN

// One instance owns at most one menu and one draw mirror in SpringBoard.
// No RemoteCall is created or destroyed here. Failed cleanup retains handles
// and makes the capability unavailable until an explicit retry succeeds.
@interface CoreSetRemoteHostingAdapter : NSObject <CoreSetHUDHostingAdapter>
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

// WZ's first hosting tier: local SBS accessibility controllers own the two
// source contexts. No RemoteCall is made by this adapter.
@interface CoreSetLocalHostingAdapter : NSObject <CoreSetHUDHostingAdapter>
@property(nonatomic, readonly) BOOL available;
@property(nonatomic, readonly) uint64_t hostGeneration;
- (NSString *)hostingDiagnosticSnapshot;
@end

NS_ASSUME_NONNULL_END
