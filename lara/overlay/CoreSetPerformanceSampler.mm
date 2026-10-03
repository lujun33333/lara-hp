#import "CoreSetPerformanceSampler.h"
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import <sys/resource.h>
#import <unistd.h>
#import <cmath>
#import <algorithm>

@interface CoreSetPerformanceSample ()
@property(nonatomic) int32_t processID;
@property(nonatomic, strong) NSDate *observedAt;
@property(nonatomic) BOOL cpuValid;
@property(nonatomic) BOOL memoryValid;
@property(nonatomic) double cpuPercent;
@property(nonatomic) double residentMiB;
@property(nonatomic) double peakResidentMiB;
@end
@implementation CoreSetPerformanceSample @end

@implementation CoreSetPerformanceSampler {
    double _previousWall;
    double _previousCPU;
    double _peakResidentMiB;
    int32_t _processID;
}

- (CoreSetPerformanceSample *)sample {
    const int32_t pid = getpid();
    if (pid <= 0) return nil;
    const double now = CACurrentMediaTime();
    if (!std::isfinite(now) || now <= 0) return nil;
    CoreSetPerformanceSample *result = [CoreSetPerformanceSample new];
    result.processID = pid;
    result.observedAt = [NSDate date];
    struct rusage usage = {};
    bool cpuCounterValid = false;
    if (getrusage(RUSAGE_SELF, &usage) == 0) {
        const double seconds = double(usage.ru_utime.tv_sec) +
            double(usage.ru_utime.tv_usec) / 1.0e6 +
            double(usage.ru_stime.tv_sec) + double(usage.ru_stime.tv_usec) / 1.0e6;
        if (std::isfinite(seconds) && seconds >= 0) {
            if (_processID == pid && _previousWall > 0 && now > _previousWall &&
                seconds >= _previousCPU) {
                const double percent = 100.0 * (seconds - _previousCPU) / (now - _previousWall);
                if (std::isfinite(percent) && percent >= 0 && percent <= 10000) {
                    result.cpuPercent = percent;
                    result.cpuValid = YES;
                }
            }
            _previousCPU = seconds;
            _previousWall = now;
            cpuCounterValid = true;
        }
    }
    // A failed/invalid cumulative counter cannot anchor the next interval.
    // Do not present a later cross-failure average as a fresh CPU sample.
    if (!cpuCounterValid) { _previousCPU = 0; _previousWall = 0; }
    mach_task_basic_info_data_t basic = {};
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                  reinterpret_cast<task_info_t>(&basic), &count) == KERN_SUCCESS &&
        count >= MACH_TASK_BASIC_INFO_COUNT) {
        const double resident = double(basic.resident_size) / (1024.0 * 1024.0);
        if (std::isfinite(resident) && resident >= 0) {
            _peakResidentMiB = _processID == pid ? std::max(_peakResidentMiB, resident) : resident;
            result.residentMiB = resident;
            result.peakResidentMiB = _peakResidentMiB;
            result.memoryValid = YES;
        }
    }
    _processID = pid;
    return result;
}
@end
