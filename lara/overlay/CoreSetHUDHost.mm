#import "CoreSetHUDHost.h"
#include "CoreSetPendingTouchQueue.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <atomic>
#include <cmath>
#include <memory>

typedef struct __IOHIDEvent *CoreSetIOHIDEventRef;
typedef struct __IOHIDService *CoreSetIOHIDServiceRef;
typedef struct __IOHIDEventSystemClient *CoreSetIOHIDEventSystemClientRef;
typedef uint32_t (*CoreSetHIDEventGetType)(CoreSetIOHIDEventRef);
typedef CFArrayRef (*CoreSetHIDEventGetChildren)(CoreSetIOHIDEventRef);

@interface CoreSetAXEventPath : NSObject
@property(nonatomic, readonly) unsigned char pathIdentity;
@end
@interface CoreSetAXEventHand : NSObject
- (NSArray<CoreSetAXEventPath *> *)paths;
@end
@interface CoreSetAXEvent : NSObject
@property(nonatomic, readonly) BOOL isTouchDown;
@property(nonatomic, readonly) BOOL isMove;
@property(nonatomic, readonly) BOOL isChordChange;
@property(nonatomic, readonly) BOOL isLift;
@property(nonatomic, readonly) BOOL isInRangeLift;
@property(nonatomic, readonly) BOOL isCancel;
+ (instancetype)representationWithHIDEvent:(CoreSetIOHIDEventRef)event
                        hidStreamIdentifier:(NSString *)identifier;
- (CoreSetAXEventHand *)handInfo;
- (CGPoint)location;
@end

// Match the source-window tier used by the working WZ dual-window host and
// by the SpringBoard mirrors in CoreSetRemoteHostingAdapter.
static const double kCoreSetHUDWindowLevel = 10000009.0;
static BOOL CoreSetHostedOrientationValid(UIInterfaceOrientation value) {
    return value == UIInterfaceOrientationPortrait ||
        value == UIInterfaceOrientationPortraitUpsideDown ||
        value == UIInterfaceOrientationLandscapeLeft ||
        value == UIInterfaceOrientationLandscapeRight;
}
static CGFloat CoreSetHostedOrientationAngle(UIInterfaceOrientation value) {
    switch (value) {
        case UIInterfaceOrientationPortraitUpsideDown: return (CGFloat)M_PI;
        case UIInterfaceOrientationLandscapeLeft: return (CGFloat)-M_PI_2;
        case UIInterfaceOrientationLandscapeRight: return (CGFloat)M_PI_2;
        default: return 0;
    }
}
static BOOL CoreSetInputLogDue(uint64_t count) {
    return count == 1 || count % 64 == 0;
}
struct CoreSetInputDiagnosticCounters {
    std::atomic_uint_fast64_t source{0}, sourceUnavailable{0}, sourceAPI{0};
    std::atomic_uint_fast64_t wrapper{0}, wrapperIncomplete{0};
    std::atomic_uint_fast64_t parseDropped{0}, pathsEmpty{0}, multiplePaths{0};
    std::atomic_uint_fast64_t reservedPointer{0}, phaseMissing{0}, nonfinitePoint{0}, cancelled{0};
    std::atomic_uint_fast64_t queued{0}, queueDropped{0}, delivered{0}, deliveryDropped{0};
    std::atomic_uint_fast64_t coordinate{0}, coordinateDropped{0};
    std::atomic_uint_fast64_t hit{0}, hitDropped{0}, dispatched{0};
    std::atomic_uint_fast64_t callback{0}, callbackHandled{0};
    std::atomic_uint_fast64_t readback{0}, readbackDropped{0};
};
// Counts are host-lifetime observations. A callback result is not a feature
// apply receipt; the menu's existing stage=actual receipts remain authoritative.
static void CoreSetLogInputStage(const char *stage, const char *reason,
                                std::atomic_uint_fast64_t *counter,
                                uint64_t generation, NSInteger phase = -1,
                                NSString *control = nil, NSInteger result = -1) {
    const uint64_t count = counter->fetch_add(1) + 1;
    if (CoreSetInputLogDue(count))
        NSLog(@"Core-SET: hosted input stage=%s reason=%s count=%llu generation=%llu phase=%ld control=%@ result=%ld",
              stage, reason, (unsigned long long)count, (unsigned long long)generation,
              (long)phase, control ?: @"none", (long)result);
}
static void CoreSetLogAXDrop(const char *reason, std::atomic_uint_fast64_t *counter,
                           std::atomic_uint_fast64_t *total = nullptr) {
    if (total) total->fetch_add(1);
    const uint64_t count = counter->fetch_add(1) + 1;
    if (CoreSetInputLogDue(count))
        NSLog(@"Core-SET: hosted input stage=ax-drop reason=%s count=%llu",
              reason, (unsigned long long)count);
}
static BOOL CoreSetAXHasUsableHand(CoreSetAXEvent *representation) {
    if (!representation || ![representation respondsToSelector:@selector(handInfo)]) return NO;
    CoreSetAXEventHand *hand = representation.handInfo;
    if (!hand || ![hand respondsToSelector:@selector(paths)]) return NO;
    NSArray *paths = hand.paths;
    return [paths isKindOfClass:NSArray.class] && paths.count > 0;
}

@interface CoreSetDrawWindow : UIWindow @end
@implementation CoreSetDrawWindow
+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isSecure { return NO; }
- (BOOL)_canBecomeKeyWindow { return YES; }
- (BOOL)_isApplicationKeyWindow { return NO; }
- (BOOL)_isWindowServerHostingManaged { return NO; }
- (BOOL)_ignoresHitTest { return YES; }
- (BOOL)_shouldCreateContextAsSecure { return NO; }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { (void)point; (void)event; return nil; }
@end

@interface CoreSetMenuWindow : UIWindow
@property(nonatomic) BOOL backgroundPassThrough;
@property(nonatomic, weak) UIView *panelRegion;
@property(nonatomic, weak) UIView *floatingRegion;
@property(nonatomic, copy) NSArray<UIView *> * (^contentHitRegions)(void);
@end
@implementation CoreSetMenuWindow
+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isSecure { return NO; }
- (BOOL)_canBecomeKeyWindow { return YES; }
- (BOOL)_isApplicationKeyWindow { return NO; }
- (BOOL)_isWindowServerHostingManaged { return NO; }
- (BOOL)_ignoresHitTest { return self.backgroundPassThrough; }
- (BOOL)_shouldCreateContextAsSecure { return NO; }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.backgroundPassThrough) return nil;
    if (!self.rootViewController) return nil;
    // UIKit color sheets/pickers are local modal UI, not game touch transport.
    NSMutableArray<UIViewController *> *controllers = [NSMutableArray arrayWithObject:self.rootViewController];
    while (controllers.count) {
        UIViewController *controller = controllers.lastObject; [controllers removeLastObject];
        if (controller.presentedViewController) return [super hitTest:point withEvent:event];
        [controllers addObjectsFromArray:controller.childViewControllers];
    }
    NSMutableArray<UIView *> *regions = [NSMutableArray array];
    if (self.floatingRegion) [regions addObject:self.floatingRegion];
    if (self.contentHitRegions) [regions addObjectsFromArray:self.contentHitRegions() ?: @[]];
    else if (self.panelRegion) [regions addObject:self.panelRegion];
    for (UIView *region in regions) {
        if (![region isKindOfClass:UIView.class] || ![region isDescendantOfView:self]) continue;
        BOOL interactive = YES;
        for (UIView *ancestor = region; ancestor && ancestor != self; ancestor = ancestor.superview) {
            if (ancestor.hidden || ancestor.alpha <= 0.01 || !ancestor.userInteractionEnabled) { interactive = NO; break; }
        }
        if (!interactive) continue;
        if ([region pointInside:[region convertPoint:point fromView:self] withEvent:event])
            return [super hitTest:point withEvent:event];
    }
    return nil;
}
@end

@interface CoreSetLayoutController : UIViewController
@property(nonatomic, copy) void (^layoutCallback)(void);
@end
@implementation CoreSetLayoutController
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; if (self.layoutCallback) self.layoutCallback(); }
@end

@interface CoreSetHUDHost ()
@property(atomic, readwrite) uint64_t generation;
@property(atomic, readwrite) uint64_t renderGeneration;
@property(nonatomic, strong, readwrite) NSError *lastError;
- (void)receiveHostedHIDEvent:(CoreSetIOHIDEventRef)event;
- (void)resetHostedPointer;
- (BOOL)dispatchHostedMenuControl:(NSString *)identifier
                           phase:(CoreSetHostedPointerPhase)phase
                           point:(CGPoint)point consumer:(id<CoreSetHostedMenuTapConsumer>)consumer;
- (void)disarmHostedInput;
- (void)failClosedHostedInput;
- (void)requestHostedReadback;
- (BOOL)startInputMonitor;
- (void)invalidatePendingTouchActions;
- (void)drainPendingTouchActionsOnQueue;
- (void)drainHostedReadbackIdleWaiters;
- (BOOL)startPreparedInScene:(UIWindowScene *)scene menuController:(UIViewController *)menuController
                       error:(NSError **)error hostedCompletion:(void (^)(BOOL))hostedCompletion;
@end

// The monitor does not retain a host. A queued callback after stop sees nil.
static __weak CoreSetHUDHost *gCoreSetHostedInputOwner;
static BOOL gCoreSetBKCallbackInstalled = NO; // BKSHID has no unregister API.
// Some OS builds expose IOHID scheduling but no unschedule selector. Reuse one
// dormant process-scoped client after stop, as WZ does, rather than registering
// another callback that could later route duplicate events to a new owner.
static CoreSetIOHIDEventSystemClientRef gCoreSetDormantHIDClient = NULL;
static void CoreSetHostedHIDCallback(void *target, void *refcon,
                                     CoreSetIOHIDServiceRef service,
                                     CoreSetIOHIDEventRef event) {
    (void)target; (void)refcon; (void)service;
    CoreSetHUDHost *owner = gCoreSetHostedInputOwner;
    if (owner && event) [owner receiveHostedHIDEvent:event];
}

