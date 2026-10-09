#import "CoreSetRemoteHostingAdapter.h"
#import "../kexploit/TaskRop/RemoteCall.h"
#import "../kexploit/darksword.h"
#import "../kexploit/offsets.h"
#import "../kexploit/utils.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <cstring>
#include <cmath>
#include <cerrno>
#include <atomic>
extern "C" int proc_name(int pid, void *buffer, uint32_t buffersize);
static const double kCoreSetCoreDrawLevel = 999998.0;
static const double kCoreSetCoreMenuLevel = 999999.0;
static const double kCoreSetCoreIconLevel = 1000000.0;
static const double kCoreSetWZRemoteDrawLevel = 10000009.0;
static const double kCoreSetWZRemoteMenuLevel = 10000010.0;
static NSString *const CSHostBuildMarker = @"core-sbs-three-surface-wz-fallback-v4";

static void CSLoadCoreHostingFrameworks(void) {
    // Core 1.7 resolves the hosting class again for every registration attempt.
    // Keep successful handles, but never cache a failed load/class lookup: the
    // private framework graph can become available later in app startup.
    static void *handles[7] = {};
    static const char *const paths[] = {
        "/System/Library/PrivateFrameworks/FrontBoard.framework/FrontBoard",
        "/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices",
        "/System/Library/PrivateFrameworks/RunningBoardServices.framework/RunningBoardServices",
        "/System/Library/PrivateFrameworks/BoardServices.framework/BoardServices",
        "/System/Library/PrivateFrameworks/BaseBoard.framework/BaseBoard",
        "/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities",
        "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
    };
    @synchronized ([NSBundle class]) {
        for (NSUInteger index = 0; index < sizeof(paths) / sizeof(paths[0]); index++) {
            if (!handles[index]) handles[index] = dlopen(paths[index], RTLD_LAZY | RTLD_LOCAL);
        }
    }
}

static Class CSAccessibilityHostingClass(void) {
    Class hostingClass = NSClassFromString(@"SBSAccessibilityWindowHostingController");
    if (hostingClass) return hostingClass;
    CSLoadCoreHostingFrameworks();
    return NSClassFromString(@"SBSAccessibilityWindowHostingController");
}

static NSInvocation *CSCoreHostingInvocation(id target, SEL selector, uint32_t context,
                                             const double *level) {
    if (!target || !selector || ![target respondsToSelector:selector]) return nil;
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    const NSUInteger requiredArguments = level ? 4 : 3;
    if (!signature || signature.numberOfArguments < requiredArguments) return nil;
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = target;
    invocation.selector = selector;
    [invocation setArgument:&context atIndex:2];
    if (level) [invocation setArgument:(void *)level atIndex:3];
    [invocation retainArguments];
    return invocation;
}

