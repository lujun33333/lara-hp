#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Metrics belong to this app process, never the target game process.
@interface CoreSetPerformanceSample : NSObject
@property(nonatomic, readonly) int32_t processID;
@property(nonatomic, strong, readonly) NSDate *observedAt;
@property(nonatomic, readonly) BOOL cpuValid;
@property(nonatomic, readonly) BOOL footprintValid;
@property(nonatomic, readonly) BOOL peakValid;
@property(nonatomic, readonly) BOOL fallbackCPUValid;
@property(nonatomic, readonly) double cpuPercent;
@property(nonatomic, readonly) double footprintMiB;
@property(nonatomic, readonly) double peakFootprintMiB;
@property(nonatomic, readonly) double fallbackCPUPercent;
@end

@interface CoreSetPerformanceSampler : NSObject
// Sampling is serialized. CPU, footprint and process-lifetime peak validity
// are independent. RUSAGE fallback never confirms the primary CPU field.
- (nullable CoreSetPerformanceSample *)sample;
@end

NS_ASSUME_NONNULL_END
