#if defined(__cplusplus)
#include <stddef.h>
#include <string.h>
namespace coreset_read_contract {
inline constexpr size_t maximumLength = 0x10000;
// Invalid spans are not writable contracts. Clear every valid bounded span
// before checking address, generation, identity or transport completion.
inline bool clearDestination(void *destination, size_t length) {
    if (!destination || length == 0 || length > maximumLength) return false;
    memset(destination, 0, length);
    return true;
}
}
#endif

#if !defined(CORESET_READ_BUFFER_CONTRACT_ONLY)
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// A target-specific, read-only lease. This type exposes no remote write/call API.
@interface CoreSetReadCleanupResult : NSObject
@property(nonatomic, readonly) BOOL taskPortReleased;
@property(nonatomic, readonly) BOOL transportReleased;
@property(nonatomic, readonly) BOOL generationAdvanced;
@property(nonatomic, readonly) BOOL complete;
- (instancetype)initWithTaskPortReleased:(BOOL)taskPortReleased
                       transportReleased:(BOOL)transportReleased
                      generationAdvanced:(BOOL)generationAdvanced;
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
// Capture producers compare this sequence before/after their own serialized
// capture. Only a changed sequence attributes lastReadDiagnostic to that capture.
@property(nonatomic, readonly) uint64_t readFailureSequence;
@property(nonatomic, copy, readonly) NSString *lastReadDiagnostic;
// Resource release/generation receipt; no payload or target-write capability.
@property(nonatomic, copy, readonly) NSString *lastCleanupDiagnostic;

// Only ShadowTrackerExtra 1.38.12/build 15915/LC_UUID 34b785b2... is accepted.
// PID discovery follows the WZ order: libproc first, then a kernel allproc lookup
// after DarkSword is ready. Readable bundle metadata must match version/build;
// when proc_pidpath is sandbox-hidden, only a kernel-verified proc plus the exact
// main-executable UUID may replace that metadata gate. Target bytes prefer a
// PID-verified Mach task. When system task-port acquisition is denied, a private
// kernel-mapped read transport may be used after proc/task/vm_map identity and
// the exact executable UUID are verified. The transport exposes no mapped
// address, remote-call or target-write API to collectors.
- (BOOL)connect;
- (BOOL)readAt:(uint64_t)address to:(void *)destination length:(size_t)length
     generation:(uint64_t)generation completedBytes:(size_t *)completedBytes
          error:(NSString * _Nullable * _Nullable)error;
- (CoreSetReadCleanupResult *)disconnect;
@end

NS_ASSUME_NONNULL_END
#endif