static BOOL CSChecked(RemoteCall *process, const char *label, void *function,
                      const uint64_t *arguments, NSUInteger count, uint64_t *value) {
    if (!process || !function || !label || count > 8 || (count && !arguments)) return NO;
    uint64_t slots[8] = {};
    if (count && arguments) memcpy(slots, arguments, count * sizeof(uint64_t));
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
                             const void *argument, size_t length, uint64_t *result) {
    if (!process || !target || !selector || length > 0x100 ||
        process.trojanMem == 0 || process.trojanMemIsStackFallback) return NO;
    uint64_t signature = 0, invocation = 0, value = 0;
    uint64_t cls = CSClass(process, "NSInvocation");
    uint64_t signatureSelector = CSSel(process, "methodSignatureForSelector:");
    uint64_t createSelector = CSSel(process, "invocationWithMethodSignature:");
    uint64_t setTarget = CSSel(process, "setTarget:");
    uint64_t setSelector = CSSel(process, "setSelector:");
    uint64_t setArgument = CSSel(process, "setArgument:atIndex:");
    uint64_t performMain = CSSel(process, "performSelectorOnMainThread:withObject:waitUntilDone:");
    uint64_t invoke = CSSel(process, "invoke");
    uint64_t getReturn = CSSel(process, "getReturnValue:");
    if (!cls || !signatureSelector || !createSelector || !setTarget ||
        !setSelector || !setArgument || !performMain || !invoke || !getReturn ||
        !CSMessage(process, target, signatureSelector, selector, 0, &signature) || !signature ||
        !CSMessage(process, cls, createSelector, signature, 0, &invocation) || !invocation ||
        !CSMessage(process, invocation, setTarget, target, 0, nullptr) ||
        !CSMessage(process, invocation, setSelector, selector, 0, nullptr)) return NO;
    if (argument && length) {
        const uint64_t slot = process.trojanMem + 0x800;
        if (![process remote_write:slot from:argument size:length] ||
            !CSMessage(process, invocation, setArgument, slot, 2, nullptr)) return NO;
    }
    // objc_msgSend has 5 arguments here: waitUntilDone must be YES.
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

@interface CoreSetRemoteHostSide : NSObject
@property(nonatomic, weak) UIWindow *source;
@property(nonatomic) uint32_t context;
@property(nonatomic) CGRect sourceFrame;
@property(nonatomic, weak) UIWindowScene *sourceScene;
@property(nonatomic) uint64_t window;
@property(nonatomic) uint64_t layer;
@property(nonatomic) uint64_t windowLayer;
@property(nonatomic) uint64_t scene;
@property(nonatomic) BOOL windowInitialized;
@property(nonatomic) BOOL layerInitialized;
@property(nonatomic) BOOL cleanupAmbiguous;
@property(nonatomic) BOOL observed;
@property(nonatomic, strong) id coreHostingController;
@property(nonatomic) SEL associationKey;
@property(nonatomic) SEL lockInvocationKey;
@property(nonatomic) SEL unlockInvocationKey;
@property(nonatomic, copy) NSString *role;
@property(nonatomic, copy) NSString *lastReadbackStep;
@end
@implementation CoreSetRemoteHostSide @end

@interface CoreSetRemoteHostingAdapter ()
- (BOOL)localSideObserved:(CoreSetRemoteHostSide *)side;
- (BOOL)remoteSideObserved:(CoreSetRemoteHostSide *)side;
- (BOOL)removeCoreLifecycleForSides:(NSArray<CoreSetRemoteHostSide *> *)sides;
- (BOOL)installCoreLifecycleForDraw:(CoreSetRemoteHostSide *)draw
                               icon:(CoreSetRemoteHostSide *)icon
                               menu:(CoreSetRemoteHostSide *)menu;
@end

@implementation CoreSetRemoteHostingAdapter {
    RemoteCall *_process;
    CoreSetRemoteHostSide *_menu;
    CoreSetRemoteHostSide *_icon;
    CoreSetRemoteHostSide *_draw;
    uint64_t _hostGeneration;
    uint64_t _pendingHostGeneration;
    pid_t _pid;
    BOOL _busy;
    BOOL _registrationInFlight;
    BOOL _loggedKernelNameFallback;
    uint64_t _observationSequence;
    BOOL _lastIdentityObserved;
    BOOL _lastBothObserved;
    dispatch_queue_t _readbackQueue;
    std::atomic_bool _registerCancelled;
    dispatch_block_t _deferredCleanup;
    BOOL _coreHosting;
}
+ (BOOL)isCoreHostingAvailable {
    Class cls = CSAccessibilityHostingClass();
    const BOOL selectorAvailable = cls && [cls instancesRespondToSelector:
        NSSelectorFromString(@"registerWindowWithContextID:atLevel:")];
    static std::atomic_int previousProbe{-1};
    const int probe = (cls ? 1 : 0) | (selectorAvailable ? 2 : 0);
    if (previousProbe.exchange(probe) != probe) {
        NSLog(@"Core-SET: core-sbs probe build=%@ class=%d selector=%d",
              CSHostBuildMarker, cls ? 1 : 0, selectorAvailable ? 1 : 0);
    }
    return selectorAvailable;
}
- (instancetype)initWithCoreHosting:(BOOL)coreHosting {
    if (!coreHosting || ![CoreSetRemoteHostingAdapter isCoreHostingAvailable]) return nil;
    if ((self = [super init])) {
        _coreHosting = YES;
        _readbackQueue = dispatch_queue_create("core-set.core-hosting-observation", DISPATCH_QUEUE_SERIAL);
        _registerCancelled.store(false);
    }
    return self;
}
- (instancetype)initWithRemoteCall:(RemoteCall *)remoteCall {
    if ((self = [super init])) {
        _process = remoteCall; _pid = remoteCall.pid;
        _readbackQueue = dispatch_queue_create("core-set.remote-readback", DISPATCH_QUEUE_SERIAL);
        _registerCancelled.store(false);
    }
    return self;
}
- (uint64_t)hostGeneration { return _hostGeneration; }
- (BOOL)requiresDedicatedIconSurface { return _coreHosting; }
- (NSString *)hostingDiagnosticSnapshot {
    // Called from scene lifecycle on the main thread. Never wait for the
    // remote worker's process lock merely to print a diagnostic.
    if (_busy) return @"remote-operation-pending";
    return [NSString stringWithFormat:
        @"build=%@ mode=%@ cachedObserved=%d menuPublished=%d iconPublished=%d drawPublished=%d hostGeneration=%llu",
        CSHostBuildMarker, _coreHosting ? @"core-sbs" : @"wz-remote", _lastBothObserved,
        _menu.observed, _icon.observed, _draw.observed,
        (unsigned long long)_hostGeneration];
}
- (BOOL)sessionIdentityReady { return self.sessionIdentityFailureReason == nil; }
- (BOOL)cleanupPending {
    // Main-owned registration state only; the remote worker can hold the
    // process lock across multiple timed calls.
    return _busy || (_menu && !_menu.observed) || (_icon && !_icon.observed) ||
        (_draw && !_draw.observed);
}
- (BOOL)localSurfacesStillPublished {
    return NSThread.isMainThread && !_busy && _lastBothObserved &&
        (_coreHosting || (_process && _process.pid == _pid && _process.trojanMem != 0 &&
        !_process.trojanMemIsStackFallback)) &&
        _menu.observed && (!_coreHosting || _icon.observed) && _draw.observed &&
        [self localSideObserved:_menu] && (!_coreHosting || [self localSideObserved:_icon]) &&
        [self localSideObserved:_draw];
}
- (void)prepareForHostGeneration:(uint64_t)generation {
    if (!NSThread.isMainThread || _busy || !generation) return;
    if (!_menu && !_icon && !_draw) {
        _hostGeneration = generation; _pendingHostGeneration = 0;
        return;
    }
    if (self.localSurfacesStillPublished) {
        _hostGeneration = generation; _pendingHostGeneration = 0;
    } else {
        // The host requests an async readback after its own generation changes.
        // Until it completes, the adapter's old generation fails closed.
        _pendingHostGeneration = generation;
    }
}
- (NSString * _Nullable)sessionIdentityFailureReason {
    if (_coreHosting) {
        return [CoreSetRemoteHostingAdapter isCoreHostingAvailable]
            ? nil : @"SBSAccessibilityWindowHostingController 不可用";
    }
    if (!_process) return @"RemoteCall 会话缺失";
    NSMutableArray<NSString *> *failures = [NSMutableArray array];
    const pid_t currentPid = _process.pid;
    if (_pid <= 0) [failures addObject:[NSString stringWithFormat:@"初始 RemoteCall.pid=%d", _pid]];
    if (currentPid != _pid) {
        [failures addObject:[NSString stringWithFormat:@"RemoteCall.pid 已变化：%d→%d", _pid, currentPid]];
    }
    if (_process.trojanMem == 0) [failures addObject:@"RemoteCall.trojanMem=0"];
    if (_process.trojanMemIsStackFallback) {
        [failures addObject:@"RemoteCall.stackFallback=1（当前托管路径不支持）"];
    }
    if (_pid > 0) {
        char name[256] = {};
        errno = 0;
        const int length = proc_name(_pid, name, sizeof(name));
        const int nameError = errno;
        name[sizeof(name) - 1] = '\0';
        if (length <= 0) {
            // proc_name may be unavailable to a sandboxed app even after the
            // RemoteCall target has been found through the kernel proc list.
            // Recheck that list and its PID instead of dropping the identity gate.
            const uint64_t kernelProc = ds_is_ready() && off_proc_p_pid
                ? proc_find_by_name("SpringBoard") : 0;
            const int kernelPid = kernelProc
                ? (int32_t)ds_kread32(kernelProc + off_proc_p_pid) : 0;
            if (!kernelProc || kernelPid != _pid) {
                [failures addObject:[NSString stringWithFormat:
                    @"proc_name(pid=%d)=%d errno=%d；内核 SpringBoard.pid=%d",
                    _pid, length, nameError, kernelPid]];
            } else if (!_loggedKernelNameFallback) {
                _loggedKernelNameFallback = YES;
                NSLog(@"Core-SET: SpringBoard identity source=kernel proc list pid=%d; proc_name=%d errno=%d",
                      _pid, length, nameError);
            }
        } else if (strcmp(name, "SpringBoard") != 0) {
            [failures addObject:[NSString stringWithFormat:@"proc_name(pid=%d)=%s，预期 SpringBoard",
                                 _pid, name]];
        }
    }
    return failures.count ? [failures componentsJoinedByString:@"；"] : nil;
}
- (BOOL)identityValid { return self.sessionIdentityFailureReason == nil; }
- (BOOL)localSideObserved:(CoreSetRemoteHostSide *)side {
    if (!side || !side.source || !side.context || !side.sourceScene ||
        (!_coreHosting && (!side.window || !side.layer || !side.windowLayer || !side.scene))) {
        side.lastReadbackStep = @"local-handle-missing";
        return NO;
    }
    SEL contextSelector = NSSelectorFromString(@"_contextId");
    uint32_t current = [side.source respondsToSelector:contextSelector]
        ? ((uint32_t (*)(id, SEL))objc_msgSend)(side.source, contextSelector) : 0;
    CGRect localFrame = CGRectStandardize(side.source.bounds);
    localFrame.origin = CGPointZero;
    if (current != side.context || side.source.windowScene != side.sourceScene ||
        !CGRectEqualToRect(localFrame, side.sourceFrame)) {
        side.lastReadbackStep = @"local-context"; return NO;
    }
    return YES;
}
- (BOOL)remoteSideObserved:(CoreSetRemoteHostSide *)side {
    if (_coreHosting) {
        id retained = side.associationKey
            ? objc_getAssociatedObject(UIApplication.sharedApplication, side.associationKey) : nil;
        if (!side.coreHostingController || retained != side.coreHostingController ||
            ![self localSideObserved:side]) {
            side.lastReadbackStep = @"core-sbs-context";
            return NO;
        }
        side.lastReadbackStep = @"ok";
        return YES;
    }
    uint64_t remoteScene = 0, remoteLayer = 0, remoteContext = 0;
    uint64_t parent = 0, hidden = 1;
    if (!CSMessage(_process, side.window, CSSel(_process, "windowScene"), 0, 0, &remoteScene)) {
        side.lastReadbackStep = @"remote-scene-call"; return NO;
    }
    if (!CSMessage(_process, side.window, CSSel(_process, "layer"), 0, 0, &remoteLayer)) {
        side.lastReadbackStep = @"remote-window-layer-call"; return NO;
    }
    if (!CSMessage(_process, side.layer, CSSel(_process, "contextId"), 0, 0, &remoteContext)) {
        side.lastReadbackStep = @"remote-context-call"; return NO;
    }
    if (!CSMessage(_process, side.layer, CSSel(_process, "superlayer"), 0, 0, &parent)) {
        side.lastReadbackStep = @"remote-parent-call"; return NO;
    }
    if (!CSMessage(_process, side.window, CSSel(_process, "isHidden"), 0, 0, &hidden)) {
        side.lastReadbackStep = @"remote-hidden-call"; return NO;
    }
    if (remoteScene != side.scene) { side.lastReadbackStep = @"remote-scene-mismatch"; return NO; }
    if (remoteLayer != side.windowLayer) { side.lastReadbackStep = @"remote-window-layer-mismatch"; return NO; }
    if (remoteContext != side.context) { side.lastReadbackStep = @"remote-context-mismatch"; return NO; }
    if (parent != side.windowLayer) { side.lastReadbackStep = @"remote-parent-mismatch"; return NO; }
    if ((hidden & 0xff) != 0) { side.lastReadbackStep = @"remote-hidden"; return NO; }
    side.lastReadbackStep = @"ok";
    return YES;
}
- (BOOL)removeCoreLifecycleForSides:(NSArray<CoreSetRemoteHostSide *> *)sides {
    if (!_coreHosting) return YES;
    UIApplication *application = UIApplication.sharedApplication;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    @try {
        // Core 1.7 removes draw/icon/menu lock observers first, followed by
        // draw/icon/menu unlock observers.
        for (NSUInteger phase = 0; phase < 2; phase++) {
            for (CoreSetRemoteHostSide *side in sides) {
                SEL key = phase == 0 ? side.lockInvocationKey : side.unlockInvocationKey;
                if (!key) continue;
                id invocation = objc_getAssociatedObject(application, key);
                if (invocation) [center removeObserver:invocation];
                objc_setAssociatedObject(application, key, nil,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                if (objc_getAssociatedObject(application, key)) return NO;
            }
        }
    } @catch (__unused NSException *exception) {
        return NO;
    }
    return YES;
}
- (BOOL)installCoreLifecycleForDraw:(CoreSetRemoteHostSide *)draw
                               icon:(CoreSetRemoteHostSide *)icon
                               menu:(CoreSetRemoteHostSide *)menu {
    if (!_coreHosting || !draw || !icon || !menu) return NO;
    NSArray<CoreSetRemoteHostSide *> *sides = @[draw, icon, menu];
    const double levels[] = {kCoreSetCoreDrawLevel, kCoreSetCoreIconLevel,
                             kCoreSetCoreMenuLevel};
    SEL unregisterSelector = NSSelectorFromString(@"unregisterWindowWithContextID:");
    SEL registerSelector = NSSelectorFromString(@"registerWindowWithContextID:atLevel:");
    SEL invokeSelector = NSSelectorFromString(@"invoke");
    UIApplication *application = UIApplication.sharedApplication;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    NSMutableArray<NSInvocation *> *locks = [NSMutableArray arrayWithCapacity:3];
    NSMutableArray<NSInvocation *> *unlocks = [NSMutableArray arrayWithCapacity:3];
    if (![self removeCoreLifecycleForSides:sides]) return NO;
    BOOL ready = YES;
    @try {
        for (NSUInteger index = 0; index < sides.count; index++) {
            CoreSetRemoteHostSide *side = sides[index];
            if (!side.context || !side.coreHostingController || !side.lockInvocationKey ||
                !side.unlockInvocationKey) { ready = NO; break; }
            NSInvocation *lock = CSCoreHostingInvocation(side.coreHostingController,
                unregisterSelector, side.context, nullptr);
            NSInvocation *unlock = CSCoreHostingInvocation(side.coreHostingController,
                registerSelector, side.context, &levels[index]);
            if (!lock || !unlock) { ready = NO; break; }
            objc_setAssociatedObject(application, side.lockInvocationKey, lock,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(application, side.unlockInvocationKey, unlock,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (objc_getAssociatedObject(application, side.lockInvocationKey) != lock ||
                objc_getAssociatedObject(application, side.unlockInvocationKey) != unlock) {
                ready = NO; break;
            }
            [locks addObject:lock];
            [unlocks addObject:unlock];
        }
        if (ready) {
            for (NSInvocation *invocation in locks) {
                [center addObserver:invocation selector:invokeSelector
                               name:UIApplicationProtectedDataWillBecomeUnavailable object:nil];
            }
            for (NSInvocation *invocation in unlocks) {
                [center addObserver:invocation selector:invokeSelector
                               name:UIApplicationProtectedDataDidBecomeAvailable object:nil];
            }
        }
    } @catch (__unused NSException *exception) {
        ready = NO;
    }
    if (!ready) (void)[self removeCoreLifecycleForSides:sides];
    return ready;
}
- (void)observeBothSurfacesAsync:(void (^)(BOOL, uint64_t))completion {
    if (!completion) return;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, 0); });
        return;
    }
    const uint64_t generation = _pendingHostGeneration ? _pendingHostGeneration : _hostGeneration;
    CoreSetRemoteHostSide *menu = _menu;
    CoreSetRemoteHostSide *icon = _icon;
    CoreSetRemoteHostSide *draw = _draw;
    const BOOL localReady = !_busy && generation && menu.observed && draw.observed &&
        (!_coreHosting || icon.observed) && [self localSideObserved:menu] &&
        (!_coreHosting || [self localSideObserved:icon]) && [self localSideObserved:draw];
    if (!localReady) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, generation); });
        return;
    }
    if (_coreHosting) {
        _observationSequence++;
        _lastIdentityObserved = [self identityValid];
        const BOOL observed = _lastIdentityObserved &&
            [self remoteSideObserved:menu] && [self remoteSideObserved:icon] &&
            [self remoteSideObserved:draw];
        const BOOL current = !_busy &&
            (_hostGeneration == generation || _pendingHostGeneration == generation) &&
            _menu == menu && _icon == icon && _draw == draw && menu.observed &&
            icon.observed && draw.observed;
        if (observed && current && _pendingHostGeneration == generation) {
            _hostGeneration = generation;
            _pendingHostGeneration = 0;
        }
        _lastBothObserved = observed && current;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(observed && current, generation); });
        return;
    }
    dispatch_async(_readbackQueue, ^{
        BOOL observed = NO;
        @synchronized (self->_process) {
            self->_observationSequence++;
            self->_lastIdentityObserved = [self identityValid];
            observed = self->_lastIdentityObserved &&
                [self remoteSideObserved:menu] && [self remoteSideObserved:draw];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            const BOOL current = !self->_busy &&
                (self->_hostGeneration == generation || self->_pendingHostGeneration == generation) &&
                self->_menu == menu && self->_draw == draw &&
                menu.observed && draw.observed &&
                [self localSideObserved:menu] && [self localSideObserved:draw];
            if (observed && current && self->_pendingHostGeneration == generation) {
                self->_hostGeneration = generation;
                self->_pendingHostGeneration = 0;
            }
            self->_lastBothObserved = observed && current;
            completion(observed && current, generation);
        });
    });
}
- (BOOL)removeSide:(CoreSetRemoteHostSide *)side {
    if (!side) return YES;
    if (_coreHosting) {
        UIApplication *application = UIApplication.sharedApplication;
        id associatedController = side.associationKey
            ? objc_getAssociatedObject(application, side.associationKey) : nil;
        if (associatedController && associatedController != side.coreHostingController) {
            side.lastReadbackStep = @"association-mismatch";
            return NO;
        }
        id controller = associatedController ?: side.coreHostingController;
        @try {
            SEL unregisterSelector = NSSelectorFromString(@"unregisterWindowWithContextID:");
            if (controller && side.context && [controller respondsToSelector:unregisterSelector]) {
                ((void (*)(id, SEL, uint32_t))objc_msgSend)(controller, unregisterSelector,
                                                            side.context);
            }
            if (side.associationKey) {
                objc_setAssociatedObject(application, side.associationKey, nil,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        } @catch (__unused NSException *exception) {
            side.lastReadbackStep = @"unregister-exception";
            return NO;
        }
        if (side.associationKey && objc_getAssociatedObject(application, side.associationKey)) {
            side.lastReadbackStep = @"association-retained";
            return NO;
        }
        side.coreHostingController = nil;
        side.observed = NO;
        side.lastReadbackStep = @"released";
        return YES;
    }
    if (![self identityValid] || side.cleanupAmbiguous) return NO;
    BOOL hidden = YES;
    uint64_t parent = UINT64_MAX, observedHidden = 0;
    const BOOL calls = (!side.layerInitialized || CSMainInvocation(_process, side.layer,
        CSSel(_process, "removeFromSuperlayer"), nullptr, 0, nullptr)) &&
        (!side.windowInitialized || CSMainInvocation(_process, side.window,
        CSSel(_process, "setHidden:"), &hidden, sizeof(hidden), nullptr));
    if (!calls) return NO;
    if (side.layerInitialized && (!CSMessage(_process, side.layer, CSSel(_process, "superlayer"),
                                  0, 0, &parent) || parent != 0)) return NO;
    if (side.windowInitialized && (!CSMessage(_process, side.window, CSSel(_process, "isHidden"),
                                   0, 0, &observedHidden) || (observedHidden & 0xff) != 1)) return NO;
    if (side.layer) {
        if (!CSMessage(_process, side.layer, CSSel(_process, "release"), 0, 0, nullptr)) {
            side.cleanupAmbiguous = YES; return NO;
        }
        side.layer = 0; side.layerInitialized = NO;
    }
    if (side.window) {
        if (!CSMessage(_process, side.window, CSSel(_process, "release"), 0, 0, nullptr)) {
            side.cleanupAmbiguous = YES; return NO;
        }
        side.window = 0; side.windowInitialized = NO;
    }
    return YES;
}
- (BOOL)createSide:(CoreSetRemoteHostSide *)side level:(double)level {
    if (![self identityValid] || !side.context ||
        !std::isfinite(level)) return NO;
    if (_coreHosting) {
        Class cls = CSAccessibilityHostingClass();
        SEL selector = NSSelectorFromString(@"registerWindowWithContextID:atLevel:");
        id controller = [[cls alloc] init];
        if (!controller || !side.associationKey || ![controller respondsToSelector:selector]) return NO;
        // Retain before the private call so an exception/partial registration
        // can still be retried through the normal teardown path.
        side.coreHostingController = controller;
        @try {
            ((void (*)(id, SEL, uint32_t, double))objc_msgSend)(controller, selector,
                                                                side.context, level);
            objc_setAssociatedObject(UIApplication.sharedApplication, side.associationKey,
                                     controller, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } @catch (__unused NSException *exception) {
            side.lastReadbackStep = @"register-exception";
            return NO;
        }
        if (objc_getAssociatedObject(UIApplication.sharedApplication, side.associationKey) != controller) {
            side.lastReadbackStep = @"association-readback";
            return NO;
        }
        side.observed = [self remoteSideObserved:side];
        return side.observed;
    }
    // Resolve teardown selectors while the app is fully active. RemoteCall
    // caches nonzero selectors, so termination never has to allocate selector
    // strings in SpringBoard merely to remove these two surfaces.
    for (const char *name : {"removeFromSuperlayer", "setHidden:",
                             "superlayer", "isHidden", "release"}) {
        if (!CSSel(_process, name)) return NO;
    }
    uint64_t workspace = 0, scene = 0, clsWindow = CSClass(_process, "UIWindow");
    uint64_t clsHost = CSClass(_process, "CALayerHost");
    uint64_t clsWorkspace = CSClass(_process, "SBMainWorkspace");
    uint64_t clsColor = CSClass(_process, "UIColor");
    if (!clsWindow || !clsHost || !clsWorkspace || !clsColor ||
        !CSMainInvocation(_process, clsWorkspace, CSSel(_process, "sharedInstance"),
                          nullptr, 0, &workspace) || !workspace ||
        !CSMainInvocation(_process, workspace, CSSel(_process, "mainWindowScene"),
                          nullptr, 0, &scene) || !scene) return NO;
    side.scene = scene;
    uint64_t windowAllocation = 0, layerAllocation = 0;
    if (!CSMessage(_process, clsWindow, CSSel(_process, "alloc"), 0, 0, &windowAllocation) ||
        !windowAllocation) return NO;
    side.window = windowAllocation;
    if (!CSMessage(_process, clsHost, CSSel(_process, "alloc"), 0, 0, &layerAllocation) ||
        !layerAllocation) return NO;
    side.layer = layerAllocation;
    uint64_t initialized = 0;
    if (!CSMainInvocation(_process, side.window, CSSel(_process, "init"),
                          nullptr, 0, &initialized)) {
        side.cleanupAmbiguous = YES; return NO;
    }
    if (!initialized) { side.cleanupAmbiguous = YES; return NO; }
    side.window = initialized;
    side.windowInitialized = YES;
    initialized = 0;
    if (!CSMainInvocation(_process, side.layer, CSSel(_process, "init"),
                          nullptr, 0, &initialized)) {
        side.cleanupAmbiguous = YES; return NO;
    }
    if (!initialized) { side.cleanupAmbiguous = YES; return NO; }
    side.layer = initialized;
    side.layerInitialized = YES;
    CGRect frame = side.sourceFrame;
    frame.origin = CGPointZero;
    if (!(frame.size.width > 0 && frame.size.height > 0)) return NO;
    BOOL disabled = NO;
    uint64_t clearColor = 0;
    uint64_t windowLayer = 0;
    const uint32_t context = side.context;
    const uint64_t layer = side.layer;
    if (!CSMainInvocation(_process, clsColor, CSSel(_process, "clearColor"),
                          nullptr, 0, &clearColor) || !clearColor ||
        !CSMainInvocation(_process, side.window, CSSel(_process, "setWindowScene:"),
                          &scene, sizeof(scene), nullptr) ||
        !CSMainInvocation(_process, side.window, CSSel(_process, "setFrame:"),
                          &frame, sizeof(frame), nullptr) ||
        !CSMainInvocation(_process, side.window, CSSel(_process, "setWindowLevel:"),
                          &level, sizeof(level), nullptr) ||
        !CSMainInvocation(_process, side.window, CSSel(_process, "setUserInteractionEnabled:"),
                          &disabled, sizeof(disabled), nullptr) ||
        !CSMainInvocation(_process, side.window, CSSel(_process, "setOpaque:"),
                          &disabled, sizeof(disabled), nullptr) ||
        !CSMainInvocation(_process, side.window, CSSel(_process, "setBackgroundColor:"),
                          &clearColor, sizeof(clearColor), nullptr) ||
        !CSMainInvocation(_process, side.window, CSSel(_process, "layer"),
                          nullptr, 0, &windowLayer) || !windowLayer) return NO;
    side.windowLayer = windowLayer;
    if (
        !CSMainInvocation(_process, side.layer, CSSel(_process, "setFrame:"),
                          &frame, sizeof(frame), nullptr) ||
        !CSMainInvocation(_process, side.layer, CSSel(_process, "setContextId:"),
                          &context, sizeof(context), nullptr) ||
        !CSMainInvocation(_process, side.windowLayer, CSSel(_process, "addSublayer:"),
                          &layer, sizeof(layer), nullptr) ||
        !CSMainInvocation(_process, side.window, CSSel(_process, "setHidden:"),
                          &disabled, sizeof(disabled), nullptr) ||
        !CSMainInvocation(_process, CSClass(_process, "CATransaction"),
                          CSSel(_process, "flush"), nullptr, 0, nullptr)) return NO;
    side.observed = [self remoteSideObserved:side];
    return side.observed;
}
- (void)registerBothSurfacesAsync:(UIWindow *)menuWindow drawWindow:(UIWindow *)drawWindow
                         completion:(void (^)(BOOL, uint64_t))completion {
    if (!completion) return;
    const uint64_t generation = _hostGeneration;
    if (_coreHosting || !NSThread.isMainThread || _busy || _menu || _icon || _draw || !generation ||
        !menuWindow || !drawWindow || ![self identityValid] ||
        !menuWindow.windowScene || menuWindow.windowScene != drawWindow.windowScene) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, generation); });
        return;
    }
    SEL selector = NSSelectorFromString(@"_contextId");
    const uint32_t menuContext = [menuWindow respondsToSelector:selector]
        ? ((uint32_t (*)(id, SEL))objc_msgSend)(menuWindow, selector) : 0;
    const uint32_t drawContext = [drawWindow respondsToSelector:selector]
        ? ((uint32_t (*)(id, SEL))objc_msgSend)(drawWindow, selector) : 0;
    CGRect menuFrame = CGRectStandardize(menuWindow.bounds);
    CGRect drawFrame = CGRectStandardize(drawWindow.bounds);
    menuFrame.origin = CGPointZero; drawFrame.origin = CGPointZero;
    if (!menuContext || !drawContext || menuContext == drawContext ||
        !std::isfinite(menuFrame.size.width) || !std::isfinite(menuFrame.size.height) ||
        menuFrame.size.width <= 0 || menuFrame.size.height <= 0 ||
        !CGRectEqualToRect(menuFrame, drawFrame)) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, generation); });
        return;
    }
    UIWindowScene *scene = menuWindow.windowScene;
    CoreSetRemoteHostSide *menu = [CoreSetRemoteHostSide new];
    CoreSetRemoteHostSide *draw = [CoreSetRemoteHostSide new];
    menu.source = menuWindow; menu.context = menuContext;
    menu.sourceFrame = menuFrame; menu.sourceScene = scene;
    draw.source = drawWindow; draw.context = drawContext;
    draw.sourceFrame = drawFrame; draw.sourceScene = scene;
    _menu = menu; _draw = draw; _busy = YES; _registrationInFlight = YES;
    _lastBothObserved = NO;
    _registerCancelled.store(false);
    // The block strongly retains both source windows while the worker uses
    // only immutable context/frame snapshots and SpringBoard RemoteCall.
    dispatch_async(_readbackQueue, ^{
        BOOL menuReady = NO, drawReady = NO;
        @synchronized (self->_process) {
            if (!self->_registerCancelled.load())
                menuReady = [self createSide:menu level:kCoreSetWZRemoteMenuLevel];
            if (menuReady && !self->_registerCancelled.load())
                drawReady = [self createSide:draw level:kCoreSetWZRemoteDrawLevel];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            const BOOL current = self->_busy && self->_menu == menu && self->_draw == draw &&
                self->_hostGeneration == generation && self->_process.pid == self->_pid &&
                menuWindow.windowScene == scene && drawWindow.windowScene == scene &&
                !self->_registerCancelled.load() && menuReady && drawReady &&
                [self localSideObserved:menu] && [self localSideObserved:draw];
            self->_busy = NO; self->_registrationInFlight = NO;
            self->_lastBothObserved = current;
            menu.observed = current; draw.observed = current;
            dispatch_block_t deferred = self->_deferredCleanup;
            self->_deferredCleanup = nil;
            if (deferred) deferred();
            completion(current, generation);
        });
    });
}
- (void)registerThreeSurfacesAsync:(UIWindow *)menuWindow iconWindow:(UIWindow *)iconWindow
                         drawWindow:(UIWindow *)drawWindow
                         completion:(void (^)(BOOL, uint64_t))completion {
    if (!completion) return;
    const uint64_t generation = _hostGeneration;
    if (!_coreHosting || !NSThread.isMainThread || _busy || _menu || _icon || _draw ||
        !generation || !menuWindow || !iconWindow || !drawWindow || ![self identityValid] ||
        !menuWindow.windowScene || menuWindow.windowScene != iconWindow.windowScene ||
        menuWindow.windowScene != drawWindow.windowScene) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, generation); });
        return;
    }
    SEL selector = NSSelectorFromString(@"_contextId");
    const uint32_t menuContext = [menuWindow respondsToSelector:selector]
        ? ((uint32_t (*)(id, SEL))objc_msgSend)(menuWindow, selector) : 0;
    const uint32_t iconContext = [iconWindow respondsToSelector:selector]
        ? ((uint32_t (*)(id, SEL))objc_msgSend)(iconWindow, selector) : 0;
    const uint32_t drawContext = [drawWindow respondsToSelector:selector]
        ? ((uint32_t (*)(id, SEL))objc_msgSend)(drawWindow, selector) : 0;
    CGRect menuFrame = CGRectStandardize(menuWindow.bounds);
    CGRect iconFrame = CGRectStandardize(iconWindow.bounds);
    CGRect drawFrame = CGRectStandardize(drawWindow.bounds);
    menuFrame.origin = CGPointZero; iconFrame.origin = CGPointZero; drawFrame.origin = CGPointZero;
    if (!menuContext || !iconContext || !drawContext || menuContext == iconContext ||
        menuContext == drawContext || iconContext == drawContext ||
        !std::isfinite(menuFrame.size.width) || !std::isfinite(menuFrame.size.height) ||
        menuFrame.size.width <= 0 || menuFrame.size.height <= 0 ||
        !CGRectEqualToRect(menuFrame, iconFrame) || !CGRectEqualToRect(menuFrame, drawFrame)) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, generation); });
        return;
    }
    UIWindowScene *scene = menuWindow.windowScene;
    CoreSetRemoteHostSide *menu = [CoreSetRemoteHostSide new];
    CoreSetRemoteHostSide *icon = [CoreSetRemoteHostSide new];
    CoreSetRemoteHostSide *draw = [CoreSetRemoteHostSide new];
    menu.source = menuWindow; menu.context = menuContext; menu.sourceFrame = menuFrame;
    menu.sourceScene = scene;
    menu.associationKey = NSSelectorFromString(@"darkswordOverlayMenuHostController");
    menu.lockInvocationKey = NSSelectorFromString(@"darkswordOverlayMenuLockInvocation");
    menu.unlockInvocationKey = NSSelectorFromString(@"darkswordOverlayMenuUnlockInvocation");
    menu.role = @"darkswordOverlayMenuHostController";
    icon.source = iconWindow; icon.context = iconContext; icon.sourceFrame = iconFrame;
    icon.sourceScene = scene;
    icon.associationKey = NSSelectorFromString(@"darkswordOverlayIconHostController");
    icon.lockInvocationKey = NSSelectorFromString(@"darkswordOverlayIconLockInvocation");
    icon.unlockInvocationKey = NSSelectorFromString(@"darkswordOverlayIconUnlockInvocation");
    icon.role = @"darkswordOverlayIconHostController";
    draw.source = drawWindow; draw.context = drawContext; draw.sourceFrame = drawFrame;
    draw.sourceScene = scene;
    draw.associationKey = NSSelectorFromString(@"darkswordOverlayDrawHostController");
    draw.lockInvocationKey = NSSelectorFromString(@"darkswordOverlayDrawLockInvocation");
    draw.unlockInvocationKey = NSSelectorFromString(@"darkswordOverlayDrawUnlockInvocation");
    draw.role = @"darkswordOverlayDrawHostController";
    _menu = menu; _icon = icon; _draw = draw; _busy = YES; _registrationInFlight = YES;
    _lastBothObserved = NO; _registerCancelled.store(false);
    // Core 1.7 registers draw, icon, then menu at the three adjacent levels.
    const BOOL drawReady = [self createSide:draw level:kCoreSetCoreDrawLevel];
    const BOOL iconReady = drawReady && [self createSide:icon level:kCoreSetCoreIconLevel];
    const BOOL menuReady = iconReady && [self createSide:menu level:kCoreSetCoreMenuLevel];
    const BOOL lifecycleReady = drawReady && iconReady && menuReady &&
        [self installCoreLifecycleForDraw:draw icon:icon menu:menu];
    const BOOL current = lifecycleReady &&
        [self localSideObserved:draw] && [self localSideObserved:icon] &&
        [self localSideObserved:menu] && !_registerCancelled.load();
    if (!current && lifecycleReady) {
        (void)[self removeCoreLifecycleForSides:@[draw, icon, menu]];
    }
    _busy = NO; _registrationInFlight = NO; _lastBothObserved = current;
    draw.observed = current; icon.observed = current; menu.observed = current;
    dispatch_async(dispatch_get_main_queue(), ^{ completion(current, generation); });
}
- (void)unregisterBothSurfacesAsync:(UIWindow *)menuWindow drawWindow:(UIWindow *)drawWindow
                         completion:(void (^)(BOOL, BOOL))completion {
    if (!completion) return;
    if (_coreHosting || !NSThread.isMainThread ||
        (_menu && _menu.source != menuWindow) ||
        (_draw && _draw.source != drawWindow)) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, NO); });
        return;
    }
    if (_busy) {
        if (!_registrationInFlight || _deferredCleanup) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, NO); });
            return;
        }
        _registerCancelled.store(true);
        __weak CoreSetRemoteHostingAdapter *weakSelf = self;
        _deferredCleanup = ^{
            [weakSelf unregisterBothSurfacesAsync:menuWindow drawWindow:drawWindow
                                        completion:completion];
        };
        return;
    }
    CoreSetRemoteHostSide *menu = _menu;
    CoreSetRemoteHostSide *draw = _draw;
    _busy = YES; _lastBothObserved = NO;
    dispatch_async(_readbackQueue, ^{
        BOOL drawRemoved = NO, menuRemoved = NO;
        @synchronized (self->_process) {
            drawRemoved = !draw || [self removeSide:draw];
            menuRemoved = !menu || [self removeSide:menu];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (drawRemoved && self->_draw == draw) self->_draw = nil;
            if (menuRemoved && self->_menu == menu) self->_menu = nil;
            self->_busy = NO;
            completion(menuRemoved && self->_menu == nil,
                       drawRemoved && self->_draw == nil);
        });
    });
}
- (void)unregisterThreeSurfacesAsync:(UIWindow *)menuWindow iconWindow:(UIWindow *)iconWindow
                           drawWindow:(UIWindow *)drawWindow
                           completion:(void (^)(BOOL, BOOL, BOOL))completion {
    if (!completion) return;
    if (!_coreHosting || !NSThread.isMainThread ||
        (_menu && _menu.source != menuWindow) || (_icon && _icon.source != iconWindow) ||
        (_draw && _draw.source != drawWindow)) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, NO, NO); });
        return;
    }
    if (_busy) {
        if (!_registrationInFlight || _deferredCleanup) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, NO, NO); });
            return;
        }
        _registerCancelled.store(true);
        __weak CoreSetRemoteHostingAdapter *weakSelf = self;
        _deferredCleanup = ^{
            [weakSelf unregisterThreeSurfacesAsync:menuWindow iconWindow:iconWindow
                                        drawWindow:drawWindow completion:completion];
        };
        return;
    }
    CoreSetRemoteHostSide *menu = _menu;
    CoreSetRemoteHostSide *icon = _icon;
    CoreSetRemoteHostSide *draw = _draw;
    _lastBothObserved = NO;
    // Core 1.7 teardown follows draw, icon, then menu and clears each owner.
    NSMutableArray<CoreSetRemoteHostSide *> *sides = [NSMutableArray arrayWithCapacity:3];
    if (draw) [sides addObject:draw];
    if (icon) [sides addObject:icon];
    if (menu) [sides addObject:menu];
    const BOOL lifecycleRemoved = [self removeCoreLifecycleForSides:sides];
    const BOOL drawRemoved = lifecycleRemoved && (!draw || [self removeSide:draw]);
    const BOOL iconRemoved = lifecycleRemoved && (!icon || [self removeSide:icon]);
    const BOOL menuRemoved = lifecycleRemoved && (!menu || [self removeSide:menu]);
    if (drawRemoved) _draw = nil;
    if (iconRemoved) _icon = nil;
    if (menuRemoved) _menu = nil;
    _busy = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(menuRemoved && self->_menu == nil,
                   iconRemoved && self->_icon == nil,
                   drawRemoved && self->_draw == nil);
    });
}
@end
