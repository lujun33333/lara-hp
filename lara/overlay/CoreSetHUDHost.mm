#import "CoreSetHUDHost.h"
#include "CoreSetHostedInputCalibration.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <mach/mach_time.h>
#include <dlfcn.h>
#include <atomic>
#include <cmath>
#include <vector>

typedef struct __IOHIDEvent *CoreSetIOHIDEventRef;
typedef struct __IOHIDService *CoreSetIOHIDServiceRef;
typedef struct __IOHIDEventSystemClient *CoreSetIOHIDEventSystemClientRef;

// Apple IOHIDFamily-701.60.2 IOHIDEventTypes.h and current WebKit
// IOKitSPIIOS.h agree on these digitizer field offsets and event mask bits.
// Raw X/Y are never assumed to be points or normalized coordinates.
static constexpr uint32_t kCoreSetDigitizerType = 11;
static constexpr uint32_t kCoreSetDigitizerBase = kCoreSetDigitizerType << 16;
static constexpr uint32_t kCoreSetDigitizerX = kCoreSetDigitizerBase;
static constexpr uint32_t kCoreSetDigitizerY = kCoreSetDigitizerBase + 1;
static constexpr uint32_t kCoreSetDigitizerIndex = kCoreSetDigitizerBase + 5;
static constexpr uint32_t kCoreSetDigitizerMask = kCoreSetDigitizerBase + 7;
static constexpr uint32_t kCoreSetDigitizerRange = kCoreSetDigitizerBase + 8;
static constexpr uint32_t kCoreSetDigitizerTouch = kCoreSetDigitizerBase + 9;
static constexpr uint32_t kCoreSetDigitizerMaskTouch = 1u << 1;
static constexpr uint32_t kCoreSetDigitizerMaskPosition = 1u << 2;
static constexpr uint32_t kCoreSetDigitizerMaskCancel = 1u << 7;
typedef uint32_t (*CoreSetHIDGetType)(CoreSetIOHIDEventRef);
typedef CFArrayRef (*CoreSetHIDGetChildren)(CoreSetIOHIDEventRef);
typedef CFIndex (*CoreSetHIDGetInteger)(CoreSetIOHIDEventRef, uint32_t);
typedef double (*CoreSetHIDGetFloat)(CoreSetIOHIDEventRef, uint32_t);
typedef uint64_t (*CoreSetHIDGetTimestamp)(CoreSetIOHIDEventRef);
struct CoreSetNativeDigitizer {
    uint32_t index = 0;
    uint32_t mask = 0;
    BOOL range = NO;
    BOOL touching = NO;
    double x = 0;
    double y = 0;
    double timestamp = 0;
};
struct CoreSetForegroundContact {
    CoreSetHostedInputCalibration::Phase phase;
    double timestamp = 0;
    double x = 0;
    double y = 0;
};

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
static void CoreSetLogAXDrop(const char *reason, std::atomic_uint_fast64_t *counter) {
    const uint64_t count = counter->fetch_add(1) + 1;
    if (count == 1 || count % 64 == 0)
        NSLog(@"Core-SET: hosted input stage=ax-drop reason=%s count=%llu",
              reason, (unsigned long long)count);
}

@interface CoreSetDrawWindow : UIWindow @end
@implementation CoreSetDrawWindow
+ (BOOL)_isSystemWindow { return NO; }
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
@property(nonatomic, weak) UIView *calibrationRegion;
@property(nonatomic, weak) UIView *panelRegion;
@property(nonatomic, weak) UIView *floatingRegion;
@property(nonatomic, copy) NSArray<UIView *> * (^contentHitRegions)(void);
@end
@interface CoreSetMirroredDrawWindow : CoreSetDrawWindow @end
@implementation CoreSetMirroredDrawWindow
+ (BOOL)_isSystemWindow { return YES; }
@end
@implementation CoreSetMenuWindow
+ (BOOL)_isSystemWindow { return NO; }
- (BOOL)_isSecure { return NO; }
- (BOOL)_canBecomeKeyWindow { return YES; }
- (BOOL)_isApplicationKeyWindow { return NO; }
- (BOOL)_isWindowServerHostingManaged { return NO; }
- (BOOL)_ignoresHitTest { return self.backgroundPassThrough; }
- (BOOL)_shouldCreateContextAsSecure { return NO; }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.backgroundPassThrough) return nil;
    if (!self.rootViewController) return nil;
    if (self.calibrationRegion && !self.calibrationRegion.hidden &&
        [self.calibrationRegion pointInside:
            [self.calibrationRegion convertPoint:point fromView:self] withEvent:event])
        return [super hitTest:point withEvent:event];
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

