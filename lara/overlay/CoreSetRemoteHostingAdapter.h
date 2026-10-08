#import "CoreSetHUDHost.h"

NS_ASSUME_NONNULL_BEGIN

// Core 1.7 path: create the three SBSAccessibilityWindowHostingController
// objects in this application, register the source UIWindow context IDs at
// their exact levels, then retain the controllers on UIApplication.
@interface CoreSetCore17HostingAdapter : NSObject <CoreSetHUDHostingAdapter>
@property(nonatomic, readonly) BOOL cleanupPending;
@property(nonatomic, readonly) uint64_t hostGeneration;
// Cached local registration state; never starts a remote call.
- (NSString *)hostingDiagnosticSnapshot;
- (instancetype)initWithPrimaryWindow:(UIWindow *)primaryWindow
    NS_DESIGNATED_INITIALIZER NS_SWIFT_NAME(init(primaryWindow:));
- (instancetype)init NS_UNAVAILABLE;
- (void)prepareForHostGeneration:(uint64_t)generation;
@end

NS_ASSUME_NONNULL_END
