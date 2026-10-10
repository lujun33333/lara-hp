#import "CoreSetRenderCommands.h"
#import <QuartzCore/QuartzCore.h>
#import <CommonCrypto/CommonDigest.h>
#import <ImageIO/ImageIO.h>
#import <objc/message.h>
#include "CoreSetTextAnchor.h"
#include <algorithm>
#include <cmath>
#include <initializer_list>

static NSString *const CSBodyFontName = @"OPPOSans-H";
static NSString *const CSIconFontName = @"icomoon";

// WZ/AX keeps its retained CoreAnimation tree publishable after the source
// application resigns active.  iOS 26 CALayerHost mirrors this same source
// context, so opt the host and retained root into background updates when the
// private selector is available.  Older systems simply keep the public path.
static void CSEnableHostedLayerUpdates(CALayer *layer) {
    if (!layer) return;
    SEL selector = NSSelectorFromString(@"setDisableUpdateMask:");
    if ([layer respondsToSelector:selector])
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(layer, selector, 0);
}

static BOOL CSIconGlyphAllowed(NSString *text) {
    if (text.length != 1) return NO;
    static NSCharacterSet *glyphs;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Exact non-empty cmap entries in Core's embedded 2,600-byte IcoMoon.
        glyphs = [NSCharacterSet characterSetWithCharactersInString:@"acersvwxz"];
    });
    return [glyphs characterIsMember:[text characterAtIndex:0]];
}

static UIFont *CSFont(CoreSetRenderFontRole role, CGFloat size) {
    if (!std::isfinite(size) || size <= 0) return nil;
    return [UIFont fontWithName:role == CoreSetRenderFontRoleIcon
        ? CSIconFontName : CSBodyFontName size:size];
}

