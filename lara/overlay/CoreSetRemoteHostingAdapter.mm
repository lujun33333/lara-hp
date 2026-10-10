#import "CoreSetRemoteHostingAdapter.h"
#import "../kexploit/TaskRop/RemoteCall.h"
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>
#include <atomic>
#include <cmath>
#include <cstring>

static NSString *const CSHostBuildMarker = @"core17-sbs-only-v3";

static BOOL CSChecked(RemoteCall *process, const char *label, void *function,
                      const uint64_t *arguments, NSUInteger count, uint64_t *value) {
    if (!process || !function || !label || count > 8 || (count && !arguments)) return NO;
    uint64_t slots[8] = {};
    if (count) memcpy(slots, arguments, count * sizeof(uint64_t));
    RemoteCallResult *result = [process doRemoteCallCheckedWithTimeout:10000
        functionName:label functionPointer:function args:slots argCount:count];
    if (!result || result.status != RemoteCallCompletionStatusCompleted ||
        !result.returnValueValid) return NO;
    if (value) *value = result.value;
    return YES;
}

static BOOL CSMessage(RemoteCall *process, uint64_t object, uint64_t selector,
                      uint64_t a0, uint64_t a1, uint64_t *value) {
    if (!object || !selector) return NO;
    const uint64_t args[] = {object, selector, a0, a1};
    return CSChecked(process, "objc_msgSend", (void *)objc_msgSend, args, 4, value);
}

static uint64_t CSClass(RemoteCall *process, const char *name) {
    return process && name ? remote_getClass(process, name) : 0;
}

static uint64_t CSSel(RemoteCall *process, const char *name) {
    return process && name ? remote_sel(process, name) : 0;
}

static BOOL CSMainInvocation(RemoteCall *process, uint64_t target, uint64_t selector,
                             const void *argument0, size_t length0,
                             const void *argument1, size_t length1,
                             uint64_t *result) {
    if (!process || !target || !selector || length0 > 0x100 || length1 > 0x100 ||
        process.trojanMem == 0 || process.trojanMemIsStackFallback) return NO;
    uint64_t signature = 0, invocation = 0, value = 0;
    const uint64_t cls = CSClass(process, "NSInvocation");
    const uint64_t signatureSelector = CSSel(process, "methodSignatureForSelector:");
    const uint64_t createSelector = CSSel(process, "invocationWithMethodSignature:");
    const uint64_t setTarget = CSSel(process, "setTarget:");
    const uint64_t setSelector = CSSel(process, "setSelector:");
    const uint64_t setArgument = CSSel(process, "setArgument:atIndex:");
    const uint64_t performMain = CSSel(process, "performSelectorOnMainThread:withObject:waitUntilDone:");
    const uint64_t invoke = CSSel(process, "invoke");
    const uint64_t getReturn = CSSel(process, "getReturnValue:");
    if (!cls || !signatureSelector || !createSelector || !setTarget || !setSelector ||
        !setArgument || !performMain || !invoke || !getReturn ||
        !CSMessage(process, target, signatureSelector, selector, 0, &signature) || !signature ||
        !CSMessage(process, cls, createSelector, signature, 0, &invocation) || !invocation ||
        !CSMessage(process, invocation, setTarget, target, 0, nullptr) ||
        !CSMessage(process, invocation, setSelector, selector, 0, nullptr)) return NO;
    if (argument0 && length0) {
        const uint64_t slot = process.trojanMem + 0x800;
        if (![process remote_write:slot from:argument0 size:length0] ||
            !CSMessage(process, invocation, setArgument, slot, 2, nullptr)) return NO;
    }
    if (argument1 && length1) {
        const uint64_t slot = process.trojanMem + 0xa00;
        if (![process remote_write:slot from:argument1 size:length1] ||
            !CSMessage(process, invocation, setArgument, slot, 3, nullptr)) return NO;
    }
    const uint64_t dispatch[] = {invocation, performMain, invoke, 0, 1};
    if (!CSChecked(process, "main-thread invoke", (void *)objc_msgSend,
                   dispatch, 5, nullptr)) return NO;
    if (!result) return YES;
    const uint64_t returnSlot = process.trojanMem + 0xc00;
    uint64_t zero = 0;
    if (![process remote_write:returnSlot from:&zero size:sizeof(zero)] ||
        !CSMessage(process, invocation, getReturn, returnSlot, 0, nullptr) ||
        ![process remoteRead:returnSlot to:&value size:sizeof(value)]) return NO;
    *result = value;
    return YES;
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
        if ([value respondsToSelector:@selector(unsignedIntValue)]) {
            context = [value unsignedIntValue];
        }
    } @catch (__unused NSException *exception) {
        context = 0;
    }
    return context;
}

