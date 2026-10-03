#import <UIKit/UIKit.h>
#import "CoreSetRenderCommands.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CoreSetHUDSurface) {
    CoreSetHUDSurfaceMenu,
    CoreSetHUDSurfaceDraw,
};

// Integration may implement this with the application's existing RemoteCall.
// Registration must return an observed result; a queued request is not success.
// A failed registration must either leave no resource or allow unregister to
// retry cleanup for the same window. This module never creates a RemoteCall.
@protocol CoreSetHUDHostingAdapter <NSObject>
- (BOOL)registerWindow:(UIWindow *)window surface:(CoreSetHUDSurface)surface
                error:(NSError * _Nullable * _Nullable)error;
- (BOOL)unregisterWindow:(UIWindow *)window surface:(CoreSetHUDSurface)surface
                  error:(NSError * _Nullable * _Nullable)error;
@optional
- (void)prepareForHostGeneration:(uint64_t)generation;
- (BOOL)bothSurfacesObserved;
- (uint64_t)hostGeneration;
@end

typedef struct CoreSetHUDStopResult {
    BOOL localWindowsStopped;
    BOOL menuHostingRemoved;
    BOOL drawHostingRemoved;
    BOOL complete;
} CoreSetHUDStopResult;

@interface CoreSetHUDHost : NSObject
@property(atomic, readonly) uint64_t generation;
@property(nonatomic, readonly) BOOL localSurfacesReady;
@property(nonatomic, readonly) BOOL crossApplicationHosted;
@property(nonatomic, readonly) BOOL cleanupPending;
@property(nonatomic, readonly) BOOL panelVisible;
@property(nonatomic, copy, readonly) NSArray<UIColor *> *observedFloatingColors;
// Accepted by the CA/Metal consumer, not proof of a displayed device pixel.
@property(nonatomic, readonly) uint64_t lastConsumedSequence;
@property(nonatomic, readonly) CoreSetHUDBackend activeBackend;
@property(nonatomic, readonly) BOOL renderFPSControlReady;
@property(nonatomic, strong, readonly, nullable) NSError *lastError;
// Main-thread notification. Producers must reread generation after invalidation.
@property(nonatomic, copy, nullable) void (^stateDidChange)(void);
// Reports this exact frame after the selected local renderer has consumed it.
// Queue acceptance, host readiness and lastConsumedSequence are not feature receipts.
@property(nonatomic, copy, nullable) void (^frameDidConsume)(CoreSetRenderFrame *frame, BOOL accepted, NSError * _Nullable error);
@property(nonatomic, copy, nullable) void (^panelVisibilityRequested)(BOOL visible);
// Configure before start. Embedded content may own its layout and return its
// actual interactive views; hit testing reevaluates these after every layout.
@property(nonatomic) BOOL contentOwnsLayout;
@property(nonatomic, copy, nullable) NSArray<UIView *> * (^contentHitRegions)(void);
- (instancetype)initWithHostingAdapter:(nullable id<CoreSetHUDHostingAdapter>)adapter NS_DESIGNATED_INITIALIZER;
- (instancetype)init;
// May be installed only before start and with no pending cleanup.
- (BOOL)installRemoteHostingAdapter:(nullable id<CoreSetHUDHostingAdapter>)adapter
    NS_SWIFT_NAME(installRemoteHostingAdapter(_:));
// All lifecycle methods require the main thread. Local-only start is supported;
// crossApplicationHosted stays false if no confirmed adapter is supplied.
- (BOOL)startInScene:(UIWindowScene *)scene menuController:(UIViewController *)menuController
              error:(NSError * _Nullable * _Nullable)error;
// Explicit Swift boundary: do not depend on NSError importer heuristics.
- (BOOL)startLocalInScene:(UIWindowScene *)scene menuController:(UIViewController *)menuController
    NS_SWIFT_NAME(startLocal(in:menuController:));
- (BOOL)applyLocalMenuVisible:(BOOL)visible colors:(NSArray<UIColor *> *)colors
    NS_SWIFT_NAME(applyLocalMenu(visible:colors:));
- (BOOL)setMetalConsumer:(nullable id<CoreSetFrameConsumer>)consumer
                   error:(NSError * _Nullable * _Nullable)error;
// Explicit Swift boundary; do not depend on NSError importer heuristics.
- (BOOL)installLocalMetalConsumer:(id<CoreSetFrameConsumer>)consumer
    NS_SWIFT_NAME(installLocalMetalConsumer(_:));
- (void)setPanelVisible:(BOOL)visible;
- (void)setApplicationActive:(BOOL)active;
- (void)setFloatingColors:(NSArray<UIColor *> *)colors;
// May be called from any thread. Frames are immutable; old generations and
// non-increasing sequence numbers are discarded on the main thread.
- (void)submitFrame:(CoreSetRenderFrame *)frame;
// Core Animation's event-driven consumer is intentionally unavailable here.
// A scheduled Metal adapter must return an actual scheduler readback.
- (NSInteger)observedRenderFPS;
- (BOOL)applyRenderFPS:(NSInteger)fps observed:(NSInteger *)observed;
- (BOOL)restoreRenderFPS;
// The owner must call stop before releasing the host, and retain it while
// cleanupPending is true so failed adapter cleanup can be retried explicitly.
- (CoreSetHUDStopResult)stop;
@end

NS_ASSUME_NONNULL_END
