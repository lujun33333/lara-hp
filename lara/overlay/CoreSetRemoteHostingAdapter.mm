#import "CoreSetRemoteHostingAdapter.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#include <cmath>

static char CSPrimaryControllerKey;
static char CSMenuControllerKey;
static char CSDrawControllerKey;

static uint32_t CSContext(UIWindow *window) {
    if (!window) return 0;
    uint32_t context = 0;
    SEL selector = NSSelectorFromString(@"_contextId");
    if ([window respondsToSelector:selector]) {
        @try {
            NSMethodSignature *signature = [window methodSignatureForSelector:selector];
            if (signature && signature.methodReturnLength == sizeof(context)) {
                NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
                invocation.target = window;
                invocation.selector = selector;
                [invocation invoke];
                [invocation getReturnValue:&context];
            }
        } @catch (__unused NSException *exception) {
            context = 0;
        }
        if (context) return context;
    }
    @try {
        id value = [window.layer valueForKey:@"contextId"];
        if ([value respondsToSelector:@selector(unsignedIntValue)]) {
            context = [value unsignedIntValue];
        }
    } @catch (__unused NSException *exception) {
        context = 0;
    }
    return context;
}

@interface CoreSetCore17HostSide : NSObject
@property(nonatomic, weak) UIWindow *source;
@property(nonatomic) uint32_t context;
@property(nonatomic) double level;
@property(nonatomic, strong, nullable) id controller;
@property(nonatomic) const void *associationKey;
@property(nonatomic) BOOL registered;
@end
@implementation CoreSetCore17HostSide @end

@implementation CoreSetCore17HostingAdapter {
    CoreSetCore17HostSide *_primary;
    CoreSetCore17HostSide *_menu;
    CoreSetCore17HostSide *_draw;
    uint64_t _hostGeneration;
    BOOL _busy;
}

- (instancetype)initWithPrimaryWindow:(UIWindow *)primaryWindow {
    if ((self = [super init])) {
        _primary = [CoreSetCore17HostSide new];
        _primary.source = primaryWindow;
        _primary.context = CSContext(primaryWindow);
        _primary.level = 999998.0;
        _primary.associationKey = &CSPrimaryControllerKey;
    }
    return self;
}

- (BOOL)usesDirectSourceInteraction { return YES; }
- (uint64_t)hostGeneration { return _hostGeneration; }
- (BOOL)cleanupPending { return _busy; }
- (NSString *)hostingDiagnosticSnapshot {
    return [NSString stringWithFormat:@"mode=core17-local-sbs-context primary=%d menu=%d draw=%d generation=%llu",
        _primary.registered, _menu.registered, _draw.registered,
        (unsigned long long)_hostGeneration];
}
- (BOOL)localSurfacesStillPublished {
    UIApplication *application = UIApplication.sharedApplication;
    return NSThread.isMainThread && !_busy && _primary.registered &&
        _menu.registered && _draw.registered && _primary.source && _menu.source &&
        _draw.source && CSContext(_primary.source) == _primary.context &&
        CSContext(_menu.source) == _menu.context &&
        CSContext(_draw.source) == _draw.context &&
        objc_getAssociatedObject(application, _primary.associationKey) == _primary.controller &&
        objc_getAssociatedObject(application, _menu.associationKey) == _menu.controller &&
        objc_getAssociatedObject(application, _draw.associationKey) == _draw.controller;
}
- (void)prepareForHostGeneration:(uint64_t)generation {
    if (NSThread.isMainThread && generation) _hostGeneration = generation;
}