static CGPoint CSGlyphPoint(CGSize size, CGFloat x, CGFloat y) {
    return CGPointMake(x * size.width, size.height * (0.5 + y));
}
static void CSAddGlyphPath(CALayer *parent, UIBezierPath *path, UIColor *fill,
                           UIColor *stroke, CGFloat thickness) {
    CAShapeLayer *layer = [CAShapeLayer layer];
    layer.frame = parent.bounds;
    layer.path = path.CGPath;
    layer.fillColor = fill.CGColor;
    layer.strokeColor = stroke.CGColor;
    layer.lineWidth = thickness;
    layer.lineJoin = kCALineJoinRound;
    layer.lineCap = kCALineCapRound;
    [parent addSublayer:layer];
}
static void CSPolygon(CALayer *parent, UIColor *color, std::initializer_list<CGPoint> vertices,
                      bool border, CGFloat outline) {
    if (!vertices.size()) return;
    UIBezierPath *path = [UIBezierPath bezierPath];
    auto vertex = vertices.begin();
    [path moveToPoint:CSGlyphPoint(parent.bounds.size, vertex->x, vertex->y)];
    for (++vertex; vertex != vertices.end(); ++vertex)
        [path addLineToPoint:CSGlyphPoint(parent.bounds.size, vertex->x, vertex->y)];
    [path closePath];
    CSAddGlyphPath(parent, path, color, border ? UIColor.blackColor : UIColor.clearColor,
                   border ? outline : 0);
}
static void CSArc(CALayer *parent, UIColor *color, CGFloat centerX, CGFloat radius,
                  CGFloat from, CGFloat to, unsigned points) {
    UIBezierPath *path = [UIBezierPath bezierPath];
    CGPoint center = CSGlyphPoint(parent.bounds.size, centerX, 0);
    for (unsigned index = 0; index < points; ++index) {
        CGFloat angle = from + (to - from) * (CGFloat)index / (CGFloat)(points - 1);
        CGPoint point = CGPointMake(center.x + std::cos(angle) * radius,
                                    center.y + std::sin(angle) * radius);
        if (!index) [path moveToPoint:point]; else [path addLineToPoint:point];
    }
    CSAddGlyphPath(parent, path, UIColor.clearColor, UIColor.blackColor,
                   std::max(0.18 * parent.bounds.size.height, 2.4));
    CSAddGlyphPath(parent, path, UIColor.clearColor, color,
                   std::max(0.095 * parent.bounds.size.height, 1.3));
}
static void CSDot(CALayer *parent, UIColor *color, CGFloat centerX, CGFloat radius,
                  CGFloat alpha, CGFloat borderFactor, CGFloat outline) {
    CGPoint center = CSGlyphPoint(parent.bounds.size, centerX, 0);
    CGFloat outer = radius + outline * borderFactor;
    UIBezierPath *back = [UIBezierPath bezierPathWithOvalInRect:
        CGRectMake(center.x - outer, center.y - outer, 2 * outer, 2 * outer)];
    UIBezierPath *front = [UIBezierPath bezierPathWithOvalInRect:
        CGRectMake(center.x - radius, center.y - radius, 2 * radius, 2 * radius)];
    CSAddGlyphPath(parent, back, UIColor.blackColor, UIColor.clearColor, 0);
    CSAddGlyphPath(parent, front, [color colorWithAlphaComponent:alpha], UIColor.clearColor, 0);
}
static CALayer *CSBackGlyphLayer(CoreSetRenderCommand *command) {
    CALayer *glyph = [CALayer layer];
    glyph.frame = command.rect;
    const CGFloat width = command.rect.size.width, height = command.rect.size.height;
    const CGFloat outline = std::max<CGFloat>(1, width / 80 * 1.35);
    UIColor *color = command.color;
    switch (command.glyphStyle) {
    case 0:
        CSPolygon(glyph, color, {{0,0},{0.42,-0.5},{0.42,-0.19},{1,-0.19},{1,0.19},{0.42,0.19},{0.42,0.5}}, true, outline);
        break;
    case 1:
        CSPolygon(glyph, color, {{0,0},{0.38,-0.5},{0.34,-0.26},{1,-0.26},{0.76,0},{1,0.26},{0.34,0.26},{0.38,0.5}}, true, outline);
        break;
    case 2:
        CSPolygon(glyph, color, {{0,0},{0.48,-0.5},{0.48,0.5}}, false, outline);
        CSPolygon(glyph, [color colorWithAlphaComponent:0.46], {{0.48,-0.5},{1,0},{0.48,0.5}}, false, outline);
        CSPolygon(glyph, UIColor.clearColor, {{0,0},{0.48,-0.5},{1,0},{0.48,0.5}}, true, outline);
        break;
    case 3:
        CSArc(glyph, color, 0.67, 0.43 * height, -2.5215926, 2.5215926, 21);
        CSPolygon(glyph, color, {{0,0},{0.52,-0.26},{0.52,0.26}}, true, outline);
        break;
    case 4:
        CSDot(glyph, color, 0.48, std::max(0.15 * height, 1.1), 0.90, 0.72, outline);
        CSDot(glyph, color, 0.67, std::max(0.11 * height, 1.1), 0.65, 0.72, outline);
        CSDot(glyph, color, 0.83, std::max(0.075 * height, 1.1), 0.40, 0.72, outline);
        CSPolygon(glyph, color, {{0,0},{0.30,-0.46},{0.30,0.46}}, true, outline);
        break;
    default:
        CSArc(glyph, color, 0.65, 0.46 * height, -2.4215927, -0.18, 13);
        CSArc(glyph, color, 0.65, 0.46 * height, 0.18, 2.4215927, 13);
        CSDot(glyph, color, 0.65, std::max(0.075 * height, 1.0), 1, 0.65, outline);
        CSPolygon(glyph, color, {{0,0},{0.53,-0.18},{0.53,0.18}}, true, outline);
        break;
    }
    glyph.transform = CATransform3DMakeRotation(command.glyphAngle, 0, 0, 1);
    return glyph;
}

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
        _cornerRadius = 0;
        _glyphStyle = -1;
        _styleRole = CoreSetRenderStyleRoleNone;
        _fontRole = CoreSetRenderFontRoleBody;
        _horizontallyCenteredText = NO;
    }
    return self;
}
- (CoreSetRenderCommand *)copyForRenderMutation {
    CoreSetRenderCommand *copy = [[CoreSetRenderCommand alloc]
        initWithKind:self.kind rect:self.rect endpoint:self.endpoint color:self.color
        lineWidth:self.lineWidth filled:self.isFilled text:self.text fontSize:self.fontSize];
    copy->_localImageName = [_localImageName copy];
    copy->_weaponID = _weaponID;
    copy->_glyphStyle = _glyphStyle;
    copy->_glyphAngle = _glyphAngle;
    copy->_styleRole = _styleRole;
    copy->_cornerRadius = _cornerRadius;
    copy->_fontRole = _fontRole;
    copy->_horizontallyCenteredText = _horizontallyCenteredText;
    copy->_textBackgroundColor = _textBackgroundColor;
    copy->_gradientLeftColor = _gradientLeftColor;
    copy->_gradientRightColor = _gradientRightColor;
    copy->_textBackgroundHorizontalPadding = _textBackgroundHorizontalPadding;
    copy->_textBackgroundVerticalPadding = _textBackgroundVerticalPadding;
    return copy;
}
- (instancetype)styledWithRole:(CoreSetRenderStyleRole)role {
    if ((_kind != CoreSetRenderKindLine && _kind != CoreSetRenderKindText) ||
        role < CoreSetRenderStyleRoleNone || role > CoreSetRenderStyleRoleBotTeam) return self;
    CoreSetRenderCommand *copy = [self copyForRenderMutation];
    copy->_styleRole = role;
    return copy;
}
- (instancetype)centeredText {
    if (_kind != CoreSetRenderKindText || _horizontallyCenteredText) return self;
    CoreSetRenderCommand *copy = [self copyForRenderMutation];
    copy->_horizontallyCenteredText = YES;
    return copy;
}
- (instancetype)roundedWithRadius:(CGFloat)radius {
    if (_kind != CoreSetRenderKindRectangle || !std::isfinite(radius) ||
        radius < 0 || radius > 256 || radius == _cornerRadius) return self;
    CoreSetRenderCommand *copy = [self copyForRenderMutation];
    copy->_cornerRadius = radius;
    return copy;
}
- (instancetype)horizontalGradientFromColor:(UIColor *)leftColor
                                     toColor:(UIColor *)rightColor {
    if (_kind != CoreSetRenderKindRectangle || !_filled || _cornerRadius != 0 ||
        !leftColor || !rightColor) return self;
    CoreSetRenderCommand *copy = [self copyForRenderMutation];
    copy->_gradientLeftColor = leftColor;
    copy->_gradientRightColor = rightColor;
    return copy;
}
- (instancetype)usingFontRole:(CoreSetRenderFontRole)role {
    if (_kind != CoreSetRenderKindText || role < CoreSetRenderFontRoleBody ||
        role > CoreSetRenderFontRoleIcon) return self;
    CoreSetRenderCommand *copy = [self copyForRenderMutation];
    copy->_fontRole = role;
    return copy;
}
- (instancetype)backedTextWithColor:(UIColor *)color
                  horizontalPadding:(CGFloat)horizontalPadding
                    verticalPadding:(CGFloat)verticalPadding {
    if (_kind != CoreSetRenderKindText || !color || !std::isfinite(horizontalPadding) ||
        !std::isfinite(verticalPadding) || horizontalPadding < 0 || verticalPadding < 0 ||
        horizontalPadding > 64 || verticalPadding > 64) return self;
    CoreSetRenderCommand *copy = [self copyForRenderMutation];
    copy->_textBackgroundColor = color;
    copy->_textBackgroundHorizontalPadding = horizontalPadding;
    copy->_textBackgroundVerticalPadding = verticalPadding;
    return copy;
}
@end

