#import "CoreSetHUDHost.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <cmath>

// Core 1.7 registers three distinct source contexts in draw/icon/menu order.
static const double kCoreSetHUDDrawWindowLevel = 999998.0;
static const double kCoreSetHUDIconWindowLevel = 1000000.0;
static const double kCoreSetHUDMenuWindowLevel = 999999.0;
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

@interface CoreSetIconWindow : UIWindow
@property(nonatomic, weak) UIView *floatingRegion;
@end
@implementation CoreSetIconWindow
+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isSecure { return NO; }
- (BOOL)_canBecomeKeyWindow { return YES; }
- (BOOL)_isApplicationKeyWindow { return NO; }
- (BOOL)_isWindowServerHostingManaged { return NO; }
- (BOOL)_shouldCreateContextAsSecure { return NO; }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *region = self.floatingRegion;
    if (!region || ![region isDescendantOfView:self] || region.hidden ||
        region.alpha <= 0.01 || !region.userInteractionEnabled) return nil;
    return [region pointInside:[region convertPoint:point fromView:self] withEvent:event]
        ? [super hitTest:point withEvent:event] : nil;
}
@end

@interface CoreSetMenuWindow : UIWindow
@property(nonatomic) BOOL backgroundPassThrough;
@property(nonatomic, weak) UIView *panelRegion;
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
- (BOOL)startPreparedInMenuScene:(UIWindowScene *)menuScene drawScene:(UIWindowScene *)drawScene
                menuController:(UIViewController *)menuController
                          error:(NSError **)error
               hostedCompletion:(void (^)(BOOL))hostedCompletion;
@end

