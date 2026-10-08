#import "CoreSetFloatingSceneManager.h"
#import <objc/message.h>
#import <dlfcn.h>

static id CSClassObject(NSString *name) {
    return NSClassFromString(name);
}

static id CSMsg0(id target, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return target && [target respondsToSelector:selector]
        ? ((id (*)(id, SEL))objc_msgSend)(target, selector) : nil;
}

static id CSMsg1(id target, NSString *name, id value) {
    SEL selector = NSSelectorFromString(name);
    return target && [target respondsToSelector:selector]
        ? ((id (*)(id, SEL, id))objc_msgSend)(target, selector, value) : nil;
}

static id CSMsg2(id target, NSString *name, id first, id second) {
    SEL selector = NSSelectorFromString(name);
    return target && [target respondsToSelector:selector]
        ? ((id (*)(id, SEL, id, id))objc_msgSend)(target, selector, first, second) : nil;
}

static void CSVoid1(id target, NSString *name, id value) {
    SEL selector = NSSelectorFromString(name);
    if (target && [target respondsToSelector:selector])
        ((void (*)(id, SEL, id))objc_msgSend)(target, selector, value);
}

static void CSSetInteger(id target, NSString *name, NSInteger value) {
    SEL selector = NSSelectorFromString(name);
    if (target && [target respondsToSelector:selector])
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(target, selector, value);
}

static void CSSetBool(id target, NSString *name, BOOL value) {
    SEL selector = NSSelectorFromString(name);
    if (target && [target respondsToSelector:selector])
        ((void (*)(id, SEL, BOOL))objc_msgSend)(target, selector, value);
}

static void CSSetRect(id target, NSString *name, CGRect value) {
    SEL selector = NSSelectorFromString(name);
    if (target && [target respondsToSelector:selector])
        ((void (*)(id, SEL, CGRect))objc_msgSend)(target, selector, value);
}

@implementation CoreSetFloatingSceneManager {
    UIWindowScene *_touchScene;
    UIWindowScene *_drawScene;
    NSMutableArray<void (^)(UIWindowScene *, UIWindowScene *)> *_waiters;
    NSMutableArray *_presentationBinders;
    BOOL _creating;
}

+ (instancetype)shared {
    static CoreSetFloatingSceneManager *value;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ value = [CoreSetFloatingSceneManager new]; });
    return value;
}

- (instancetype)init {
    if ((self = [super init])) {
        _waiters = [NSMutableArray array];
        _presentationBinders = [NSMutableArray array];
    }
    return self;
}

+ (BOOL)isFloatingIdentifier:(NSString *)identifier {
    return [identifier containsString:@"-touchFloating"] ||
        [identifier containsString:@"-noTouchFloating"];
}

- (NSString *)identifierForTouch:(BOOL)touch {
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"Core-SET";
    return [bundle stringByAppendingString:touch ? @"-touchFloating" : @"-noTouchFloating"];
}

