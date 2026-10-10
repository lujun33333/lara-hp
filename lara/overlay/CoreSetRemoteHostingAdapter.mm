#import "CoreSetRemoteHostingAdapter.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <cmath>
#include <dlfcn.h>

static const double kCoreSetDrawLevel = 999998.0;
static const double kCoreSetIconLevel = 1000000.0;
static const double kCoreSetMenuLevel = 999999.0;
static NSString *const CSHostBuildMarker = @"core17-local-sbs-v4";

static Class CSAccessibilityHostingClass(void) {
    Class cls = NSClassFromString(@"SBSAccessibilityWindowHostingController");
    if (cls) return cls;
    static void *accessibilityUtilities;
    static void *springBoardServices;
    @synchronized (NSBundle.class) {
        if (!accessibilityUtilities) accessibilityUtilities = dlopen(
            "/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities",
            RTLD_LAZY | RTLD_LOCAL);
        if (!springBoardServices) springBoardServices = dlopen(
            "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
            RTLD_LAZY | RTLD_LOCAL);
    }
    return NSClassFromString(@"SBSAccessibilityWindowHostingController");
}

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
        if ([value respondsToSelector:@selector(unsignedIntValue)])
            context = [value unsignedIntValue];
    } @catch (__unused NSException *exception) {
        context = 0;
    }
    return context;
}

static NSInvocation *CSHostingInvocation(id target, SEL selector, uint32_t context,
                                         const double *level) {
    if (!target || !selector || ![target respondsToSelector:selector]) return nil;
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    const NSUInteger argumentCount = level ? 4 : 3;
    if (!signature || signature.numberOfArguments < argumentCount) return nil;
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = target;
    invocation.selector = selector;
    [invocation setArgument:&context atIndex:2];
    if (level) [invocation setArgument:(void *)level atIndex:3];
    [invocation retainArguments];
    return invocation;
}

@interface CoreSetLocalHostSide : NSObject
@property(nonatomic, weak) UIWindow *source;
@property(nonatomic) uint32_t context;
@property(nonatomic) double level;
@property(nonatomic, strong) id controller;
@property(nonatomic) SEL associationKey;
@property(nonatomic) SEL lockInvocationKey;
@property(nonatomic) SEL unlockInvocationKey;
@property(nonatomic, copy) NSString *role;
@property(nonatomic) BOOL registered;
@end
@implementation CoreSetLocalHostSide @end

@implementation CoreSetRemoteHostingAdapter {
    CoreSetLocalHostSide *_draw;
    CoreSetLocalHostSide *_icon;
    CoreSetLocalHostSide *_menu;
    uint64_t _hostGeneration;
    BOOL _busy;
}

- (instancetype)init { return [super init]; }
- (uint64_t)hostGeneration { return _hostGeneration; }
- (BOOL)cleanupPending { return _busy; }
- (BOOL)sessionIdentityReady {
    Class cls = CSAccessibilityHostingClass();
    return cls && [cls instancesRespondToSelector:
        NSSelectorFromString(@"registerWindowWithContextID:atLevel:")] &&
        [cls instancesRespondToSelector:
        NSSelectorFromString(@"unregisterWindowWithContextID:")];
}
- (NSString *)sessionIdentityFailureReason {
    return self.sessionIdentityReady ? nil : @"应用进程无法解析 Core SBS 托管类或注册 selector";
}
- (NSString *)hostingDiagnosticSnapshot {
    return [NSString stringWithFormat:
        @"mode=core17-local-sbs build=%@ draw=%d icon=%d menu=%d generation=%llu",
        CSHostBuildMarker, _draw.registered, _icon.registered, _menu.registered,
        (unsigned long long)_hostGeneration];
}
- (BOOL)localSurfacesStillPublished {
    if (!NSThread.isMainThread || _busy || !_draw.registered || !_icon.registered ||
        !_menu.registered) return NO;
    UIApplication *application = UIApplication.sharedApplication;
    for (CoreSetLocalHostSide *side in @[_draw, _icon, _menu]) {
        if (!side.source || CSContext(side.source) != side.context ||
            objc_getAssociatedObject(application, side.associationKey) != side.controller)
            return NO;
    }
    return YES;
}
- (void)prepareForHostGeneration:(uint64_t)generation {
    if (NSThread.isMainThread && generation) _hostGeneration = generation;
}

