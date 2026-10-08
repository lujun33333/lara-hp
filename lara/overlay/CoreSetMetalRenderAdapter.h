#import "CoreSetRenderCommands.h"

NS_ASSUME_NONNULL_BEGIN

// Core 1.7-compatible Dear ImGui 1.92.8 renderer backed directly by Metal.
// A successful consumeFrame means the command buffer was submitted locally, not
// that a cross-application surface or a device pixel was observed.
@interface CoreSetMetalRenderAdapter : NSObject <CoreSetFrameConsumer>
@end

NS_ASSUME_NONNULL_END