@interface CoreSetCalibrationView : UIView
@property(nonatomic) NSUInteger targetIndex;
@property(nonatomic, copy) void (^contact)(CoreSetHostedPointerPhase, CGPoint, double);
@property(nonatomic, copy) void (^cancel)(void);
- (CGPoint)targetPoint;
@end
@implementation CoreSetCalibrationView {
    UILabel *_instruction;
    UIButton *_cancelButton;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.96];
        self.multipleTouchEnabled = YES;
        _instruction = [UILabel new];
        _instruction.textColor = UIColor.whiteColor;
        _instruction.textAlignment = NSTextAlignmentCenter;
        _instruction.numberOfLines = 3;
        _instruction.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        [self addSubview:_instruction];
        _cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_cancelButton setTitle:@"取消校准" forState:UIControlStateNormal];
        [_cancelButton addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_cancelButton];
        [self updateInstruction];
    }
    return self;
}
- (void)setTargetIndex:(NSUInteger)targetIndex {
    _targetIndex = targetIndex;
    [self updateInstruction];
    [self setNeedsLayout];
    [self setNeedsDisplay];
}
- (void)updateInstruction {
    _instruction.text = [NSString stringWithFormat:
        @"触控校准 %lu/7\n每次只用一根手指短按圆点。失败将停止游戏启动。",
        (unsigned long)MIN(_targetIndex + 1, 7)];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    const CGFloat instructionY = self.targetPoint.y < CGRectGetMidY(self.bounds)
        ? CGRectGetHeight(self.bounds) * .62 : CGRectGetHeight(self.bounds) * .27;
    _instruction.frame = CGRectMake(20, instructionY,
                                    CGRectGetWidth(self.bounds) - 40, 84);
    _cancelButton.frame = CGRectMake(CGRectGetWidth(self.bounds) - 130, 72, 110, 44);
}
- (CGPoint)targetPoint {
    static const double positions[7][2] = {
        {.20, .20}, {.80, .20}, {.20, .80},
        {.50, .10}, {.50, .90}, {.10, .50}, {.90, .50}
    };
    const NSUInteger index = MIN(_targetIndex, 6);
    return CGPointMake(self.bounds.size.width * positions[index][0],
                       self.bounds.size.height * positions[index][1]);
}
- (void)drawRect:(CGRect)rect {
    [super drawRect:rect];
    (void)rect;
    CGPoint center = self.targetPoint;
    UIBezierPath *ring = [UIBezierPath bezierPathWithOvalInRect:
        CGRectMake(center.x - 23, center.y - 23, 46, 46)];
    ring.lineWidth = 4;
    [UIColor.systemTealColor setStroke]; [ring stroke];
    UIBezierPath *dot = [UIBezierPath bezierPathWithOvalInRect:
        CGRectMake(center.x - 6, center.y - 6, 12, 12)];
    [UIColor.whiteColor setFill]; [dot fill];
}
- (void)cancelTapped { if (self.cancel) self.cancel(); }
- (void)reportTouch:(UITouch *)touch phase:(CoreSetHostedPointerPhase)phase {
    if (!touch || !self.window || !self.contact) return;
    CGPoint windowPoint = [touch locationInView:self.window];
    CGPoint fixed = [self.window.screen.fixedCoordinateSpace
        convertPoint:windowPoint fromCoordinateSpace:self.window];
    self.contact(phase, fixed, touch.timestamp);
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (event.allTouches.count != 1 || touches.count != 1) {
        if (self.cancel) self.cancel(); return;
    }
    [self reportTouch:touches.anyObject phase:CoreSetHostedPointerPhaseBegan];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    if (touches.count != 1) { if (self.cancel) self.cancel(); return; }
    [self reportTouch:touches.anyObject phase:CoreSetHostedPointerPhaseEnded];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches; (void)event;
    if (self.cancel) self.cancel();
}
@end