- (BOOL)registerSide:(CoreSetLocalHostSide *)side {
    Class cls = CSAccessibilityHostingClass();
    SEL selector = NSSelectorFromString(@"registerWindowWithContextID:atLevel:");
    if (!cls || !side.context || !std::isfinite(side.level) || !side.associationKey ||
        ![cls instancesRespondToSelector:selector]) return NO;
    id controller = [[cls alloc] init];
    if (!controller) return NO;
    side.controller = controller;
    double level = side.level;
    NSInvocation *invocation = CSHostingInvocation(controller, selector, side.context, &level);
    if (!invocation) return NO;
    @try {
        [invocation invoke];
        objc_setAssociatedObject(UIApplication.sharedApplication, side.associationKey,
                                 controller, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } @catch (__unused NSException *exception) {
        return NO;
    }
    side.registered = objc_getAssociatedObject(UIApplication.sharedApplication,
                                                side.associationKey) == controller;
    NSLog(@"Core-SET: core17-local-sbs build=%@ stage=registered role=%@ context=%u level=%.0f",
          CSHostBuildMarker, side.role, side.context, side.level);
    return side.registered;
}

- (BOOL)removeLifecycleForSides:(NSArray<CoreSetLocalHostSide *> *)sides {
    UIApplication *application = UIApplication.sharedApplication;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    @try {
        for (NSUInteger phase = 0; phase < 2; phase++) {
            for (CoreSetLocalHostSide *side in sides) {
                SEL key = phase == 0 ? side.lockInvocationKey : side.unlockInvocationKey;
                id invocation = key ? objc_getAssociatedObject(application, key) : nil;
                if (invocation) [center removeObserver:invocation];
                if (key) objc_setAssociatedObject(application, key, nil,
                                                  OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                if (key && objc_getAssociatedObject(application, key)) return NO;
            }
        }
    } @catch (__unused NSException *exception) {
        return NO;
    }
    return YES;
}

- (BOOL)installLifecycleForSides:(NSArray<CoreSetLocalHostSide *> *)sides {
    SEL unregisterSelector = NSSelectorFromString(@"unregisterWindowWithContextID:");
    SEL registerSelector = NSSelectorFromString(@"registerWindowWithContextID:atLevel:");
    UIApplication *application = UIApplication.sharedApplication;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    NSMutableArray<NSInvocation *> *locks = [NSMutableArray arrayWithCapacity:3];
    NSMutableArray<NSInvocation *> *unlocks = [NSMutableArray arrayWithCapacity:3];
    if (![self removeLifecycleForSides:sides]) return NO;
    @try {
        for (CoreSetLocalHostSide *side in sides) {
            double level = side.level;
            NSInvocation *lock = CSHostingInvocation(side.controller, unregisterSelector,
                                                     side.context, nullptr);
            NSInvocation *unlock = CSHostingInvocation(side.controller, registerSelector,
                                                       side.context, &level);
            if (!lock || !unlock || !side.lockInvocationKey || !side.unlockInvocationKey)
                return NO;
            objc_setAssociatedObject(application, side.lockInvocationKey, lock,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(application, side.unlockInvocationKey, unlock,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [locks addObject:lock]; [unlocks addObject:unlock];
        }
        for (NSInvocation *invocation in locks)
            [center addObserver:invocation selector:@selector(invoke)
                           name:UIApplicationProtectedDataWillBecomeUnavailable object:nil];
        for (NSInvocation *invocation in unlocks)
            [center addObserver:invocation selector:@selector(invoke)
                           name:UIApplicationProtectedDataDidBecomeAvailable object:nil];
    } @catch (__unused NSException *exception) {
        (void)[self removeLifecycleForSides:sides];
        return NO;
    }
    return YES;
}

- (BOOL)removeSide:(CoreSetLocalHostSide *)side {
    if (!side) return YES;
    UIApplication *application = UIApplication.sharedApplication;
    id associated = side.associationKey
        ? objc_getAssociatedObject(application, side.associationKey) : nil;
    if (associated && associated != side.controller) return NO;
    id controller = associated ?: side.controller;
    @try {
        SEL selector = NSSelectorFromString(@"unregisterWindowWithContextID:");
        NSInvocation *invocation = CSHostingInvocation(controller, selector,
                                                       side.context, nullptr);
        if (side.registered && !invocation) return NO;
        if (invocation) [invocation invoke];
        if (side.associationKey)
            objc_setAssociatedObject(application, side.associationKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } @catch (__unused NSException *exception) {
        return NO;
    }
    if (side.associationKey && objc_getAssociatedObject(application, side.associationKey))
        return NO;
    side.controller = nil; side.registered = NO; side.source = nil; side.context = 0;
    return YES;
}

- (void)registerThreeSurfacesAsync:(UIWindow *)menuWindow iconWindow:(UIWindow *)iconWindow
                         drawWindow:(UIWindow *)drawWindow
                         completion:(void (^)(BOOL, uint64_t))completion {
    if (!completion) return;
    const uint64_t generation = _hostGeneration;
    if (!NSThread.isMainThread || _busy || _draw || _icon || _menu || !generation ||
        !drawWindow || !iconWindow || !menuWindow || !self.sessionIdentityReady) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, generation); });
        return;
    }
    CoreSetLocalHostSide *draw = [CoreSetLocalHostSide new];
    CoreSetLocalHostSide *icon = [CoreSetLocalHostSide new];
    CoreSetLocalHostSide *menu = [CoreSetLocalHostSide new];
    [CATransaction flush];
    draw.source = drawWindow; draw.context = CSContext(drawWindow); draw.level = kCoreSetDrawLevel;
    draw.role = @"darkswordOverlayDrawHostController";
    draw.associationKey = NSSelectorFromString(@"darkswordOverlayDrawHostController");
    draw.lockInvocationKey = NSSelectorFromString(@"darkswordOverlayDrawLockInvocation");
    draw.unlockInvocationKey = NSSelectorFromString(@"darkswordOverlayDrawUnlockInvocation");
    icon.source = iconWindow; icon.context = CSContext(iconWindow); icon.level = kCoreSetIconLevel;
    icon.role = @"darkswordOverlayIconHostController";
    icon.associationKey = NSSelectorFromString(@"darkswordOverlayIconHostController");
    icon.lockInvocationKey = NSSelectorFromString(@"darkswordOverlayIconLockInvocation");
    icon.unlockInvocationKey = NSSelectorFromString(@"darkswordOverlayIconUnlockInvocation");
    menu.source = menuWindow; menu.context = CSContext(menuWindow); menu.level = kCoreSetMenuLevel;
    menu.role = @"darkswordOverlayMenuHostController";
    menu.associationKey = NSSelectorFromString(@"darkswordOverlayMenuHostController");
    menu.lockInvocationKey = NSSelectorFromString(@"darkswordOverlayMenuLockInvocation");
    menu.unlockInvocationKey = NSSelectorFromString(@"darkswordOverlayMenuUnlockInvocation");
    NSLog(@"Core-SET: core17-local-sbs build=%@ stage=context-capture draw=%u icon=%u menu=%u",
          CSHostBuildMarker, draw.context, icon.context, menu.context);
    if (!draw.context || !icon.context || !menu.context || draw.context == icon.context ||
        draw.context == menu.context || icon.context == menu.context) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, generation); });
        return;
    }
    _draw = draw; _icon = icon; _menu = menu; _busy = YES;
    const BOOL drawReady = [self registerSide:draw];
    const BOOL iconReady = drawReady && [self registerSide:icon];
    const BOOL menuReady = iconReady && [self registerSide:menu];
    NSArray *sides = @[draw, icon, menu];
    const BOOL lifecycleReady = drawReady && iconReady && menuReady &&
        [self installLifecycleForSides:sides];
    _busy = NO;
    const BOOL ready = lifecycleReady && self.localSurfacesStillPublished;
    if (!ready) {
        _busy = YES;
        (void)[self removeLifecycleForSides:sides];
        (void)[self removeSide:draw];
        (void)[self removeSide:icon];
        (void)[self removeSide:menu];
        _draw = nil; _icon = nil; _menu = nil; _busy = NO;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ completion(ready, generation); });
}

