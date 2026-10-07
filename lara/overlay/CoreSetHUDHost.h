#import <UIKit/UIKit.h>
#import "CoreSetRenderCommands.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CoreSetHUDSurface) {
    CoreSetHUDSurfaceMenu,
    CoreSetHUDSurfaceDraw,
};

typedef NS_ENUM(NSInteger, CoreSetHostedPointerPhase) {
    CoreSetHostedPointerPhaseBegan = 0,
    CoreSetHostedPointerPhaseMoved = 1,
    CoreSetHostedPointerPhaseEnded = 2,
    CoreSetHostedPointerPhaseCancelled = 3,
};

// Returns only controls registered with an explicit semantic consumer.
// A rebuild changes revision and invalidates an in-flight pointer.
@protocol CoreSetHostedMenuTapConsumer <NSObject>
- (nullable NSString *)hostedControlIDAtPoint:(CGPoint)point
    NS_SWIFT_NAME(hostedControlID(at:));
- (BOOL)hostedControlAllowsDrag:(NSString *)identifier
    NS_SWIFT_NAME(hostedControlAllowsDrag(_:));
- (BOOL)handleHostedControlID:(NSString *)identifier phase:(CoreSetHostedPointerPhase)phase
                      atPoint:(CGPoint)point
    NS_SWIFT_NAME(handleHostedControl(_:phase:at:));
@property(nonatomic, readonly) uint64_t hostedMenuRevision;
@end

// Integration may implement this with the application's existing RemoteCall.
// Registration must return an observed result; a queued request is not success.
// A failed registration must either leave no resource or allow unregister to
// retry cleanup for the same window. This module never creates a RemoteCall.
@protocol CoreSetHUDHostingAdapter <NSObject>
- (void)registerBothSurfacesAsync:(UIWindow *)menuWindow drawWindow:(UIWindow *)drawWindow
                         completion:(void (^)(BOOL observed, uint64_t generation))completion;
- (void)unregisterBothSurfacesAsync:(UIWindow *)menuWindow drawWindow:(UIWindow *)drawWindow
                         completion:(void (^)(BOOL menuRemoved, BOOL drawRemoved))completion;
@optional
- (void)prepareForHostGeneration:(uint64_t)generation;
- (uint64_t)hostGeneration;
- (BOOL)localSurfacesStillPublished;
// Captures local UIKit context on the main thread, then verifies remote
// mirrors on a serialized worker and completes on the main thread.
- (void)observeBothSurfacesAsync:(void (^)(BOOL observed, uint64_t generation))completion;
@end

typedef struct CoreSetHUDStopResult {
    BOOL localWindowsStopped;
    BOOL menuHostingRemoved;
    BOOL drawHostingRemoved;
    BOOL complete;
} CoreSetHUDStopResult;

@interface CoreSetHUDHost : NSObject
@property(atomic, readonly) uint64_t generation;
// Local geometry and frame provenance. A pure orientation change advances
// this token without replacing the remote source/context generation.
@property(atomic, readonly) uint64_t renderGeneration;
@property(nonatomic, readonly) BOOL localSurfacesReady;
@property(nonatomic, readonly) CGSize logicalCanvasSize;
// Cached registration receipt: generation, source context and process identity
// remain structurally valid. A separate async remote readback is mandatory
// during launch and after openURL; external remote destruction is not observed
// until such a readback or an explicit local invalidation.
@property(nonatomic, readonly) BOOL hostedRegistrationReceipt;
// Registration only, not a physical-touch or UIKit action receipt.
@property(nonatomic, readonly) BOOL hostedInputMonitorArmed;
@property(nonatomic, readonly) BOOL foregroundTouchCalibrationReady;
// A normal foreground window pairs raw digitizer contacts with real UITouch
// points before any SpringBoard source context is created.
- (BOOL)beginForegroundTouchCalibration:(void (^)(BOOL confirmed))completion;
- (void)cancelForegroundTouchCalibration;
// Uses the next serialized background readback when the current receipt is
// stale. Completion is on the main thread and tied to this host generation.
- (void)confirmHostedReadbackAsync:(void (^)(BOOL observed))completion;
// Lifecycle teardown waits for a serialized remote readback worker to leave
// its process lock; this method itself never performs RemoteCall.
- (void)whenHostedReadbackIdle:(dispatch_block_t)completion;
// Cached local state only. Does not call the remote readback gate.
- (NSString *)hostingDiagnosticSnapshot;
@property(nonatomic, readonly) BOOL cleanupPending;
@property(nonatomic, readonly) BOOL hostedCleanupInFlight;
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
// A confirmed hosted source/context becoming invalid requires owner teardown.
@property(nonatomic, copy, nullable) void (^hostingInvalidated)(void);
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
// Remote registration remains false until its async worker returns a receipt.
- (BOOL)startInScene:(UIWindowScene *)scene menuController:(UIViewController *)menuController
              error:(NSError * _Nullable * _Nullable)error;
// Explicit Swift boundary: do not depend on NSError importer heuristics.
- (BOOL)startLocalInScene:(UIWindowScene *)scene menuController:(UIViewController *)menuController
    NS_SWIFT_NAME(startLocal(in:menuController:));
- (BOOL)startHostedInScene:(UIWindowScene *)scene menuController:(UIViewController *)menuController
                completion:(void (^)(BOOL observed))completion
    NS_SWIFT_NAME(startHosted(in:menuController:completion:));
- (BOOL)applyLocalMenuVisible:(BOOL)visible colors:(NSArray<UIColor *> *)colors
    NS_SWIFT_NAME(applyLocalMenu(visible:colors:));
- (BOOL)setMetalConsumer:(nullable id<CoreSetFrameConsumer>)consumer
                   error:(NSError * _Nullable * _Nullable)error;
// Explicit Swift boundary; do not depend on NSError importer heuristics.
- (BOOL)installLocalMetalConsumer:(id<CoreSetFrameConsumer>)consumer
    NS_SWIFT_NAME(installLocalMetalConsumer(_:));
- (void)setPanelVisible:(BOOL)visible;
- (void)setApplicationActive:(BOOL)active;
// A passive HID observer: it does not intercept or consume the game's touches.
// Must be armed on the main thread after both SpringBoard surfaces are observed.
- (BOOL)armHostedInput;
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
// Detaches the local owner only after both remote sides finish their serialized
// cleanup. The caller may start a normal local owner on complete == YES.
- (void)stopHostedAsync:(void (^)(CoreSetHUDStopResult result))completion;
@end

NS_ASSUME_NONNULL_END
