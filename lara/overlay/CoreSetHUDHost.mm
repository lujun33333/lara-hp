#import "CoreSetHUDHost.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <atomic>
#include <cmath>

typedef struct __IOHIDEvent *CoreSetIOHIDEventRef;
typedef struct __IOHIDService *CoreSetIOHIDServiceRef;
typedef struct __IOHIDEventSystemClient *CoreSetIOHIDEventSystemClientRef;

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
- (BOOL)_ignoresHitTest { return NO; }
- (BOOL)_shouldCreateContextAsSecure { return NO; }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
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
@property(nonatomic, strong, readwrite) NSError *lastError;
- (void)receiveHostedHIDEvent:(CoreSetIOHIDEventRef)event;
- (void)resetHostedPointer;
- (void)disarmHostedInput;
- (void)requestHostedReadback;
@end

// The monitor does not retain a host. A queued callback after stop sees nil.
static __weak CoreSetHUDHost *gCoreSetHostedInputOwner;
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
    std::atomic_bool _inputArmed;
    std::atomic_uint_fast64_t _hidCallbacks;
    std::atomic_uint_fast64_t _axParsed;
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
    CFAbsoluteTime _hostedReadbackAt;
    dispatch_source_t _hostedReadbackTimer;
    BOOL _hostedReadbackPending;
    uint64_t _hostedReadbackEpoch;
    NSMutableArray *_hostedReadbackWaiters;
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
        _hostedReadbackWaiters = [NSMutableArray array];
    }
    return self;
}
- (BOOL)localSurfacesReady {
    return _running && _drawWindow && _menuWindow && _drawCanvas && _panel &&
        _menuWindow.windowScene.activationState != UISceneActivationStateUnattached;
}
- (BOOL)crossApplicationHosted {
    const BOOL observed = self.localSurfacesReady && CoreSetHUDHostingReady(_menuRegistered, _drawRegistered) &&
        _adapter && [_adapter respondsToSelector:@selector(bothSurfacesObserved)] &&
        [_adapter respondsToSelector:@selector(hostGeneration)] &&
        [_adapter hostGeneration] == self.generation &&
        [_adapter bothSurfacesObserved];
    _hostedReadbackGeneration = observed ? self.generation : 0;
    _hostedReadbackAt = observed ? CFAbsoluteTimeGetCurrent() : 0;
    return observed;
}
- (BOOL)hasFreshHostedReadback {
    const CFAbsoluteTime age = CFAbsoluteTimeGetCurrent() - _hostedReadbackAt;
    return self.localSurfacesReady && _menuRegistered && _drawRegistered &&
        _adapter && [_adapter respondsToSelector:@selector(hostGeneration)] &&
        [_adapter hostGeneration] == self.generation &&
        _hostedReadbackGeneration == self.generation &&
        age >= 0 && age <= 3.5;
}
- (BOOL)recentCrossApplicationHosted { return [self hasFreshHostedReadback]; }
- (CGSize)logicalCanvasSize { return _drawCanvas ? _drawCanvas.bounds.size : CGSizeZero; }
- (BOOL)hostedInputMonitorArmed { return _inputArmed.load() && _touchClient != NULL; }
- (NSString *)hostingDiagnosticSnapshot {
    const NSInteger sceneState = _menuWindow.windowScene
        ? _menuWindow.windowScene.activationState : -1;
    const BOOL adapterGenerationAvailable = _adapter &&
        [_adapter respondsToSelector:@selector(hostGeneration)];
    const uint64_t adapterGeneration = adapterGenerationAvailable ? [_adapter hostGeneration] : 0;
    const CGSize logicalSize = self.logicalCanvasSize;
    return [NSString stringWithFormat:
        @"running=%d foreground=%d sceneState=%ld localReady=%d menuRegistered=%d drawRegistered=%d adapter=%d adapterGenerationAvailable=%d hostGeneration=%llu adapterGeneration=%llu panel=%d menuWindowHidden=%d drawWindowHidden=%d floatingHidden=%d floatingAttached=%d orientation=%ld canvas=%.0fx%.0f inputMonitor=%d",
        _running, _foreground, (long)sceneState, self.localSurfacesReady,
        _menuRegistered, _drawRegistered, _adapter != nil, adapterGenerationAvailable,
        (unsigned long long)self.generation, (unsigned long long)adapterGeneration, _panelVisible,
        _menuWindow.hidden, _drawWindow.hidden, _floating.hidden,
        _floating.superview != nil, (long)_hostedOrientation,
        logicalSize.width, logicalSize.height,
        self.hostedInputMonitorArmed];
}
- (BOOL)cleanupPending { return !_running && (_menuCleanupNeeded || _drawCleanupNeeded || _schedulerCleanupNeeded); }
- (BOOL)panelVisible { return _panelVisible; }
- (uint64_t)lastConsumedSequence { return _lastConsumedSequence; }
- (NSArray<UIColor *> *)observedFloatingColors {
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
    NSArray *cancelledWaiters = [_hostedReadbackWaiters copy];
    [_hostedReadbackWaiters removeAllObjects];
    for (id waiter in cancelledWaiters) ((void (^)(BOOL))waiter)(NO);
    _hostedReadbackAt = 0; _hostedReadbackGeneration = 0;
    ++_hostedReadbackEpoch; _hostedReadbackPending = NO;
    self.generation = CoreSetHUDNextGeneration(self.generation);
    if ([_adapter respondsToSelector:@selector(prepareForHostGeneration:)])
        [_adapter prepareForHostGeneration:self.generation];
    if (_running && !_foreground) [self requestHostedReadback];
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
    if (_running) [self invalidateFrames];
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
        [(id<CoreSetHostedMenuTapConsumer>)_menuController
            handleHostedControlID:_touchControlID phase:CoreSetHostedPointerPhaseCancelled
            atPoint:CGPointZero];
    }
    _touchPointerID = -1; _touchControlID = nil; _touchGeneration = 0;
    _touchMenuRevision = 0; _touchContinuous = NO;
    _touchDownPoint = CGPointZero; _touchDownTime = 0;
    _touchFloatingDownLogical = CGPointZero; _touchFloatingOrigin = CGPointZero;
    _touchFloatingDragged = NO;
}
- (NSString *)hostedControlIDAtSurfacePoint:(CGPoint)point {
    if (!_menuWindow || !_floating || !_menuController ||
        !std::isfinite(point.x) || !std::isfinite(point.y)) return nil;
    CGRect surface = _menuWindow.windowScene.screen.fixedCoordinateSpace.bounds;
    if (!CGRectContainsPoint(surface, point)) return nil;
    CGPoint floatPoint = [_floating convertPoint:point fromView:_menuWindow];
    if (!_floating.hidden && _floating.alpha > 0.01 && _floating.userInteractionEnabled &&
        [_floating pointInside:floatPoint withEvent:nil]) return @"host.floating";
    if (!_panelVisible || _panel.hidden ||
        ![_menuController conformsToProtocol:@protocol(CoreSetHostedMenuTapConsumer)]) return nil;
    if (_menuController.presentedViewController ||
        _menuWindow.rootViewController.presentedViewController) return nil;
    CGPoint menuPoint = [_menuController.view convertPoint:point fromView:_menuWindow];
    id<CoreSetHostedMenuTapConsumer> consumer = (id)_menuController;
    return [consumer hostedControlIDAtPoint:menuPoint];
}
- (void)handleHostedPointer:(NSInteger)phase pointerID:(int64_t)pointerID
                     point:(CGPoint)point generation:(uint64_t)generation
                  timestamp:(CFAbsoluteTime)timestamp {
    if (!NSThread.isMainThread || !_inputArmed.load() || !_running || _foreground ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateBackground) {
        [self resetHostedPointer]; return;
    }
    if (CFAbsoluteTimeGetCurrent() - timestamp > 0.75) {
        [self resetHostedPointer]; return;
    }
    if (phase == CoreSetHostedPointerPhaseCancelled) { [self resetHostedPointer]; return; }
    id<CoreSetHostedMenuTapConsumer> consumer =
        [_menuController conformsToProtocol:@protocol(CoreSetHostedMenuTapConsumer)]
            ? (id)_menuController : nil;
    if (phase == CoreSetHostedPointerPhaseBegan) {
        if (![self hasFreshHostedReadback]) {
            [self requestHostedReadback];
            NSLog(@"Core-SET: hosted input stage=hit rejected=stale-readback");
            return;
        }
        if (_touchPointerID >= 0 || generation != self.generation ||
            !self.localSurfacesReady || !_menuRegistered || !_drawRegistered ||
            ![_adapter respondsToSelector:@selector(hostGeneration)] ||
            [_adapter hostGeneration] != self.generation) return;
        NSString *identifier = [self hostedControlIDAtSurfacePoint:point];
        if (!identifier) return;
        _touchPointerID = pointerID; _touchControlID = [identifier copy];
        _touchGeneration = generation; _touchDownPoint = point;
        _touchDownTime = timestamp;
        if ([identifier isEqualToString:@"host.floating"]) {
            _touchContinuous = YES;
            _touchFloatingDownLogical = [_menuWindow.rootViewController.view
                convertPoint:point fromView:_menuWindow];
            _touchFloatingOrigin = _floatingCenter;
        }
        if (![identifier isEqualToString:@"host.floating"] && consumer) {
            _touchMenuRevision = consumer.hostedMenuRevision;
            _touchContinuous = [consumer hostedControlAllowsDrag:identifier];
            CGPoint menuPoint = [_menuController.view convertPoint:point fromView:_menuWindow];
            (void)[consumer handleHostedControlID:identifier
                phase:CoreSetHostedPointerPhaseBegan atPoint:menuPoint];
        }
        NSLog(@"Core-SET: hosted input stage=hit control=%@ generation=%llu",
              identifier, (unsigned long long)generation);
        return;
    }
    if (_touchPointerID != pointerID || _touchGeneration != self.generation ||
        (_touchMenuRevision && (!consumer ||
            consumer.hostedMenuRevision != _touchMenuRevision)) ||
        (!_touchContinuous && (timestamp - _touchDownTime > 0.75 ||
            hypot(point.x - _touchDownPoint.x, point.y - _touchDownPoint.y) > 9.0))) {
        [self resetHostedPointer]; return;
    }
    if (phase == CoreSetHostedPointerPhaseMoved) {
        if ([_touchControlID isEqualToString:@"host.floating"]) {
            CGPoint logical = [_menuWindow.rootViewController.view convertPoint:point fromView:_menuWindow];
            CGFloat dx = logical.x - _touchFloatingDownLogical.x;
            CGFloat dy = logical.y - _touchFloatingDownLogical.y;
            if (hypot(dx, dy) > 9) _touchFloatingDragged = YES;
            if (_touchFloatingDragged) {
                _floatingCenter = CGPointMake(_touchFloatingOrigin.x + dx, _touchFloatingOrigin.y + dy);
                [self layoutSurfaces];
            }
        } else if (_touchContinuous && consumer) {
            CGPoint menuPoint = [_menuController.view convertPoint:point fromView:_menuWindow];
            (void)[consumer handleHostedControlID:_touchControlID
                phase:CoreSetHostedPointerPhaseMoved atPoint:menuPoint];
        }
        return;
    }
    if (phase != CoreSetHostedPointerPhaseEnded) { [self resetHostedPointer]; return; }
    NSString *identifier = _touchControlID;
    const BOOL continuous = _touchContinuous;
    const BOOL floatingDragged = _touchFloatingDragged;
    if ((!continuous && ![identifier isEqualToString:[self hostedControlIDAtSurfacePoint:point]]) ||
        ![self hasFreshHostedReadback]) { [self resetHostedPointer]; return; }
    _touchControlID = nil; // A confirmed End must not run the cancel handler.
    [self resetHostedPointer];
    BOOL dispatched = NO;
    if ([identifier isEqualToString:@"host.floating"]) {
        if (!floatingDragged) [self togglePanel];
        dispatched = YES;
        NSLog(@"Core-SET: hosted input stage=actual capability=floatingDrag confirmed=%d",
              floatingDragged ? 1 : 0);
    } else if (consumer) {
        CGPoint menuPoint = [_menuController.view convertPoint:point fromView:_menuWindow];
        dispatched = [consumer handleHostedControlID:identifier
            phase:CoreSetHostedPointerPhaseEnded atPoint:menuPoint];
    }
    // Dispatch is not an apply receipt; existing menu/channel callbacks own it.
    NSLog(@"Core-SET: hosted input stage=dispatch control=%@ dispatched=%d generation=%llu",
          identifier, dispatched, (unsigned long long)generation);
}
- (void)receiveHostedHIDEvent:(CoreSetIOHIDEventRef)event {
    if (!_inputArmed.load() || !event) return;
    const uint64_t callbacks = _hidCallbacks.fetch_add(1) + 1;
    if (callbacks == 1 || callbacks % 64 == 0)
        NSLog(@"Core-SET: hosted input stage=callback count=%llu",
              (unsigned long long)callbacks);
    @autoreleasepool { @try {
        Class eventClass = NSClassFromString(@"AXEventRepresentation");
        if (!eventClass) return;
        CoreSetAXEvent *representation = ((id (*)(id, SEL, CoreSetIOHIDEventRef, NSString *))objc_msgSend)(
            eventClass, @selector(representationWithHIDEvent:hidStreamIdentifier:),
            event, @"UIApplicationEvents");
        if (!representation) return;
        NSArray<CoreSetAXEventPath *> *paths = representation.handInfo.paths;
        const uint64_t parsed = _axParsed.fetch_add(1) + 1;
        if (parsed == 1 || parsed % 64 == 0)
            NSLog(@"Core-SET: hosted input stage=ax-parse count=%llu single=%d",
                  (unsigned long long)parsed, paths.count == 1);
        if (paths.count != 1) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self resetHostedPointer]; });
            return;
        }
        const int64_t pointerID = (int64_t)paths.firstObject.pathIdentity;
        if (pointerID == 9) return; // Exclude WZ-style synthetic sender echo.
        NSInteger phase = -1;
        if (representation.isCancel) phase = 3;
        else if (representation.isLift || representation.isInRangeLift) phase = 2;
        else if (representation.isTouchDown) phase = 0;
        else if (representation.isMove || representation.isChordChange) phase = 1;
        if (phase < 0) return;
        const CGPoint point = representation.location;
        const uint64_t generation = self.generation;
        const CFAbsoluteTime timestamp = CFAbsoluteTimeGetCurrent();
        __weak CoreSetHUDHost *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            CoreSetHUDHost *host = weakSelf;
            [host handleHostedPointer:phase pointerID:pointerID point:point
                          generation:generation timestamp:timestamp];
        });
    } @catch (__unused NSException *exception) {} }
}
- (BOOL)armHostedInput {
    if (!NSThread.isMainThread || !_running || !_orientationObserver) {
        NSLog(@"Core-SET: hosted input monitor armed=0 reason=host-orientation"); return NO;
    }
    if (!self.crossApplicationHosted) {
        NSLog(@"Core-SET: hosted input monitor armed=0 reason=hosting-readback"); return NO;
    }
    if (self.hostedInputMonitorArmed) return YES;
    if (gCoreSetHostedInputOwner && gCoreSetHostedInputOwner != self) {
        NSLog(@"Core-SET: hosted input monitor armed=0 reason=another-owner"); return NO;
    }
    if (!_accessibilityHandle) _accessibilityHandle = dlopen(
        "/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities",
        RTLD_LAZY | RTLD_LOCAL);
    Class eventClass = NSClassFromString(@"AXEventRepresentation");
    if (!eventClass || ![eventClass respondsToSelector:
        @selector(representationWithHIDEvent:hidStreamIdentifier:)]) {
        NSLog(@"Core-SET: hosted input monitor armed=0 reason=AX-event-class"); return NO;
    }
    if (!_ioKitHandle) _ioKitHandle = dlopen(
        "/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL);
    typedef CoreSetIOHIDEventSystemClientRef (*Create)(CFAllocatorRef);
    typedef void (*Register)(CoreSetIOHIDEventSystemClientRef,
        void (*)(void *, void *, CoreSetIOHIDServiceRef, CoreSetIOHIDEventRef), void *, void *);
    typedef void (*Schedule)(CoreSetIOHIDEventSystemClientRef, CFRunLoopRef, CFStringRef);
    Create create = _ioKitHandle ? (Create)dlsym(_ioKitHandle, "IOHIDEventSystemClientCreate") : NULL;
    Register reg = _ioKitHandle ? (Register)dlsym(_ioKitHandle,
        "IOHIDEventSystemClientRegisterEventCallback") : NULL;
    Schedule schedule = _ioKitHandle ? (Schedule)dlsym(_ioKitHandle,
        "IOHIDEventSystemClientScheduleWithRunLoop") : NULL;
    // Require a cleanup route before registering any process-wide callback.
    if (!create || !reg || !schedule ||
        !dlsym(_ioKitHandle, "IOHIDEventSystemClientUnscheduleWithRunLoop")) {
        NSLog(@"Core-SET: hosted input monitor armed=0 reason=IOHID-symbols"); return NO;
    }
    _touchClient = create(kCFAllocatorDefault);
    if (!_touchClient) {
        NSLog(@"Core-SET: hosted input monitor armed=0 reason=IOHID-create"); return NO;
    }
    [self resetHostedPointer];
    gCoreSetHostedInputOwner = self;
    _inputArmed.store(true);
    reg(_touchClient, CoreSetHostedHIDCallback, NULL, NULL);
    schedule(_touchClient, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    _hostedReadbackTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                   dispatch_get_main_queue());
    if (_hostedReadbackTimer) {
        __weak CoreSetHUDHost *weakSelf = self;
        dispatch_source_set_timer(_hostedReadbackTimer,
            dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
            2 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
        dispatch_source_set_event_handler(_hostedReadbackTimer, ^{
            [weakSelf requestHostedReadback];
        });
        dispatch_resume(_hostedReadbackTimer);
    }
    NSLog(@"Core-SET: hosted input monitor armed=1 passive=1");
    return YES;
}
- (void)requestHostedReadback {
    if (!NSThread.isMainThread || !_inputArmed.load() || !_running || _foreground ||
        _hostedReadbackPending ||
        ![_adapter respondsToSelector:@selector(observeBothSurfacesAsync:)]) return;
    _hostedReadbackPending = YES;
    const uint64_t epoch = ++_hostedReadbackEpoch;
    const uint64_t generation = self.generation;
    __weak CoreSetHUDHost *weakSelf = self;
    [_adapter observeBothSurfacesAsync:^(BOOL observed, uint64_t adapterGeneration) {
        CoreSetHUDHost *host = weakSelf;
        if (!host || epoch != host->_hostedReadbackEpoch) return;
        host->_hostedReadbackPending = NO;
        const BOOL current = observed && host->_inputArmed.load() && host->_running &&
            !host->_foreground && host.generation == generation &&
            adapterGeneration == generation && host.localSurfacesReady &&
            host->_menuRegistered && host->_drawRegistered;
        host->_hostedReadbackGeneration = current ? generation : 0;
        host->_hostedReadbackAt = current ? CFAbsoluteTimeGetCurrent() : 0;
        NSArray *waiters = [host->_hostedReadbackWaiters copy];
        [host->_hostedReadbackWaiters removeAllObjects];
        for (id waiter in waiters) ((void (^)(BOOL))waiter)(current);
        if (host->_running && !host->_foreground) {
            [host selectBackend];
            [host publishState];
        }
        NSLog(@"Core-SET: hosted input stage=readback observed=%d generation=%llu source=async",
              current, (unsigned long long)generation);
    }];
}
- (void)confirmHostedReadbackAsync:(void (^)(BOOL))completion {
    if (!completion) return;
    if (!NSThread.isMainThread || !_running || _foreground || !_inputArmed.load()) {
        completion(NO); return;
    }
    if ([self hasFreshHostedReadback]) { completion(YES); return; }
    if (![_adapter respondsToSelector:@selector(observeBothSurfacesAsync:)]) {
        completion(NO); return;
    }
    [_hostedReadbackWaiters addObject:[completion copy]];
    [self requestHostedReadback];
}
- (void)disarmHostedInput {
    _inputArmed.store(false);
    NSArray *cancelledWaiters = [_hostedReadbackWaiters copy];
    [_hostedReadbackWaiters removeAllObjects];
    for (id waiter in cancelledWaiters) ((void (^)(BOOL))waiter)(NO);
    ++_hostedReadbackEpoch; _hostedReadbackPending = NO;
    _hostedReadbackAt = 0; _hostedReadbackGeneration = 0;
    if (_hostedReadbackTimer) {
        dispatch_source_cancel(_hostedReadbackTimer); _hostedReadbackTimer = nil;
    }
    if (gCoreSetHostedInputOwner == self) gCoreSetHostedInputOwner = nil;
    [self resetHostedPointer];
    if (!_touchClient) return;
    typedef void (*Unschedule)(CoreSetIOHIDEventSystemClientRef, CFRunLoopRef, CFStringRef);
    Unschedule unschedule = _ioKitHandle ? (Unschedule)dlsym(_ioKitHandle,
        "IOHIDEventSystemClientUnscheduleWithRunLoop") : NULL;
    if (unschedule) {
        unschedule(_touchClient, CFRunLoopGetMain(), kCFRunLoopCommonModes);
        CFRelease(_touchClient);
    }
    // If the OS loses its unschedule symbol, leave a dormant client scheduled;
    // the weak global owner and _inputArmed prevent dispatch into a dead host.
    _touchClient = NULL;
}
- (BOOL)startLocalInScene:(UIWindowScene *)scene menuController:(UIViewController *)menuController {
    return [self startInScene:scene menuController:menuController error:nil];
}
- (BOOL)applyLocalMenuVisible:(BOOL)visible colors:(NSArray<UIColor *> *)colors {
    if (!NSThread.isMainThread || !self.localSurfacesReady || !colors.count) return NO;
    [self setFloatingColors:colors];
    [self setPanelVisible:visible];
    return self.localSurfacesReady && self.panelVisible == visible;
}
- (BOOL)startInScene:(UIWindowScene *)scene menuController:(UIViewController *)menuController error:(NSError **)error {
    if (!NSThread.isMainThread) return [self fail:1 message:@"Main thread required" error:error];
    if (self.cleanupPending) return [self fail:4 message:@"Prior hosting cleanup is still pending" error:error];
    if (_running) {
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
    if (_adapter) {
        NSError *hostingError = nil;
        _menuCleanupNeeded = YES;
        _menuRegistered = [_adapter registerWindow:_menuWindow surface:CoreSetHUDSurfaceMenu error:&hostingError];
        if (_menuRegistered) {
            _drawCleanupNeeded = YES;
            _drawRegistered = [_adapter registerWindow:_drawWindow surface:CoreSetHUDSurfaceDraw error:&hostingError];
        }
        if (!CoreSetHUDHostingReady(_menuRegistered, _drawRegistered)) {
            [self stop];
            return [self fail:6 message:hostingError.localizedDescription ?: @"Hosting registration failed" error:error];
        }
    }
    _running = YES;
    for (NSNotificationName name in @[UIApplicationDidBecomeActiveNotification, UIApplicationDidEnterBackgroundNotification]) {
        id token = [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(NSNotification *note) { [weakSelf setApplicationActive:[note.name isEqualToString:UIApplicationDidBecomeActiveNotification]]; }];
        [_observers addObject:token];
    }
    id disconnect = [NSNotificationCenter.defaultCenter addObserverForName:UISceneDidDisconnectNotification
        object:scene queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            [weakSelf stop];
        }];
    [_observers addObject:disconnect];
    [self selectBackend]; [self publishState];
    return YES;
}
- (void)layoutSurfaces {
    if (!_menuWindow || !_drawWindow || _layoutApplying) return;
    _layoutApplying = YES;
    CGRect bounds = _adapter ? _menuWindow.windowScene.screen.fixedCoordinateSpace.bounds
                             : _menuWindow.windowScene.coordinateSpace.bounds;
    bounds = CGRectMake(0, 0, CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    if (!CGRectEqualToRect(_menuWindow.frame, bounds)) _menuWindow.frame = bounds;
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
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (UIView *surface in @[root, drawRoot]) {
        if (CGRectEqualToRect(surface.bounds, logical) &&
            CGPointEqualToPoint(surface.center, center) &&
            CGAffineTransformEqualToTransform(surface.transform, transform)) continue;
        surface.transform = CGAffineTransformIdentity;
        surface.bounds = logical;
        surface.center = center;
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
    if (!std::isfinite(_floatingCenter.x) || !std::isfinite(_floatingCenter.y))
        _floatingCenter = CGPointMake(CGRectGetMaxX(safe) - 30, CGRectGetMidY(safe));
    _floatingCenter.x = MIN(MAX(_floatingCenter.x, CGRectGetMinX(safe) + 22), MAX(CGRectGetMinX(safe) + 22, CGRectGetMaxX(safe) - 22));
    _floatingCenter.y = MIN(MAX(_floatingCenter.y, CGRectGetMinY(safe) + 22), MAX(CGRectGetMinY(safe) + 22, CGRectGetMaxY(safe) - 22));
    _floating.center = _floatingCenter;
    _layoutApplying = NO;
}
- (void)togglePanel {
    if (self.panelVisibilityRequested) self.panelVisibilityRequested(!_panelVisible);
    else [self setPanelVisible:!_panelVisible];
}
- (void)setPanelVisible:(BOOL)visible {
    if (!NSThread.isMainThread || !_running) return;
    _panelVisible = visible; _panel.hidden = !visible;
    _floating.accessibilityLabel = visible ? @"收起菜单" : @"打开菜单";
    [self publishState];
}
- (void)dragFloating:(UIPanGestureRecognizer *)gesture {
    if (!_running) return;
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
                                             self.recentCrossApplicationHosted);
    [_layers setVisible:_activeBackend == CoreSetHUDBackendCoreAnimation];
    [_metal setVisible:_activeBackend == CoreSetHUDBackendMetal];
}
- (void)setApplicationActive:(BOOL)active {
    if (!NSThread.isMainThread || !_running || _foreground == active) return;
    const uint64_t previousGeneration = self.generation;
    if (active) [self disarmHostedInput];
    _foreground = active;
    [self invalidateFrames]; [self selectBackend]; [self layoutSurfaces]; [self publishState];
    if (!active) [self requestHostedReadback];
    NSLog(@"Core-SET: host active-transition active=%d previousGeneration=%llu state={%@}",
          active, (unsigned long long)previousGeneration, [self hostingDiagnosticSnapshot]);
}
- (void)submitFrame:(CoreSetRenderFrame *)frame {
    if (!frame) return;
    __weak CoreSetHUDHost *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        CoreSetHUDHost *host = weakSelf;
        if (!host || !CoreSetHUDFrameIsCurrent(host->_running, host.generation, frame.generation, host->_lastSequence, frame.sequence)) return;
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
    [self disarmHostedInput];
    [self stopHostedOrientationObserver];
    (void)[self restoreRenderFPS];
    _running = NO; _panelVisible = NO;
    [self invalidateFrames];
    for (id token in _observers) [NSNotificationCenter.defaultCenter removeObserver:token];
    [_observers removeAllObjects];
    _drawWindow.hidden = YES; _menuWindow.hidden = YES;
    [CATransaction flush];
    NSError *cleanupError = nil;
    if (_drawCleanupNeeded && [_adapter unregisterWindow:_drawWindow surface:CoreSetHUDSurfaceDraw error:&cleanupError]) _drawCleanupNeeded = NO;
    if (_menuCleanupNeeded && [_adapter unregisterWindow:_menuWindow surface:CoreSetHUDSurfaceMenu error:&cleanupError]) _menuCleanupNeeded = NO;
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
    if (cleanupError) self.lastError = cleanupError;
    else if (self.cleanupPending) [self fail:8 message:@"Hosting cleanup has not been confirmed; retry stop" error:nil];
    CoreSetHUDStopResult result = {YES, !_menuCleanupNeeded, !_drawCleanupNeeded, !self.cleanupPending};
    [self publishState];
    return result;
}
@end