// Created only for a CALayerHost source context. Keep the source UIWindow
// non-interactive from its first registration, independent of background
// lifecycle notifications or a dynamic WindowServer input-region refresh.
@interface CoreSetMirroredMenuWindow : CoreSetMenuWindow @end
@implementation CoreSetMirroredMenuWindow
+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_ignoresHitTest { return YES; }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    (void)point; (void)event; return nil;
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
- (void)disarmHostedInput;
- (void)failClosedHostedInput;
- (void)requestHostedReadback;
- (void)receiveNativeContact:(CoreSetNativeDigitizer)contact;
- (BOOL)extractNativeDigitizer:(CoreSetIOHIDEventRef)event
                        into:(CoreSetNativeDigitizer *)contact;
- (BOOL)startInputMonitor;
- (void)completeForegroundCalibration:(BOOL)success;
- (void)pairCalibrationContacts;
- (void)drainHostedReadbackIdleWaiters;
- (BOOL)startPreparedInScene:(UIWindowScene *)scene menuController:(UIViewController *)menuController
                       error:(NSError **)error hostedCompletion:(void (^)(BOOL))hostedCompletion;
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
    std::atomic_uint_fast64_t _axClassMissing;
    std::atomic_uint_fast64_t _axFactoryNil;
    std::atomic_uint_fast64_t _axHandMissing;
    std::atomic_uint_fast64_t _axPathsMissing;
    std::atomic_uint_fast64_t _axException;
    std::atomic_uint_fast64_t _nativeParsed;
    std::atomic_int _inputSource; // 0 undecided, 1 AX, 2 calibrated digitizer.
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
    CoreSetHIDGetType _hidGetType;
    CoreSetHIDGetChildren _hidGetChildren;
    CoreSetHIDGetInteger _hidGetInteger;
    CoreSetHIDGetFloat _hidGetFloat;
    CoreSetHIDGetTimestamp _hidGetTimestamp;
    double _machSecondsPerTick;
    BOOL _nativeTouching;
    uint32_t _nativeIndex;
    std::atomic_bool _calibrating;
    CoreSetCalibrationView *_calibrationView;
    void (^_calibrationCompletion)(BOOL);
    __weak UIScreen *_calibrationScreen;
    CoreSetHostedInputCalibration::SurfaceIdentity _calibrationIdentity;
    CoreSetHostedInputCalibration::PairRecorder _pairRecorder;
    CoreSetHostedInputCalibration::AffineCalibration _nativeCalibration;
    std::vector<CoreSetHostedInputCalibration::RawContact> _pendingRawContacts;
    std::vector<CoreSetForegroundContact> _pendingForegroundContacts;
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
        _axClassMissing.store(0); _axFactoryNil.store(0);
        _axHandMissing.store(0); _axPathsMissing.store(0); _axException.store(0);
        _nativeParsed.store(0); _inputSource.store(0);
        _hostedReadbackWaiters = [NSMutableArray array];
        _hostedReadbackIdleWaiters = [NSMutableArray array];
        _hostedAsyncStopWaiters = [NSMutableArray array];
        _calibrating.store(false);
        _calibrationIdentity = {0, 0, 1};
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
- (BOOL)hostedCleanupInFlight { return _hostedAsyncStopPending; }
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
        if (![self hasHostedRegistrationReceipt]) {
            if (_hostedReadbackPending || _hostedReadbackInFlight) {
                NSLog(@"Core-SET: hosted input stage=drop reason=readback-pending");
                [self resetHostedPointer]; return;
            }
            [self failClosedHostedInput];
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
    if (![self hasHostedRegistrationReceipt]) {
        if (_hostedReadbackPending || _hostedReadbackInFlight) {
            [self resetHostedPointer]; return;
        }
        [self failClosedHostedInput]; return;
    }
    if (!continuous && ![identifier isEqualToString:[self hostedControlIDAtSurfacePoint:point]]) {
        [self resetHostedPointer]; return;
    }
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
- (BOOL)extractNativeDigitizer:(CoreSetIOHIDEventRef)event
                        into:(CoreSetNativeDigitizer *)contact {
    if (!event || !contact || !_hidGetType || !_hidGetChildren ||
        !_hidGetInteger || !_hidGetFloat || _hidGetType(event) != kCoreSetDigitizerType)
        return NO;
    CFArrayRef children = _hidGetChildren(event);
    if (!children || CFGetTypeID(children) != CFArrayGetTypeID() ||
        CFArrayGetCount(children) != 1) return NO;
    CoreSetIOHIDEventRef child = (CoreSetIOHIDEventRef)CFArrayGetValueAtIndex(children, 0);
    if (!child || _hidGetType(child) != kCoreSetDigitizerType) return NO;
    const CFIndex index = _hidGetInteger(child, kCoreSetDigitizerIndex);
    const CFIndex mask = _hidGetInteger(child, kCoreSetDigitizerMask);
    if (index < 0 || (uint64_t)index > UINT32_MAX || mask < 0 ||
        (uint64_t)mask > UINT32_MAX) return NO;
    contact->index = (uint32_t)index;
    contact->mask = (uint32_t)mask;
    contact->range = _hidGetInteger(child, kCoreSetDigitizerRange) != 0;
    contact->touching = _hidGetInteger(child, kCoreSetDigitizerTouch) != 0;
    contact->x = _hidGetFloat(child, kCoreSetDigitizerX);
    contact->y = _hidGetFloat(child, kCoreSetDigitizerY);
    const uint64_t ticks = _hidGetTimestamp ? _hidGetTimestamp(event) : 0;
    contact->timestamp = ticks * _machSecondsPerTick;
    const double now = mach_absolute_time() * _machSecondsPerTick;
    return std::isfinite(contact->x) && std::isfinite(contact->y) &&
           std::isfinite(contact->timestamp) && contact->timestamp > 0 &&
           contact->timestamp <= now + 0.05 && now - contact->timestamp <= 1.0;
}
- (void)receiveNativeContact:(CoreSetNativeDigitizer)contact {
    if (!NSThread.isMainThread || !_touchClient ||
        (!_calibrating.load() && !_inputArmed.load())) return;
    const BOOL cancel = (contact.mask & kCoreSetDigitizerMaskCancel) != 0;
    const BOOL active = contact.range && contact.touching;
    CoreSetHostedInputCalibration::Phase phase;
    if (cancel) {
        _nativeTouching = NO;
        if (_calibrating.load()) { [self completeForegroundCalibration:NO]; return; }
        [self resetHostedPointer];
        return;
    }
    if (active) {
        if (!_nativeTouching) {
            phase = CoreSetHostedInputCalibration::Phase::Began;
            _nativeIndex = contact.index; _nativeTouching = YES;
        } else if (_nativeIndex == contact.index) {
            if (!(contact.mask & (kCoreSetDigitizerMaskPosition | kCoreSetDigitizerMaskTouch))) return;
            phase = CoreSetHostedInputCalibration::Phase::Moved;
        } else {
            if (_calibrating.load()) [self completeForegroundCalibration:NO];
            else [self resetHostedPointer];
            _nativeTouching = NO;
            return;
        }
    } else if (_nativeTouching && _nativeIndex == contact.index) {
        phase = CoreSetHostedInputCalibration::Phase::Ended;
        _nativeTouching = NO;
    } else return;
    CoreSetHostedInputCalibration::RawContact raw = {
        contact.index, phase, contact.timestamp, contact.x, contact.y,
        (uint32_t)(active ? 1 : 0)
    };
    if (_calibrating.load()) {
        if (phase != CoreSetHostedInputCalibration::Phase::Moved) {
            _pendingRawContacts.push_back(raw);
            [self pairCalibrationContacts];
        }
        return;
    }
    if (_foreground || UIApplication.sharedApplication.applicationState != UIApplicationStateBackground)
        return;
    if (_inputSource.load() == 1) return;
    if (!_nativeCalibration.valid(_calibrationIdentity) ||
        _calibrationScreen != _menuWindow.windowScene.screen) {
        [self failClosedHostedInput]; return;
    }
    double fixedX = 0, fixedY = 0;
    if (!_nativeCalibration.map(raw.x, raw.y, _calibrationIdentity, &fixedX, &fixedY)) {
        [self failClosedHostedInput]; return;
    }
    _inputSource.store(2);
    const uint64_t count = _nativeParsed.fetch_add(1) + 1;
    if (count == 1 || count % 64 == 0)
        NSLog(@"Core-SET: hosted input stage=native-map count=%llu", (unsigned long long)count);
    [self handleHostedPointer:(NSInteger)phase pointerID:(int64_t)raw.index
                      point:CGPointMake(fixedX, fixedY) generation:self.generation
                   timestamp:CFAbsoluteTimeGetCurrent()];
}
- (void)receiveHostedHIDEvent:(CoreSetIOHIDEventRef)event {
    if ((!_inputArmed.load() && !_calibrating.load()) || !event) return;
    if (_hidGetType && _hidGetChildren &&
        _hidGetType(event) == kCoreSetDigitizerType) {
        CFArrayRef children = _hidGetChildren(event);
        if (!children || CFGetTypeID(children) != CFArrayGetTypeID() ||
            CFArrayGetCount(children) != 1) {
            __weak CoreSetHUDHost *weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                CoreSetHUDHost *host = weakSelf;
                if (!host) return;
                if (host->_calibrating.load()) [host completeForegroundCalibration:NO];
                else [host resetHostedPointer];
            });
            return;
        }
    }
    CoreSetNativeDigitizer native;
    const BOOL nativePresent = [self extractNativeDigitizer:event into:&native];
    if (nativePresent) {
        __weak CoreSetHUDHost *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf receiveNativeContact:native];
        });
    }
    if (_calibrating.load()) return;
    const uint64_t callbacks = _hidCallbacks.fetch_add(1) + 1;
    if (callbacks == 1 || callbacks % 64 == 0)
        NSLog(@"Core-SET: hosted input stage=callback count=%llu",
              (unsigned long long)callbacks);
    if (callbacks == 64) {
        __weak CoreSetHUDHost *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            CoreSetHUDHost *host = weakSelf;
            if (host && host->_inputArmed.load() && !host->_foreground &&
                host->_axParsed.load() == 0 && host->_nativeParsed.load() == 0) {
                NSLog(@"Core-SET: hosted input stage=invalidated reason=ax-unusable");
                [host failClosedHostedInput];
            }
        });
    }
    @autoreleasepool { @try {
        Class eventClass = NSClassFromString(@"AXEventRepresentation");
        if (!eventClass) {
            CoreSetLogAXDrop("class-missing", &_axClassMissing); return;
        }
        CoreSetAXEvent *representation = ((id (*)(id, SEL, CoreSetIOHIDEventRef, NSString *))objc_msgSend)(
            eventClass, @selector(representationWithHIDEvent:hidStreamIdentifier:),
            event, @"UIApplicationEvents");
        if (!representation) {
            CoreSetLogAXDrop("factory-nil", &_axFactoryNil); return;
        }
        CoreSetAXEventHand *hand = representation.handInfo;
        if (!hand || ![hand respondsToSelector:@selector(paths)]) {
            CoreSetLogAXDrop("hand-missing", &_axHandMissing);
            dispatch_async(dispatch_get_main_queue(), ^{ [self resetHostedPointer]; });
            return;
        }
        NSArray<CoreSetAXEventPath *> *paths = hand.paths;
        if (![paths isKindOfClass:NSArray.class]) {
            CoreSetLogAXDrop("paths-missing", &_axPathsMissing);
            dispatch_async(dispatch_get_main_queue(), ^{ [self resetHostedPointer]; });
            return;
        }
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
        if (!std::isfinite(point.x) || !std::isfinite(point.y) ||
            point.x < 0 || point.y < 0 ||
            point.x > _calibrationIdentity.width ||
            point.y > _calibrationIdentity.height) return;
        if (!_running || _foreground || !_inputArmed.load()) return;
        if (_inputSource.load() == 2) return;
        _inputSource.store(1);
        const uint64_t parsed = _axParsed.fetch_add(1) + 1;
        if (parsed == 1 || parsed % 64 == 0)
            NSLog(@"Core-SET: hosted input stage=ax-parse count=%llu single=1",
                  (unsigned long long)parsed);
        const uint64_t generation = self.generation;
        const CFAbsoluteTime timestamp = CFAbsoluteTimeGetCurrent();
        __weak CoreSetHUDHost *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            CoreSetHUDHost *host = weakSelf;
            [host handleHostedPointer:phase pointerID:pointerID point:point
                          generation:generation timestamp:timestamp];
        });
    } @catch (__unused NSException *exception) {
        CoreSetLogAXDrop("exception", &_axException);
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
        NSLog(@"Core-SET: hosted input monitor armed=0 reason=host-orientation"); return NO;
    }
    if (!self.hostedRegistrationReceipt) {
        NSLog(@"Core-SET: hosted input monitor armed=0 reason=hosting-readback"); return NO;
    }
    if (!self.foregroundTouchCalibrationReady) {
        NSLog(@"Core-SET: hosted input monitor armed=0 reason=calibration"); return NO;
    }
    if (self.hostedInputMonitorArmed) return YES;
    const BOOL armed = [self startInputMonitor];
    if (armed) NSLog(@"Core-SET: hosted input monitor armed=1 passive=1 calibrated=1");
    return armed;
}
- (BOOL)startInputMonitor {
    if (!NSThread.isMainThread || !_running || _touchClient) return NO;
    if (gCoreSetHostedInputOwner && gCoreSetHostedInputOwner != self) {
        NSLog(@"Core-SET: hosted input monitor armed=0 reason=another-owner"); return NO;
    }
    if (!_accessibilityHandle) _accessibilityHandle = dlopen(
        "/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities",
        RTLD_LAZY | RTLD_LOCAL);
    // AX can be absent on iOS 26. Native digitizer access is required for
    // both foreground calibration and the background fallback.
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
    _hidGetType = _ioKitHandle ? (CoreSetHIDGetType)dlsym(_ioKitHandle, "IOHIDEventGetType") : NULL;
    _hidGetChildren = _ioKitHandle ? (CoreSetHIDGetChildren)dlsym(_ioKitHandle, "IOHIDEventGetChildren") : NULL;
    _hidGetInteger = _ioKitHandle ? (CoreSetHIDGetInteger)dlsym(_ioKitHandle, "IOHIDEventGetIntegerValue") : NULL;
    _hidGetFloat = _ioKitHandle ? (CoreSetHIDGetFloat)dlsym(_ioKitHandle, "IOHIDEventGetFloatValue") : NULL;
    _hidGetTimestamp = _ioKitHandle ? (CoreSetHIDGetTimestamp)dlsym(_ioKitHandle, "IOHIDEventGetTimeStamp") : NULL;
    mach_timebase_info_data_t timebase = {};
    const BOOL timebaseReady = mach_timebase_info(&timebase) == KERN_SUCCESS &&
        timebase.numer != 0 && timebase.denom != 0;
    _machSecondsPerTick = timebaseReady
        ? (double)timebase.numer / (double)timebase.denom * 1e-9 : 0;
    // Require a cleanup route before registering any process-wide callback.
    if (!create || !reg || !schedule || !_hidGetType || !_hidGetChildren ||
        !_hidGetInteger || !_hidGetFloat || !_hidGetTimestamp || !timebaseReady ||
        !dlsym(_ioKitHandle, "IOHIDEventSystemClientUnscheduleWithRunLoop")) {
        NSLog(@"Core-SET: hosted input monitor armed=0 reason=IOHID-symbols"); return NO;
    }
    _touchClient = create(kCFAllocatorDefault);
    if (!_touchClient) {
        NSLog(@"Core-SET: hosted input monitor armed=0 reason=IOHID-create"); return NO;
    }
    [self resetHostedPointer];
    _nativeTouching = NO; _inputSource.store(0);
    gCoreSetHostedInputOwner = self;
    reg(_touchClient, CoreSetHostedHIDCallback, NULL, NULL);
    schedule(_touchClient, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    _inputArmed.store(!_calibrating.load());
    return YES;
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
        NSLog(@"Core-SET: hosted input stage=readback observed=%d generation=%llu source=async",
              current, (unsigned long long)generation);
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
    _calibrating.store(false);
    _nativeTouching = NO;
    _inputSource.store(0);
    _pendingRawContacts.clear(); _pendingForegroundContacts.clear();
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
    }
    // If the OS loses its unschedule symbol, leave a dormant client scheduled;
    // the weak global owner and _inputArmed prevent dispatch into a dead host.
    _touchClient = NULL;
}
- (BOOL)foregroundTouchCalibrationReady {
    if (!_nativeCalibration.valid(_calibrationIdentity) || !_calibrationScreen) return NO;
    if (_menuWindow && _menuWindow.windowScene.screen != _calibrationScreen) return NO;
    const CGSize size = _calibrationScreen.fixedCoordinateSpace.bounds.size;
    return _calibrationIdentity.width == size.width &&
        _calibrationIdentity.height == size.height;
}
- (BOOL)beginForegroundTouchCalibration:(void (^)(BOOL))completion {
    if (!NSThread.isMainThread || !completion || !_running || _adapter ||
        !_foreground || !_menuWindow || !_menuWindow.userInteractionEnabled ||
        _menuWindow.windowScene.activationState != UISceneActivationStateForegroundActive ||
        _calibrating.load()) return NO;
    if (self.foregroundTouchCalibrationReady) { completion(YES); return YES; }
    const CGSize size = _menuWindow.windowScene.screen.fixedCoordinateSpace.bounds.size;
    if (size.width <= 0 || size.height <= 0) return NO;
    _calibrationIdentity = {size.width, size.height,
        CoreSetHUDNextGeneration(_calibrationIdentity.generation)};
    _calibrationScreen = _menuWindow.windowScene.screen;
    _nativeCalibration.reset(); _pairRecorder.reset();
    _pendingRawContacts.clear(); _pendingForegroundContacts.clear();
    _calibrationCompletion = [completion copy];
    _calibrationView = [[CoreSetCalibrationView alloc]
        initWithFrame:_menuWindow.rootViewController.view.bounds];
    _calibrationView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    __weak CoreSetHUDHost *weakSelf = self;
    _calibrationView.cancel = ^{ [weakSelf completeForegroundCalibration:NO]; };
    _calibrationView.contact = ^(CoreSetHostedPointerPhase phase, CGPoint fixed, double timestamp) {
        CoreSetHUDHost *host = weakSelf;
        if (!host || !host->_calibrating.load()) return;
        CoreSetForegroundContact touch = {
            (CoreSetHostedInputCalibration::Phase)phase, timestamp, fixed.x, fixed.y
        };
        host->_pendingForegroundContacts.push_back(touch);
        [host pairCalibrationContacts];
    };
    [_menuWindow.rootViewController.view addSubview:_calibrationView];
    _menuWindow.calibrationRegion = _calibrationView;
    _calibrating.store(true);
    if (![self startInputMonitor]) {
        [self completeForegroundCalibration:NO]; return YES;
    }
    NSLog(@"Core-SET: hosted input stage=calibration-start targets=7");
    const uint64_t epoch = _calibrationIdentity.generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 45 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        CoreSetHUDHost *host = weakSelf;
        if (host && host->_calibrating.load() &&
            host->_calibrationIdentity.generation == epoch)
            [host completeForegroundCalibration:NO];
    });
    return YES;
}
- (void)pairCalibrationContacts {
    if (!_calibrating.load()) return;
    using namespace CoreSetHostedInputCalibration;
    while (!_pendingRawContacts.empty() && !_pendingForegroundContacts.empty()) {
        const RawContact raw = _pendingRawContacts.front();
        const CoreSetForegroundContact touch = _pendingForegroundContacts.front();
        _pendingRawContacts.erase(_pendingRawContacts.begin());
        _pendingForegroundContacts.erase(_pendingForegroundContacts.begin());
        PairedSample paired = {raw, touch.timestamp, touch.phase, touch.x, touch.y};
        CGPoint target = [_calibrationScreen.fixedCoordinateSpace convertPoint:
            _calibrationView.targetPoint fromCoordinateSpace:_calibrationView];
        if (hypot(touch.x - target.x, touch.y - target.y) > 30.0 ||
            !_pairRecorder.add(paired)) {
            [self completeForegroundCalibration:NO]; return;
        }
        if (raw.phase != Phase::Ended) continue;
        const NSUInteger next = _calibrationView.targetIndex + 1;
        if (next < 7) { _calibrationView.targetIndex = next; continue; }
        const auto &samples = _pairRecorder.samples();
        if (samples.size() != 7) { [self completeForegroundCalibration:NO]; return; }
        std::vector<PairedSample> training(samples.begin(), samples.begin() + 3);
        std::vector<PairedSample> heldout(samples.begin() + 3, samples.end());
        const BOOL valid = _nativeCalibration.fit(training, heldout, _calibrationIdentity);
        NSLog(@"Core-SET: hosted input stage=calibration-finish valid=%d pairs=%lu",
              valid, (unsigned long)samples.size());
        [self completeForegroundCalibration:valid];
        return;
    }
    if (_pendingRawContacts.size() > 2 || _pendingForegroundContacts.size() > 2)
        [self completeForegroundCalibration:NO];
}
- (void)completeForegroundCalibration:(BOOL)success {
    if (!NSThread.isMainThread || !_calibrating.load()) return;
    void (^completion)(BOOL) = [_calibrationCompletion copy];
    _calibrationCompletion = nil;
    _calibrationView.contact = nil; _calibrationView.cancel = nil;
    [_calibrationView removeFromSuperview];
    _menuWindow.calibrationRegion = nil; _calibrationView = nil;
    [self disarmHostedInput];
    if (!success) _nativeCalibration.reset();
    NSLog(@"Core-SET: hosted input stage=calibration-complete confirmed=%d", success);
    if (completion) completion(success);
}
- (void)cancelForegroundTouchCalibration {
    if (_calibrating.load()) [self completeForegroundCalibration:NO];
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
    return self.localSurfacesReady && self.panelVisible == visible;
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
    if (_adapter && (!self.foregroundTouchCalibrationReady ||
                     scene.screen != _calibrationScreen))
        return [self fail:12 message:@"Foreground digitizer calibration is required before a system source window" error:error];
    self.lastError = nil;
    [self invalidateFrames];
    _foreground = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    _drawWindow = _adapter
        ? [[CoreSetMirroredDrawWindow alloc] initWithWindowScene:scene]
        : [[CoreSetDrawWindow alloc] initWithWindowScene:scene];
    _menuWindow = _adapter
        ? [[CoreSetMirroredMenuWindow alloc] initWithWindowScene:scene]
        : [[CoreSetMenuWindow alloc] initWithWindowScene:scene];
    _menuWindow.backgroundPassThrough = _adapter != nil || !_foreground;
    _menuWindow.userInteractionEnabled = _adapter == nil && _foreground;
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
                                             self.hostedRegistrationReceipt);
    [_layers setVisible:_activeBackend == CoreSetHUDBackendCoreAnimation];
    [_metal setVisible:_activeBackend == CoreSetHUDBackendMetal];
}
- (void)setApplicationActive:(BOOL)active {
    if (!NSThread.isMainThread || !_running || _foreground == active) return;
    if (!active && _calibrating.load()) [self completeForegroundCalibration:NO];
    const uint64_t previousGeneration = self.generation;
    if (active) [self disarmHostedInput];
    _foreground = active;
    _menuWindow.backgroundPassThrough = _adapter != nil || !active;
    _menuWindow.userInteractionEnabled = _adapter == nil && active;
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
    if (_calibrating.load()) [self completeForegroundCalibration:NO];
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