@implementation CoreSetHUDHost {
    id<CoreSetHUDHostingAdapter> _adapter;
    id<CoreSetFrameConsumer> _metal;
    CoreSetCoreAnimationConsumer *_layers;
    CoreSetDrawWindow *_drawWindow;
    CoreSetMenuWindow *_menuWindow;
    UIView *_drawCanvas;
    UIView *_panel;
    UIButton *_floating;
    CAGradientLayer *_floatingGradient;
    UIViewController *_menuController;
    NSMutableArray<id> *_observers;
    BOOL _running;
    BOOL _foreground;
    BOOL _panelVisible;
    BOOL _localUIKitPointerActive;
    BOOL _menuRegistered;
    BOOL _drawRegistered;
    BOOL _menuCleanupNeeded;
    BOOL _drawCleanupNeeded;
    uint64_t _lastSequence;
    uint64_t _lastConsumedSequence;
    CGPoint _floatingCenter;
    CGPoint _dragOrigin;
    CoreSetHUDBackend _activeBackend;
    NSInteger _renderFPSBaseline;
    BOOL _schedulerCleanupNeeded;
    BOOL _layoutApplying;
    UIInterfaceOrientation _hostedOrientation;
    id _orientationObserver;
    id _orientationHandler;
    void *_frontBoardHandle;
    uint64_t _orientationEpoch;
    CoreSetIOHIDEventSystemClientRef _touchClient;
    void *_ioKitHandle;
    void *_accessibilityHandle;
    void *_backBoardHandle;
    BOOL _bkInputRegistered;
    CoreSetHIDEventGetType _hidEventGetType;
    CoreSetHIDEventGetChildren _hidEventGetChildren;
    BOOL _hidCanUnschedule;
    dispatch_queue_t _pendingTouchSerialQueue;
    coreset_pending_touch::PendingTouchQueue _pendingTouchActions;
    std::atomic_uint_fast64_t _pendingTouchGeneration;
    BOOL _pendingTouchDrainInFlight;
    std::atomic_bool _inputArmed;
    std::atomic_uint_fast64_t _hidCallbacks;
    std::atomic_uint_fast64_t _hidTypeVendor;
    std::atomic_uint_fast64_t _hidTypeDigitizer;
    std::atomic_uint_fast64_t _hidTypeOther;
    std::atomic_uint_fast64_t _axParsed;
    std::atomic_uint_fast64_t _axClassMissing;
    std::atomic_uint_fast64_t _axFactoryNil;
    std::atomic_uint_fast64_t _axHandMissing;
    std::atomic_uint_fast64_t _axPathsMissing;
    std::atomic_uint_fast64_t _axException;
    std::atomic_uint_fast64_t _axChildRecovered;
    std::atomic_uint_fast64_t _axChildUnavailable;
    CoreSetInputDiagnosticCounters _inputCounts;
    int64_t _touchPointerID;
    NSString *_touchControlID;
    uint64_t _touchMenuRevision;
    BOOL _touchContinuous;
    CGPoint _touchDownPoint;
    CFAbsoluteTime _touchDownTime;
    uint64_t _touchGeneration;
    CGPoint _touchFloatingDownLogical;
    CGPoint _touchFloatingOrigin;
    BOOL _touchFloatingDragged;
    uint64_t _hostedReadbackGeneration;
    BOOL _hostedReadbackPending;
    BOOL _hostedReadbackInFlight;
    BOOL _hostedReadbackRetryNeeded;
    uint64_t _hostedReadbackEpoch;
    NSMutableArray *_hostedReadbackWaiters;
    NSMutableArray *_hostedReadbackIdleWaiters;
    BOOL _hostedAsyncStopPending;
    BOOL _hostedCleanupFailed;
    NSMutableArray *_hostedAsyncStopWaiters;
}
- (instancetype)init { return [self initWithHostingAdapter:nil]; }
- (instancetype)initWithHostingAdapter:(id<CoreSetHUDHostingAdapter>)adapter {
    if ((self = [super init])) {
        _adapter = adapter; _layers = [CoreSetCoreAnimationConsumer new];
        _observers = [NSMutableArray array]; _floatingCenter = CGPointMake(NAN, NAN);
        _hostedOrientation = UIInterfaceOrientationPortrait;
        _touchPointerID = -1;
        _inputArmed.store(false);
        _hidCallbacks.store(0); _axParsed.store(0);
        _hidTypeVendor.store(0); _hidTypeDigitizer.store(0); _hidTypeOther.store(0);
        _axClassMissing.store(0); _axFactoryNil.store(0);
        _axHandMissing.store(0); _axPathsMissing.store(0); _axException.store(0);
        _axChildRecovered.store(0); _axChildUnavailable.store(0);
        _pendingTouchGeneration.store(1);
        _pendingTouchActions.reset(1);
        _pendingTouchSerialQueue = dispatch_queue_create("com.coldcheat.simtouch", DISPATCH_QUEUE_SERIAL);
        _hostedReadbackWaiters = [NSMutableArray array];
        _hostedReadbackIdleWaiters = [NSMutableArray array];
        _hostedAsyncStopWaiters = [NSMutableArray array];
    }
    return self;
}
- (BOOL)localSurfacesReady {
    return _running && _drawWindow && _menuWindow && _drawCanvas && _panel &&
        _menuWindow.windowScene.activationState != UISceneActivationStateUnattached;
}
- (BOOL)hasHostedRegistrationReceipt {
    return self.localSurfacesReady && _menuRegistered && _drawRegistered &&
        _adapter && [_adapter respondsToSelector:@selector(hostGeneration)] &&
        [_adapter respondsToSelector:@selector(localSurfacesStillPublished)] &&
        [_adapter hostGeneration] == self.generation &&
        _hostedReadbackGeneration == self.generation &&
        [_adapter localSurfacesStillPublished];
}
- (BOOL)hostedRegistrationReceipt { return [self hasHostedRegistrationReceipt]; }
- (CGSize)logicalCanvasSize { return _drawCanvas ? _drawCanvas.bounds.size : CGSizeZero; }
- (BOOL)hostedInputMonitorArmed { return _inputArmed.load() && (_touchClient != NULL || _bkInputRegistered); }
- (NSString *)hostingDiagnosticSnapshot {
    const NSInteger sceneState = _menuWindow.windowScene
        ? _menuWindow.windowScene.activationState : -1;
    const BOOL adapterGenerationAvailable = _adapter &&
        [_adapter respondsToSelector:@selector(hostGeneration)];
    const uint64_t adapterGeneration = adapterGenerationAvailable ? [_adapter hostGeneration] : 0;
    const CGSize logicalSize = self.logicalCanvasSize;
    NSString *state = [NSString stringWithFormat:
        @"running=%d foreground=%d sceneState=%ld localReady=%d menuRegistered=%d drawRegistered=%d adapter=%d adapterGenerationAvailable=%d hostGeneration=%llu adapterGeneration=%llu panel=%d menuWindowHidden=%d drawWindowHidden=%d floatingHidden=%d floatingAttached=%d orientation=%ld canvas=%.0fx%.0f inputMonitor=%d",
        _running, _foreground, (long)sceneState, self.localSurfacesReady,
        _menuRegistered, _drawRegistered, _adapter != nil, adapterGenerationAvailable,
        (unsigned long long)self.generation, (unsigned long long)adapterGeneration, _panelVisible,
        _menuWindow.hidden, _drawWindow.hidden, _floating.hidden,
        _floating.superview != nil, (long)_hostedOrientation,
        logicalSize.width, logicalSize.height,
        self.hostedInputMonitorArmed];
    return [state stringByAppendingFormat:
        @" inputCounters={source=%llu sourceUnavailable=%llu event=%llu wrapper=%llu wrapperIncomplete=%llu parsed=%llu parseDropped=%llu queued=%llu queueDropped=%llu delivered=%llu deliveryDropped=%llu coordinate=%llu coordinateDropped=%llu hit=%llu hitDropped=%llu dispatched=%llu callback=%llu callbackHandled=%llu readback=%llu readbackDropped=%llu}",
        (unsigned long long)_inputCounts.source.load(),
        (unsigned long long)_inputCounts.sourceUnavailable.load(),
        (unsigned long long)_hidCallbacks.load(), (unsigned long long)_inputCounts.wrapper.load(),
        (unsigned long long)_inputCounts.wrapperIncomplete.load(), (unsigned long long)_axParsed.load(),
        (unsigned long long)_inputCounts.parseDropped.load(),
        (unsigned long long)_inputCounts.queued.load(), (unsigned long long)_inputCounts.queueDropped.load(),
        (unsigned long long)_inputCounts.delivered.load(), (unsigned long long)_inputCounts.deliveryDropped.load(),
        (unsigned long long)_inputCounts.coordinate.load(), (unsigned long long)_inputCounts.coordinateDropped.load(),
        (unsigned long long)_inputCounts.hit.load(), (unsigned long long)_inputCounts.hitDropped.load(),
        (unsigned long long)_inputCounts.dispatched.load(),
        (unsigned long long)_inputCounts.callback.load(), (unsigned long long)_inputCounts.callbackHandled.load(),
        (unsigned long long)_inputCounts.readback.load(), (unsigned long long)_inputCounts.readbackDropped.load()];
}
- (BOOL)cleanupPending { return !_running && (_menuCleanupNeeded || _drawCleanupNeeded || _schedulerCleanupNeeded); }
- (BOOL)hostedCleanupInFlight { return _hostedAsyncStopPending; }
- (BOOL)panelVisible { return _panelVisible; }
- (BOOL)floatingControlReady {
    if (!NSThread.isMainThread || !self.localSurfacesReady ||
        !_floating || !_menuWindow || _menuWindow.hidden ||
        _floating.hidden || _floating.alpha <= 0.01 ||
        !_floating.userInteractionEnabled ||
        ![_floating isDescendantOfView:_menuWindow]) return NO;
    const CGRect button = [_floating convertRect:_floating.bounds toView:_menuWindow];
    return CGRectIntersectsRect(button, _menuWindow.bounds);
}
- (uint64_t)lastConsumedSequence { return _lastConsumedSequence; }
- (NSArray<UIColor *> *)observedFloatingColors {
    if (!self.floatingControlReady || _floatingGradient.superlayer != _floating.layer ||
        !CGPointEqualToPoint(_floatingGradient.startPoint, CGPointMake(0, .5)) ||
        !CGPointEqualToPoint(_floatingGradient.endPoint, CGPointMake(1, .5))) return @[];
    NSMutableArray<UIColor *> *colors = [NSMutableArray array];
    for (id value in _floatingGradient.colors) [colors addObject:[UIColor colorWithCGColor:(__bridge CGColorRef)value]];
    return colors;
}
- (CoreSetHUDBackend)activeBackend { return _activeBackend; }
- (BOOL)renderFPSControlReady {
    return NSThread.isMainThread && self.localSurfacesReady &&
        _activeBackend == CoreSetHUDBackendMetal && _metal &&
        [_metal respondsToSelector:@selector(renderSurfaceReady)] && [_metal renderSurfaceReady] &&
        [_metal respondsToSelector:@selector(observedRenderFPS)] &&
        [_metal respondsToSelector:@selector(setPreferredRenderFPS:)];
}
- (NSInteger)observedRenderFPS {
    if (!self.renderFPSControlReady) return 0;
    const NSInteger value = [_metal observedRenderFPS];
    return value >= 30 && value <= 144 ? value : 0;
}
- (CoreSetPresentationCadenceSample)observedPresentationCadence {
    if (!NSThread.isMainThread || !self.localSurfacesReady || _activeBackend != CoreSetHUDBackendMetal ||
        !_metal || ![_metal respondsToSelector:@selector(observedPresentationCadence)])
        return CoreSetPresentationCadenceSample{};
    return [_metal observedPresentationCadence];
}
- (BOOL)applyRenderFPS:(NSInteger)fps observed:(NSInteger *)observed {
    if (observed) *observed = 0;
    if (!self.renderFPSControlReady || fps < 30 || fps > 144) return NO;
    if (!_schedulerCleanupNeeded) {
        _renderFPSBaseline = [self observedRenderFPS];
        if (_renderFPSBaseline < 30 || _renderFPSBaseline > 144) return NO;
        _schedulerCleanupNeeded = YES;
    }
    const BOOL accepted = [_metal setPreferredRenderFPS:fps];
    const NSInteger actual = [self observedRenderFPS];
    if (observed) *observed = actual;
    return accepted && actual == fps;
}
- (BOOL)restoreRenderFPS {
    if (!NSThread.isMainThread) return NO;
    if (!_schedulerCleanupNeeded) return YES;
    if (!_metal || ![_metal respondsToSelector:@selector(setPreferredRenderFPS:)] ||
        ![_metal respondsToSelector:@selector(observedRenderFPS)]) return NO;
    (void)[_metal setPreferredRenderFPS:_renderFPSBaseline];
    if ([_metal observedRenderFPS] != _renderFPSBaseline) return NO;
    _schedulerCleanupNeeded = NO;
    return YES;
}
- (BOOL)fail:(NSInteger)code message:(NSString *)message error:(NSError **)error {
    NSError *failure = [NSError errorWithDomain:@"CoreSetHUDHost" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
    if (NSThread.isMainThread) self.lastError = failure;
    if (error) *error = failure;
    return NO;
}
- (void)publishState { if (self.stateDidChange) self.stateDidChange(); }
- (void)invalidateFrames {
    [self resetHostedPointer];
    [self invalidatePendingTouchActions];
    NSArray *cancelledWaiters = [_hostedReadbackWaiters copy];
    [_hostedReadbackWaiters removeAllObjects];
    for (id waiter in cancelledWaiters) ((void (^)(BOOL))waiter)(NO);
    _hostedReadbackGeneration = 0;
    ++_hostedReadbackEpoch; _hostedReadbackPending = NO;
    self.generation = CoreSetHUDNextGeneration(self.generation);
    self.renderGeneration = CoreSetHUDNextGeneration(self.renderGeneration);
    if ([_adapter respondsToSelector:@selector(prepareForHostGeneration:)])
        [_adapter prepareForHostGeneration:self.generation];
    _lastSequence = 0;
    _lastConsumedSequence = 0;
    [_layers clear]; [_metal clear];
}
- (BOOL)setMetalConsumer:(id<CoreSetFrameConsumer>)consumer error:(NSError **)error {
    if (!NSThread.isMainThread) return [self fail:1 message:@"Main thread required" error:error];
    if (_running || self.cleanupPending) return [self fail:2 message:@"Stop and finish cleanup before replacing a renderer" error:error];
    if (consumer && consumer.backend != CoreSetHUDBackendMetal)
        return [self fail:3 message:@"The supplied adapter is not a Metal consumer" error:error];
    [_metal detach]; _metal = consumer;
    return YES;
}
- (BOOL)installRemoteHostingAdapter:(id<CoreSetHUDHostingAdapter>)adapter {
    if (!NSThread.isMainThread || _running || self.cleanupPending) return NO;
    _adapter = adapter;
    return YES;
}
- (void)attachHostingAdapter:(id<CoreSetHUDHostingAdapter>)adapter
                 completion:(void (^)(BOOL))completion {
    if (!completion) return;
    if (!NSThread.isMainThread || !_running || _adapter || !adapter ||
        !self.localSurfacesReady || self.cleanupPending) {
        completion(NO); return;
    }
    _adapter = adapter;
    if (![self installHostedOrientationObserver]) {
        _adapter = nil; completion(NO); return;
    }
    [self invalidateFrames];
    [self layoutSurfaces];
    [_drawWindow layoutIfNeeded]; [_menuWindow layoutIfNeeded];
    [CATransaction flush];
    _menuCleanupNeeded = YES; _drawCleanupNeeded = YES;
    const uint64_t generation = self.generation;
    CoreSetMenuWindow *menu = _menuWindow;
    CoreSetDrawWindow *draw = _drawWindow;
    __weak CoreSetHUDHost *weakSelf = self;
    [adapter registerBothSurfacesAsync:menu drawWindow:draw
        completion:^(BOOL observed, uint64_t adapterGeneration) {
            CoreSetHUDHost *host = weakSelf;
            const BOOL ready = host && observed && host->_running &&
                host.generation == generation && adapterGeneration == generation &&
                host->_menuWindow == menu && host->_drawWindow == draw &&
                [adapter localSurfacesStillPublished];
            if (host) {
                host->_menuRegistered = ready; host->_drawRegistered = ready;
                host->_hostedReadbackGeneration = ready ? generation : 0;
                [host selectBackend]; [host publishState];
            }
            completion(ready);
        }];
}
- (void)transitionToRemoteHostingAdapter:(id<CoreSetHUDHostingAdapter>)adapter
                              completion:(void (^)(BOOL))completion {
    if (!completion) return;
    const BOOL local = _adapter &&
        [_adapter respondsToSelector:@selector(usesDirectSourceInteraction)] &&
        [_adapter usesDirectSourceInteraction];
    if (!NSThread.isMainThread || !local || !adapter || !_running ||
        !_menuWindow || !_drawWindow || _hostedReadbackInFlight ||
        ![_adapter respondsToSelector:@selector(unregisterBothSurfacesAsync:drawWindow:completion:)]) {
        completion(NO); return;
    }
    [self disarmHostedInput];
    CoreSetMenuWindow *menu = _menuWindow;
    CoreSetDrawWindow *draw = _drawWindow;
    const uint64_t generation = self.generation;
    __weak CoreSetHUDHost *weakSelf = self;
    [_adapter unregisterBothSurfacesAsync:menu drawWindow:draw
        completion:^(BOOL menuRemoved, BOOL drawRemoved) {
            CoreSetHUDHost *host = weakSelf;
            if (!host || !menuRemoved || !drawRemoved || !host->_running ||
                host.generation != generation || host->_menuWindow != menu ||
                host->_drawWindow != draw) { completion(NO); return; }
            host->_menuRegistered = NO; host->_drawRegistered = NO;
            host->_hostedReadbackGeneration = 0;
            // Keep WZ's source/context and its local UIKit hit-test policy;
            // SpringBoard's mirror remains non-interactive.
            [CATransaction flush];
            host->_adapter = adapter;
            [host layoutSurfaces];
            [CATransaction flush];
            [adapter prepareForHostGeneration:generation];
            [adapter registerBothSurfacesAsync:menu drawWindow:draw
                completion:^(BOOL observed, uint64_t adapterGeneration) {
                    CoreSetHUDHost *current = weakSelf;
                    const BOOL ready = current && observed && current->_running &&
                        current.generation == generation && adapterGeneration == generation &&
                        current->_menuWindow == menu && current->_drawWindow == draw &&
                        [adapter localSurfacesStillPublished];
                    if (current) {
                        current->_menuRegistered = ready;
                        current->_drawRegistered = ready;
                        current->_hostedReadbackGeneration = ready ? generation : 0;
                        current->_menuCleanupNeeded = YES;
                        current->_drawCleanupNeeded = YES;
                        [current selectBackend]; [current publishState];
                    }
                    completion(ready);
                }];
        }];
}
- (BOOL)installLocalMetalConsumer:(id<CoreSetFrameConsumer>)consumer {
    return [self setMetalConsumer:consumer error:nil];
}
- (UIInterfaceOrientation)orientationFromObject:(id)object selector:(SEL)selector {
    if (!object || ![object respondsToSelector:selector]) return UIInterfaceOrientationUnknown;
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (!signature || signature.methodReturnLength != sizeof(NSInteger)) return UIInterfaceOrientationUnknown;
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = object; invocation.selector = selector;
    NSInteger raw = 0;
    @try { [invocation invoke]; [invocation getReturnValue:&raw]; }
    @catch (__unused NSException *exception) { return UIInterfaceOrientationUnknown; }
    return CoreSetHostedOrientationValid((UIInterfaceOrientation)raw)
        ? (UIInterfaceOrientation)raw : UIInterfaceOrientationUnknown;
}
- (void)applyHostedOrientation:(UIInterfaceOrientation)orientation {
    if (!NSThread.isMainThread || !_adapter || !_menuWindow || !_drawWindow ||
        !CoreSetHostedOrientationValid(orientation) || _hostedOrientation == orientation) return;
    const CGRect surface = _menuWindow.windowScene.screen.fixedCoordinateSpace.bounds;
    const CGSize previous = UIInterfaceOrientationIsLandscape(_hostedOrientation)
        ? CGSizeMake(surface.size.height, surface.size.width) : surface.size;
    const CGSize logical = UIInterfaceOrientationIsLandscape(orientation)
        ? CGSizeMake(surface.size.height, surface.size.width) : surface.size;
    if (std::isfinite(_floatingCenter.x) && std::isfinite(_floatingCenter.y) &&
        previous.width > 0 && previous.height > 0) {
        _floatingCenter.x *= logical.width / previous.width;
        _floatingCenter.y *= logical.height / previous.height;
    }
    _hostedOrientation = orientation;
    [self resetHostedPointer];
    if (_running) {
        // The source UIWindow and CA context are unchanged. Invalidate only
        // local pixels; keep host/adapter generation and the remote receipt.
        [_layers clear]; [_metal clear]; _lastSequence = 0; _lastConsumedSequence = 0;
        self.renderGeneration = CoreSetHUDNextGeneration(self.renderGeneration);
    }
    [self layoutSurfaces];
    [_drawWindow layoutIfNeeded]; [_menuWindow layoutIfNeeded];
    [CATransaction flush];
    if (_running) [self publishState];
    NSLog(@"Core-SET: hosted orientation=%ld surface=%.0fx%.0f logical=%.0fx%.0f angle=%.3f",
          (long)orientation, surface.size.width, surface.size.height,
          logical.width, logical.height, CoreSetHostedOrientationAngle(orientation));
}
- (BOOL)installHostedOrientationObserver {
    if (!_adapter || _orientationObserver) return YES;
    if (!_frontBoardHandle) _frontBoardHandle = dlopen(
        "/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices",
        RTLD_LAZY | RTLD_GLOBAL);
    Class observerClass = objc_getClass("FBSOrientationObserver");
    if (!observerClass) return NO;
    id observer = [[observerClass alloc] init];
    SEL setHandler = NSSelectorFromString(@"setHandler:");
    NSMethodSignature *signature = [observer methodSignatureForSelector:setHandler];
    if (!signature) return NO;
    const uint64_t epoch = ++_orientationEpoch;
    __weak CoreSetHUDHost *weakSelf = self;
    id handler = [^(id update) {
        dispatch_async(dispatch_get_main_queue(), ^{
            CoreSetHUDHost *host = weakSelf;
            if (!host || host->_orientationEpoch != epoch) return;
            UIInterfaceOrientation value = [host orientationFromObject:update
                selector:NSSelectorFromString(@"orientation")];
            [host applyHostedOrientation:value];
        });
    } copy];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = observer; invocation.selector = setHandler;
    [invocation setArgument:&handler atIndex:2];
    @try { [invocation invoke]; }
    @catch (__unused NSException *exception) { return NO; }
    _orientationObserver = observer; _orientationHandler = handler;
    UIInterfaceOrientation initial = [self orientationFromObject:observer
        selector:NSSelectorFromString(@"activeInterfaceOrientation")];
    NSLog(@"Core-SET: hosted orientation observer armed=1 initial=%ld", (long)initial);
    [self applyHostedOrientation:initial];
    return YES;
}
- (void)stopHostedOrientationObserver {
    ++_orientationEpoch;
    SEL invalidate = NSSelectorFromString(@"invalidate");
    if ([_orientationObserver respondsToSelector:invalidate]) {
        @try { ((void (*)(id, SEL))objc_msgSend)(_orientationObserver, invalidate); }
        @catch (__unused NSException *exception) {}
    }
    _orientationObserver = nil; _orientationHandler = nil;
}
- (void)resetHostedPointer {
    if (_touchControlID && ![_touchControlID isEqualToString:@"host.floating"] &&
        [_menuController conformsToProtocol:@protocol(CoreSetHostedMenuTapConsumer)]) {
        [self dispatchHostedMenuControl:_touchControlID phase:CoreSetHostedPointerPhaseCancelled
            point:CGPointZero consumer:(id<CoreSetHostedMenuTapConsumer>)_menuController];
    }
    _touchPointerID = -1; _touchControlID = nil; _touchGeneration = 0;
    _touchMenuRevision = 0; _touchContinuous = NO;
    _touchDownPoint = CGPointZero; _touchDownTime = 0;
    _touchFloatingDownLogical = CGPointZero; _touchFloatingOrigin = CGPointZero;
    _touchFloatingDragged = NO;
}
- (BOOL)dispatchHostedMenuControl:(NSString *)identifier
                           phase:(CoreSetHostedPointerPhase)phase
                           point:(CGPoint)point consumer:(id<CoreSetHostedMenuTapConsumer>)consumer {
    const uint64_t generation = self.generation;
    const BOOL handled = [consumer handleHostedControlID:identifier phase:phase atPoint:point];
    if (handled) _inputCounts.callbackHandled.fetch_add(1);
    CoreSetLogInputStage("callback", "menu-return", &_inputCounts.callback,
        generation, phase, identifier, handled);
    return handled;
}
- (CGPoint)menuWindowPointFromFixedSurface:(CGPoint)point {
    const CGPoint converted = [_menuWindow convertPoint:point
        fromCoordinateSpace:_menuWindow.windowScene.screen.fixedCoordinateSpace];
    const BOOL inside = _menuWindow && std::isfinite(converted.x) && std::isfinite(converted.y) &&
        CGRectContainsPoint(_menuWindow.bounds, converted);
    UIScreen *screen = _menuWindow.windowScene.screen;
    const BOOL fixedInside = screen && CGRectContainsPoint(screen.fixedCoordinateSpace.bounds, point);
    const BOOL sceneInside = _menuWindow.windowScene &&
        CGRectContainsPoint(_menuWindow.windowScene.coordinateSpace.bounds, point);
    const BOOL nativeInside = screen && CGRectContainsPoint(screen.nativeBounds, point);
    const BOOL unitRange = point.x >= 0 && point.x <= 1 && point.y >= 0 && point.y <= 1;
    std::atomic_uint_fast64_t *counter = inside ? &_inputCounts.coordinate : &_inputCounts.coordinateDropped;
    const uint64_t count = counter->fetch_add(1) + 1;
    if (CoreSetInputLogDue(count))
        NSLog(@"Core-SET: hosted input stage=coordinate count=%llu generation=%llu mapping=screen-fixed fixedInside=%d sceneInside=%d nativeInside=%d unitRange=%d menuInside=%d orientation=%ld scale=%.2f",
              (unsigned long long)count, (unsigned long long)self.generation,
              fixedInside, sceneInside, nativeInside, unitRange, inside,
              (long)_hostedOrientation, screen.scale);
    return converted;
}
- (NSString *)hostedControlIDAtSurfacePoint:(CGPoint)point missReason:(const char **)missReason {
    if (missReason) *missReason = "no-eligible-control";
    if (!_menuWindow || !_floating || !_menuController ||
        !std::isfinite(point.x) || !std::isfinite(point.y)) {
        if (missReason) *missReason = "surface-or-point-unavailable";
        return nil;
    }
    CGRect surface = _menuWindow.windowScene.screen.fixedCoordinateSpace.bounds;
    const CGPoint windowPoint = [self menuWindowPointFromFixedSurface:point];
    if (!CGRectContainsPoint(surface, point)) {
        if (missReason) *missReason = "outside-fixed-surface";
        return nil;
    }
    CGPoint floatPoint = [_floating convertPoint:windowPoint fromView:_menuWindow];
    if (!_floating.hidden && _floating.alpha > 0.01 && _floating.userInteractionEnabled &&
        [_floating pointInside:floatPoint withEvent:nil]) return @"host.floating";
    if (!_panelVisible || _panel.hidden ||
        ![_menuController conformsToProtocol:@protocol(CoreSetHostedMenuTapConsumer)]) {
        if (missReason) *missReason = "panel-hidden-or-consumer-unavailable";
        return nil;
    }
    if (_menuController.presentedViewController ||
        _menuWindow.rootViewController.presentedViewController) {
        if (missReason) *missReason = "modal-presented";
        return nil;
    }
    CGPoint menuPoint = [_menuController.view convertPoint:windowPoint fromView:_menuWindow];
    id<CoreSetHostedMenuTapConsumer> consumer = (id)_menuController;
    return [consumer hostedControlIDAtPoint:menuPoint];
}
- (void)handleHostedPointer:(NSInteger)phase pointerID:(int64_t)pointerID
                     point:(CGPoint)point generation:(uint64_t)generation
                  timestamp:(CFAbsoluteTime)timestamp {
    if (!NSThread.isMainThread || !_inputArmed.load() || !_running || _foreground ||
        UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
        CoreSetLogInputStage("hit", "host-not-interactive", &_inputCounts.hitDropped,
            self.generation, phase, nil, 0);
        [self resetHostedPointer]; return;
    }
    if (CFAbsoluteTimeGetCurrent() - timestamp > 0.75) {
        CoreSetLogInputStage("hit", "event-expired", &_inputCounts.hitDropped,
            self.generation, phase, nil, 0);
        [self resetHostedPointer]; return;
    }
    if (phase == CoreSetHostedPointerPhaseCancelled) { [self resetHostedPointer]; return; }
    id<CoreSetHostedMenuTapConsumer> consumer =
        [_menuController conformsToProtocol:@protocol(CoreSetHostedMenuTapConsumer)]
            ? (id)_menuController : nil;
    if (phase == CoreSetHostedPointerPhaseBegan) {
        if (![self hasHostedRegistrationReceipt]) {
            if (_hostedReadbackPending || _hostedReadbackInFlight) {
                CoreSetLogInputStage("hit", "readback-pending", &_inputCounts.hitDropped,
                    self.generation, phase, nil, 0);
                [self resetHostedPointer]; return;
            }
            CoreSetLogInputStage("hit", "source-context-unavailable", &_inputCounts.hitDropped,
                self.generation, phase, nil, 0);
            [self failClosedHostedInput];
            return;
        }
        if (_touchPointerID >= 0 || generation != self.generation ||
            !self.localSurfacesReady || !_menuRegistered || !_drawRegistered ||
            ![_adapter respondsToSelector:@selector(hostGeneration)] ||
            [_adapter hostGeneration] != self.generation) {
            CoreSetLogInputStage("hit", _touchPointerID >= 0 ? "pointer-busy" : "stale-host-generation",
                &_inputCounts.hitDropped, self.generation, phase, nil, 0);
            return;
        }
        const char *missReason = "no-eligible-control";
        NSString *identifier = [self hostedControlIDAtSurfacePoint:point missReason:&missReason];
        if (!identifier) {
            CoreSetLogInputStage("hit", missReason, &_inputCounts.hitDropped,
                self.generation, phase, nil, 0);
            return;
        }
        _touchPointerID = pointerID; _touchControlID = [identifier copy];
        _touchGeneration = generation; _touchDownPoint = point;
        _touchDownTime = timestamp;
        CoreSetLogInputStage("hit", "control-matched", &_inputCounts.hit,
            generation, phase, identifier, 1);
        if ([identifier isEqualToString:@"host.floating"]) {
            _touchContinuous = YES;
            _touchFloatingDownLogical = [_menuWindow.rootViewController.view
                convertPoint:[self menuWindowPointFromFixedSurface:point] fromView:_menuWindow];
            _touchFloatingOrigin = _floatingCenter;
        }
        if (![identifier isEqualToString:@"host.floating"] && consumer) {
            _touchMenuRevision = consumer.hostedMenuRevision;
            _touchContinuous = [consumer hostedControlAllowsDrag:identifier];
            CGPoint menuPoint = [_menuController.view convertPoint:[self menuWindowPointFromFixedSurface:point] fromView:_menuWindow];
            (void)[self dispatchHostedMenuControl:identifier phase:CoreSetHostedPointerPhaseBegan
                point:menuPoint consumer:consumer];
        }
        return;
    }
    if (_touchPointerID != pointerID || _touchGeneration != self.generation ||
        (_touchMenuRevision && (!consumer ||
            consumer.hostedMenuRevision != _touchMenuRevision)) ||
        (!_touchContinuous && (timestamp - _touchDownTime > 0.75 ||
            hypot(point.x - _touchDownPoint.x, point.y - _touchDownPoint.y) > 9.0))) {
        CoreSetLogInputStage("hit", "pointer-or-menu-lifecycle-changed", &_inputCounts.hitDropped,
            self.generation, phase, _touchControlID, 0);
        [self resetHostedPointer]; return;
    }
    if (phase == CoreSetHostedPointerPhaseMoved) {
        if ([_touchControlID isEqualToString:@"host.floating"]) {
            CGPoint logical = [_menuWindow.rootViewController.view convertPoint:[self menuWindowPointFromFixedSurface:point] fromView:_menuWindow];
            CGFloat dx = logical.x - _touchFloatingDownLogical.x;
            CGFloat dy = logical.y - _touchFloatingDownLogical.y;
            if (hypot(dx, dy) > 9) _touchFloatingDragged = YES;
            if (_touchFloatingDragged) {
                _floatingCenter = CGPointMake(_touchFloatingOrigin.x + dx, _touchFloatingOrigin.y + dy);
                [self layoutSurfaces];
            }
        } else if (_touchContinuous && consumer) {
            CGPoint menuPoint = [_menuController.view convertPoint:[self menuWindowPointFromFixedSurface:point] fromView:_menuWindow];
            (void)[self dispatchHostedMenuControl:_touchControlID phase:CoreSetHostedPointerPhaseMoved
                point:menuPoint consumer:consumer];
        }
        return;
    }
    if (phase != CoreSetHostedPointerPhaseEnded) { [self resetHostedPointer]; return; }
    NSString *identifier = _touchControlID;
    const BOOL continuous = _touchContinuous;
    const BOOL floatingDragged = _touchFloatingDragged;
    if (![self hasHostedRegistrationReceipt]) {
        if (_hostedReadbackPending || _hostedReadbackInFlight) {
            CoreSetLogInputStage("hit", "readback-pending-at-end", &_inputCounts.hitDropped,
                self.generation, phase, identifier, 0);
            [self resetHostedPointer]; return;
        }
        CoreSetLogInputStage("hit", "source-context-unavailable-at-end", &_inputCounts.hitDropped,
            self.generation, phase, identifier, 0);
        [self failClosedHostedInput]; return;
    }
    if (!continuous && ![identifier isEqualToString:[self hostedControlIDAtSurfacePoint:point missReason:nullptr]]) {
        CoreSetLogInputStage("hit", "control-changed-at-end", &_inputCounts.hitDropped,
            self.generation, phase, identifier, 0);
        [self resetHostedPointer]; return;
    }
    _touchControlID = nil; // A confirmed End must not run the cancel handler.
    [self resetHostedPointer];
    const uint64_t dispatchCount = _inputCounts.dispatched.fetch_add(1) + 1;
    if (CoreSetInputLogDue(dispatchCount))
        NSLog(@"Core-SET: hosted input stage=dispatch source=HID control=%@ action=begin generation=%llu count=%llu",
              identifier, (unsigned long long)generation, (unsigned long long)dispatchCount);
    BOOL dispatched = NO;
    if ([identifier isEqualToString:@"host.floating"]) {
        if (!floatingDragged) [self togglePanelFromHostedPointer];
        dispatched = YES;
        CoreSetLogInputStage("callback", floatingDragged ? "floating-drag" : "panel-request",
            &_inputCounts.callback, generation, phase, identifier, -1);
    } else if (consumer) {
        CGPoint menuPoint = [_menuController.view convertPoint:[self menuWindowPointFromFixedSurface:point] fromView:_menuWindow];
        dispatched = [self dispatchHostedMenuControl:identifier phase:CoreSetHostedPointerPhaseEnded
            point:menuPoint consumer:consumer];
    }
    // Dispatch is not an apply receipt; existing menu/channel callbacks own it.
    if (CoreSetInputLogDue(dispatchCount))
        NSLog(@"Core-SET: hosted input stage=dispatch source=HID control=%@ dispatched=%d generation=%llu count=%llu",
              identifier, dispatched, (unsigned long long)generation, (unsigned long long)dispatchCount);
}
- (void)invalidatePendingTouchActions {
    const uint64_t next = _pendingTouchGeneration.fetch_add(1) + 1;
    __weak CoreSetHUDHost *weakSelf = self;
    dispatch_async(_pendingTouchSerialQueue, ^{
        CoreSetHUDHost *host = weakSelf;
        if (!host || next != host->_pendingTouchGeneration.load()) return;
        host->_pendingTouchActions.reset(next);
        // Place cancellation in the same serial-to-main ordering as delivery.
        // A later generation must never be cleared by this queued callback.
        dispatch_async(dispatch_get_main_queue(), ^{
            CoreSetHUDHost *current = weakSelf;
            if (current && next == current->_pendingTouchGeneration.load())
                [current resetHostedPointer];
        });
    });
}
- (void)drainPendingTouchActionsOnQueue {
    if (_pendingTouchDrainInFlight) return;
    const uint64_t generation = _pendingTouchGeneration.load();
    coreset_pending_touch::PendingTouchAction action;
    int64_t expiredPointerID = -1;
    const auto result = _pendingTouchActions.popNext(CFAbsoluteTimeGetCurrent(),
        generation, &action, &expiredPointerID);
    if (result == coreset_pending_touch::PopResult::DroppedExpiredLifecycle) {
        CoreSetLogInputStage("delivery", "queue-lifecycle-expired", &_inputCounts.deliveryDropped,
            self.generation, -1, nil, 0);
        __weak CoreSetHUDHost *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            CoreSetHUDHost *host = weakSelf;
            if (host && generation == host->_pendingTouchGeneration.load() &&
                host->_touchPointerID == expiredPointerID) [host resetHostedPointer];
        });
        return;
    }
    if (result != coreset_pending_touch::PopResult::Action) return;
    _pendingTouchDrainInFlight = YES;
    auto pending = std::make_shared<coreset_pending_touch::PendingTouchAction>(std::move(action));
    __weak CoreSetHUDHost *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        CoreSetHUDHost *host = weakSelf;
        const double now = CFAbsoluteTimeGetCurrent();
        const BOOL current = host && generation == host->_pendingTouchGeneration.load();
        const BOOL expired = current && now >= pending->expirationTime &&
            coreset_pending_touch::isLifecycle(pending->kind);
        if (current && host->_running && host->_inputArmed.load() && !host->_foreground &&
            coreset_pending_touch::canExecute(*pending, now, generation)) {
            CoreSetLogInputStage("delivery", "main-action", &host->_inputCounts.delivered,
                host.generation, (NSInteger)pending->kind, nil, 1);
            pending->actionBlock();
        } else if (host) {
            const char *reason = !current ? "stale-queue-generation" :
                (expired ? "main-lifecycle-expired" : "host-not-interactive");
            CoreSetLogInputStage("delivery", reason, &host->_inputCounts.deliveryDropped,
                host.generation, (NSInteger)pending->kind, nil, 0);
            if (expired && host->_touchPointerID == pending->pointerID)
                [host resetHostedPointer];
        }
        dispatch_async(host ? host->_pendingTouchSerialQueue : dispatch_get_main_queue(), ^{
            if (!host) return;
            if (expired && generation == host->_pendingTouchGeneration.load())
                host->_pendingTouchActions.discardAll();
            host->_pendingTouchDrainInFlight = NO;
            [host drainPendingTouchActionsOnQueue];
        });
    });
}
- (void)receiveHostedHIDEvent:(CoreSetIOHIDEventRef)event {
    if (!_inputArmed.load() || !event) return;
    const uint64_t callbacks = _hidCallbacks.fetch_add(1) + 1;
    const uint32_t eventType = _hidEventGetType
        ? _hidEventGetType(event) : UINT32_MAX;
    if (eventType == 1) _hidTypeVendor.fetch_add(1);
    else if (eventType == 11) _hidTypeDigitizer.fetch_add(1);
    else _hidTypeOther.fetch_add(1);
    if (callbacks <= 8 || callbacks % 64 == 0)
        NSLog(@"Core-SET: hosted input stage=event count=%llu provider=%s type=%u vendor=%llu digitizer=%llu other=%llu cleanupCapable=%d typeKnown=%d",
              (unsigned long long)callbacks, _bkInputRegistered ? "BKSHID" : "IOHID",
              eventType, (unsigned long long)_hidTypeVendor.load(),
              (unsigned long long)_hidTypeDigitizer.load(),
              (unsigned long long)_hidTypeOther.load(),
              _touchClient && _hidCanUnschedule, eventType != UINT32_MAX);
    // AX decodes the HID pointer while the callback owns it. Only value types
    // enter the serial queue; the IOHIDEventRef is never retained asynchronously.
    @autoreleasepool { @try {
        Class eventClass = NSClassFromString(@"AXEventRepresentation");
        if (!eventClass) {
            CoreSetLogAXDrop("class-missing", &_axClassMissing, &_inputCounts.parseDropped); return;
        }
        CoreSetAXEvent *representation = ((id (*)(id, SEL, CoreSetIOHIDEventRef, NSString *))objc_msgSend)(
            eventClass, @selector(representationWithHIDEvent:hidStreamIdentifier:),
            event, @"UIApplicationEvents");
        const BOOL rootAX = representation != nil;
        const BOOL rootHand = CoreSetAXHasUsableHand(representation);
        CFIndex childCount = 0;
        uint64_t digitizerChildren = 0;
        uint64_t vendorChildren = 0, otherChildren = 0, candidates = 0;
        NSUInteger selectedDepth = 0, maxDepth = 0, scannedNodes = 0;
        uint32_t selectedType = eventType;
        BOOL scanTruncated = NO;
        NSMutableIndexSet *candidatePointers = [NSMutableIndexSet indexSet];
        if (!rootHand && _hidEventGetChildren) {
            // The callback ABI and factory are WZ's unchanged IOHIDEventRef
            // path. Inspect parent-to-child layers with the already resolved
            // accessors; do not guess ObjC wrappers or object field offsets.
            struct Node { CoreSetIOHIDEventRef event; NSUInteger depth; };
            constexpr NSUInteger nodeLimit = 64, depthLimit = 4;
            Node nodes[nodeLimit] = {{event, 0}};
            NSUInteger nodeCount = 1;
            for (NSUInteger cursor = 0; cursor < nodeCount; ++cursor) {
                ++scannedNodes;
                const Node node = nodes[cursor];
                maxDepth = MAX(maxDepth, node.depth);
                if (cursor != 0) {
                    const uint32_t type = _hidEventGetType ? _hidEventGetType(node.event) : UINT32_MAX;
                    if (type == 11) ++digitizerChildren;
                    else if (type == 1) ++vendorChildren;
                    else ++otherChildren;
                    CoreSetAXEvent *candidate = ((id (*)(id, SEL, CoreSetIOHIDEventRef, NSString *))objc_msgSend)(
                        eventClass, @selector(representationWithHIDEvent:hidStreamIdentifier:),
                        node.event, @"UIApplicationEvents");
                    if (CoreSetAXHasUsableHand(candidate)) {
                        ++candidates;
                        NSArray<CoreSetAXEventPath *> *candidatePaths = candidate.handInfo.paths;
                        if (candidatePaths.count > nodeLimit) { scanTruncated = YES; break; }
                        for (CoreSetAXEventPath *path in candidatePaths)
                            [candidatePointers addIndex:path.pathIdentity];
                        // Breadth first keeps the outer digitizer/hand
                        // container ahead of leaf finger events.
                        if (selectedDepth == 0) {
                            representation = candidate; selectedDepth = node.depth; selectedType = type;
                        }
                    }
                }
                CFArrayRef children = _hidEventGetChildren(node.event);
                if (!children || CFGetTypeID(children) != CFArrayGetTypeID()) continue;
                const CFIndex count = CFArrayGetCount(children);
                if (cursor == 0) childCount = count;
                if (count > (CFIndex)nodeLimit) scanTruncated = YES;
                if (node.depth >= depthLimit && count > 0) { scanTruncated = YES; continue; }
                const CFIndex boundedCount = MIN(count, (CFIndex)nodeLimit);
                for (CFIndex index = 0; index < boundedCount; ++index) {
                    CoreSetIOHIDEventRef child = (CoreSetIOHIDEventRef)CFArrayGetValueAtIndex(children, index);
                    if (!child) continue;
                    BOOL seen = NO;
                    for (NSUInteger visited = 0; visited < nodeCount; ++visited)
                        if (nodes[visited].event == child) { seen = YES; break; }
                    if (seen) continue;
                    if (nodeCount == nodeLimit) { scanTruncated = YES; break; }
                    nodes[nodeCount++] = {child, node.depth + 1};
                }
            }
        }
        const uint64_t wrapperCount = _inputCounts.wrapper.fetch_add(1) + 1;
        if (CoreSetInputLogDue(wrapperCount))
            NSLog(@"Core-SET: hosted input stage=wrapper count=%llu provider=%s rootType=%u rootAX=%d rootHand=%d children=%ld digitizerNodes=%llu vendorNodes=%llu otherNodes=%llu candidates=%llu candidatePointers=%lu nodes=%lu selectedDepth=%lu selectedType=%u maxDepth=%lu truncated=%d childrenAPI=%d typeAPI=%d",
                  (unsigned long long)wrapperCount, _bkInputRegistered ? "BKSHID" : "IOHID",
                  eventType, rootAX, rootHand, (long)childCount,
                  (unsigned long long)digitizerChildren, (unsigned long long)vendorChildren,
                  (unsigned long long)otherChildren, (unsigned long long)candidates,
                  (unsigned long)candidatePointers.count, (unsigned long)scannedNodes, (unsigned long)selectedDepth,
                  selectedType, (unsigned long)maxDepth, scanTruncated,
                  _hidEventGetChildren != NULL, _hidEventGetType != NULL);
        if (scanTruncated) {
            CoreSetLogAXDrop("wrapper-scan-limit", &_inputCounts.wrapperIncomplete, &_inputCounts.parseDropped);
            [self invalidatePendingTouchActions]; return;
        }
        if (candidatePointers.count > 1) {
            CoreSetLogAXDrop("wrapper-multiple-pointers", &_inputCounts.multiplePaths, &_inputCounts.parseDropped);
            [self invalidatePendingTouchActions]; return;
        }
        if (!representation) {
            const uint64_t count = _axFactoryNil.fetch_add(1) + 1;
            _inputCounts.parseDropped.fetch_add(1);
            _axChildUnavailable.fetch_add(1);
            if (CoreSetInputLogDue(count))
                NSLog(@"Core-SET: hosted input stage=ax-drop reason=factory-nil count=%llu eventType=%u children=%ld digitizerChildren=%llu",
                      (unsigned long long)count, eventType, (long)childCount,
                      (unsigned long long)digitizerChildren);
            return;
        }
        if (selectedDepth > 0) {
            const uint64_t recovered = _axChildRecovered.fetch_add(1) + 1;
            if (CoreSetInputLogDue(recovered))
                NSLog(@"Core-SET: hosted input stage=ax-child-recover count=%llu eventType=%u children=%ld digitizerChildren=%llu",
                      (unsigned long long)recovered, eventType, (long)childCount,
                      (unsigned long long)digitizerChildren);
        }
        CoreSetAXEventHand *hand = representation.handInfo;
        if (!hand || ![hand respondsToSelector:@selector(paths)]) {
            CoreSetLogAXDrop("hand-missing", &_axHandMissing, &_inputCounts.parseDropped); return;
        }
        NSArray<CoreSetAXEventPath *> *paths = hand.paths;
        if (![paths isKindOfClass:NSArray.class]) {
            CoreSetLogAXDrop("paths-missing", &_axPathsMissing, &_inputCounts.parseDropped); return;
        }
        if (!paths.count) {
            CoreSetLogAXDrop("paths-empty", &_inputCounts.pathsEmpty, &_inputCounts.parseDropped); return;
        }
        if (paths.count != 1) {
            CoreSetLogAXDrop("multiple-paths", &_inputCounts.multiplePaths, &_inputCounts.parseDropped);
            [self invalidatePendingTouchActions];
            return;
        }
        const int64_t pointerID = (int64_t)paths.firstObject.pathIdentity;
        if (pointerID == 9) {
            CoreSetLogAXDrop("reserved-pointer", &_inputCounts.reservedPointer, &_inputCounts.parseDropped); return;
        }
        NSInteger phase = -1;
        if (representation.isCancel) phase = CoreSetHostedPointerPhaseCancelled;
        else if (representation.isLift || representation.isInRangeLift) phase = CoreSetHostedPointerPhaseEnded;
        else if (representation.isTouchDown) phase = CoreSetHostedPointerPhaseBegan;
        else if (representation.isMove || representation.isChordChange) phase = CoreSetHostedPointerPhaseMoved;
        if (phase < 0) {
            CoreSetLogAXDrop("phase-missing", &_inputCounts.phaseMissing, &_inputCounts.parseDropped); return;
        }
        const CGPoint point = representation.location;
        if (!std::isfinite(point.x) || !std::isfinite(point.y)) {
            CoreSetLogAXDrop("nonfinite-point", &_inputCounts.nonfinitePoint, &_inputCounts.parseDropped); return;
        }
        if (phase == CoreSetHostedPointerPhaseCancelled) {
            CoreSetLogAXDrop("physical-cancel", &_inputCounts.cancelled, &_inputCounts.parseDropped);
            [self invalidatePendingTouchActions];
            return;
        }
        const uint64_t parsed = _axParsed.fetch_add(1) + 1;
        if (CoreSetInputLogDue(parsed))
            NSLog(@"Core-SET: hosted input stage=ax-parse count=%llu single=1 phase=%ld generation=%llu",
                  (unsigned long long)parsed, (long)phase, (unsigned long long)self.generation);
        const uint64_t hostGeneration = self.generation;
        const uint64_t queueGeneration = _pendingTouchGeneration.load();
        const double timestamp = CFAbsoluteTimeGetCurrent();
        const auto kind = phase == CoreSetHostedPointerPhaseBegan
            ? coreset_pending_touch::Kind::Began
            : (phase == CoreSetHostedPointerPhaseMoved
                ? coreset_pending_touch::Kind::Moved : coreset_pending_touch::Kind::Ended);
        __weak CoreSetHUDHost *weakSelf = self;
        coreset_pending_touch::PendingTouchAction action{
            pointerID, kind, timestamp + coreset_pending_touch::kExpirationInterval,
            queueGeneration, [=] {
                CoreSetHUDHost *host = weakSelf;
                if (host) [host handleHostedPointer:phase pointerID:pointerID point:point
                                         generation:hostGeneration timestamp:timestamp];
            }
        };
        dispatch_async(_pendingTouchSerialQueue, ^{
            CoreSetHUDHost *host = weakSelf;
            if (!host) return;
            const auto result = host->_pendingTouchActions.enqueue(std::move(action),
                CFAbsoluteTimeGetCurrent(), host->_pendingTouchGeneration.load());
            const BOOL accepted = result != coreset_pending_touch::EnqueueResult::Rejected;
            const char *reason = !accepted ? "stale-or-expired" :
                (result == coreset_pending_touch::EnqueueResult::CoalescedMove ? "coalesced-move" :
                 (result == coreset_pending_touch::EnqueueResult::AppendedAfterDroppingLifecycle
                    ? "expired-lifecycle-pruned" : "appended"));
            CoreSetLogInputStage("queue", reason,
                accepted ? &host->_inputCounts.queued : &host->_inputCounts.queueDropped,
                host.generation, phase, nil, accepted);
            if (result == coreset_pending_touch::EnqueueResult::AppendedAfterDroppingLifecycle) {
                // Expiry cleared the pending lifecycle. Release its active
                // pointer before the newly appended Begin reaches main.
                dispatch_async(dispatch_get_main_queue(), ^{
                    CoreSetHUDHost *current = weakSelf;
                    if (current && queueGeneration == current->_pendingTouchGeneration.load())
                        [current resetHostedPointer];
                });
            }
            if (accepted)
                [host drainPendingTouchActionsOnQueue];
        });
    } @catch (__unused NSException *exception) {
        CoreSetLogAXDrop("exception", &_axException, &_inputCounts.parseDropped);
    } }
}
- (void)failClosedHostedInput {
    if (!_running || !_inputArmed.load()) return;
    NSLog(@"Core-SET: hosted input stage=invalidated reason=source-context");
    [self disarmHostedInput];
    _menuWindow.backgroundPassThrough = YES;
    _menuWindow.userInteractionEnabled = NO;
    __weak CoreSetHUDHost *weakSelf = self;
    [self whenHostedReadbackIdle:^{
        CoreSetHUDHost *host = weakSelf;
        if (!host || !host->_running) return;
        if (host.hostingInvalidated) host.hostingInvalidated();
        else (void)[host stop];
    }];
}
- (BOOL)armHostedInput {
    if (!NSThread.isMainThread || !_running || !_orientationObserver) {
        CoreSetLogInputStage("source", "host-orientation", &_inputCounts.sourceUnavailable,
            self.generation, -1, nil, 0);
        NSLog(@"Core-SET: hosted input monitor armed=0 reason=host-orientation"); return NO;
    }
    if (!self.hostedRegistrationReceipt) {
        CoreSetLogInputStage("source", "hosting-registration", &_inputCounts.sourceUnavailable,
            self.generation, -1, nil, 0);
        NSLog(@"Core-SET: hosted input monitor armed=0 reason=hosting-registration"); return NO;
    }
    if (self.hostedInputMonitorArmed) return YES;
    const BOOL armed = [self startInputMonitor];
    CoreSetLogInputStage("source", armed ? (_bkInputRegistered ? "BKSHID" : "IOHID") : "provider-unavailable",
        armed ? &_inputCounts.source : &_inputCounts.sourceUnavailable,
        self.generation, -1, nil, armed);
    NSLog(@"Core-SET: hosted input monitor armed=%d mode=%@ cleanupCapable=%d",
          armed, _bkInputRegistered ? @"BKSHID" : @"IOHID",
          _touchClient && _hidCanUnschedule);
    return armed;
}
- (BOOL)startInputMonitor {
    if (!NSThread.isMainThread || !_running || _touchClient || _bkInputRegistered) return NO;
    if (gCoreSetHostedInputOwner && gCoreSetHostedInputOwner != self) {
        NSLog(@"Core-SET: hosted input monitor armed=0 reason=another-owner"); return NO;
    }
    if (!_accessibilityHandle) _accessibilityHandle = dlopen(
        "/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities",
        RTLD_LAZY | RTLD_LOCAL);
    Class axClass = NSClassFromString(@"AXEventRepresentation");
    if (!axClass) {
        NSLog(@"Core-SET: hosted input monitor armed=0 reason=AX-class"); return NO;
    }
    const SEL factory = @selector(representationWithHIDEvent:hidStreamIdentifier:);
    NSMethodSignature *factorySignature = [axClass methodSignatureForSelector:factory];
    const NSUInteger argumentCount = factorySignature.numberOfArguments;
    const char *eventArgument = argumentCount > 2 ? [factorySignature getArgumentTypeAtIndex:2] : "missing";
    const char *streamArgument = argumentCount > 3 ? [factorySignature getArgumentTypeAtIndex:3] : "missing";
    const uint64_t sourceAPICount = _inputCounts.sourceAPI.fetch_add(1) + 1;
    if (CoreSetInputLogDue(sourceAPICount))
        NSLog(@"Core-SET: hosted input stage=source-api count=%llu callbackABI=WZ-IOHIDEventRef factoryAvailable=%d arguments=%lu eventArgument=%s streamArgument=%s returnArgument=%s",
              (unsigned long long)sourceAPICount, [axClass respondsToSelector:factory],
              (unsigned long)argumentCount, eventArgument, streamArgument,
              factorySignature.methodReturnType ?: "missing");
    if (!_ioKitHandle) _ioKitHandle = dlopen(
        "/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL);
    _hidEventGetType = _ioKitHandle ? (CoreSetHIDEventGetType)dlsym(
        _ioKitHandle, "IOHIDEventGetType") : NULL;
    _hidEventGetChildren = _ioKitHandle ? (CoreSetHIDEventGetChildren)dlsym(
        _ioKitHandle, "IOHIDEventGetChildren") : NULL;
    _hidCanUnschedule = _ioKitHandle && dlsym(
        _ioKitHandle, "IOHIDEventSystemClientUnscheduleWithRunLoop");
    if (gCoreSetDormantHIDClient) {
        _touchClient = gCoreSetDormantHIDClient;
        gCoreSetHostedInputOwner = self;
        _inputArmed.store(true);
        return YES;
    }
    if (gCoreSetBKCallbackInstalled) {
        // BKSHID cannot be unregistered. Reuse its one process callback rather
        // than adding a later IOHID callback for the next scene/host.
        _bkInputRegistered = YES;
        gCoreSetHostedInputOwner = self;
        _inputArmed.store(true);
        return YES;
    }
    // WZ's install_hid_monitor_main tries IOHID first and BKSHID as fallback.
    // The supplied IOHID device log has 4160 callbacks, zero digitizer events
    // and 4160 AX factory-nil drops. Prefer that existing BK tier for a fresh
    // subscription; registration alone does not prove a physical touch parses.
    if (!_backBoardHandle) _backBoardHandle = dlopen(
        "/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices",
        RTLD_NOW | RTLD_GLOBAL);
    typedef void *(*RegisterBK)(void (*)(void *, void *, CoreSetIOHIDServiceRef, CoreSetIOHIDEventRef));
    RegisterBK registerBK = _backBoardHandle ? (RegisterBK)dlsym(
        _backBoardHandle, "BKSHIDEventRegisterEventCallback") : NULL;
    if (registerBK) {
        (void)registerBK(CoreSetHostedHIDCallback);
        gCoreSetBKCallbackInstalled = YES;
        _bkInputRegistered = YES;
        gCoreSetHostedInputOwner = self;
        _inputArmed.store(true);
        NSLog(@"Core-SET: hosted input monitor source-select preferred=BKSHID fallback=IOHID");
        return YES;
    }
    typedef CoreSetIOHIDEventSystemClientRef (*Create)(CFAllocatorRef);
    typedef void (*Register)(CoreSetIOHIDEventSystemClientRef,
        void (*)(void *, void *, CoreSetIOHIDServiceRef, CoreSetIOHIDEventRef), void *, void *);
    typedef void (*Schedule)(CoreSetIOHIDEventSystemClientRef, CFRunLoopRef, CFStringRef);
    Create create = _ioKitHandle ? (Create)dlsym(_ioKitHandle, "IOHIDEventSystemClientCreate") : NULL;
    Register reg = _ioKitHandle ? (Register)dlsym(_ioKitHandle,
        "IOHIDEventSystemClientRegisterEventCallback") : NULL;
    Schedule schedule = _ioKitHandle ? (Schedule)dlsym(_ioKitHandle,
        "IOHIDEventSystemClientScheduleWithRunLoop") : NULL;
    if (create && reg && schedule) {
        _touchClient = create(kCFAllocatorDefault);
        if (_touchClient) {
            gCoreSetHostedInputOwner = self;
            reg(_touchClient, CoreSetHostedHIDCallback, NULL, NULL);
            schedule(_touchClient, CFRunLoopGetMain(), kCFRunLoopCommonModes);
            _inputArmed.store(true);
            return YES;
        }
    }
    NSLog(@"Core-SET: hosted input monitor armed=0 reason=IOHID-and-BK-unavailable");
    return NO;
}
- (void)requestHostedReadback {
    if (!NSThread.isMainThread || !_running ||
        _hostedReadbackPending ||
        ![_adapter respondsToSelector:@selector(observeBothSurfacesAsync:)]) return;
    if (_hostedReadbackInFlight) { _hostedReadbackRetryNeeded = YES; return; }
    _hostedReadbackPending = YES;
    _hostedReadbackInFlight = YES;
    _hostedReadbackRetryNeeded = NO;
    const uint64_t epoch = ++_hostedReadbackEpoch;
    const uint64_t generation = self.generation;
    __weak CoreSetHUDHost *weakSelf = self;
    [_adapter observeBothSurfacesAsync:^(BOOL observed, uint64_t adapterGeneration) {
        CoreSetHUDHost *host = weakSelf;
        if (!host) return;
        host->_hostedReadbackInFlight = NO;
        if (epoch != host->_hostedReadbackEpoch) {
            CoreSetLogInputStage("readback", "stale-epoch", &host->_inputCounts.readbackDropped,
                host.generation, -1, nil, 0);
            if (host->_hostedReadbackRetryNeeded && host->_running && !host->_foreground) {
                host->_hostedReadbackRetryNeeded = NO;
                [host requestHostedReadback];
            }
            [host drainHostedReadbackIdleWaiters];
            return;
        }
        host->_hostedReadbackPending = NO;
        const BOOL current = observed && host->_running &&
            host.generation == generation &&
            adapterGeneration == generation && host.localSurfacesReady &&
            host->_menuRegistered && host->_drawRegistered;
        host->_hostedReadbackGeneration = current ? generation : 0;
        NSArray *waiters = [host->_hostedReadbackWaiters copy];
        [host->_hostedReadbackWaiters removeAllObjects];
        for (id waiter in waiters) ((void (^)(BOOL))waiter)(current);
        if (host->_running) {
            [host selectBackend];
            [host publishState];
        }
        if (!current && host->_inputArmed.load() && !host->_foreground)
            [host failClosedHostedInput];
        std::atomic_uint_fast64_t *counter = current
            ? &host->_inputCounts.readback : &host->_inputCounts.readbackDropped;
        const uint64_t readbackCount = counter->fetch_add(1) + 1;
        if (CoreSetInputLogDue(readbackCount))
            NSLog(@"Core-SET: hosted input stage=readback observed=%d generation=%llu source=async count=%llu",
                  current, (unsigned long long)generation, (unsigned long long)readbackCount);
        [host drainHostedReadbackIdleWaiters];
    }];
}
- (void)drainHostedReadbackIdleWaiters {
    if (_hostedReadbackInFlight) return;
    NSArray *waiters = [_hostedReadbackIdleWaiters copy];
    [_hostedReadbackIdleWaiters removeAllObjects];
    for (dispatch_block_t waiter in waiters) waiter();
}
- (void)whenHostedReadbackIdle:(dispatch_block_t)completion {
    if (!completion || !NSThread.isMainThread) return;
    if (!_hostedReadbackInFlight) { dispatch_async(dispatch_get_main_queue(), completion); return; }
    [_hostedReadbackIdleWaiters addObject:[completion copy]];
}
- (void)confirmHostedReadbackAsync:(void (^)(BOOL))completion {
    if (!completion) return;
    if (!NSThread.isMainThread || !_running) {
        completion(NO); return;
    }
    if (![_adapter respondsToSelector:@selector(observeBothSurfacesAsync:)]) {
        completion(NO); return;
    }
    [_hostedReadbackWaiters addObject:[completion copy]];
    [self requestHostedReadback];
}
- (void)disarmHostedInput {
    _inputArmed.store(false);
    [self invalidatePendingTouchActions];
    _bkInputRegistered = NO;
    NSArray *cancelledWaiters = [_hostedReadbackWaiters copy];
    [_hostedReadbackWaiters removeAllObjects];
    for (id waiter in cancelledWaiters) ((void (^)(BOOL))waiter)(NO);
    ++_hostedReadbackEpoch; _hostedReadbackPending = NO;
    _hostedReadbackRetryNeeded = NO;
    _hostedReadbackGeneration = 0;
    if (gCoreSetHostedInputOwner == self) gCoreSetHostedInputOwner = nil;
    [self resetHostedPointer];
    if (!_touchClient) return;
    typedef void (*Unschedule)(CoreSetIOHIDEventSystemClientRef, CFRunLoopRef, CFStringRef);
    Unschedule unschedule = _ioKitHandle ? (Unschedule)dlsym(_ioKitHandle,
        "IOHIDEventSystemClientUnscheduleWithRunLoop") : NULL;
    if (unschedule) {
        unschedule(_touchClient, CFRunLoopGetMain(), kCFRunLoopCommonModes);
        CFRelease(_touchClient);
        if (gCoreSetDormantHIDClient == _touchClient) gCoreSetDormantHIDClient = NULL;
    } else {
        gCoreSetDormantHIDClient = _touchClient;
    }
    // Without unschedule the process-scoped client stays scheduled but has no
    // owner until a later host explicitly arms it again.
    _touchClient = NULL;
}
- (BOOL)startLocalInScene:(UIWindowScene *)scene menuController:(UIViewController *)menuController {
    return [self startInScene:scene menuController:menuController error:nil];
}
- (BOOL)startHostedInScene:(UIWindowScene *)scene menuController:(UIViewController *)menuController
                completion:(void (^)(BOOL))completion {
    if (!_adapter || !completion) return NO;
    return [self startPreparedInScene:scene menuController:menuController
                               error:nil hostedCompletion:completion];
}
- (BOOL)applyLocalMenuVisible:(BOOL)visible colors:(NSArray<UIColor *> *)colors {
    if (!NSThread.isMainThread || !self.localSurfacesReady || !colors.count) return NO;
    [self setFloatingColors:colors];
    [self setPanelVisible:visible];
    return self.localSurfacesReady && self.panelVisible == visible &&
        self.floatingControlReady;
}
- (BOOL)startInScene:(UIWindowScene *)scene menuController:(UIViewController *)menuController error:(NSError **)error {
    return [self startPreparedInScene:scene menuController:menuController
                               error:error hostedCompletion:nil];
}
- (BOOL)startPreparedInScene:(UIWindowScene *)scene menuController:(UIViewController *)menuController
                       error:(NSError **)error hostedCompletion:(void (^)(BOOL))hostedCompletion {
    if (!NSThread.isMainThread) return [self fail:1 message:@"Main thread required" error:error];
    if ((_adapter != nil) != (hostedCompletion != nil))
        return [self fail:14 message:@"Hosted sources require asynchronous registration" error:error];
    if (self.cleanupPending) return [self fail:4 message:@"Prior hosting cleanup is still pending" error:error];
    if (_running) {
        if (hostedCompletion)
            return [self fail:9 message:@"Hosted registration already in progress" error:error];
        if (_drawWindow.windowScene == scene && _menuController == menuController) return self.localSurfacesReady;
        return [self fail:9 message:@"Stop the current scene before attaching another menu" error:error];
    }
    if (!scene || !menuController || menuController.parentViewController || menuController.presentingViewController)
        return [self fail:5 message:@"A scene and unowned menu controller are required" error:error];
    self.lastError = nil;
    [self invalidateFrames];
    _foreground = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    _drawWindow = [[CoreSetDrawWindow alloc] initWithWindowScene:scene];
    _menuWindow = [[CoreSetMenuWindow alloc] initWithWindowScene:scene];
    _menuWindow.backgroundPassThrough = NO;
    _menuWindow.userInteractionEnabled = YES;
    _drawWindow.windowLevel = kCoreSetHUDWindowLevel;
    _menuWindow.windowLevel = kCoreSetHUDWindowLevel + 1.0;
    _drawWindow.backgroundColor = _menuWindow.backgroundColor = UIColor.clearColor;
    UIViewController *drawRoot = [UIViewController new];
    drawRoot.view.backgroundColor = UIColor.clearColor;
    _drawWindow.rootViewController = drawRoot;
    _drawCanvas = drawRoot.view;
    [_layers attachToView:_drawCanvas]; [_metal attachToView:_drawCanvas];
    CoreSetLayoutController *menuRoot = [CoreSetLayoutController new];
    menuRoot.view.backgroundColor = UIColor.clearColor;
    _menuWindow.rootViewController = menuRoot;
    _panel = [UIView new]; _panel.backgroundColor = UIColor.clearColor;
    [menuRoot.view addSubview:_panel];
    _menuController = menuController;
    [menuRoot addChildViewController:menuController];
    [_panel addSubview:menuController.view];
    [menuController didMoveToParentViewController:menuRoot];
    _floating = [UIButton buttonWithType:UIButtonTypeCustom];
    _floating.bounds = CGRectMake(0, 0, 44, 44);
    _floating.layer.cornerRadius = 22;
    _floatingGradient = [CAGradientLayer layer];
    _floatingGradient.frame = _floating.bounds; _floatingGradient.cornerRadius = 22;
    [_floating.layer insertSublayer:_floatingGradient atIndex:0];
    [self setFloatingColors:@[UIColor.systemTealColor]];
    [_floating setTitle:@"菜单" forState:UIControlStateNormal];
    _floating.titleLabel.font = [UIFont systemFontOfSize:12];
    _floating.accessibilityLabel = @"打开菜单";
    [_floating addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [_floating addTarget:self action:@selector(localFloatingTouchDown)
        forControlEvents:UIControlEventTouchDown];
    [_floating addTarget:self action:@selector(localFloatingTouchEnded)
        forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside |
                          UIControlEventTouchCancel];
    [_floating addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragFloating:)]];
    [menuRoot.view addSubview:_floating];
    _menuWindow.panelRegion = _panel; _menuWindow.floatingRegion = _floating;
    __weak CoreSetHUDHost *weakSelf = self;
    if (self.contentOwnsLayout) {
        _menuWindow.contentHitRegions = ^NSArray<UIView *> * {
            CoreSetHUDHost *host = weakSelf;
            return host.contentHitRegions ? host.contentHitRegions() : @[];
        };
    }
    menuRoot.layoutCallback = ^{ [weakSelf layoutSurfaces]; };
    _panelVisible = NO; _panel.hidden = YES;
    if (_adapter && ![self installHostedOrientationObserver]) {
        [self stop];
        return [self fail:10 message:@"Hosted orientation observer unavailable" error:error];
    }
    [self layoutSurfaces];
    _drawWindow.hidden = NO; _menuWindow.hidden = NO;
    [_drawWindow layoutIfNeeded]; [_menuWindow layoutIfNeeded];
    [CATransaction flush];
    _running = YES;
    for (NSNotificationName name in @[UIApplicationDidBecomeActiveNotification, UIApplicationDidEnterBackgroundNotification]) {
        id token = [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(NSNotification *note) { [weakSelf setApplicationActive:[note.name isEqualToString:UIApplicationDidBecomeActiveNotification]]; }];
        [_observers addObject:token];
    }
    [self selectBackend]; [self publishState];
    if (_adapter) {
        _menuCleanupNeeded = YES; _drawCleanupNeeded = YES;
        const uint64_t generation = self.generation;
        CoreSetMenuWindow *menuWindow = _menuWindow;
        CoreSetDrawWindow *drawWindow = _drawWindow;
        [_adapter registerBothSurfacesAsync:menuWindow drawWindow:drawWindow
            completion:^(BOOL observed, uint64_t adapterGeneration) {
                CoreSetHUDHost *host = weakSelf;
                if (!host) return;
                const BOOL current = observed && host->_running &&
                    host.generation == generation && adapterGeneration == generation &&
                    host->_menuWindow == menuWindow && host->_drawWindow == drawWindow &&
                    host.localSurfacesReady &&
                    [host->_adapter respondsToSelector:@selector(hostGeneration)] &&
                    [host->_adapter hostGeneration] == generation;
                host->_menuRegistered = current; host->_drawRegistered = current;
                host->_hostedReadbackGeneration = current ? generation : 0;
                if (!current) [host fail:6 message:@"Asynchronous remote registration/readback failed" error:nil];
                [host selectBackend]; [host publishState];
                hostedCompletion(current);
            }];
    }
    return YES;
}
- (void)layoutSurfaces {
    if (!_menuWindow || !_drawWindow || _layoutApplying) return;
    _layoutApplying = YES;
    CGRect bounds = _menuWindow.windowScene.screen.fixedCoordinateSpace.bounds;
    bounds = CGRectMake(0, 0, CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    if (!CGRectEqualToRect(_drawWindow.frame, bounds)) _drawWindow.frame = bounds;
    UIView *root = _menuWindow.rootViewController.view;
    UIView *drawRoot = _drawWindow.rootViewController.view;
    if (!root || !drawRoot) { _layoutApplying = NO; return; }
    const BOOL quarterTurn = _adapter && UIInterfaceOrientationIsLandscape(_hostedOrientation);
    const CGRect logical = quarterTurn
        ? CGRectMake(0, 0, bounds.size.height, bounds.size.width) : bounds;
    const CGFloat angle = _adapter ? CoreSetHostedOrientationAngle(_hostedOrientation) : 0;
    const CGAffineTransform transform = CGAffineTransformMakeRotation(angle);
    const CGPoint center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    const BOOL directHosted = !_adapter ||
        ([_adapter respondsToSelector:@selector(usesDirectSourceInteraction)] &&
         [_adapter usesDirectSourceInteraction]);
    CGRect desired = bounds;
    if (directHosted && !_panelVisible && !_localUIKitPointerActive &&
        _touchPointerID < 0 && std::isfinite(_floatingCenter.x) &&
        std::isfinite(_floatingCenter.y)) {
        CGPoint relative = CGPointMake(_floatingCenter.x - CGRectGetMidX(logical),
                                        _floatingCenter.y - CGRectGetMidY(logical));
        CGPoint rotated = CGPointApplyAffineTransform(relative, transform);
        CGPoint fixed = CGPointMake(center.x + rotated.x, center.y + rotated.y);
        CGRect compact = CGRectIntersection(bounds, CGRectInset(
            CGRectMake(fixed.x - 22, fixed.y - 22, 44, 44), -4, -4));
        if (!CGRectIsNull(compact) && !CGRectIsEmpty(compact)) desired = compact;
    }
    if (!CGRectEqualToRect(_menuWindow.frame, desired)) _menuWindow.frame = desired;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (UIView *surface in @[root, drawRoot]) {
        const CGPoint surfaceCenter = surface == root
            ? CGPointMake(center.x - desired.origin.x, center.y - desired.origin.y) : center;
        if (CGRectEqualToRect(surface.bounds, logical) &&
            CGPointEqualToPoint(surface.center, surfaceCenter) &&
            CGAffineTransformEqualToTransform(surface.transform, transform)) continue;
        surface.transform = CGAffineTransformIdentity;
        surface.bounds = logical;
        surface.center = surfaceCenter;
        surface.transform = transform;
    }
    [CATransaction commit];
    CGRect safe = _adapter ? root.bounds
                           : UIEdgeInsetsInsetRect(root.bounds, root.safeAreaInsets);
    if (self.contentOwnsLayout) {
        _panel.transform = CGAffineTransformIdentity;
        _panel.frame = root.bounds;
    } else {
        CGFloat scale = MIN(1, MIN(MAX(1, safe.size.width - 16) / 838, MAX(1, safe.size.height - 16) / 535));
        _panel.bounds = CGRectMake(0, 0, 838, 535);
        _panel.center = CGPointMake(CGRectGetMidX(safe), CGRectGetMidY(safe));
        _panel.transform = CGAffineTransformMakeScale(scale, scale);
    }
    _menuController.view.frame = _panel.bounds;
    const BOOL floatingInitialized = std::isfinite(_floatingCenter.x) &&
        std::isfinite(_floatingCenter.y);
    if (!floatingInitialized)
        _floatingCenter = CGPointMake(CGRectGetMaxX(safe) - 30, CGRectGetMidY(safe));
    _floatingCenter.x = MIN(MAX(_floatingCenter.x, CGRectGetMinX(safe) + 22), MAX(CGRectGetMinX(safe) + 22, CGRectGetMaxX(safe) - 22));
    _floatingCenter.y = MIN(MAX(_floatingCenter.y, CGRectGetMinY(safe) + 22), MAX(CGRectGetMinY(safe) + 22, CGRectGetMaxY(safe) - 22));
    _floating.center = _floatingCenter;
    _layoutApplying = NO;
    if (directHosted && !floatingInitialized && !_panelVisible) [self layoutSurfaces];
}
- (void)togglePanel {
    if (!_running) return;
    NSLog(@"Core-SET: hosted input stage=dispatch source=UIKit control=host.floating panelBefore=%d",
          _panelVisible);
    [self togglePanelFromHostedPointer];
}
- (void)togglePanelFromHostedPointer {
    if (self.panelVisibilityRequested) self.panelVisibilityRequested(!_panelVisible);
    else [self setPanelVisible:!_panelVisible];
}
- (void)localFloatingTouchDown {
    _localUIKitPointerActive = YES;
    [self layoutSurfaces];
}
- (void)localFloatingTouchEnded {
    _localUIKitPointerActive = NO;
    [self layoutSurfaces];
}
- (void)setPanelVisible:(BOOL)visible {
    if (!NSThread.isMainThread || !_running) return;
    _panelVisible = visible; _panel.hidden = !visible;
    _floating.accessibilityLabel = visible ? @"收起菜单" : @"打开菜单";
    [self layoutSurfaces];
    [self publishState];
}
- (void)dragFloating:(UIPanGestureRecognizer *)gesture {
    if (!_running) return;
    if (gesture.state == UIGestureRecognizerStateBegan ||
        gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled)
        NSLog(@"Core-SET: hosted input stage=gesture source=UIKit control=host.floating phase=%ld",
              (long)gesture.state);
    if (gesture.state == UIGestureRecognizerStateBegan) _dragOrigin = _floatingCenter;
    if (gesture.state == UIGestureRecognizerStateChanged || gesture.state == UIGestureRecognizerStateEnded) {
        CGPoint delta = [gesture translationInView:_menuWindow.rootViewController.view];
        _floatingCenter = CGPointMake(_dragOrigin.x + delta.x, _dragOrigin.y + delta.y);
        [self layoutSurfaces];
    }
}
- (void)setFloatingColors:(NSArray<UIColor *> *)colors {
    if (!NSThread.isMainThread || !_floatingGradient) return;
    NSMutableArray *values = [NSMutableArray array];
    for (UIColor *color in colors) if ([color isKindOfClass:UIColor.class]) [values addObject:(id)color.CGColor];
    if (!values.count) return;
    if (values.count == 1) [values addObject:values.firstObject];
    _floatingGradient.colors = values;
    _floatingGradient.startPoint = CGPointMake(0, .5); _floatingGradient.endPoint = CGPointMake(1, .5);
}
- (void)selectBackend {
    const BOOL metalReady = _metal && [_metal respondsToSelector:@selector(renderSurfaceReady)] &&
        [_metal renderSurfaceReady];
    _activeBackend = CoreSetHUDSelectBackend(_foreground, metalReady,
                                             self.hostedRegistrationReceipt);
    [_layers setVisible:_activeBackend == CoreSetHUDBackendCoreAnimation];
    [_metal setVisible:_activeBackend == CoreSetHUDBackendMetal];
}
- (void)setApplicationActive:(BOOL)active {
    if (!NSThread.isMainThread || !_running || _foreground == active) return;
    const uint64_t previousGeneration = self.generation;
    // WZ retains the passive HID subscription across foreground/background.
    // invalidateFrames below cancels queued pointers; foreground routing is
    // gated by _foreground in drainPendingTouchActionsOnQueue/handleHostedPointer.
    _foreground = active;
    _menuWindow.backgroundPassThrough = NO;
    _menuWindow.userInteractionEnabled = YES;
    [self invalidateFrames]; [self selectBackend]; [self layoutSurfaces]; [self publishState];
    if (!active && _inputArmed.load()) [self requestHostedReadback];
    NSLog(@"Core-SET: host active-transition active=%d previousGeneration=%llu state={%@}",
          active, (unsigned long long)previousGeneration, [self hostingDiagnosticSnapshot]);
}
- (void)submitFrame:(CoreSetRenderFrame *)frame {
    if (!frame) return;
    __weak CoreSetHUDHost *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        CoreSetHUDHost *host = weakSelf;
        if (!host || !CoreSetHUDFrameIsCurrent(host->_running, host.renderGeneration, frame.generation, host->_lastSequence, frame.sequence)) return;
        if (!CGSizeEqualToSize(frame.canvasSize, host.logicalCanvasSize)) {
            if (host.frameDidConsume) host.frameDidConsume(frame, NO,
                [NSError errorWithDomain:@"CoreSetHUDHost" code:11
                            userInfo:@{NSLocalizedDescriptionKey:@"Frame canvas changed"}]);
            return;
        }
        host->_lastSequence = frame.sequence;
        id<CoreSetFrameConsumer> consumer = host->_activeBackend == CoreSetHUDBackendMetal ? host->_metal : host->_layers;
        NSError *error = nil;
        if (![consumer consumeFrame:frame error:&error]) {
            [consumer clear]; host.lastError = error ?: [NSError errorWithDomain:@"CoreSetHUDHost" code:7 userInfo:@{NSLocalizedDescriptionKey:@"Frame rejected"}];
            if (host.frameDidConsume) host.frameDidConsume(frame, NO, host.lastError);
            [host publishState];
        } else {
            const BOOL firstFrame = host->_lastConsumedSequence == 0;
            host->_lastConsumedSequence = frame.sequence;
            if (host.frameDidConsume) host.frameDidConsume(frame, YES, nil);
            if (firstFrame) [host publishState];
        }
    });
}
- (CoreSetHUDStopResult)stop {
    if (!NSThread.isMainThread) {
        CoreSetHUDStopResult rejected = {NO, NO, NO, NO};
        return rejected;
    }
    if (_hostedAsyncStopPending) {
        CoreSetHUDStopResult pending = {NO, !_menuCleanupNeeded, !_drawCleanupNeeded, NO};
        return pending;
    }
    if (_adapter && (_menuCleanupNeeded || _drawCleanupNeeded)) {
        if (_hostedCleanupFailed) {
            CoreSetHUDStopResult pending = {YES, !_menuCleanupNeeded, !_drawCleanupNeeded, NO};
            return pending;
        }
        // Termination/disconnect cannot wait for a RemoteCall. Disarm and hide
        // immediately, enqueue best-effort cleanup, retain handles on failure.
        [self stopHostedAsync:^(__unused CoreSetHUDStopResult result) {}];
        CoreSetHUDStopResult pending = {YES, NO, NO, NO};
        return pending;
    }
    [self disarmHostedInput];
    [self stopHostedOrientationObserver];
    (void)[self restoreRenderFPS];
    _running = NO; _panelVisible = NO;
    [self invalidateFrames];
    for (id token in _observers) [NSNotificationCenter.defaultCenter removeObserver:token];
    [_observers removeAllObjects];
    _drawWindow.hidden = YES; _menuWindow.hidden = YES;
    [CATransaction flush];
    _drawRegistered = NO; _menuRegistered = NO;
    [_layers detach];
    if (!_schedulerCleanupNeeded) [_metal detach];
    [_menuController willMoveToParentViewController:nil];
    [_menuController.view removeFromSuperview]; [_menuController removeFromParentViewController];
    _drawWindow.rootViewController = nil; _menuWindow.rootViewController = nil;
    _drawCanvas = nil; _menuController = nil; _panel = nil; _floating = nil; _floatingGradient = nil;
    // Retain failed cleanup handles; retry stop before allowing another start.
    if (!_drawCleanupNeeded) _drawWindow = nil;
    if (!_menuCleanupNeeded) _menuWindow = nil;
    if (self.cleanupPending) [self fail:8 message:@"Hosting cleanup has not been confirmed; retry stop" error:nil];
    CoreSetHUDStopResult result = {YES, !_menuCleanupNeeded, !_drawCleanupNeeded, !self.cleanupPending};
    [self publishState];
    return result;
}
- (void)stopHostedAsync:(void (^)(CoreSetHUDStopResult))completion {
    if (!completion || !NSThread.isMainThread) return;
    if (!_running && !_menuCleanupNeeded && !_drawCleanupNeeded && !_hostedAsyncStopPending) {
        completion([self stop]); return;
    }
    if (!_adapter || ![_adapter respondsToSelector:@selector(unregisterBothSurfacesAsync:drawWindow:completion:)]) {
        completion([self stop]); return;
    }
    if (_hostedAsyncStopPending) {
        [_hostedAsyncStopWaiters addObject:[completion copy]];
        return;
    }
    [_hostedAsyncStopWaiters addObject:[completion copy]];
    _hostedAsyncStopPending = YES;
    _hostedCleanupFailed = NO;
    [self disarmHostedInput];
    [self stopHostedOrientationObserver];
    _running = NO; _panelVisible = NO;
    [self resetHostedPointer];
    [_layers clear]; [_metal clear];
    _menuWindow.backgroundPassThrough = YES;
    _menuWindow.userInteractionEnabled = NO;
    _menuWindow.hidden = YES; _drawWindow.hidden = YES;
    [CATransaction flush];
    __weak CoreSetHUDHost *weakSelf = self;
    [_adapter unregisterBothSurfacesAsync:_menuWindow drawWindow:_drawWindow
        completion:^(BOOL menuRemoved, BOOL drawRemoved) {
            CoreSetHUDHost *host = weakSelf;
            if (!host) return;
            host->_menuCleanupNeeded = !menuRemoved;
            host->_drawCleanupNeeded = !drawRemoved;
            host->_menuRegistered = NO; host->_drawRegistered = NO;
            host->_hostedAsyncStopPending = NO;
            if (!menuRemoved || !drawRemoved) {
                host->_hostedCleanupFailed = YES;
                [host fail:13 message:@"Asynchronous remote cleanup unconfirmed; handles retained" error:nil];
                CoreSetHUDStopResult incomplete = {YES, menuRemoved, drawRemoved, NO};
                [host publishState];
                NSArray *waiters = [host->_hostedAsyncStopWaiters copy];
                [host->_hostedAsyncStopWaiters removeAllObjects];
                for (id waiter in waiters) ((void (^)(CoreSetHUDStopResult))waiter)(incomplete);
                return;
            }
            // Remote handles are gone. The existing local stop now performs
            // only UIKit detach; it cannot make a RemoteCall on this path.
            const CoreSetHUDStopResult result = [host stop];
            NSArray *waiters = [host->_hostedAsyncStopWaiters copy];
            [host->_hostedAsyncStopWaiters removeAllObjects];
            for (id waiter in waiters) ((void (^)(CoreSetHUDStopResult))waiter)(result);
        }];
}
@end
