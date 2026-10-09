#import <UIKit/UIKit.h>
#import "CoreSetPresentationCadence.h"
#import "CoreSetHUDLifecycle.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CoreSetRenderKind) {
    CoreSetRenderKindLine,
    CoreSetRenderKindRectangle,
    CoreSetRenderKindEllipse,
    CoreSetRenderKindText,
    CoreSetRenderKindImage,
    CoreSetRenderKindBackGlyph,
};

typedef NS_ENUM(NSInteger, CoreSetRenderStyleRole) {
    CoreSetRenderStyleRoleNone,
    CoreSetRenderStyleRolePlayerRay,
    CoreSetRenderStyleRoleBotRay,
    CoreSetRenderStyleRolePlayerDistance,
    CoreSetRenderStyleRoleBotDistance,
    CoreSetRenderStyleRolePlayerBone,
    CoreSetRenderStyleRoleBotBone,
    CoreSetRenderStyleRoleMaterialText,
    CoreSetRenderStyleRolePlayerName,
    CoreSetRenderStyleRoleBotName,
    CoreSetRenderStyleRolePlayerTeam,
    CoreSetRenderStyleRoleBotTeam,
};

// Core v1.7 embeds two independent ImGui fonts. Body text uses OPPOSans-H;
// the icon face is the 25-point IcoMoon face and is never used as a fallback
// for ordinary text.
typedef NS_ENUM(NSInteger, CoreSetRenderFontRole) {
    CoreSetRenderFontRoleBody,
    CoreSetRenderFontRoleIcon,
};

// Immutable, application-neutral drawing input. Coordinates use canvas points.
@interface CoreSetRenderCommand : NSObject
@property(nonatomic, readonly) CoreSetRenderKind kind;
@property(nonatomic, readonly) CGRect rect;
@property(nonatomic, readonly) CGPoint endpoint;
@property(nonatomic, readonly) CGFloat lineWidth;
@property(nonatomic, readonly) CGFloat cornerRadius;
@property(nonatomic, readonly) CGFloat fontSize;
@property(nonatomic, readonly, getter=isFilled) BOOL filled;
@property(nonatomic, strong, readonly) UIColor *color;
@property(nonatomic, copy, readonly, nullable) NSString *text;
@property(nonatomic, copy, readonly, nullable) NSString *localImageName;
@property(nonatomic, readonly) uint32_t weaponID;
@property(nonatomic, readonly) NSInteger glyphStyle;
@property(nonatomic, readonly) CGFloat glyphAngle;
@property(nonatomic, readonly) CoreSetRenderStyleRole styleRole;
@property(nonatomic, readonly) CoreSetRenderFontRole fontRole;
@property(nonatomic, readonly) BOOL horizontallyCenteredText;
@property(nonatomic, strong, readonly, nullable) UIColor *textBackgroundColor;
@property(nonatomic, strong, readonly, nullable) UIColor *gradientLeftColor;
@property(nonatomic, strong, readonly, nullable) UIColor *gradientRightColor;
@property(nonatomic, readonly) CGFloat textBackgroundHorizontalPadding;
@property(nonatomic, readonly) CGFloat textBackgroundVerticalPadding;
- (instancetype)initWithKind:(CoreSetRenderKind)kind rect:(CGRect)rect endpoint:(CGPoint)endpoint
                       color:(UIColor *)color lineWidth:(CGFloat)lineWidth filled:(BOOL)filled
                        text:(nullable NSString *)text fontSize:(CGFloat)fontSize NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)styledWithRole:(CoreSetRenderStyleRole)role
    NS_SWIFT_NAME(styled(role:));
- (instancetype)centeredText NS_SWIFT_NAME(centeredText());
- (instancetype)roundedWithRadius:(CGFloat)radius
    NS_SWIFT_NAME(rounded(radius:));
- (instancetype)horizontalGradientFromColor:(UIColor *)leftColor
                                     toColor:(UIColor *)rightColor
    NS_SWIFT_NAME(horizontalGradient(from:to:));