static CGRect CSCenteredTextRect(CoreSetRenderCommand *command) {
    UIFont *font = CSFont(command.fontRole, command.fontSize);
    if (!font) return CGRectNull;
    CGFloat measured = [(command.text ?: @"") sizeWithAttributes:@{NSFontAttributeName: font}].width;
    CoreSet::CenteredTextSpan span = {};
    if (!CoreSet::centeredTextSpan(CGRectGetMidX(command.rect), measured, &span)) return CGRectNull;
    return CGRectMake(span.originX, command.rect.origin.y,
                      span.width, command.rect.size.height);
}

static NSString *CSCommandLayerSignature(CoreSetRenderCommand *command) {
    if (command.kind == CoreSetRenderKindBackGlyph) return @"back-glyph";
    if (command.kind == CoreSetRenderKindImage) return @"image";
    if (command.kind == CoreSetRenderKindRectangle && command.gradientLeftColor) return @"gradient";
    if (command.kind == CoreSetRenderKindText)
        return command.textBackgroundColor ? @"text-background" : @"text";
    return @"shape";
}

static void CSResetCommandContainer(CALayer *container, CoreSetRenderCommand *command) {
    NSString *signature = CSCommandLayerSignature(command);
    if ([container.name isEqualToString:signature]) return;
    container.sublayers = nil;
    container.contents = nil;
    container.name = signature;
    if ([signature isEqualToString:@"back-glyph"]) return;
    if ([signature isEqualToString:@"gradient"]) {
        [container addSublayer:[CAGradientLayer layer]];
    } else if ([signature isEqualToString:@"text-background"]) {
        [container addSublayer:[CALayer layer]];
        [container addSublayer:[CATextLayer layer]];
    } else if ([signature isEqualToString:@"text"]) {
        [container addSublayer:[CATextLayer layer]];
    } else if ([signature isEqualToString:@"image"]) {
        [container addSublayer:[CALayer layer]];
    } else {
        [container addSublayer:[CAShapeLayer layer]];
    }
}