- (BOOL)registerSide:(CoreSetCore17HostSide *)side {
    if (!NSThread.isMainThread || !side || !side.context || !std::isfinite(side.level)) {
        NSLog(@"Core-SET: core17-sbs stage=preflight main=%d context=%u level=%.0f ready=0",
              NSThread.isMainThread, side.context, side.level);
        return NO;
    }
    Class controllerClass = NSClassFromString(@"SBSAccessibilityWindowHostingController");
    SEL registerSelector = NSSelectorFromString(@"registerWindowWithContextID:atLevel:");
    if (!controllerClass || ![controllerClass instancesRespondToSelector:registerSelector]) {
        NSLog(@"Core-SET: core17-sbs stage=class context=%u class=%d selector=%d ready=0",
              side.context, controllerClass != Nil,
              controllerClass && [controllerClass instancesRespondToSelector:registerSelector]);
        return NO;
    }
    id controller = [[controllerClass alloc] init];
    if (!controller) {
        NSLog(@"Core-SET: core17-sbs stage=init context=%u ready=0", side.context);
        return NO;
    }
    @try {
        ((void (*)(id, SEL, uint32_t, double))objc_msgSend)(
            controller, registerSelector, side.context, side.level);
    } @catch (NSException *exception) {
        NSLog(@"Core-SET: core17-sbs stage=invoke context=%u exception=%@ ready=0",
              side.context, exception.name);
        return NO;
    }
    UIApplication *application = UIApplication.sharedApplication;
    objc_setAssociatedObject(application, side.associationKey, controller,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (objc_getAssociatedObject(application, side.associationKey) != controller) {
        objc_setAssociatedObject(application, side.associationKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSLog(@"Core-SET: core17-sbs stage=association context=%u ready=0", side.context);
        return NO;
    }
    side.controller = controller;
    side.registered = YES;
    NSLog(@"Core-SET: core17-sbs stage=registered context=%u level=%.0f ready=1",
          side.context, side.level);
    return YES;
}

- (BOOL)removeSide:(CoreSetCore17HostSide *)side {
    if (!side) return YES;
    UIApplication *application = UIApplication.sharedApplication;
    objc_setAssociatedObject(application, side.associationKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    const BOOL removed = objc_getAssociatedObject(application, side.associationKey) == nil;
    if (removed) {
        side.controller = nil;
        side.registered = NO;
    }
    return removed;
}

- (void)registerBothSurfacesAsync:(UIWindow *)menuWindow drawWindow:(UIWindow *)drawWindow
                         completion:(void (^)(BOOL, uint64_t))completion {
    if (!completion) return;
    const uint64_t generation = _hostGeneration;
    if (!NSThread.isMainThread || _busy || _menu || _draw || !generation ||
        !menuWindow || !drawWindow) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, generation); });
        return;
    }
    CoreSetCore17HostSide *menu = [CoreSetCore17HostSide new];
    CoreSetCore17HostSide *draw = [CoreSetCore17HostSide new];
    [CATransaction flush];
    _primary.context = CSContext(_primary.source);
    menu.source = menuWindow;
    menu.context = CSContext(menuWindow);
    menu.level = 1000000.0;
    menu.associationKey = &CSMenuControllerKey;
    draw.source = drawWindow;
    draw.context = CSContext(drawWindow);
    draw.level = 999999.0;
    draw.associationKey = &CSDrawControllerKey;
    NSLog(@"Core-SET: core17-sbs stage=context-capture primary=%u menu=%u draw=%u",
          _primary.context, menu.context, draw.context);
    if (!menu.context || !draw.context) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, generation); });
        return;
    }
    _menu = menu;
    _draw = draw;
    _busy = YES;
    const BOOL primaryReady = [self registerSide:_primary];
    const BOOL menuReady = primaryReady && [self registerSide:menu];
    const BOOL drawReady = menuReady && [self registerSide:draw];
    const BOOL registered = primaryReady && menuReady && drawReady;
    if (!registered) {
        (void)[self removeSide:draw];
        (void)[self removeSide:menu];
        (void)[self removeSide:_primary];
    }
    _busy = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(registered && self->_hostGeneration == generation, generation);
    });
}

- (void)observeBothSurfacesAsync:(void (^)(BOOL, uint64_t))completion {
    if (!completion) return;
    const BOOL observed = self.localSurfacesStillPublished;
    const uint64_t generation = _hostGeneration;
    dispatch_async(dispatch_get_main_queue(), ^{ completion(observed, generation); });
}

- (void)unregisterBothSurfacesAsync:(UIWindow *)menuWindow drawWindow:(UIWindow *)drawWindow
                         completion:(void (^)(BOOL, BOOL))completion {
    if (!completion) return;
    if (!NSThread.isMainThread || _busy || (_menu.source && _menu.source != menuWindow) ||
        (_draw.source && _draw.source != drawWindow)) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, NO); });
        return;
    }
    _busy = YES;
    const BOOL drawRemoved = [self removeSide:_draw];
    const BOOL menuRemoved = [self removeSide:_menu];
    const BOOL primaryRemoved = [self removeSide:_primary];
    if (drawRemoved) _draw = nil;
    if (menuRemoved) _menu = nil;
    _busy = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(menuRemoved && primaryRemoved, drawRemoved);
    });
}
@end
