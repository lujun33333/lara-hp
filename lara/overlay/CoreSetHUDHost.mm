#import "CoreSetHUDHost.h"
#import <QuartzCore/QuartzCore.h>
#include <cmath>

@interface CoreSetDrawWindow : UIWindow @end
@implementation CoreSetDrawWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { (void)point; (void)event; return nil; }
@end

@interface CoreSetMenuWindow : UIWindow
@property(nonatomic, weak) UIView *panelRegion;
@property(nonatomic, weak) UIView *floatingRegion;
@property(nonatomic, copy) NSArray<UIView *> * (^contentHitRegions)(void);
@end
@implementation CoreSetMenuWindow
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
@end

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
}
- (instancetype)init { return [self initWithHostingAdapter:nil]; }
- (instancetype)initWithHostingAdapter:(id<CoreSetHUDHostingAdapter>)adapter {
    if ((self = [super init])) {
        _adapter = adapter; _layers = [CoreSetCoreAnimationConsumer new];
        _observers = [NSMutableArray array]; _floatingCenter = CGPointMake(NAN, NAN);
    }
    return self;
}
- (BOOL)localSurfacesReady {
    return _running && _drawWindow && _menuWindow && _drawCanvas && _panel &&
        _menuWindow.windowScene.activationState != UISceneActivationStateUnattached;
}
- (BOOL)crossApplicationHosted {
    return self.localSurfacesReady && CoreSetHUDHostingReady(_menuRegistered, _drawRegistered) &&
        _adapter && [_adapter respondsToSelector:@selector(bothSurfacesObserved)] &&
        [_adapter respondsToSelector:@selector(hostGeneration)] &&
        [_adapter hostGeneration] == self.generation &&
        [_adapter bothSurfacesObserved];
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
    self.generation = CoreSetHUDNextGeneration(self.generation);
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
- (BOOL)installLocalMetalConsumer:(id<CoreSetFrameConsumer>)consumer {
    return [self setMetalConsumer:consumer error:nil];
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
    _drawWindow.windowLevel = UIWindowLevelAlert + 1;
    _menuWindow.windowLevel = UIWindowLevelAlert + 2;
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
    [self layoutSurfaces];
    _drawWindow.hidden = NO; _menuWindow.hidden = NO;
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
    if (!_menuWindow || !_drawWindow) return;
    CGRect bounds = _menuWindow.windowScene.coordinateSpace.bounds;
    _menuWindow.frame = bounds; _drawWindow.frame = bounds;
    UIView *root = _menuWindow.rootViewController.view;
    CGRect safe = UIEdgeInsetsInsetRect(root.bounds, root.safeAreaInsets);
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
    _activeBackend = CoreSetHUDSelectBackend(_foreground, metalReady, self.crossApplicationHosted);
    [_layers setVisible:_activeBackend == CoreSetHUDBackendCoreAnimation];
    [_metal setVisible:_activeBackend == CoreSetHUDBackendMetal];
}
- (void)setApplicationActive:(BOOL)active {
    if (!NSThread.isMainThread || !_running || _foreground == active) return;
    _foreground = active;
    [self invalidateFrames]; [self selectBackend]; [self layoutSurfaces]; [self publishState];
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
            host->_lastConsumedSequence = frame.sequence;
            if (host.frameDidConsume) host.frameDidConsume(frame, YES, nil);
            [host publishState];
        }
    });
}
- (CoreSetHUDStopResult)stop {
    if (!NSThread.isMainThread) {
        CoreSetHUDStopResult rejected = {NO, NO, NO, NO};
        return rejected;
    }
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