static BOOL CSConfigureCommandContainer(CALayer *container, CoreSetRenderCommand *command,
                                        CGSize canvasSize, CGFloat scale) {
    CSResetCommandContainer(container, command);
    container.frame = CGRectMake(0, 0, canvasSize.width, canvasSize.height);
    container.hidden = NO;
    NSString *signature = container.name;
    if ([signature isEqualToString:@"back-glyph"]) {
        CALayer *glyph = CSBackGlyphLayer(command);
        if (!glyph) return NO;
        container.sublayers = @[glyph];
        return YES;
    }
    if ([signature isEqualToString:@"image"]) {
        UIImage *image = command.weaponID != 0
            ? [CoreSetWeaponImageCatalog imageForWeaponID:command.weaponID]
            : [UIImage imageNamed:command.localImageName];
        CALayer *layer = container.sublayers.firstObject;
        if (!image || !layer) return NO;
        layer.frame = command.rect;
        layer.contents = (__bridge id)image.CGImage;
        layer.contentsGravity = kCAGravityResizeAspect;
        layer.contentsScale = scale;
        return YES;
    }
    if ([signature isEqualToString:@"gradient"]) {
        CAGradientLayer *gradient = (CAGradientLayer *)container.sublayers.firstObject;
        if (![gradient isKindOfClass:CAGradientLayer.class]) return NO;
        gradient.frame = command.rect;
        gradient.colors = @[(id)command.gradientLeftColor.CGColor,
                            (id)command.gradientRightColor.CGColor];
        gradient.startPoint = CGPointMake(0, 0.5);
        gradient.endPoint = CGPointMake(1, 0.5);
        return YES;
    }
    if ([signature hasPrefix:@"text"]) {
        UIFont *font = CSFont(command.fontRole, command.fontSize);
        CGRect textRect = command.horizontallyCenteredText
            ? CSCenteredTextRect(command) : command.rect;
        if (!font || CGRectIsNull(textRect)) return NO;
        NSUInteger textIndex = 0;
        if ([signature isEqualToString:@"text-background"]) {
            CALayer *background = container.sublayers.firstObject;
            if (!background) return NO;
            background.frame = CGRectInset(textRect,
                -command.textBackgroundHorizontalPadding,
                -command.textBackgroundVerticalPadding);
            background.backgroundColor = command.textBackgroundColor.CGColor;
            textIndex = 1;
        }
        if (container.sublayers.count <= textIndex) return NO;
        CATextLayer *text = (CATextLayer *)container.sublayers[textIndex];
        if (![text isKindOfClass:CATextLayer.class]) return NO;
        text.frame = textRect;
        text.string = command.text ?: @"";
        text.fontSize = command.fontSize;
        text.font = (__bridge CFTypeRef)font.fontName;
        text.foregroundColor = command.color.CGColor;
        text.contentsScale = scale;
        text.truncationMode = kCATruncationEnd;
        return YES;
    }
    CAShapeLayer *shape = (CAShapeLayer *)container.sublayers.firstObject;
    if (![shape isKindOfClass:CAShapeLayer.class]) return NO;
    UIBezierPath *path;
    if (command.kind == CoreSetRenderKindLine) {
        path = [UIBezierPath bezierPath];
        [path moveToPoint:command.rect.origin];
        [path addLineToPoint:command.endpoint];
    } else if (command.kind == CoreSetRenderKindEllipse) {
        path = [UIBezierPath bezierPathWithOvalInRect:command.rect];
    } else if (command.cornerRadius > 0) {
        path = [UIBezierPath bezierPathWithRoundedRect:command.rect
                                         cornerRadius:command.cornerRadius];
    } else {
        path = [UIBezierPath bezierPathWithRect:command.rect];
    }
    shape.path = path.CGPath;
    shape.lineWidth = command.lineWidth;
    shape.strokeColor = command.color.CGColor;
    shape.fillColor = command.isFilled && command.kind != CoreSetRenderKindLine
        ? command.color.CGColor : UIColor.clearColor.CGColor;
    return YES;
}

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

