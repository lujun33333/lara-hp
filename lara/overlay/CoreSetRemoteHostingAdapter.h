#import "CoreSetHUDHost.h"

NS_ASSUME_NONNULL_BEGIN

// Core 1.7 path: create the three SBS hosting controllers in this application
// process, then register the draw/icon/menu UIWindow context IDs.
@interface CoreSetRemoteHostingAdapter : NSObject <CoreSetHUDHostingAdapter>
@property(nonatomic, readonly) BOOL cleanupPending;
@property(nonatomic, readonly) BOOL sessionIdentityReady;
@property(nonatomic, copy, readonly, nullable) NSString *sessionIdentityFailureReason;
@property(nonatomic, readonly) uint64_t hostGeneration;
- (NSString *)hostingDiagnosticSnapshot;
- (instancetype)init NS_DESIGNATED_INITIALIZER;
- (void)prepareForHostGeneration:(uint64_t)generation;
@end

NS_ASSUME_NONNULL_END