- (instancetype)usingFontRole:(CoreSetRenderFontRole)role
    NS_SWIFT_NAME(usingFont(_:));
- (instancetype)backedTextWithColor:(UIColor *)color
                  horizontalPadding:(CGFloat)horizontalPadding
                    verticalPadding:(CGFloat)verticalPadding
    NS_SWIFT_NAME(backedText(color:horizontalPadding:verticalPadding:));
// Bundled loading art remains a separate allowlisted resource.
+ (nullable instancetype)localImageNamed:(NSString *)name rect:(CGRect)rect;
+ (nullable instancetype)weaponImageWithID:(uint32_t)weaponID rect:(CGRect)rect
    NS_SWIFT_NAME(weaponImage(id:rect:));
+ (nullable instancetype)backGlyphWithStyle:(NSInteger)style rect:(CGRect)rect
                                     angle:(CGFloat)angle color:(UIColor *)color
    NS_SWIFT_NAME(backGlyph(style:rect:angle:color:));
@end

// Bundle-only image catalogue. All public methods are main-thread confined.
// Completion reports decoded and SHA-256-verified availability, never a game effect.
@interface CoreSetWeaponImageCatalog : NSObject
+ (BOOL)ready NS_SWIFT_NAME(isReady());
+ (nullable UIImage *)imageForWeaponID:(uint32_t)weaponID NS_SWIFT_NAME(image(for:));
+ (void)prepareWithCompletion:(void (^)(BOOL ready))completion NS_SWIFT_NAME(prepare(completion:));
+ (void)stop;
@end

@interface CoreSetRenderFrame : NSObject
@property(nonatomic, readonly) uint64_t generation;
@property(nonatomic, readonly) uint64_t sequence;
@property(nonatomic, readonly) CGSize canvasSize;
@property(nonatomic, readonly) uint64_t configRevision;
@property(nonatomic, copy, readonly) NSString *snapshotID;
@property(nonatomic, copy, readonly) NSString *requestToken;
@property(nonatomic, copy, readonly) NSArray<CoreSetRenderCommand *> *commands;
- (instancetype)initWithGeneration:(uint64_t)generation sequence:(uint64_t)sequence
                       canvasSize:(CGSize)canvasSize commands:(NSArray<CoreSetRenderCommand *> *)commands;
- (instancetype)initWithGeneration:(uint64_t)generation sequence:(uint64_t)sequence
                       canvasSize:(CGSize)canvasSize configRevision:(uint64_t)configRevision
                       snapshotID:(NSString *)snapshotID requestToken:(NSString *)requestToken
                         commands:(NSArray<CoreSetRenderCommand *> *)commands NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

// Consumer methods run on the main thread. A Metal adapter supplies its own view;
// this module does not require Metal/ImGui or claim that an absent adapter works.
@protocol CoreSetFrameConsumer <NSObject>
@property(nonatomic, readonly) CoreSetHUDBackend backend;
- (void)attachToView:(UIView *)view;
- (BOOL)consumeFrame:(CoreSetRenderFrame *)frame error:(NSError * _Nullable * _Nullable)error;
- (void)setVisible:(BOOL)visible;
- (void)clear;
- (void)detach;
@optional
// A non-nil adapter is not itself a usable Metal surface.
- (BOOL)renderSurfaceReady;
// Only an adapter with a real display scheduler (for example a configured
// CADisplayLink/Metal drawable loop) may implement these observed controls.
- (NSInteger)observedRenderFPS;
- (BOOL)setPreferredRenderFPS:(NSInteger)fps;
// Present-handler host timestamps only; zero/dropped/stale observations fail closed.
- (CoreSetPresentationCadenceSample)observedPresentationCadence;
@end

@interface CoreSetCoreAnimationConsumer : NSObject <CoreSetFrameConsumer>
@end

NS_ASSUME_NONNULL_END