@interface CoreSetRemoteHostSide : NSObject
@property(nonatomic, weak) UIWindow *source;
@property(nonatomic) uint32_t context;
@property(nonatomic) double level;
@property(nonatomic, copy) NSString *role;
@property(nonatomic) uint64_t controller;
@property(nonatomic) BOOL registered;
@end
@implementation CoreSetRemoteHostSide @end

@implementation CoreSetRemoteHostingAdapter {
    RemoteCall *_process;
    CoreSetRemoteHostSide *_menu;
    CoreSetRemoteHostSide *_icon;
    CoreSetRemoteHostSide *_draw;
    uint64_t _hostGeneration;
    pid_t _pid;
    BOOL _busy;
    dispatch_queue_t _queue;
    std::atomic_bool _cancelled;
}

- (instancetype)initWithRemoteCall:(RemoteCall *)remoteCall {
    if ((self = [super init])) {
        _process = remoteCall;
        _pid = remoteCall.pid;
        _queue = dispatch_queue_create("core-set.v17-sbs-host", DISPATCH_QUEUE_SERIAL);
        _cancelled.store(false);
    }
    return self;
}

- (uint64_t)hostGeneration { return _hostGeneration; }
- (BOOL)cleanupPending { return _busy; }
- (BOOL)sessionIdentityReady {
    return _process && _pid > 0 && _process.pid == _pid && _process.trojanMem != 0 &&
        !_process.trojanMemIsStackFallback;
}
- (NSString *)sessionIdentityFailureReason {
    return self.sessionIdentityReady ? nil : @"SpringBoard RemoteCall session unavailable";
}
- (NSString *)hostingDiagnosticSnapshot {
    return [NSString stringWithFormat:@"mode=core17-springboard-sbs build=%@ pid=%d draw=%d icon=%d menu=%d generation=%llu",
        CSHostBuildMarker, _pid, _draw.registered, _icon.registered, _menu.registered,
        (unsigned long long)_hostGeneration];
}
- (BOOL)localSurfacesStillPublished {
    return NSThread.isMainThread && !_busy && _draw.registered && _icon.registered && _menu.registered &&
        _draw.source && _icon.source && _menu.source &&
        CSContext(_draw.source) == _draw.context &&
        CSContext(_icon.source) == _icon.context &&
        CSContext(_menu.source) == _menu.context;
}
- (void)prepareForHostGeneration:(uint64_t)generation {
    if (NSThread.isMainThread && generation) _hostGeneration = generation;
}

- (BOOL)registerSide:(CoreSetRemoteHostSide *)side {
    if (_cancelled.load() || !self.sessionIdentityReady || !side.context ||
        !std::isfinite(side.level)) return NO;
    const uint64_t cls = CSClass(_process, "SBSAccessibilityWindowHostingController");
    const uint64_t alloc = CSSel(_process, "alloc");
    const uint64_t init = CSSel(_process, "init");
    const uint64_t registerSelector = CSSel(_process, "registerWindowWithContextID:atLevel:");
    NSLog(@"Core-SET: core17-sbs build=%@ stage=remote-class pid=%d role=%@ context=%u class=%llu selector=%llu",
          CSHostBuildMarker, _pid, side.role, side.context, cls, registerSelector);
    uint64_t controller = 0, initialized = 0;
    if (!cls || !alloc || !init || !registerSelector ||
        !CSMessage(_process, cls, alloc, 0, 0, &controller) || !controller ||
        !CSMessage(_process, controller, init, 0, 0, &initialized) || !initialized) return NO;
    side.controller = initialized;
    const uint32_t context = side.context;
    const double level = side.level;
    if (!CSMainInvocation(_process, initialized, registerSelector,
                          &context, sizeof(context),
                          &level, sizeof(level), nullptr)) return NO;
    side.registered = YES;
    NSLog(@"Core-SET: core17-sbs build=%@ stage=remote-registered pid=%d role=%@ context=%u level=%.0f",
          CSHostBuildMarker, _pid, side.role, context, level);
    return YES;
}

