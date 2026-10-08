#import "CoreSetPerformanceSampler.h"
#include "CoreSetPerformanceMetrics.h"
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import <sys/resource.h>
#import <unistd.h>
#import <cmath>
#include <mutex>

@interface CoreSetPerformanceSample ()
@property(nonatomic) int32_t processID;
@property(nonatomic, strong) NSDate *observedAt;
@property(nonatomic) BOOL cpuValid;
@property(nonatomic) BOOL footprintValid;
@property(nonatomic) BOOL peakValid;
@property(nonatomic) BOOL fallbackCPUValid;
@property(nonatomic) double cpuPercent;
@property(nonatomic) double footprintMiB;
@property(nonatomic) double peakFootprintMiB;
@property(nonatomic) double fallbackCPUPercent;
@end
@implementation CoreSetPerformanceSample @end

// Reference peak is process-lifetime state, not a per-menu sampled-resident
// maximum. All instances serialize system reads, PID resets and CAS updates.
static std::mutex CSPerformanceMutex;
static std::atomic<float> CSPeakFootprintMiB{0};
static int32_t CSPeakProcessID = 0;
static bool CSHasPeakObservation = false;

@implementation CoreSetPerformanceSampler {
    double _previousWall;
    double _previousCPU;
    int32_t _processID;
}

- (CoreSetPerformanceSample *)sample {
    std::lock_guard<std::mutex> samplingLock(CSPerformanceMutex);
    const int32_t pid = getpid();
    if (pid <= 0) return nil;
    const double now = CACurrentMediaTime();
    if (!std::isfinite(now) || now <= 0) return nil;
    CoreSetPerformanceSample *result = [CoreSetPerformanceSample new];
    result.processID = pid;
    result.observedAt = [NSDate date];
    if (CSPeakProcessID != pid) {
        CSPeakFootprintMiB.store(0, std::memory_order_release);
        CSHasPeakObservation = false; CSPeakProcessID = pid;
    }
    thread_act_array_t threads = nullptr;
    mach_msg_type_number_t threadCount = 0;
    const kern_return_t threadsResult = task_threads(mach_task_self(), &threads, &threadCount);
    bool primaryCPUValid = threadsResult == KERN_SUCCESS && threads != nullptr && threadCount > 0;
    float primaryCPU = 0;
    if (threadsResult == KERN_SUCCESS && threads != nullptr) {
        for (mach_msg_type_number_t index = 0; index < threadCount; ++index) {
            thread_basic_info_data_t info = {};
            mach_msg_type_number_t infoCount = THREAD_BASIC_INFO_COUNT;
            const kern_return_t infoResult = thread_info(threads[index], THREAD_BASIC_INFO,
                reinterpret_cast<thread_info_t>(&info), &infoCount);
            if (infoResult != KERN_SUCCESS || infoCount < THREAD_BASIC_INFO_COUNT ||
                !CoreSetPerformanceMetrics::accumulateThread(info.cpu_usage, (info.flags & TH_FLAGS_IDLE) != 0, primaryCPU)) {
                primaryCPUValid = false; // A partial thread sum is not the full primary reading.
            }
            if (mach_port_deallocate(mach_task_self(), threads[index]) != KERN_SUCCESS) primaryCPUValid = false;
        }
        if (vm_deallocate(mach_task_self(), reinterpret_cast<vm_address_t>(threads),
                          vm_size_t(threadCount) * sizeof(thread_t)) != KERN_SUCCESS) primaryCPUValid = false;
    }
    if (primaryCPUValid) { result.cpuPercent = primaryCPU; result.cpuValid = YES; }
    else NSLog(@"Core-SET: performance point=v17-030 primaryValid=0 source=nonidle-thread-basic-info reason=thread-enumeration/info/count/cleanup-unconfirmed fallback-does-not-confirm-primary=1");
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
                    result.fallbackCPUPercent = percent;
                    result.fallbackCPUValid = YES;
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
    task_vm_info_data_t vm = {};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO,
                  reinterpret_cast<task_info_t>(&vm), &count) == KERN_SUCCESS &&
        count >= TASK_VM_INFO_REV1_COUNT) {
        const float footprint = CoreSetPerformanceMetrics::footprintMiB(vm.phys_footprint);
        if (std::isfinite(footprint) && footprint >= 0) {
            result.footprintMiB = footprint; result.footprintValid = YES;
            if (CoreSetPerformanceMetrics::updatePeak(footprint, CSPeakFootprintMiB)) CSHasPeakObservation = true;
        }
    }
    if (CSHasPeakObservation) {
        const float peak = CSPeakFootprintMiB.load(std::memory_order_acquire);
        if (std::isfinite(peak) && peak >= 0) { result.peakFootprintMiB = peak; result.peakValid = YES; }
    }
    if (!result.footprintValid) NSLog(@"Core-SET: performance point=v17-031 valid=0 source=TASK_VM_INFO.phys_footprint reason=task-info/count/value-unconfirmed peakValid=%d", result.peakValid);
    if (!result.peakValid) NSLog(@"Core-SET: performance point=v17-032 valid=0 source=process-lifetime-footprint-CAS-max reason=no-confirmed-footprint-baseline");
    if (!result.cpuValid && result.fallbackCPUValid) NSLog(@"Core-SET: performance point=v17-030 fallbackValid=1 fallback=%.1f source=RUSAGE_SELF-delta scope=diagnostic-only primaryValid=0", result.fallbackCPUPercent);
    _processID = pid;
    return result;
}
@end
