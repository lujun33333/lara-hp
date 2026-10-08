#import "CoreSetRenderCommands.h"
#import <CommonCrypto/CommonDigest.h>
#import <ImageIO/ImageIO.h>
#include <algorithm>
#include <cmath>

@implementation CoreSetRenderCommand
+ (instancetype)localImageNamed:(NSString *)name rect:(CGRect)rect {
    if (![name isEqualToString:@"CoreSetLoading.png"] || ![UIImage imageNamed:name]) return nil;
    CoreSetRenderCommand *command = [[self alloc] initWithKind:CoreSetRenderKindImage rect:rect
        endpoint:CGPointZero color:UIColor.whiteColor lineWidth:0 filled:NO text:nil fontSize:1];
    command->_localImageName = [name copy];
    return command;
}
+ (instancetype)weaponImageWithID:(uint32_t)weaponID rect:(CGRect)rect {
    if (!weaponID || ![CoreSetWeaponImageCatalog imageForWeaponID:weaponID]) return nil;
    CoreSetRenderCommand *command = [[self alloc] initWithKind:CoreSetRenderKindImage rect:rect
        endpoint:CGPointZero color:UIColor.whiteColor lineWidth:0 filled:NO text:nil fontSize:1];
    command->_weaponID = weaponID;
    return command;
}
+ (instancetype)backGlyphWithStyle:(NSInteger)style rect:(CGRect)rect
                             angle:(CGFloat)angle color:(UIColor *)color {
    if (style < 0 || style > 5 || !std::isfinite(angle) || !color) return nil;
    CoreSetRenderCommand *command = [[self alloc] initWithKind:CoreSetRenderKindBackGlyph rect:rect
        endpoint:CGPointZero color:color lineWidth:0 filled:YES text:nil fontSize:1];
    command->_glyphStyle = style;
    command->_glyphAngle = angle;
    return command;
}
- (instancetype)initWithKind:(CoreSetRenderKind)kind rect:(CGRect)rect endpoint:(CGPoint)endpoint
                       color:(UIColor *)color lineWidth:(CGFloat)lineWidth filled:(BOOL)filled
                        text:(NSString *)text fontSize:(CGFloat)fontSize {
    if ((self = [super init])) {
        _kind = kind; _rect = rect; _endpoint = endpoint; _color = color;
        _lineWidth = lineWidth; _filled = filled; _text = [text copy]; _fontSize = fontSize;
        _glyphStyle = -1;
        _styleRole = CoreSetRenderStyleRoleNone;
        _horizontallyCenteredText = NO;
    }
    return self;
}
- (instancetype)styledWithRole:(CoreSetRenderStyleRole)role {
    if ((_kind != CoreSetRenderKindLine && _kind != CoreSetRenderKindText) ||
        role < CoreSetRenderStyleRoleNone || role > CoreSetRenderStyleRoleBotTeam) return self;
    CoreSetRenderCommand *copy = [[CoreSetRenderCommand alloc]
        initWithKind:self.kind rect:self.rect endpoint:self.endpoint color:self.color
        lineWidth:self.lineWidth filled:self.isFilled text:self.text fontSize:self.fontSize];
    copy->_styleRole = role;
    copy->_horizontallyCenteredText = _horizontallyCenteredText;
    return copy;
}
- (instancetype)centeredText {
    if (_kind != CoreSetRenderKindText || _horizontallyCenteredText) return self;
    CoreSetRenderCommand *copy = [[CoreSetRenderCommand alloc]
        initWithKind:self.kind rect:self.rect endpoint:self.endpoint color:self.color
        lineWidth:self.lineWidth filled:self.isFilled text:self.text fontSize:self.fontSize];
    copy->_styleRole = _styleRole;
    copy->_horizontallyCenteredText = YES;
    return copy;
}
@end

static NSString *CSWeaponSHA256(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *result = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (unsigned char byte : digest) [result appendFormat:@"%02x", byte];
    return result;
}

static NSMutableDictionary<NSNumber *, UIImage *> *CSWeaponImages;
static NSMutableArray *CSWeaponWaiters;
static BOOL CSWeaponLoading;
static uint64_t CSWeaponEpoch;
@implementation CoreSetWeaponImageCatalog

