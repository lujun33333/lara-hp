#import "CoreSetRenderCommands.h"

NS_ASSUME_NONNULL_BEGIN

// Generic immutable-frame renderer. The existing application-neutral CA
// primitives rasterize to an image; Metal presents that image to a drawable.
// A successful consumeFrame means the command buffer completed locally, not
// that a cross-application surface or a device pixel was observed.
@interface CoreSetMetalRenderAdapter : NSObject <CoreSetFrameConsumer>
@end

NS_ASSUME_NONNULL_END
