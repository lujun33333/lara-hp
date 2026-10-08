#import "CoreSetHUDHost.h"

@class RemoteCall;
NS_ASSUME_NONNULL_BEGIN

// Core 1.7 path: retain three SBSAccessibilityWindowHostingController objects
// in SpringBoard and register the source UIWindow context IDs at their exact
// window levels. Interaction stays in the touchFloating UIKit scene.
@interface CoreSetRemoteHostingAdapter : NSObject <CoreSetHUDHostingAdapter>
@property(nonatomic, readonly) BOOL cleanupPending;
@property(nonatomic, readonly) BOOL sessionIdentityReady;
@property(nonatomic, copy, readonly, nullable) NSString *sessionIdentityFailureReason;
@property(nonatomic, readonly) uint64_t hostGeneration;
- (NSString *)hostingDiagnosticSnapshot;
- (instancetype)initWithRemoteCall:(RemoteCall *)remoteCall primaryWindow:(UIWindow *)primaryWindow
    NS_DESIGNATED_INITIALIZER NS_SWIFT_NAME(init(remoteCall:primaryWindow:));
- (instancetype)init NS_UNAVAILABLE;
- (void)prepareForHostGeneration:(uint64_t)generation;
@end

NS_ASSUME_NONNULL_END
