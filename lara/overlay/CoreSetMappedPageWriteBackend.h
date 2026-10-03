#import <Foundation/Foundation.h>
#import "CoreSetReadSession.h"
#import "CoreSetTargetWriteSession.h"

NS_ASSUME_NONNULL_BEGIN

// Internal transport only. Public callers never receive a general UVA write.
@interface CoreSetMappedPageWriteBackend : NSObject
@property(nonatomic, readonly) BOOL ready;
@property(nonatomic, readonly) BOOL pendingCleanup;
@property(nonatomic, readonly) BOOL aliasesReleased;
- (instancetype)initWithReadSession:(CoreSetReadSession *)readSession;
- (BOOL)connectForController:(uint64_t)controller;
- (BOOL)matchesPID:(int32_t)pid imageBase:(uint64_t)imageBase
        generation:(uint64_t)generation controller:(uint64_t)controller;
- (size_t)writeControllerSlot:(CoreSetTargetWriteSlot)slot
                         axis:(CoreSetTargetWriteAxis)axis
                   controller:(uint64_t)controller
                        bytes:(const void *)bytes length:(size_t)length;
- (BOOL)disconnect;
@end

NS_ASSUME_NONNULL_END
