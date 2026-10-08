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

// Core 1.7 registration is performed in the application process. A failed
// registration must leave no retained controller or allow explicit cleanup.
@protocol CoreSetHUDHostingAdapter <NSObject>
- (void)registerBothSurfacesAsync:(UIWindow *)menuWindow drawWindow:(UIWindow *)drawWindow
                         completion:(void (^)(BOOL observed, uint64_t generation))completion;
- (void)unregisterBothSurfacesAsync:(UIWindow *)menuWindow drawWindow:(UIWindow *)drawWindow
                         completion:(void (^)(BOOL menuRemoved, BOOL drawRemoved))completion;
@optional
- (BOOL)usesDirectSourceInteraction;
- (void)prepareForHostGeneration:(uint64_t)generation;
- (uint64_t)hostGeneration;
- (BOOL)localSurfacesStillPublished;
// Verifies the three local controller associations and source contexts.
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
// this token without replacing the source/context generation.
@property(atomic, readonly) uint64_t renderGeneration;
@property(nonatomic, readonly) BOOL localSurfacesReady;
@property(nonatomic, readonly) CGSize logicalCanvasSize;
// Cached receipt from the Core 1.7 SBS registration call.
@property(nonatomic, readonly) BOOL hostedRegistrationReceipt;
// Registration only, not a physical-touch or UIKit action receipt.
@property(nonatomic, readonly) BOOL hostedInputMonitorArmed;
// Compatibility boundary; Core 1.7 has no extra readback worker.
- (void)whenHostedReadbackIdle:(dispatch_block_t)completion;
// Cached local state only. Does not start another registration.
- (NSString *)hostingDiagnosticSnapshot;
@property(nonatomic, readonly) BOOL cleanupPending;
@property(nonatomic, readonly) BOOL hostedCleanupInFlight;
@property(nonatomic, readonly) BOOL panelVisible;
// UIKit source geometry receipt only; physical cross-app touch still requires
// a device observation.
@property(nonatomic, readonly) BOOL floatingControlReady;
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
// Attach the first hosting tier to the already visible system source windows.
- (void)attachHostingAdapter:(id<CoreSetHUDHostingAdapter>)adapter
                 completion:(void (^)(BOOL registered))completion;
// Retains both UIWindow source contexts while replacing an adapter.
- (void)transitionToRemoteHostingAdapter:(id<CoreSetHUDHostingAdapter>)adapter
                              completion:(void (^)(BOOL registered))completion;
// All lifecycle methods require the main thread. Local-only start is supported;
// hosted registration remains false until the adapter returns a receipt.
- (BOOL)startInScene:(UIWindowScene *)scene menuController:(UIViewController *)menuController
              error:(NSError * _Nullable * _Nullable)error;
// Explicit Swift boundary: do not depend on NSError importer heuristics.
- (BOOL)startLocalInScene:(UIWindowScene *)scene menuController:(UIViewController *)menuController
    NS_SWIFT_NAME(startLocal(in:menuController:));
- (BOOL)startHostedInScene:(UIWindowScene *)scene menuController:(UIViewController *)menuController
                completion:(void (^)(BOOL observed))completion
    NS_SWIFT_NAME(startHosted(in:menuController:completion:));
- (BOOL)startHostedInMenuScene:(UIWindowScene *)menuScene drawScene:(UIWindowScene *)drawScene
                menuController:(UIViewController *)menuController
                     completion:(void (^)(BOOL observed))completion
    NS_SWIFT_NAME(startHosted(menuScene:drawScene:menuController:completion:));
- (BOOL)applyLocalMenuVisible:(BOOL)visible colors:(NSArray<UIColor *> *)colors
    NS_SWIFT_NAME(applyLocalMenu(visible:colors:));
- (BOOL)setMetalConsumer:(nullable id<CoreSetFrameConsumer>)consumer
                   error:(NSError * _Nullable * _Nullable)error;
// Explicit Swift boundary; do not depend on NSError importer heuristics.
- (BOOL)installLocalMetalConsumer:(id<CoreSetFrameConsumer>)consumer
    NS_SWIFT_NAME(installLocalMetalConsumer(_:));
- (void)setPanelVisible:(BOOL)visible;
- (void)setApplicationActive:(BOOL)active;
// Core 1.7 uses UIKit interaction in the touchFloating scene; no HID replay.
- (BOOL)armHostedInput;
- (void)setFloatingColors:(NSArray<UIColor *> *)colors;
// May be called from any thread. Frames are immutable; old generations and
// non-increasing sequence numbers are discarded on the main thread.
- (void)submitFrame:(CoreSetRenderFrame *)frame;
// The scheduled ImGui/Metal adapter must return an actual scheduler readback.
- (NSInteger)observedRenderFPS;
// Actual drawable present-time window; not the configured scheduler property.
- (CoreSetPresentationCadenceSample)observedPresentationCadence;
- (BOOL)applyRenderFPS:(NSInteger)fps observed:(NSInteger *)observed;
- (BOOL)restoreRenderFPS;
// The owner must call stop before releasing the host, and retain it while
// cleanupPending is true so failed adapter cleanup can be retried explicitly.
- (CoreSetHUDStopResult)stop;
// Detaches the local owner only after all associated controllers are released.
- (void)stopHostedAsync:(void (^)(CoreSetHUDStopResult result))completion;
@end

NS_ASSUME_NONNULL_END