- (BOOL)removeSide:(CoreSetRemoteHostSide *)side {
    if (!side || !side.controller) return YES;
    const uint64_t unregisterSelector = CSSel(_process, "unregisterWindowWithContextID:");
    const uint64_t releaseSelector = CSSel(_process, "release");
    const uint32_t context = side.context;
    const BOOL unregistered = !side.registered || (unregisterSelector && context &&
        CSMainInvocation(_process, side.controller, unregisterSelector,
                         &context, sizeof(context), nullptr, 0, nullptr));
    const BOOL released = unregistered && releaseSelector &&
        CSMainInvocation(_process, side.controller, releaseSelector,
                         nullptr, 0, nullptr, 0, nullptr);
    if (released) {
        side.controller = 0;
        side.context = 0;
        side.registered = NO;
        side.source = nil;
    }
    return released;
}

- (void)registerThreeSurfacesAsync:(UIWindow *)menuWindow iconWindow:(UIWindow *)iconWindow
                         drawWindow:(UIWindow *)drawWindow
                         completion:(void (^)(BOOL, uint64_t))completion {
    if (!completion) return;
    const uint64_t generation = _hostGeneration;
    if (!NSThread.isMainThread || _busy || _menu || _icon || _draw || !generation ||
        !menuWindow || !iconWindow || !drawWindow || !self.sessionIdentityReady) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, generation); });
        return;
    }
    CoreSetRemoteHostSide *menu = [CoreSetRemoteHostSide new];
    CoreSetRemoteHostSide *icon = [CoreSetRemoteHostSide new];
    CoreSetRemoteHostSide *draw = [CoreSetRemoteHostSide new];
    [CATransaction flush];
    draw.source = drawWindow; draw.context = CSContext(drawWindow); draw.level = 999998.0;
    draw.role = @"darkswordOverlayDrawHostController";
    icon.source = iconWindow; icon.context = CSContext(iconWindow); icon.level = 1000000.0;
    icon.role = @"darkswordOverlayIconHostController";
    menu.source = menuWindow; menu.context = CSContext(menuWindow); menu.level = 999999.0;
    menu.role = @"darkswordOverlayMenuHostController";
    NSLog(@"Core-SET: core17-sbs build=%@ stage=context-capture draw=%u icon=%u menu=%u",
          CSHostBuildMarker, draw.context, icon.context, menu.context);
    if (!draw.context || !icon.context || !menu.context ||
        draw.context == icon.context || draw.context == menu.context || icon.context == menu.context) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, generation); });
        return;
    }
    _menu = menu; _icon = icon; _draw = draw; _busy = YES; _cancelled.store(false);
    dispatch_async(_queue, ^{
        BOOL ok = NO;
        @synchronized (self->_process) {
            const BOOL drawReady = [self registerSide:draw];
            const BOOL iconReady = drawReady && [self registerSide:icon];
            const BOOL menuReady = iconReady && [self registerSide:menu];
            ok = drawReady && iconReady && menuReady;
            if (!ok) {
                (void)[self removeSide:menu];
                (void)[self removeSide:icon];
                (void)[self removeSide:draw];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_busy = NO;
            const BOOL current = ok && !self->_cancelled.load() &&
                self->_hostGeneration == generation && self->_draw == draw &&
                self->_icon == icon && self->_menu == menu;
            completion(current, generation);
        });
    });
}

- (void)unregisterThreeSurfacesAsync:(UIWindow *)menuWindow iconWindow:(UIWindow *)iconWindow
                           drawWindow:(UIWindow *)drawWindow
                           completion:(void (^)(BOOL, BOOL, BOOL))completion {
    if (!completion) return;
    if (!NSThread.isMainThread || _busy || (_menu.source && _menu.source != menuWindow) ||
        (_icon.source && _icon.source != iconWindow) || (_draw.source && _draw.source != drawWindow)) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, NO, NO); });
        return;
    }
    _busy = YES; _cancelled.store(true);
    CoreSetRemoteHostSide *menu = _menu;
    CoreSetRemoteHostSide *icon = _icon;
    CoreSetRemoteHostSide *draw = _draw;
    dispatch_async(_queue, ^{
        BOOL drawRemoved = NO, iconRemoved = NO, menuRemoved = NO;
        @synchronized (self->_process) {
            drawRemoved = [self removeSide:draw];
            iconRemoved = [self removeSide:icon];
            menuRemoved = [self removeSide:menu];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_busy = NO;
            if (drawRemoved) self->_draw = nil;
            if (iconRemoved) self->_icon = nil;
            if (menuRemoved) self->_menu = nil;
            completion(menuRemoved, iconRemoved, drawRemoved);
        });
    });
}
@end
