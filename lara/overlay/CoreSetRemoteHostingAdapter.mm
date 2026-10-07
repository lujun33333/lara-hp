#import "CoreSetRemoteHostingAdapter.h"
#import "../kexploit/TaskRop/RemoteCall.h"
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>
#include <cstring>
#include <cmath>
extern "C" int proc_name(int pid, void *buffer, uint32_t buffersize);
static const double kCoreSetRemoteDrawLevel = 10000009.0;
static const double kCoreSetRemoteMenuLevel = 10000010.0;

static NSError *CSHostError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"CoreSetRemoteHosting" code:code
        userInfo:@{NSLocalizedDescriptionKey:message}];
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
@property(nonatomic) uint64_t window;
@property(nonatomic) uint64_t layer;
@property(nonatomic) uint64_t windowLayer;
@property(nonatomic) uint64_t scene;
@property(nonatomic) BOOL windowInitialized;
@property(nonatomic) BOOL layerInitialized;
@property(nonatomic) BOOL cleanupAmbiguous;
@property(nonatomic) BOOL observed;
@end
@implementation CoreSetRemoteHostSide @end

@implementation CoreSetRemoteHostingAdapter {
    RemoteCall *_process;
    CoreSetRemoteHostSide *_menu;
    CoreSetRemoteHostSide *_draw;
    uint64_t _hostGeneration;
    pid_t _pid;
    BOOL _busy;
}
- (instancetype)initWithRemoteCall:(RemoteCall *)remoteCall {
    if ((self = [super init])) { _process = remoteCall; _pid = remoteCall.pid; }
    return self;
}
- (uint64_t)hostGeneration { return _hostGeneration; }
- (BOOL)sessionIdentityReady { return [self identityValid]; }
- (BOOL)cleanupPending {
    @synchronized (_process) {
        return (_menu && (!_menu.observed || ![self sideObserved:_menu])) ||
               (_draw && (!_draw.observed || ![self sideObserved:_draw]));
    }
}
- (BOOL)bothSurfacesObserved {
    @synchronized (_process) {
        return [self identityValid] && _menu.observed && _draw.observed &&
            [self sideObserved:_menu] && [self sideObserved:_draw];
    }
}
- (void)prepareForHostGeneration:(uint64_t)generation {
    if (!NSThread.isMainThread || _busy || !generation) return;
    if ((_menu || _draw) && !self.bothSurfacesObserved) return;
    _hostGeneration = generation;
}
- (BOOL)identityValid {
    if (!_process || _pid <= 0 || _process.pid != _pid ||
        _process.trojanMem == 0 || _process.trojanMemIsStackFallback) return NO;
    char name[256] = {};
    return proc_name(_pid, name, sizeof(name)) > 0 && strcmp(name, "SpringBoard") == 0;
}
- (BOOL)sideObserved:(CoreSetRemoteHostSide *)side {
    if (!side || !side.source || !side.window || !side.layer || !side.windowLayer ||
        !side.context || !side.scene || ![self identityValid]) return NO;
    SEL contextSelector = NSSelectorFromString(@"_contextId");
    uint32_t current = [side.source respondsToSelector:contextSelector]
        ? ((uint32_t (*)(id, SEL))objc_msgSend)(side.source, contextSelector) : 0;
    if (current != side.context) return NO;
    uint64_t remoteScene = 0, remoteLayer = 0, remoteContext = 0;
    uint64_t parent = 0, hidden = 1;
    return CSMessage(_process, side.window, CSSel(_process, "windowScene"), 0, 0, &remoteScene) &&
        CSMessage(_process, side.window, CSSel(_process, "layer"), 0, 0, &remoteLayer) &&
        CSMessage(_process, side.layer, CSSel(_process, "contextId"), 0, 0, &remoteContext) &&
        CSMessage(_process, side.layer, CSSel(_process, "superlayer"), 0, 0, &parent) &&
        CSMessage(_process, side.window, CSSel(_process, "isHidden"), 0, 0, &hidden) &&
        remoteScene == side.scene && remoteLayer == side.windowLayer &&
        remoteContext == side.context && parent == side.windowLayer && (hidden & 0xff) == 0;
}
- (BOOL)removeSide:(CoreSetRemoteHostSide *)side {
    if (!side) return YES;
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
    if (![self identityValid] || !side.context || !side.source ||
        !std::isfinite(level)) return NO;
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
    CGRect frame = CGRectStandardize(side.source.bounds);
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
    side.observed = [self sideObserved:side];
    return side.observed;
}
- (BOOL)registerWindow:(UIWindow *)window surface:(CoreSetHUDSurface)surface error:(NSError **)error {
    if (!NSThread.isMainThread || _busy || !window || !_hostGeneration ||
        ![self identityValid] || self.cleanupPending) {
        if (error) *error = CSHostError(1, @"SpringBoard session or prior cleanup is not ready");
        return NO;
    }
    SEL selector = NSSelectorFromString(@"_contextId");
    uint32_t context = [window respondsToSelector:selector]
        ? ((uint32_t (*)(id, SEL))objc_msgSend)(window, selector) : 0;
    if (!context || (surface != CoreSetHUDSurfaceMenu && surface != CoreSetHUDSurfaceDraw)) {
        if (error) *error = CSHostError(2, @"Local window context is unavailable");
        return NO;
    }
    CoreSetRemoteHostSide * __strong *slot = surface == CoreSetHUDSurfaceMenu ? &_menu : &_draw;
    if (*slot) {
        BOOL unchanged = (*slot).source == window && (*slot).context == context &&
            [self sideObserved:*slot];
        if (!unchanged && error) *error = CSHostError(3, @"Existing remote surface changed");
        return unchanged;
    }
    CoreSetRemoteHostSide *side = [CoreSetRemoteHostSide new];
    side.source = window; side.context = context;
    *slot = side; _busy = YES;
    BOOL success = NO;
    const double remoteLevel = surface == CoreSetHUDSurfaceMenu
        ? kCoreSetRemoteMenuLevel : kCoreSetRemoteDrawLevel;
    @synchronized (_process) { success = [self createSide:side level:remoteLevel]; }
    _busy = NO;
    if (!success) {
        // Keep partial handles for the host's same-window rollback path.
        if (error) *error = CSHostError(4, @"Remote mirror creation or independent readback failed");
    }
    return success;
}
- (BOOL)unregisterWindow:(UIWindow *)window surface:(CoreSetHUDSurface)surface error:(NSError **)error {
    if (!NSThread.isMainThread || _busy) {
        if (error) *error = CSHostError(5, @"Main-thread serialized cleanup required");
        return NO;
    }
    CoreSetRemoteHostSide * __strong *slot = surface == CoreSetHUDSurfaceMenu ? &_menu : &_draw;
    CoreSetRemoteHostSide *side = *slot;
    if (!side) return YES;
    if (side.source != window) {
        if (error) *error = CSHostError(6, @"Cleanup window identity changed");
        return NO;
    }
    _busy = YES;
    BOOL cleaned = NO;
    @synchronized (_process) { cleaned = [self removeSide:side]; }
    _busy = NO;
    if (cleaned) *slot = nil;
    else if (error) *error = CSHostError(7, @"Remote side cleanup/readback pending; handles retained");
    return cleaned;
}
@end