+ (BOOL)ready { NSAssert(NSThread.isMainThread, @"Main thread required"); return CSWeaponImages.count == 89; }
+ (UIImage *)imageForWeaponID:(uint32_t)weaponID {
    NSAssert(NSThread.isMainThread, @"Main thread required");
    return CSWeaponImages[@(weaponID)];
}
+ (void)prepareWithCompletion:(void (^)(BOOL))completion {
    NSAssert(NSThread.isMainThread, @"Main thread required");
    if ([self ready]) { if (completion) completion(YES); return; }
    if (!CSWeaponWaiters) CSWeaponWaiters = [NSMutableArray array];
    if (completion) [CSWeaponWaiters addObject:[completion copy]];
    if (CSWeaponLoading) return;
    CSWeaponLoading = YES;
    const uint64_t epoch = ++CSWeaponEpoch;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableDictionary<NSNumber *, UIImage *> *loaded = [NSMutableDictionary dictionaryWithCapacity:89];
        NSString *folder = [NSBundle.mainBundle pathForResource:@"CoreSetWeaponIcons" ofType:nil];
        NSData *manifestBytes = [NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:@"manifest.json"]];
        // This digest binds the manifest to the exact E32 extraction, not merely to self-declared hashes.
        BOOL valid = [CSWeaponSHA256(manifestBytes ?: [NSData data]) isEqualToString:
            @"426c223f6a1859edc11930c20200a7ce7cd5e001946d0bf9cc8bdaa93ce96a10"];
        id parsed = valid ? [NSJSONSerialization JSONObjectWithData:manifestBytes options:0 error:nil] : nil;
        NSDictionary *manifest = [parsed isKindOfClass:NSDictionary.class] ? parsed : nil;
        NSArray *rows = [manifest[@"icons"] isKindOfClass:NSArray.class] ? manifest[@"icons"] : nil;
        valid = valid && rows.count == 89 &&
            [manifest[@"source_ipa_sha256"] isEqualToString:@"57412d36a1092931d81a9a820c57eb5c1eb92dcf77076ce865dc95035a3a41cb"];
        for (NSDictionary *row in rows) {
            if (!valid || ![row isKindOfClass:NSDictionary.class]) { valid = NO; break; }
            NSNumber *identifier = row[@"id"];
            NSString *file = row[@"file"];
            if (![identifier isKindOfClass:NSNumber.class] || identifier.unsignedIntValue == 0 ||
                ![file isKindOfClass:NSString.class] ||
                ![file isEqualToString:[NSString stringWithFormat:@"%u.png", identifier.unsignedIntValue]] ||
                loaded[identifier] != nil) { valid = NO; break; }
            NSData *data = [NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:file]];
            if (!data || data.length != [row[@"bytes"] unsignedIntegerValue] ||
                ![CSWeaponSHA256(data) isEqualToString:row[@"sha256"]]) { valid = NO; break; }
            CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, nil);
            CGImageRef cgImage = source ? CGImageSourceCreateImageAtIndex(source, 0, nil) : nil;
            if (!cgImage || CGImageGetWidth(cgImage) != [row[@"width"] unsignedIntegerValue] ||
                CGImageGetHeight(cgImage) != [row[@"height"] unsignedIntegerValue]) valid = NO;
            if (valid) loaded[identifier] = [UIImage imageWithCGImage:cgImage];
            if (cgImage) CGImageRelease(cgImage);
            if (source) CFRelease(source);
            if (!valid) break;
        }
        if (loaded.count != 89) valid = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (epoch != CSWeaponEpoch) return; // stop or newer load superseded this result.
            CSWeaponLoading = NO;
            CSWeaponImages = valid ? loaded : nil;
            NSArray *callbacks = [CSWeaponWaiters copy];
            [CSWeaponWaiters removeAllObjects];
            for (id item in callbacks) {
                void (^callback)(BOOL) = item;
                callback(valid);
            }
        });
    });
}
+ (void)stop {
    NSAssert(NSThread.isMainThread, @"Main thread required");
    ++CSWeaponEpoch;
    CSWeaponLoading = NO;
    CSWeaponImages = nil;
    NSArray *callbacks = [CSWeaponWaiters copy];
    [CSWeaponWaiters removeAllObjects];
    for (id item in callbacks) {
        void (^callback)(BOOL) = item;
        callback(NO);
    }
}
@end

@implementation CoreSetRenderFrame
- (instancetype)initWithGeneration:(uint64_t)generation sequence:(uint64_t)sequence
                       canvasSize:(CGSize)canvasSize commands:(NSArray<CoreSetRenderCommand *> *)commands {
    return [self initWithGeneration:generation sequence:sequence canvasSize:canvasSize
        configRevision:0 snapshotID:@"" requestToken:@"" commands:commands];
}
- (instancetype)initWithGeneration:(uint64_t)generation sequence:(uint64_t)sequence
                       canvasSize:(CGSize)canvasSize configRevision:(uint64_t)configRevision
                       snapshotID:(NSString *)snapshotID requestToken:(NSString *)requestToken
                         commands:(NSArray<CoreSetRenderCommand *> *)commands {
    if ((self = [super init])) {
        _generation = generation; _sequence = sequence; _canvasSize = canvasSize;
        _configRevision = configRevision; _snapshotID = [snapshotID copy];
        _requestToken = [requestToken copy]; _commands = [commands copy];
    }
    return self;
}
@end
