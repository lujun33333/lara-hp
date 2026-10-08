#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Static Core 1.7 scene contract: one interactive floating scene and one
// non-interactive drawing scene, created through FrontBoard at level 1.
@interface CoreSetFloatingSceneManager : NSObject
+ (instancetype)shared NS_SWIFT_NAME(shared());
- (void)createScenesWithCompletion:(void (^)(UIWindowScene * _Nullable touchScene,
                                              UIWindowScene * _Nullable drawScene))completion
    NS_SWIFT_NAME(createScenes(completion:));
- (void)connectScene:(UIWindowScene *)scene identifier:(NSString *)identifier
    NS_SWIFT_NAME(connect(scene:identifier:));
- (void)disconnectScene:(UIWindowScene *)scene NS_SWIFT_NAME(disconnect(scene:));
+ (BOOL)isFloatingIdentifier:(NSString *)identifier
    NS_SWIFT_NAME(isFloating(identifier:));
@end

NS_ASSUME_NONNULL_END
