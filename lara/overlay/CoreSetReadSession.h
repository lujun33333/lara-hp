#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// A target-specific, read-only lease. This type exposes no remote write/call API.
@interface CoreSetReadCleanupResult : NSObject
@property(nonatomic, readonly) BOOL taskPortReleased;
@property(nonatomic, readonly) BOOL generationAdvanced;
- (instancetype)initWithTaskPortReleased:(BOOL)released generationAdvanced:(BOOL)advanced;
@end

@interface CoreSetReadSession : NSObject
@property(nonatomic, readonly) BOOL ready;
@property(nonatomic, readonly) uint64_t generation;
@property(nonatomic, readonly) uint64_t imageBase;
@property(nonatomic, readonly) int32_t processID;
@property(nonatomic, readonly) uint64_t capabilities; // Bit 0 = read; no other bits are defined.
// Short lane name used only by transition/throttled diagnostics.
@property(nonatomic, copy) NSString *diagnosticLabel;
// Latest exact connect boundary. This is suitable for unavailable UI text and
// never implies that a request or render receipt has succeeded.
@property(nonatomic, copy, readonly) NSString *lastConnectDiagnostic;

// Only ShadowTrackerExtra 1.38.12/build 15915/LC_UUID 34b785b2... is accepted.
// An unavailable task_read_for_pid port leaves this session unavailable; there is no
// RemoteCall or mapped-page fallback.
- (BOOL)connect;
- (BOOL)readAt:(uint64_t)address to:(void *)destination length:(size_t)length
     generation:(uint64_t)generation completedBytes:(size_t *)completedBytes
          error:(NSString * _Nullable * _Nullable)error;
- (CoreSetReadCleanupResult *)disconnect;
@end

NS_ASSUME_NONNULL_END
