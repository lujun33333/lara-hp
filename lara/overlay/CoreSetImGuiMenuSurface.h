#import <UIKit/UIKit.h>
#import "CoreSetHUDHost.h"

NS_ASSUME_NONNULL_BEGIN

// The Swift owner publishes immutable, value-only menu records.  No UIKit
// control participates in rendering or hit testing on this path. Scalar
// changed values update the owner during the current ImGui frame.
@protocol CoreSetImGuiMenuModel <NSObject>
@property(nonatomic, readonly) uint64_t imguiMenuModelRevision;
- (NSDictionary<NSString *, id> *)imguiMenuSnapshot;
- (BOOL)performImGuiMenuAction:(NSString *)action value:(double)value;
@end

// Core v1.7 menu surface: a dedicated ImGui context, Metal renderer and
// ImGuiIO pointer input. The host captures the surface, not widget actions.
// The draw HUD owns a different ImGui context.
@interface CoreSetImGuiMenuViewController : UIViewController <CoreSetHostedMenuTapConsumer>
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)initWithModel:(id<CoreSetImGuiMenuModel>)model NS_DESIGNATED_INITIALIZER;
@property(nonatomic, weak, readonly) id<CoreSetImGuiMenuModel> model;
@end

NS_ASSUME_NONNULL_END
