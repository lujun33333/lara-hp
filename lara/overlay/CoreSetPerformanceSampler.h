#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Metrics belong to this app process, never the target game process.
@interface CoreSetPerformanceSample : NSObject
@property(nonatomic, readonly) int32_t processID;
@property(nonatomic, strong, readonly) NSDate *observedAt;
@property(nonatomic, readonly) BOOL cpuValid;
@property(nonatomic, readonly) BOOL memoryValid;
@property(nonatomic, readonly) double cpuPercent;
@property(nonatomic, readonly) double residentMiB;
@property(nonatomic, readonly) double peakResidentMiB;
@end

@interface CoreSetPerformanceSampler : NSObject
// Call serially. A missing system reading is represented by its validity flag.
- (nullable CoreSetPerformanceSample *)sample;
@end

NS_ASSUME_NONNULL_END