@implementation CoreSetCoreAnimationConsumer {
    CALayer *_root;
    __weak UIView *_view;
    NSMutableArray<CALayer *> *_commandLayers;
}
- (instancetype)init {
    if ((self = [super init])) {
        _root = [CALayer layer];
        _root.masksToBounds = YES;
        _commandLayers = [NSMutableArray array];
    }
    return self;
}
- (CoreSetHUDBackend)backend { return CoreSetHUDBackendCoreAnimation; }
- (void)attachToView:(UIView *)view {
    NSAssert(NSThread.isMainThread, @"Rendering must run on the main thread");
    _view = view;
    [_root removeFromSuperlayer];
    _root.name = @"CoreSetHostedDrawContent";
    CSEnableHostedLayerUpdates(view.layer);
    CSEnableHostedLayerUpdates(_root);
    [view.layer addSublayer:_root];
}
- (void)setVisible:(BOOL)visible { _root.hidden = !visible; }
- (void)clear { _root.sublayers = nil; [_commandLayers removeAllObjects]; }
- (void)detach { [self clear]; [_root removeFromSuperlayer]; _view = nil; }
- (BOOL)consumeFrame:(CoreSetRenderFrame *)frame error:(NSError **)error {
    if (!NSThread.isMainThread) {
        if (error) *error = [NSError errorWithDomain:@"CoreSetRender" code:2
            userInfo:@{NSLocalizedDescriptionKey:@"Main thread required"}];
        return NO;
    }
    const CGSize size = frame.canvasSize;
    BOOL valid = _view &&
        std::isfinite(size.width) && std::isfinite(size.height) && size.width > 0 && size.height > 0 &&
        frame.commands.count <= 8192;
    for (CoreSetRenderCommand *command in frame.commands) {
        if (![command isKindOfClass:CoreSetRenderCommand.class]) { valid = NO; break; }
        const CGRect r = command.rect;
        valid = valid && command.kind >= CoreSetRenderKindLine && command.kind <= CoreSetRenderKindBackGlyph &&
            std::isfinite(r.origin.x) && std::isfinite(r.origin.y) &&
            std::isfinite(r.size.width) && std::isfinite(r.size.height) && r.size.width >= 0 && r.size.height >= 0 &&
            std::isfinite(command.endpoint.x) && std::isfinite(command.endpoint.y) &&
            std::isfinite(command.lineWidth) && command.lineWidth >= 0 && command.lineWidth <= 1024 &&
            std::isfinite(command.cornerRadius) && command.cornerRadius >= 0 && command.cornerRadius <= 256 &&
            std::isfinite(command.fontSize) && command.fontSize > 0 && command.fontSize <= 512 && command.color != nil;
        if (command.kind != CoreSetRenderKindRectangle && command.cornerRadius != 0) valid = NO;
        const BOOL hasGradient = command.gradientLeftColor || command.gradientRightColor;
        if (hasGradient)
            valid = valid && command.kind == CoreSetRenderKindRectangle && command.isFilled &&
                command.cornerRadius == 0 && command.gradientLeftColor && command.gradientRightColor;
        if (command.kind == CoreSetRenderKindText) {
            valid = valid && command.text.length <= 4096 &&
                command.fontRole >= CoreSetRenderFontRoleBody &&
                command.fontRole <= CoreSetRenderFontRoleIcon &&
                CSFont(command.fontRole, command.fontSize) != nil &&
                (command.fontRole != CoreSetRenderFontRoleIcon || CSIconGlyphAllowed(command.text));
            if (valid && command.horizontallyCenteredText)
                valid = !CGRectIsNull(CSCenteredTextRect(command));
            valid = valid && std::isfinite(command.textBackgroundHorizontalPadding) &&
                std::isfinite(command.textBackgroundVerticalPadding) &&
                command.textBackgroundHorizontalPadding >= 0 &&
                command.textBackgroundHorizontalPadding <= 64 &&
                command.textBackgroundVerticalPadding >= 0 &&
                command.textBackgroundVerticalPadding <= 64;
        } else if (command.horizontallyCenteredText || command.textBackgroundColor != nil ||
                   command.fontRole != CoreSetRenderFontRoleBody) valid = NO;
        if (command.kind == CoreSetRenderKindImage)
            valid = valid && (command.weaponID != 0
                ? [CoreSetWeaponImageCatalog imageForWeaponID:command.weaponID] != nil
                : ([command.localImageName isEqualToString:@"CoreSetLoading.png"] &&
                   [UIImage imageNamed:command.localImageName] != nil));
        if (command.kind == CoreSetRenderKindBackGlyph)
            valid = valid && command.glyphStyle >= 0 && command.glyphStyle <= 5 &&
                std::isfinite(command.glyphAngle) && r.size.width >= 1 && r.size.height >= 1 &&
                r.size.width <= 160 && r.size.height <= 160;
        if (!valid) break;
    }
    if (!valid) {
        [self clear];
        if (error) *error = [NSError errorWithDomain:@"CoreSetRender" code:1
            userInfo:@{NSLocalizedDescriptionKey:@"Invalid frame or unavailable canvas"}];
        return NO;
    }
    const CGFloat scale = _view.window.screen.scale ?: UIScreen.mainScreen.scale;
    while (_commandLayers.count < frame.commands.count)
        [_commandLayers addObject:[CALayer layer]];
    NSMutableArray<CALayer *> *layers = [NSMutableArray arrayWithCapacity:frame.commands.count];
    NSUInteger index = 0;
    for (CoreSetRenderCommand *command in frame.commands) {
        CALayer *container = _commandLayers[index++];
        if (!CSConfigureCommandContainer(container, command, size, scale)) {
            [self clear];
            if (error) *error = [NSError errorWithDomain:@"CoreSetRender" code:3
                userInfo:@{NSLocalizedDescriptionKey:@"Reusable layer update failed"}];
            return NO;
        }
        [layers addObject:container];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _root.frame = _view.bounds;
    _root.sublayerTransform = CATransform3DMakeScale(_view.bounds.size.width / size.width,
                                                   _view.bounds.size.height / size.height, 1);
    _root.sublayers = layers;
    [CATransaction commit];
    // The source app is backgrounded while the game is foreground.  Match the
    // working WZ retained renderer and flush the committed layer tree so the
    // SpringBoard CALayerHost receives the new transaction immediately.
    [CATransaction flush];
    return YES;
}
@end