@implementation CoreSetHUDHost {
    id<CoreSetHUDHostingAdapter> _adapter;
    id<CoreSetFrameConsumer> _metal;
    CoreSetCoreAnimationConsumer *_layers;
    CoreSetDrawWindow *_drawWindow;
    CoreSetIconWindow *_iconWindow;
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
    BOOL _iconRegistered;
    BOOL _drawRegistered;
    BOOL _menuCleanupNeeded;
    BOOL _iconCleanupNeeded;
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
    uint64_t _hostedReadbackGeneration;
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
        _hostedAsyncStopWaiters = [NSMutableArray array];
    }
    return self;
}
- (BOOL)localSurfacesReady {
    return _running && _drawWindow && _iconWindow && _menuWindow && _drawCanvas && _panel &&
        _menuWindow.windowScene.activationState != UISceneActivationStateUnattached;
}
- (BOOL)hasHostedRegistrationReceipt {
    return self.localSurfacesReady && _drawRegistered && _iconRegistered && _menuRegistered &&
        _adapter && [_adapter respondsToSelector:@selector(hostGeneration)] &&
        [_adapter respondsToSelector:@selector(localSurfacesStillPublished)] &&
        [_adapter hostGeneration] == self.generation &&
        _hostedReadbackGeneration == self.generation &&
        [_adapter localSurfacesStillPublished];
}
- (BOOL)hostedRegistrationReceipt { return [self hasHostedRegistrationReceipt]; }
- (CGSize)logicalCanvasSize { return _drawCanvas ? _drawCanvas.bounds.size : CGSizeZero; }
- (NSString *)hostingDiagnosticSnapshot {
    const NSInteger sceneState = _menuWindow.windowScene
        ? _menuWindow.windowScene.activationState : -1;
    const BOOL adapterGenerationAvailable = _adapter &&
        [_adapter respondsToSelector:@selector(hostGeneration)];
    const uint64_t adapterGeneration = adapterGenerationAvailable ? [_adapter hostGeneration] : 0;
    const CGSize logicalSize = self.logicalCanvasSize;
    NSString *state = [NSString stringWithFormat:
        @"running=%d foreground=%d sceneState=%ld localReady=%d drawRegistered=%d iconRegistered=%d menuRegistered=%d adapter=%d adapterGenerationAvailable=%d hostGeneration=%llu adapterGeneration=%llu panel=%d drawWindowHidden=%d iconWindowHidden=%d menuWindowHidden=%d floatingHidden=%d floatingAttached=%d orientation=%ld canvas=%.0fx%.0f",
        _running, _foreground, (long)sceneState, self.localSurfacesReady,
        _drawRegistered, _iconRegistered, _menuRegistered, _adapter != nil, adapterGenerationAvailable,
        (unsigned long long)self.generation, (unsigned long long)adapterGeneration, _panelVisible,
        _drawWindow.hidden, _iconWindow.hidden, _menuWindow.hidden, _floating.hidden,
        _floating.superview != nil, (long)_hostedOrientation,
        logicalSize.width, logicalSize.height];
    return state;
}
- (BOOL)cleanupPending { return !_running && (_drawCleanupNeeded || _iconCleanupNeeded || _menuCleanupNeeded || _schedulerCleanupNeeded); }
- (BOOL)hostedCleanupInFlight { return _hostedAsyncStopPending; }
- (BOOL)panelVisible { return _panelVisible; }
- (BOOL)floatingControlReady {
    if (!NSThread.isMainThread || !self.localSurfacesReady ||
        !_floating || !_iconWindow || _iconWindow.hidden ||
        _floating.hidden || _floating.alpha <= 0.01 ||
        !_floating.userInteractionEnabled ||
        ![_floating isDescendantOfView:_iconWindow]) return NO;
    const CGRect button = [_floating convertRect:_floating.bounds toView:_iconWindow];
    return CGRectIntersectsRect(button, _iconWindow.bounds);
}
- (uint64_t)lastConsumedSequence { return _lastConsumedSequence; }
- (NSArray<UIColor *> *)observedFloatingColors {
    if (!self.floatingControlReady || !_floatingGradient) return @[];
    NSMutableArray<UIColor *> *colors = [NSMutableArray array];
    for (id value in _floatingGradient.colors)
        [colors addObject:[UIColor colorWithCGColor:(__bridge CGColorRef)value]];
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
    _hostedReadbackGeneration = 0;
    self.generation = CoreSetHUDNextGeneration(self.generation);
    self.renderGeneration = CoreSetHUDNextGeneration(self.renderGeneration);
    if ([_adapter respondsToSelector:@selector(prepareForHostGeneration:)])
        [_adapter prepareForHostGeneration:self.generation];
    // Core keeps the same three SBS controllers across app activation changes.
    // Advancing the frame generation must not discard that already-published
    // hosting receipt, otherwise the menu loses its hosted state as soon as the
    // launcher backgrounds after opening the game.
    if (_adapter &&
        [_adapter respondsToSelector:@selector(hostGeneration)] &&
        [_adapter respondsToSelector:@selector(localSurfacesStillPublished)] &&
        [_adapter hostGeneration] == self.generation &&
        [_adapter localSurfacesStillPublished]) {
        _hostedReadbackGeneration = self.generation;
    }
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
    if (!NSThread.isMainThread || !_adapter || !_menuWindow || !_iconWindow || !_drawWindow ||
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
    if (_running) {
        // The source UIWindow and CA context are unchanged. Invalidate only
        // local pixels; keep host/adapter generation and the remote receipt.
        [_layers clear]; [_metal clear]; _lastSequence = 0; _lastConsumedSequence = 0;
        self.renderGeneration = CoreSetHUDNextGeneration(self.renderGeneration);
    }
    [self layoutSurfaces];
    [_drawWindow layoutIfNeeded]; [_iconWindow layoutIfNeeded]; [_menuWindow layoutIfNeeded];
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

- (void)whenHostingOperationIdle:(dispatch_block_t)completion {
    if (!completion) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_adapter &&
            [self->_adapter respondsToSelector:@selector(cleanupPending)] &&
            ((BOOL (*)(id, SEL))objc_msgSend)(self->_adapter, @selector(cleanupPending))) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                [self whenHostingOperationIdle:completion];
            });
            return;
        }
        completion();
    });
}
- (BOOL)startLocalInScene:(UIWindowScene *)scene menuController:(UIViewController *)menuController {
    return [self startInScene:scene menuController:menuController error:nil];
}
- (BOOL)startHostedInScene:(UIWindowScene *)scene menuController:(UIViewController *)menuController
                completion:(void (^)(BOOL))completion {
    if (!_adapter || !completion) return NO;
    return [self startPreparedInMenuScene:scene drawScene:scene menuController:menuController
                               error:nil hostedCompletion:completion];
}
- (BOOL)startHostedInMenuScene:(UIWindowScene *)menuScene drawScene:(UIWindowScene *)drawScene
                menuController:(UIViewController *)menuController
                     completion:(void (^)(BOOL))completion {
    if (!_adapter || !completion) return NO;
    return [self startPreparedInMenuScene:menuScene drawScene:drawScene
        menuController:menuController error:nil hostedCompletion:completion];
}
- (BOOL)applyLocalMenuVisible:(BOOL)visible colors:(NSArray<UIColor *> *)colors {
    if (!NSThread.isMainThread || !self.localSurfacesReady || !colors.count) return NO;
    [self setFloatingColors:colors];
    [self setPanelVisible:visible];
    return self.localSurfacesReady && self.panelVisible == visible &&
        self.floatingControlReady;
}
- (BOOL)startInScene:(UIWindowScene *)scene menuController:(UIViewController *)menuController error:(NSError **)error {
    return [self startPreparedInMenuScene:scene drawScene:scene menuController:menuController
                               error:error hostedCompletion:nil];
}
- (BOOL)startPreparedInMenuScene:(UIWindowScene *)menuScene drawScene:(UIWindowScene *)drawScene
                menuController:(UIViewController *)menuController
                       error:(NSError **)error hostedCompletion:(void (^)(BOOL))hostedCompletion {
    if (!NSThread.isMainThread) return [self fail:1 message:@"Main thread required" error:error];
    if ((_adapter != nil) != (hostedCompletion != nil))
        return [self fail:14 message:@"Hosted sources require asynchronous registration" error:error];
    if (self.cleanupPending) return [self fail:4 message:@"Prior hosting cleanup is still pending" error:error];
    if (_running) {
        if (hostedCompletion)
            return [self fail:9 message:@"Hosted registration already in progress" error:error];
        if (_drawWindow.windowScene == drawScene && _iconWindow.windowScene == menuScene &&
            _menuWindow.windowScene == menuScene &&
            _menuController == menuController) return self.localSurfacesReady;
        return [self fail:9 message:@"Stop the current scene before attaching another menu" error:error];
    }
    if (!menuScene || !drawScene || !menuController || menuController.parentViewController ||
        menuController.presentingViewController)
        return [self fail:5 message:@"Two scenes and an unowned menu controller are required" error:error];
    self.lastError = nil;
    [self invalidateFrames];
    _foreground = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    _drawWindow = [[CoreSetDrawWindow alloc] initWithWindowScene:drawScene];
    _iconWindow = [[CoreSetIconWindow alloc] initWithWindowScene:menuScene];
    _menuWindow = [[CoreSetMenuWindow alloc] initWithWindowScene:menuScene];
    _menuWindow.backgroundPassThrough = NO;
    _menuWindow.userInteractionEnabled = YES;
    _drawWindow.windowLevel = kCoreSetHUDDrawWindowLevel;
    _iconWindow.windowLevel = kCoreSetHUDIconWindowLevel;
    _menuWindow.windowLevel = kCoreSetHUDMenuWindowLevel;
    _drawWindow.backgroundColor = _iconWindow.backgroundColor =
        _menuWindow.backgroundColor = UIColor.clearColor;
    UIViewController *drawRoot = [UIViewController new];
    drawRoot.view.backgroundColor = UIColor.clearColor;
    _drawWindow.rootViewController = drawRoot;
    _drawCanvas = drawRoot.view;
    [_layers attachToView:_drawCanvas]; [_metal attachToView:_drawCanvas];
    UIViewController *iconRoot = [UIViewController new];
    iconRoot.view.backgroundColor = UIColor.clearColor;
    _iconWindow.rootViewController = iconRoot;
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
    _floatingGradient.frame = _floating.bounds;
    _floatingGradient.cornerRadius = 22;
    [_floating.layer insertSublayer:_floatingGradient atIndex:0];
    [self setFloatingColors:@[UIColor.systemTealColor]];
    [_floating setTitle:@"菜单" forState:UIControlStateNormal];
    _floating.titleLabel.font = [UIFont systemFontOfSize:12];
    _floating.accessibilityLabel = @"打开菜单";
    [_floating addTarget:self action:@selector(togglePanel)
        forControlEvents:UIControlEventTouchUpInside];
    [_floating addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragFloating:)]];
    [iconRoot.view addSubview:_floating];
    _iconWindow.floatingRegion = _floating;
    _menuWindow.panelRegion = _panel;
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
    _drawWindow.hidden = NO; _iconWindow.hidden = NO; _menuWindow.hidden = NO;
    [_drawWindow layoutIfNeeded]; [_iconWindow layoutIfNeeded]; [_menuWindow layoutIfNeeded];
    [CATransaction flush];
    _running = YES;
    for (NSNotificationName name in @[UIApplicationDidBecomeActiveNotification, UIApplicationDidEnterBackgroundNotification]) {
        id token = [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(NSNotification *note) { [weakSelf setApplicationActive:[note.name isEqualToString:UIApplicationDidBecomeActiveNotification]]; }];
        [_observers addObject:token];
    }
    [self selectBackend]; [self publishState];
    if (_adapter) {
        _drawCleanupNeeded = YES; _iconCleanupNeeded = YES; _menuCleanupNeeded = YES;
        const uint64_t generation = self.generation;
        CoreSetMenuWindow *menuWindow = _menuWindow;
        CoreSetIconWindow *iconWindow = _iconWindow;
        CoreSetDrawWindow *drawWindow = _drawWindow;
        [_adapter registerThreeSurfacesAsync:menuWindow iconWindow:iconWindow drawWindow:drawWindow
            completion:^(BOOL observed, uint64_t adapterGeneration) {
                CoreSetHUDHost *host = weakSelf;
                if (!host) return;
                const BOOL current = observed && host->_running &&
                    host.generation == generation && adapterGeneration == generation &&
                    host->_drawWindow == drawWindow && host->_iconWindow == iconWindow &&
                    host->_menuWindow == menuWindow &&
                    host.localSurfacesReady &&
                    [host->_adapter respondsToSelector:@selector(hostGeneration)] &&
                    [host->_adapter hostGeneration] == generation;
                host->_drawRegistered = current; host->_iconRegistered = current;
                host->_menuRegistered = current;
                host->_hostedReadbackGeneration = current ? generation : 0;
                if (!current) [host fail:6 message:@"Core 1.7 context registration failed" error:nil];
                [host selectBackend]; [host publishState];
                hostedCompletion(current);
            }];
    }
    return YES;
}
- (void)layoutSurfaces {
    if (!_menuWindow || !_iconWindow || !_drawWindow || _layoutApplying) return;
    _layoutApplying = YES;
    CGRect bounds = _menuWindow.windowScene.screen.fixedCoordinateSpace.bounds;
    bounds = CGRectMake(0, 0, CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    if (!CGRectEqualToRect(_drawWindow.frame, bounds)) _drawWindow.frame = bounds;
    if (!CGRectEqualToRect(_iconWindow.frame, bounds)) _iconWindow.frame = bounds;
    if (!CGRectEqualToRect(_menuWindow.frame, bounds)) _menuWindow.frame = bounds;
    UIView *root = _menuWindow.rootViewController.view;
    UIView *iconRoot = _iconWindow.rootViewController.view;
    UIView *drawRoot = _drawWindow.rootViewController.view;
    if (!root || !iconRoot || !drawRoot) { _layoutApplying = NO; return; }
    const BOOL quarterTurn = _adapter && UIInterfaceOrientationIsLandscape(_hostedOrientation);
    const CGRect logical = quarterTurn
        ? CGRectMake(0, 0, bounds.size.height, bounds.size.width) : bounds;
    const CGFloat angle = _adapter ? CoreSetHostedOrientationAngle(_hostedOrientation) : 0;
    const CGAffineTransform transform = CGAffineTransformMakeRotation(angle);
    const CGPoint center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (UIView *surface in @[root, iconRoot, drawRoot]) {
        const CGPoint surfaceCenter = center;
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
    if (!floatingInitialized) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        if ([defaults boolForKey:@"hud_button_center_saved"])
            _floatingCenter = CGPointMake([defaults doubleForKey:@"hud_button_center_x"],
                                          [defaults doubleForKey:@"hud_button_center_y"]);
        else
            _floatingCenter = CGPointMake(CGRectGetMaxX(safe) - 30, CGRectGetMidY(safe));
    }
    _floatingCenter.x = MIN(MAX(_floatingCenter.x, CGRectGetMinX(safe) + 22), MAX(CGRectGetMinX(safe) + 22, CGRectGetMaxX(safe) - 22));
    _floatingCenter.y = MIN(MAX(_floatingCenter.y, CGRectGetMinY(safe) + 22), MAX(CGRectGetMinY(safe) + 22, CGRectGetMaxY(safe) - 22));
    _floating.center = _floatingCenter;
    _layoutApplying = NO;
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
        CGPoint delta = [gesture translationInView:_iconWindow.rootViewController.view];
        _floatingCenter = CGPointMake(_dragOrigin.x + delta.x, _dragOrigin.y + delta.y);
        [self layoutSurfaces];
        if (gesture.state == UIGestureRecognizerStateEnded) {
            NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
            [defaults setDouble:_floatingCenter.x forKey:@"hud_button_center_x"];
            [defaults setDouble:_floatingCenter.y forKey:@"hud_button_center_y"];
            [defaults setBool:YES forKey:@"hud_button_center_saved"];
        }
    }
}
- (void)setFloatingColors:(NSArray<UIColor *> *)colors {
    if (!NSThread.isMainThread || !_floatingGradient) return;
    NSMutableArray *values = [NSMutableArray array];
    for (UIColor *color in colors)
        if ([color isKindOfClass:UIColor.class]) [values addObject:(id)color.CGColor];
    if (!values.count) return;
    if (values.count == 1) [values addObject:values.firstObject];
    _floatingGradient.colors = values;
    _floatingGradient.startPoint = CGPointMake(0, .5);
    _floatingGradient.endPoint = CGPointMake(1, .5);
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
    _foreground = active;
    _menuWindow.backgroundPassThrough = NO;
    _menuWindow.userInteractionEnabled = YES;
    _iconWindow.userInteractionEnabled = YES;
    [self invalidateFrames]; [self selectBackend]; [self layoutSurfaces]; [self publishState];
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
        id<CoreSetFrameConsumer> consumer = host->_activeBackend == CoreSetHUDBackendMetal
            ? host->_metal : host->_layers;
        NSError *error = nil;
        if (!consumer || ![consumer consumeFrame:frame error:&error]) {
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
        CoreSetHUDStopResult pending = {NO, !_menuCleanupNeeded && !_iconCleanupNeeded,
                                        !_drawCleanupNeeded, NO};
        return pending;
    }
    if (_adapter && (_drawCleanupNeeded || _iconCleanupNeeded || _menuCleanupNeeded)) {
        if (_hostedCleanupFailed) {
            CoreSetHUDStopResult pending = {YES, !_menuCleanupNeeded && !_iconCleanupNeeded,
                                            !_drawCleanupNeeded, NO};
            return pending;
        }
        // Termination/disconnect disarms and hides immediately, then releases
        // the SpringBoard hosting controllers.
        [self stopHostedAsync:^(__unused CoreSetHUDStopResult result) {}];
        CoreSetHUDStopResult pending = {YES, NO, NO, NO};
        return pending;
    }
    [self stopHostedOrientationObserver];
    (void)[self restoreRenderFPS];
    _running = NO; _panelVisible = NO;
    [self invalidateFrames];
    for (id token in _observers) [NSNotificationCenter.defaultCenter removeObserver:token];
    [_observers removeAllObjects];
    _drawWindow.hidden = YES; _iconWindow.hidden = YES; _menuWindow.hidden = YES;
    [CATransaction flush];
    _drawRegistered = NO; _iconRegistered = NO; _menuRegistered = NO;
    [_layers detach];
    if (!_schedulerCleanupNeeded) [_metal detach];
    [_menuController willMoveToParentViewController:nil];
    [_menuController.view removeFromSuperview]; [_menuController removeFromParentViewController];
    _drawWindow.rootViewController = nil; _iconWindow.rootViewController = nil;
    _menuWindow.rootViewController = nil;
    _drawCanvas = nil; _menuController = nil; _panel = nil;
    _floating = nil; _floatingGradient = nil;
    // Retain failed cleanup handles; retry stop before allowing another start.
    if (!_drawCleanupNeeded) _drawWindow = nil;
    if (!_iconCleanupNeeded) _iconWindow = nil;
    if (!_menuCleanupNeeded) _menuWindow = nil;
    if (self.cleanupPending) [self fail:8 message:@"Hosting cleanup has not been confirmed; retry stop" error:nil];
    CoreSetHUDStopResult result = {YES, !_menuCleanupNeeded && !_iconCleanupNeeded,
                                   !_drawCleanupNeeded, !self.cleanupPending};
    [self publishState];
    return result;
}
- (void)stopHostedAsync:(void (^)(CoreSetHUDStopResult))completion {
    if (!completion || !NSThread.isMainThread) return;
    if (!_running && !_drawCleanupNeeded && !_iconCleanupNeeded && !_menuCleanupNeeded &&
        !_hostedAsyncStopPending) {
        completion([self stop]); return;
    }
    if (!_adapter || ![_adapter respondsToSelector:
        @selector(unregisterThreeSurfacesAsync:iconWindow:drawWindow:completion:)]) {
        completion([self stop]); return;
    }
    if (_hostedAsyncStopPending) {
        [_hostedAsyncStopWaiters addObject:[completion copy]];
        return;
    }
    [_hostedAsyncStopWaiters addObject:[completion copy]];
    _hostedAsyncStopPending = YES;
    _hostedCleanupFailed = NO;
    [self stopHostedOrientationObserver];
    _running = NO; _panelVisible = NO;
    [_layers clear]; [_metal clear];
    _menuWindow.backgroundPassThrough = YES;
    _menuWindow.userInteractionEnabled = NO;
    _iconWindow.userInteractionEnabled = NO;
    _drawWindow.hidden = YES; _iconWindow.hidden = YES; _menuWindow.hidden = YES;
    [CATransaction flush];
    __weak CoreSetHUDHost *weakSelf = self;
    id<CoreSetHUDHostingAdapter> adapter = _adapter;
    CoreSetMenuWindow *menuWindow = _menuWindow;
    CoreSetIconWindow *iconWindow = _iconWindow;
    CoreSetDrawWindow *drawWindow = _drawWindow;
    [self whenHostingOperationIdle:^{
        [adapter unregisterThreeSurfacesAsync:menuWindow iconWindow:iconWindow drawWindow:drawWindow
          completion:^(BOOL menuRemoved, BOOL iconRemoved, BOOL drawRemoved) {
            CoreSetHUDHost *host = weakSelf;
            if (!host) return;
            host->_menuCleanupNeeded = !menuRemoved;
            host->_iconCleanupNeeded = !iconRemoved;
            host->_drawCleanupNeeded = !drawRemoved;
            host->_drawRegistered = NO; host->_iconRegistered = NO;
            host->_menuRegistered = NO;
            host->_hostedAsyncStopPending = NO;
            if (!menuRemoved || !iconRemoved || !drawRemoved) {
                host->_hostedCleanupFailed = YES;
                [host fail:13 message:@"SpringBoard cleanup unconfirmed; handles retained" error:nil];
                CoreSetHUDStopResult incomplete = {YES, menuRemoved && iconRemoved,
                                                   drawRemoved, NO};
                [host publishState];
                NSArray *waiters = [host->_hostedAsyncStopWaiters copy];
                [host->_hostedAsyncStopWaiters removeAllObjects];
                for (id waiter in waiters) ((void (^)(CoreSetHUDStopResult))waiter)(incomplete);
                return;
            }
            // Remote hosting controllers are gone. The existing local stop now
            // performs only UIKit detach.
            const CoreSetHUDStopResult result = [host stop];
            NSArray *waiters = [host->_hostedAsyncStopWaiters copy];
            [host->_hostedAsyncStopWaiters removeAllObjects];
            for (id waiter in waiters) ((void (^)(CoreSetHUDStopResult))waiter)(result);
        }];
    }];
}
@end