- (BOOL)createSceneWithIdentifier:(NSString *)identifier {
    static void *frontBoard = nullptr;
    if (!frontBoard) frontBoard = dlopen(
        "/System/Library/PrivateFrameworks/FrontBoard.framework/FrontBoard",
        RTLD_NOW | RTLD_GLOBAL);
    id manager = CSMsg0(CSClassObject(@"FBSceneManager"), @"sharedInstance");
    id definition = CSMsg0(CSClassObject(@"FBSMutableSceneDefinition"), @"definition");
    id identity = CSMsg1(CSClassObject(@"FBSSceneIdentity"), @"identityForIdentifier:", identifier);
    id clientIdentity = CSMsg0(CSClassObject(@"FBSSceneClientIdentity"), @"localIdentity");
    id specification = CSMsg0(CSClassObject(@"UIApplicationSceneSpecification"), @"specification");
    if (!manager || !definition || !identity || !clientIdentity || !specification) return NO;
    CSVoid1(definition, @"setIdentity:", identity);
    CSVoid1(definition, @"setClientIdentity:", clientIdentity);
    CSVoid1(definition, @"setSpecification:", specification);
    id parameters = CSMsg1(CSClassObject(@"FBSMutableSceneParameters"),
                           @"parametersForSpecification:", specification);
    id settings = CSMsg0(CSClassObject(@"UIMutableApplicationSceneSettings"), @"new");
    id screen = UIScreen.mainScreen;
    id displayConfiguration = CSMsg0(screen, @"displayConfiguration");
    if (!parameters || !settings || !displayConfiguration) return NO;
    CSVoid1(settings, @"setDisplayConfiguration:", displayConfiguration);
    CSSetRect(settings, @"setFrame:", screen.fixedCoordinateSpace.bounds);
    CSSetInteger(settings, @"setLevel:", 1);
    CSSetBool(settings, @"setForeground:", YES);
    CSSetInteger(settings, @"setInterruptionPolicy:", 1);
    CSSetBool(settings, @"setDeviceOrientationEventsEnabled:", YES);
    CSVoid1(parameters, @"setSettings:", settings);
    id clientSettings = CSMsg0(CSClassObject(@"UIMutableApplicationSceneClientSettings"), @"new");
    if (!clientSettings) return NO;
    CSSetInteger(clientSettings, @"setInterfaceOrientation:", UIInterfaceOrientationPortrait);
    CSSetInteger(clientSettings, @"setStatusBarStyle:", 0);
    CSVoid1(parameters, @"setClientSettings:", clientSettings);
    id scene = CSMsg2(manager, @"createSceneWithDefinition:initialParameters:", definition, parameters);
    id binderAllocation = CSMsg0(CSClassObject(@"UIRootWindowScenePresentationBinder"), @"alloc");
    if (!scene || !binderAllocation) return NO;
    SEL binderInit = NSSelectorFromString(@"initWithPriority:displayConfiguration:");
    if (![binderAllocation respondsToSelector:binderInit]) return NO;
    id binder = ((id (*)(id, SEL, NSInteger, id))objc_msgSend)(
        binderAllocation, binderInit, 0, displayConfiguration);
    if (!binder || ![binder respondsToSelector:NSSelectorFromString(@"addScene:")]) return NO;
    CSVoid1(binder, @"addScene:", scene);
    [_presentationBinders addObject:binder];
    return YES;
}

- (void)createScenesWithCompletion:(void (^)(UIWindowScene *, UIWindowScene *))completion {
    NSAssert(NSThread.isMainThread, @"Floating scenes require the main thread");
    if (!completion) return;
    if (_touchScene && _drawScene) { completion(_touchScene, _drawScene); return; }
    [_waiters addObject:[completion copy]];
    if (_creating) return;
    _creating = YES;
    const BOOL touch = [self createSceneWithIdentifier:[self identifierForTouch:YES]];
    const BOOL draw = touch && [self createSceneWithIdentifier:[self identifierForTouch:NO]];
    if (!touch || !draw) {
        _creating = NO;
        NSArray *waiters = [_waiters copy];
        [_waiters removeAllObjects];
        for (void (^waiter)(UIWindowScene *, UIWindowScene *) in waiters) waiter(nil, nil);
    }
}

- (void)connectScene:(UIWindowScene *)scene identifier:(NSString *)identifier {
    NSAssert(NSThread.isMainThread, @"Floating scenes require the main thread");
    if ([identifier containsString:@"-touchFloating"]) _touchScene = scene;
    if ([identifier containsString:@"-noTouchFloating"]) _drawScene = scene;
    if (!_touchScene || !_drawScene) return;
    _creating = NO;
    NSArray *waiters = [_waiters copy];
    [_waiters removeAllObjects];
    for (void (^waiter)(UIWindowScene *, UIWindowScene *) in waiters)
        waiter(_touchScene, _drawScene);
}

- (void)disconnectScene:(UIWindowScene *)scene {
    if (_touchScene == scene) _touchScene = nil;
    if (_drawScene == scene) _drawScene = nil;
}
@end