- (void)unregisterThreeSurfacesAsync:(UIWindow *)menuWindow iconWindow:(UIWindow *)iconWindow
                           drawWindow:(UIWindow *)drawWindow
                           completion:(void (^)(BOOL, BOOL, BOOL))completion {
    if (!completion) return;
    if (!NSThread.isMainThread || _busy || (_draw.source && _draw.source != drawWindow) ||
        (_icon.source && _icon.source != iconWindow) || (_menu.source && _menu.source != menuWindow)) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, NO, NO); });
        return;
    }
    _busy = YES;
    CoreSetLocalHostSide *draw = _draw;
    CoreSetLocalHostSide *icon = _icon;
    CoreSetLocalHostSide *menu = _menu;
    NSMutableArray *sides = [NSMutableArray arrayWithCapacity:3];
    if (draw) [sides addObject:draw];
    if (icon) [sides addObject:icon];
    if (menu) [sides addObject:menu];
    const BOOL lifecycleRemoved = [self removeLifecycleForSides:sides];
    const BOOL drawRemoved = lifecycleRemoved && [self removeSide:draw];
    const BOOL iconRemoved = lifecycleRemoved && [self removeSide:icon];
    const BOOL menuRemoved = lifecycleRemoved && [self removeSide:menu];
    if (drawRemoved) _draw = nil;
    if (iconRemoved) _icon = nil;
    if (menuRemoved) _menu = nil;
    _busy = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(menuRemoved, iconRemoved, drawRemoved);
    });
}
@end
