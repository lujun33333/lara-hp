#import "CoreSetHUDHost.h"

@class RemoteCall;
NS_ASSUME_NONNULL_BEGIN

// iOS 26 replacement for the removed SBS hosting controller. The adapter
// mirrors the three Core source contexts into SpringBoard with UIWindow and
// CALayerHost through the application's existing RemoteCall session.
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

NS_ASSUME_NONNULL_END
