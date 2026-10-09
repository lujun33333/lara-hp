#import "CoreSetReadSession.h"
#import "CoreSetKernelMappedReadTransport.h"
#import "CoreSetKernelReadProfile.h"
#import "../kexploit/darksword.h"
#import "../kexploit/offsets.h"
#import "../kexploit/utils.h"
#import <dlfcn.h>
#import <limits.h>
#import <mach/mach.h>
#import <mach-o/loader.h>
#import <pthread.h>
#import <stdlib.h>
#import <string.h>
#import <CoreFoundation/CoreFoundation.h>

extern "C" kern_return_t mach_vm_read_overwrite(vm_map_read_t, mach_vm_address_t,
    mach_vm_size_t, mach_vm_address_t, mach_vm_size_t *);
extern "C" kern_return_t mach_vm_region_recurse(vm_map_read_t, mach_vm_address_t *,
    mach_vm_size_t *, natural_t *, vm_region_recurse_info_t, mach_msg_type_number_t *);
extern "C" kern_return_t mach_vm_deallocate(task_t, mach_vm_address_t, mach_vm_size_t);
extern "C" int proc_listallpids(void *, int);
extern "C" int proc_name(int, void *, uint32_t);

static const char *const CSProcessName = "ShadowTrackerExtra";
static const char *const CSBundleID = "com.tencent.tmgp.pubgmhd";
static const char *const CSBuild = "15915";
static const char *const CSVersion = "1.38.12";
static const uint8_t CSUUID[16] = {
    0x34, 0xb7, 0x85, 0xb2, 0x0d, 0xab, 0x39, 0x92,
    0x98, 0x5d, 0x35, 0x9e, 0x6b, 0xf4, 0x55, 0x85
};

typedef struct {
    int pid;
    uint64_t kernelProc;
    const char *source;
} CSProcessCandidate;

typedef struct {
    int pid;
    uint64_t kernelProc;
    bool attempted;
} CSKernelTarget;

typedef struct {
    task_t task;
    kern_return_t result;
    const char *source;
    bool mechanismAvailable;
} CSTaskAcquisition;

static pthread_mutex_t CSProcessResolverLock = PTHREAD_MUTEX_INITIALIZER;
static CSKernelTarget CSCachedKernelTarget = {-1, 0, false};
static CFAbsoluteTime CSCachedKernelTargetAt = 0;

// WZ serializes target discovery around its global transport. Core-SET owns
// several independent read sessions, so share a short-lived kernel proc lookup
// rather than walking allproc once per lane every second.
static CSKernelTarget CSResolveKernelTarget(bool forceRefresh) {
    pthread_mutex_lock(&CSProcessResolverLock);
    const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!forceRefresh && CSCachedKernelTargetAt > 0 &&
        now - CSCachedKernelTargetAt >= 0 && now - CSCachedKernelTargetAt <= 1.0) {
        CSKernelTarget cached = CSCachedKernelTarget;
        pthread_mutex_unlock(&CSProcessResolverLock);
        return cached;
    }

    CSKernelTarget result = {-1, 0, false};
    if (ds_is_ready() && off_proc_p_pid != 0) {
        result.attempted = true;
        result.kernelProc = procbyname(CSProcessName);
        if (result.kernelProc != 0 && ds_address_usable(result.kernelProc) &&
            result.kernelProc <= UINT64_MAX - off_proc_p_pid &&
            ds_address_usable(result.kernelProc + off_proc_p_pid)) {
            const uint32_t pid = ds_kread32(result.kernelProc + off_proc_p_pid);
            if (pid > 0 && pid <= INT_MAX) result.pid = (int)pid;
        } else {
            result.kernelProc = 0;
        }
    }
    CSCachedKernelTarget = result;
    CSCachedKernelTargetAt = now;
    pthread_mutex_unlock(&CSProcessResolverLock);
    return result;
}

static task_t CSTaskFromProcessorSet(int wantedPID, kern_return_t *lastResult,
                                     bool *mechanismAvailable) {
    typedef kern_return_t (*processor_set_default_fn)(host_t, processor_set_name_t *);
    typedef kern_return_t (*host_processor_set_priv_fn)(
        host_priv_t, processor_set_name_t, processor_set_control_t *);
    typedef kern_return_t (*processor_set_tasks_fn)(
        processor_set_control_t, task_array_t *, mach_msg_type_number_t *);
    static processor_set_default_fn processorSetDefault = NULL;
    static host_processor_set_priv_fn hostProcessorSetPriv = NULL;
    static processor_set_tasks_fn processorSetTasks = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        processorSetDefault = (processor_set_default_fn)dlsym(RTLD_DEFAULT, "processor_set_default");
        hostProcessorSetPriv = (host_processor_set_priv_fn)dlsym(RTLD_DEFAULT, "host_processor_set_priv");
        processorSetTasks = (processor_set_tasks_fn)dlsym(RTLD_DEFAULT, "processor_set_tasks");
    });
    const bool available = processorSetDefault && hostProcessorSetPriv && processorSetTasks;
    if (mechanismAvailable) *mechanismAvailable = available;
    if (!available) return MACH_PORT_NULL;

    host_t host = mach_host_self();
    processor_set_name_t setName = MACH_PORT_NULL;
    processor_set_control_t setControl = MACH_PORT_NULL;
    task_array_t tasks = NULL;
    mach_msg_type_number_t taskCount = 0;
    task_t selected = MACH_PORT_NULL;
    kern_return_t kr = processorSetDefault(host, &setName);
    if (kr == KERN_SUCCESS) kr = hostProcessorSetPriv(host, setName, &setControl);
    if (kr == KERN_SUCCESS) kr = processorSetTasks(setControl, &tasks, &taskCount);
    if (kr == KERN_SUCCESS && tasks) {
        for (mach_msg_type_number_t index = 0; index < taskCount; ++index) {
            int candidatePID = -1;
            if (selected == MACH_PORT_NULL &&
                pid_for_task(tasks[index], &candidatePID) == KERN_SUCCESS &&
                candidatePID == wantedPID) {
                selected = tasks[index];
            } else if (tasks[index] != MACH_PORT_NULL) {
                mach_port_deallocate(mach_task_self(), tasks[index]);
            }
        }
        mach_vm_deallocate(mach_task_self(),
            (mach_vm_address_t)(uintptr_t)tasks,
            (mach_vm_size_t)taskCount * sizeof(task_t));
    }
    if (setControl != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), setControl);
    if (setName != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), setName);
    if (host != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), host);
    if (selected == MACH_PORT_NULL && kr == KERN_SUCCESS) kr = KERN_FAILURE;
    if (lastResult) *lastResult = selected != MACH_PORT_NULL ? KERN_SUCCESS : kr;
    return selected;
}

static CSTaskAcquisition CSAcquireTaskForPID(int pid) {
    typedef kern_return_t (*task_for_pid_fn)(mach_port_t, int, mach_port_t *);
    static task_for_pid_fn taskForPID = NULL;
    static task_for_pid_fn taskReadForPID = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        taskForPID = (task_for_pid_fn)dlsym(RTLD_DEFAULT, "task_for_pid");
        taskReadForPID = (task_for_pid_fn)dlsym(RTLD_DEFAULT, "task_read_for_pid");
    });

    CSTaskAcquisition result = {MACH_PORT_NULL, KERN_FAILURE, "none", false};
    const struct {
        task_for_pid_fn function;
        const char *source;
    } attempts[] = {
        {taskForPID, "task_for_pid"},
        {taskReadForPID, "task_read_for_pid"},
    };
    for (const auto &attempt : attempts) {
        if (!attempt.function) continue;
        result.mechanismAvailable = true;
        task_t task = MACH_PORT_NULL;
        result.result = attempt.function(mach_task_self(), pid, &task);
        result.source = attempt.source;
        if (result.result == KERN_SUCCESS && task != MACH_PORT_NULL) {
            result.task = task;
            return result;
        }
        if (task != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), task);
    }

    bool processorSetAvailable = false;
    task_t task = CSTaskFromProcessorSet(pid, &result.result, &processorSetAvailable);
    result.mechanismAvailable = result.mechanismAvailable || processorSetAvailable;
    if (processorSetAvailable) result.source = "processor_set_tasks";
    if (task != MACH_PORT_NULL) result.task = task;
    return result;
}

@implementation CoreSetReadCleanupResult
- (instancetype)initWithTaskPortReleased:(BOOL)taskPortReleased
                       transportReleased:(BOOL)transportReleased
                      generationAdvanced:(BOOL)generationAdvanced {
    if ((self = [super init])) {
        _taskPortReleased = taskPortReleased;
        _transportReleased = transportReleased;
        _generationAdvanced = generationAdvanced;
        _complete = taskPortReleased && transportReleased && generationAdvanced;
    }
    return self;
}
@end

@interface CoreSetReadSession () {
    task_t _task;
    CoreSetKernelMappedReadTransport *_kernelTransport;
    int32_t _pid;
    uint64_t _base;
    uint64_t _generation;
    NSString *_path;
    NSString *_diagnosticLabel;
    NSString *_lastConnectDiagnostic;
    NSString *_lastLoggedDiagnostic;
    CFAbsoluteTime _lastDiagnosticLogTime;
    uint64_t _readFailureSequence;
    NSString *_lastReadDiagnostic;
    NSString *_lastLoggedReadFailureKind;
    CFAbsoluteTime _lastReadFailureLogTime;
    NSString *_lastCleanupDiagnostic;
    NSString *_lastLoggedCleanupKind;
    CFAbsoluteTime _lastCleanupLogTime;
    NSString *_pidSource;
    NSString *_taskSource;
    NSString *_profileSource;
}
@end

@implementation CoreSetReadSession

- (instancetype)init {
    if ((self = [super init])) {
        _task = MACH_PORT_NULL; _pid = -1; _generation = 1;
        _diagnosticLabel = @"unassigned";
        _lastConnectDiagnostic = @"尚未尝试连接目标只读会话";
        _lastReadDiagnostic = @"no-read-failure";
        _lastCleanupDiagnostic = @"no-cleanup-attempt";
    }
    return self;
}

- (void)dealloc { [self disconnect]; }

- (BOOL)ready {
    @synchronized (self) {
        if (_task == MACH_PORT_NULL && !_kernelTransport) return NO;
        if ([self identityStillValid:YES]) return YES;
        [self disconnect];
        [self publishConnectDiagnostic:@"identity-lost stage=ready" ready:NO];
        return NO;
    }
}
- (uint64_t)generation { @synchronized (self) { return _generation; } }
- (uint64_t)imageBase { @synchronized (self) { return _base; } }
- (int32_t)processID { @synchronized (self) { return _pid; } }
- (uint64_t)capabilities { return self.ready ? UINT64_C(1) : 0; }
- (NSString *)diagnosticLabel { @synchronized (self) { return [_diagnosticLabel copy]; } }
- (void)setDiagnosticLabel:(NSString *)value {
    @synchronized (self) {
        NSString *trimmed = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        _diagnosticLabel = trimmed.length ? [trimmed copy] : @"unassigned";
    }
}
- (NSString *)lastConnectDiagnostic {
    @synchronized (self) { return [_lastConnectDiagnostic copy] ?: @"目标只读会话状态未知"; }
}
- (uint64_t)readFailureSequence { @synchronized (self) { return _readFailureSequence; } }
- (NSString *)lastReadDiagnostic {
    @synchronized (self) { return [_lastReadDiagnostic copy] ?: @"no-read-failure"; }
}
- (NSString *)lastCleanupDiagnostic {
    @synchronized (self) { return [_lastCleanupDiagnostic copy] ?: @"cleanup-state-unknown"; }
}

// Called only while this session's lock is held. Never log the read buffer.
- (void)recordReadFailure:(NSString *)kind address:(uint64_t)address
                  length:(size_t)length generation:(uint64_t)generation
               completed:(size_t)completed result:(kern_return_t)result {
    ++_readFailureSequence;
    NSString *transportDetail = @"";
    if (_kernelTransport && [kind isEqualToString:@"read-partial-or-kern-failure"]) {
        transportDetail = [NSString stringWithFormat:@" mappedTransport=%@",
                           _kernelTransport.lastError ?: @"unknown"];
    }
    _lastReadDiagnostic = [NSString stringWithFormat:
        @"%@ captureGeneration=%llu sessionGeneration=%llu address=0x%llx length=%zu completed=%zu kr=0x%x%@",
        kind, (unsigned long long)generation, (unsigned long long)_generation,
        (unsigned long long)address, length, completed, (unsigned)result, transportDetail];
    const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (![_lastLoggedReadFailureKind isEqualToString:kind] || now - _lastReadFailureLogTime >= 30.0) {
        _lastLoggedReadFailureKind = [kind copy];
        _lastReadFailureLogTime = now;
        NSLog(@"Core-SET: target-read lane=%@ stage=read ready=0 failureSequence=%llu reason=%@",
              _diagnosticLabel ?: @"unassigned", (unsigned long long)_readFailureSequence,
              _lastReadDiagnostic);
    }
}

- (void)publishConnectDiagnostic:(NSString *)diagnostic ready:(BOOL)ready {
    NSString *value = diagnostic.length ? diagnostic : @"目标只读会话状态未知";
    const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    const BOOL changed = ![_lastConnectDiagnostic isEqualToString:value];
    _lastConnectDiagnostic = [value copy];
    if (changed || !_lastLoggedDiagnostic || now - _lastDiagnosticLogTime >= 30.0) {
        _lastLoggedDiagnostic = [value copy];
        _lastDiagnosticLogTime = now;
        NSLog(@"Core-SET: target-read lane=%@ stage=connect ready=%d generation=%llu reason=%@",
              _diagnosticLabel ?: @"unassigned", ready ? 1 : 0,
              (unsigned long long)_generation, value);
    }
}

+ (NSString *)pathForPID:(int)pid {
    typedef int (*proc_pidpath_fn)(int, void *, uint32_t);
    proc_pidpath_fn function = (proc_pidpath_fn)dlsym(RTLD_DEFAULT, "proc_pidpath");
    if (!function) return nil;
    char path[PATH_MAX] = {0};
    int count = function(pid, path, sizeof(path));
    if (count <= 0 || count >= (int)sizeof(path)) return nil;
    path[sizeof(path) - 1] = 0;
    NSString *value = [NSString stringWithUTF8String:path];
    return [value.lastPathComponent isEqualToString:@"ShadowTrackerExtra"] ? value : nil;
}

+ (BOOL)profileMatchesPath:(NSString *)path {
    if (!path) return NO;
    NSString *appPath = [path stringByDeletingLastPathComponent];
    if (![appPath.lastPathComponent isEqualToString:@"ShadowTrackerExtra.app"]) return NO;
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
        [appPath stringByAppendingPathComponent:@"Info.plist"]];
    return [info[@"CFBundleIdentifier"] isEqualToString:[NSString stringWithUTF8String:CSBundleID]] &&
           [info[@"CFBundleVersion"] isEqualToString:[NSString stringWithUTF8String:CSBuild]] &&
           [info[@"CFBundleShortVersionString"] isEqualToString:[NSString stringWithUTF8String:CSVersion]];
}

+ (BOOL)imageAt:(uint64_t)address task:(task_t)task {
    struct mach_header_64 header = {0};
    mach_vm_size_t done = 0;
    if (mach_vm_read_overwrite(task, address, sizeof(header),
        (mach_vm_address_t)(uintptr_t)&header, &done) != KERN_SUCCESS || done != sizeof(header)) return NO;
    if (header.magic != MH_MAGIC_64 || header.cputype != CPU_TYPE_ARM64 ||
        header.filetype != MH_EXECUTE || header.ncmds == 0 || header.ncmds >= 0x1000 ||
        header.sizeofcmds < sizeof(struct uuid_command) || header.sizeofcmds > 0x20000 ||
        address > UINT64_MAX - sizeof(header) - header.sizeofcmds) return NO;
    NSMutableData *commands = [NSMutableData dataWithLength:header.sizeofcmds];
    if (!commands) return NO;
    done = 0;
    if (mach_vm_read_overwrite(task, address + sizeof(header), header.sizeofcmds,
        (mach_vm_address_t)(uintptr_t)commands.mutableBytes, &done) != KERN_SUCCESS ||
        done != header.sizeofcmds) return NO;
    const uint8_t *bytes = (const uint8_t *)commands.bytes;
    size_t offset = 0;
    for (uint32_t index = 0; index < header.ncmds; ++index) {
        if (offset > commands.length || commands.length - offset < sizeof(struct load_command)) return NO;
        const struct load_command *command = (const struct load_command *)(bytes + offset);
        if (command->cmdsize < sizeof(*command) || command->cmdsize > commands.length - offset) return NO;
        if (command->cmd == LC_UUID) {
            if (command->cmdsize < sizeof(struct uuid_command)) return NO;
            const struct uuid_command *uuid = (const struct uuid_command *)command;
            return memcmp(uuid->uuid, CSUUID, sizeof(CSUUID)) == 0;
        }
        offset += command->cmdsize;
    }
    return NO;
}

+ (uint64_t)findImageInTask:(task_t)task {
    mach_vm_address_t address = 0;
    natural_t depth = 0;
    for (int visited = 0; visited < 8192; ++visited) {
        mach_vm_size_t size = 0;
        vm_region_submap_info_data_64_t info = {0};
        mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
        kern_return_t kr = mach_vm_region_recurse(task, &address, &size, &depth,
            (vm_region_recurse_info_t)&info, &count);
        if (kr != KERN_SUCCESS) return 0;
        if (info.is_submap) { ++depth; continue; }
        if ((info.protection & VM_PROT_READ) && size >= sizeof(struct mach_header_64) &&
            [self imageAt:address task:task]) return address;
        if (size == 0 || address > UINT64_MAX - size) return 0;
        address += size;
    }
    return 0;
}

- (BOOL)identityStillValid:(BOOL)verifyImage {
    if ((_task == MACH_PORT_NULL && !_kernelTransport) || _pid <= 0 || !_base) return NO;
    if (_task != MACH_PORT_NULL) {
        int currentPID = -1;
        if (pid_for_task(_task, &currentPID) != KERN_SUCCESS || currentPID != _pid) return NO;
    } else if (!_kernelTransport || _kernelTransport.processID != _pid ||
               ![_kernelTransport identityValid]) {
        return NO;
    }
    if (_path) {
        NSString *currentPath = [CoreSetReadSession pathForPID:_pid];
        if (![currentPath isEqualToString:_path] ||
            (verifyImage && ![CoreSetReadSession profileMatchesPath:currentPath])) return NO;
    }
    if (!verifyImage) return YES;
    return _task != MACH_PORT_NULL
        ? [CoreSetReadSession imageAt:_base task:_task]
        : [_kernelTransport imageAt:_base matchesUUID:CSUUID];
}

- (BOOL)connect {
    @synchronized (self) {
        if ([self identityStillValid:YES]) {
            [self publishConnectDiagnostic:[NSString stringWithFormat:
                @"ready pid=%d base=0x%llx uuid=1 profileSource=%@ pidSource=%@ taskSource=%@",
                _pid, (unsigned long long)_base, _profileSource ?: @"unknown",
                _pidSource ?: @"unknown", _taskSource ?: @"unknown"] ready:YES];
            return YES;
        }
        CoreSetReadCleanupResult *cleanup = [self disconnect];
        if (!cleanup.complete || _generation == UINT64_MAX) {
            [self publishConnectDiagnostic:@"cleanup-or-generation-failed" ready:NO]; return NO;
        }
        int pids[4096] = {0};
        const int libprocResult = proc_listallpids(pids, sizeof(pids));
        const int libprocCount = libprocResult > 0
            ? MIN(libprocResult, (int)(sizeof(pids) / sizeof(pids[0]))) : 0;
        CSProcessCandidate candidates[4097] = {};
        int candidateCount = 0;
        for (int index = 0; index < libprocCount; ++index) {
            const int pid = pids[index];
            if (pid <= 0) continue;
            char name[64] = {0};
            if (proc_name(pid, name, sizeof(name)) <= 0 || strcmp(name, CSProcessName) != 0) continue;
            candidates[candidateCount++] = {pid, 0, "libproc"};
        }

        const CSKernelTarget kernelTarget = CSResolveKernelTarget(false);
        if (kernelTarget.pid > 0 && kernelTarget.kernelProc != 0) {
            bool duplicate = false;
            for (int index = 0; index < candidateCount; ++index) {
                if (candidates[index].pid != kernelTarget.pid) continue;
                candidates[index].kernelProc = kernelTarget.kernelProc;
                candidates[index].source = "libproc+kernel-allproc";
                duplicate = true;
                break;
            }
            if (!duplicate && candidateCount < (int)(sizeof(candidates) / sizeof(candidates[0]))) {
                candidates[candidateCount++] = {
                    kernelTarget.pid, kernelTarget.kernelProc, "kernel-allproc"
                };
            }
        }

        BOOL sawProcess = NO, sawPath = NO, sawProfile = NO, sawTask = NO, sawPID = NO;
        BOOL taskMechanismAvailable = NO, kernelIdentityChanged = NO;
        kern_return_t lastTaskResult = KERN_FAILURE;
        const char *lastTaskSource = "none";
        NSString *lastProfile = nil;
        NSString *lastKernelTransportError = nil;
        for (int index = 0; index < candidateCount; ++index) {
            const CSProcessCandidate candidate = candidates[index];
            const int pid = candidate.pid;
            sawProcess = YES;
            NSString *path = [CoreSetReadSession pathForPID:pid];
            NSString *profileSource = nil;
            if (path) {
                sawPath = YES;
                NSString *appPath = [path stringByDeletingLastPathComponent];
                NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                    [appPath stringByAppendingPathComponent:@"Info.plist"]];
                lastProfile = [NSString stringWithFormat:@"bundle=%@ version=%@ build=%@",
                    info[@"CFBundleIdentifier"] ?: @"nil",
                    info[@"CFBundleShortVersionString"] ?: @"nil",
                    info[@"CFBundleVersion"] ?: @"nil"];
                if (![CoreSetReadSession profileMatchesPath:path]) continue;
                sawProfile = YES;
                profileSource = @"bundle-metadata+mach-uuid";
            } else {
                // WZ continues from a kernel-verified proc when the sandbox hides
                // proc_pidpath. The exact main-executable UUID below remains the
                // final identity authority; libproc-only candidates may not skip
                // bundle metadata.
                if (candidate.kernelProc == 0) continue;
                sawPath = YES;
                sawProfile = YES;
                profileSource = @"kernel-proc+mach-uuid";
            }
            const CSTaskAcquisition acquisition = CSAcquireTaskForPID(pid);
            taskMechanismAvailable = taskMechanismAvailable || acquisition.mechanismAvailable;
            lastTaskResult = acquisition.result;
            lastTaskSource = acquisition.source;
            task_t task = acquisition.task;
            if (task != MACH_PORT_NULL) {
                sawTask = YES;
                int verifiedPID = -1;
                if (pid_for_task(task, &verifiedPID) != KERN_SUCCESS || verifiedPID != pid) {
                    mach_port_deallocate(mach_task_self(), task); continue;
                }
                sawPID = YES;
                uint64_t base = [CoreSetReadSession findImageInTask:task];
                if (!base) { mach_port_deallocate(mach_task_self(), task); continue; }
                if (candidate.kernelProc != 0) {
                    const CSKernelTarget current = CSResolveKernelTarget(true);
                    if (current.pid != pid || current.kernelProc != candidate.kernelProc) {
                        kernelIdentityChanged = YES;
                        mach_port_deallocate(mach_task_self(), task);
                        continue;
                    }
                }
                _task = task; _pid = pid; _base = base; _path = [path copy];
                _pidSource = [NSString stringWithUTF8String:candidate.source ?: "unknown"];
                _taskSource = [NSString stringWithUTF8String:acquisition.source ?: "unknown"];
                _profileSource = profileSource;
            } else if (candidate.kernelProc != 0) {
                CoreSetKernelMappedReadTransport *transport =
                    [[CoreSetKernelMappedReadTransport alloc]
                        initWithKernelProcess:candidate.kernelProc expectedPID:pid];
                uint64_t base = transport ? [transport findImageWithUUID:CSUUID] : 0;
                lastKernelTransportError = transport
                    ? transport.lastError : [NSString stringWithFormat:
                        @"mapped-read-prerequisites-or-identity-invalid profile=%@",
                        [CoreSetKernelReadProfile lastFailure]];
                const CSKernelTarget current = CSResolveKernelTarget(true);
                if (!transport || !base || current.pid != pid ||
                    current.kernelProc != candidate.kernelProc || ![transport identityValid]) {
                    kernelIdentityChanged = transport &&
                        (current.pid != pid || current.kernelProc != candidate.kernelProc);
                    if (transport && ![transport disconnect]) {
                        // Retain the owner so a later disconnect can retry every
                        // cached alias/port release. Never orphan cleanup state.
                        _kernelTransport = transport;
                        _pid = pid;
                        _taskSource = @"kernel-mapped-read-cleanup-pending";
                        lastKernelTransportError = transport.lastError;
                        break;
                    }
                    continue;
                }
                sawTask = YES;
                sawPID = YES;
                _kernelTransport = transport; _pid = pid; _base = base; _path = [path copy];
                _pidSource = [NSString stringWithUTF8String:candidate.source ?: "unknown"];
                _taskSource = @"kernel-mapped-read";
                _profileSource = profileSource;
            } else {
                continue;
            }
            if ([self identityStillValid:YES]) {
                ++_generation;
                [self publishConnectDiagnostic:[NSString stringWithFormat:
                    @"ready pid=%d base=0x%llx uuid=1 profileSource=%@ pidSource=%@ taskSource=%@",
                    _pid, (unsigned long long)_base, _profileSource, _pidSource, _taskSource] ready:YES];
                return YES;
            }
            [self disconnect];
        }
        NSString *reason = nil;
        if (!sawProcess && libprocResult <= 0 && !kernelTarget.attempted) {
            reason = [NSString stringWithFormat:
                @"process-discovery-unavailable libproc-count=%d kernel-ready=%d pid-offset=0x%x",
                libprocResult, ds_is_ready() ? 1 : 0, off_proc_p_pid];
        }
        else if (!sawProcess) reason = [NSString stringWithFormat:
            @"process-not-found name=ShadowTrackerExtra libproc-count=%d kernel-attempted=%d",
            libprocResult, kernelTarget.attempted ? 1 : 0];
        else if (!sawPath) reason = @"process-path-unavailable";
        else if (!sawProfile) reason = [NSString stringWithFormat:@"profile-mismatch expected=1.38.12/15915 actual={%@}",
            lastProfile ?: @"unreadable"];
        else if (!sawTask && lastKernelTransportError.length) reason = [NSString stringWithFormat:
            @"kernel-mapped-read-unavailable reason=%@ machSource=%s machKr=0x%x",
            lastKernelTransportError, lastTaskSource, lastTaskResult];
        else if (!taskMechanismAvailable) reason = @"task-read-symbol-missing acquisition=task_for_pid/task_read_for_pid/processor_set_tasks";
        else if (!sawTask) reason = [NSString stringWithFormat:@"task-read-denied source=%s kr=0x%x",
            lastTaskSource, lastTaskResult];
        else if (!sawPID) reason = @"task-port-pid-verification-failed";
        else if (kernelIdentityChanged) reason = @"kernel-proc-identity-changed-after-region-walk";
        else reason = @"main-image-or-uuid-not-found expected=34b785b2-0dab-3992-985d-359e6bf45585";
        [self publishConnectDiagnostic:reason ready:NO];
        return NO;
    }
}

- (BOOL)readAt:(uint64_t)address to:(void *)destination length:(size_t)length
     generation:(uint64_t)generation completedBytes:(size_t *)completedBytes
          error:(NSString * _Nullable * _Nullable)error {
    @synchronized (self) {
        if (completedBytes) *completedBytes = 0;
        if (error) *error = nil;
        const BOOL writableSpan = coreset_read_contract::clearDestination(destination, length);
        if (!writableSpan || address == 0 ||
            address > UINT64_MAX - length) {
            [self recordReadFailure:@"read-arguments-invalid" address:address length:length
                         generation:generation completed:0 result:KERN_INVALID_ARGUMENT];
            if (error) *error = _lastReadDiagnostic;
            return NO;
        }
        if (generation != _generation) {
            [self recordReadFailure:@"read-generation-stale" address:address length:length
                         generation:generation completed:0 result:KERN_FAILURE];
            if (error) *error = _lastReadDiagnostic;
            return NO;
        }
        if (![self identityStillValid:NO]) {
            if (_task != MACH_PORT_NULL || _kernelTransport) {
                [self disconnect];
                [self publishConnectDiagnostic:@"identity-lost stage=read-before" ready:NO];
            }
            [self recordReadFailure:@"read-identity-unavailable" address:address length:length
                         generation:generation completed:0 result:KERN_FAILURE];
            if (error) *error = _lastReadDiagnostic;
            return NO;
        }
        NSMutableData *scratch = [NSMutableData dataWithLength:length];
        if (!scratch) {
            [self recordReadFailure:@"read-allocation-failed" address:address length:length
                         generation:generation completed:0 result:KERN_RESOURCE_SHORTAGE];
            if (error) *error = _lastReadDiagnostic;
            return NO;
        }
        mach_vm_size_t done = 0;
        kern_return_t kr = KERN_FAILURE;
        if (_task != MACH_PORT_NULL) {
            kr = mach_vm_read_overwrite(_task, address, length,
                (mach_vm_address_t)(uintptr_t)scratch.mutableBytes, &done);
        } else if (_kernelTransport) {
            size_t mappedDone = 0;
            const BOOL mapped = [_kernelTransport readAt:address to:scratch.mutableBytes
                                                  length:length completedBytes:&mappedDone];
            done = (mach_vm_size_t)mappedDone;
            kr = mapped ? KERN_SUCCESS : KERN_FAILURE;
        }
        if (completedBytes) *completedBytes = (size_t)done;
        const BOOL identityValid = [self identityStillValid:NO] && generation == _generation;
        if (kr != KERN_SUCCESS || done != length || !identityValid) {
            if (!identityValid) {
                [self disconnect];
                [self publishConnectDiagnostic:@"identity-lost stage=read-after" ready:NO];
            }
            [self recordReadFailure:identityValid ? @"read-partial-or-kern-failure" : @"read-identity-changed"
                           address:address length:length generation:generation completed:(size_t)done result:kr];
            if (error) *error = _lastReadDiagnostic;
            return NO; // Never expose a partially filled destination.
        }
        memcpy(destination, scratch.bytes, length);
        return YES;
    }
}

- (CoreSetReadCleanupResult *)disconnect {
    @synchronized (self) {
        BOOL released = YES;
        BOOL transportReleased = YES;
        kern_return_t releaseResult = KERN_SUCCESS;
        const uint64_t previousGeneration = _generation;
        const BOOL hadIdentity = _task != MACH_PORT_NULL || _kernelTransport ||
            _pid > 0 || _base != 0 || _path.length != 0;
        if (_task != MACH_PORT_NULL) {
            releaseResult = mach_port_deallocate(mach_task_self(), _task);
            released = releaseResult == KERN_SUCCESS;
        }
        if (released) _task = MACH_PORT_NULL;
        if (_kernelTransport) {
            transportReleased = [_kernelTransport disconnect];
            if (transportReleased) _kernelTransport = nil;
        }
        const BOOL resourcesReleased = released && transportReleased;
        if (resourcesReleased) {
            _pid = -1; _base = 0; _path = nil;
            _pidSource = nil; _taskSource = nil; _profileSource = nil;
        }
        // Failure sequence stays monotonic for in-flight capture attribution,
        // but old identity diagnostics must not survive a disconnected lease.
        if (hadIdentity) {
            _lastConnectDiagnostic = @"disconnected";
            _lastLoggedDiagnostic = nil;
            _lastDiagnosticLogTime = 0;
            _lastReadDiagnostic = @"no-read-failure session-disconnected";
            _lastLoggedReadFailureKind = nil;
            _lastReadFailureLogTime = 0;
        }
        BOOL advanced = resourcesReleased && _generation != UINT64_MAX;
        if (advanced) ++_generation;
        NSString *kind = !released ? @"task-port-release-failed" :
            (!transportReleased ? @"read-transport-release-failed" :
            (!advanced ? @"generation-exhausted" : @"complete"));
        _lastCleanupDiagnostic = [NSString stringWithFormat:
            @"%@ taskPortReleased=%d transportReleased=%d generationAdvanced=%d retainedPort=%d retainedTransport=%d hadIdentity=%d previousGeneration=%llu sessionGeneration=%llu kr=0x%x",
            kind, released, transportReleased, advanced, _task != MACH_PORT_NULL,
            _kernelTransport != nil, hadIdentity,
            (unsigned long long)previousGeneration, (unsigned long long)_generation,
            (unsigned)releaseResult];
        const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (![_lastLoggedCleanupKind isEqualToString:kind] || now - _lastCleanupLogTime >= 30.0) {
            _lastLoggedCleanupKind = [kind copy]; _lastCleanupLogTime = now;
            NSLog(@"Core-SET: target-read lane=%@ stage=cleanup reason=%@",
                _diagnosticLabel ?: @"unassigned", _lastCleanupDiagnostic);
        }
        return [[CoreSetReadCleanupResult alloc] initWithTaskPortReleased:released
                                                       transportReleased:transportReleased
                                                      generationAdvanced:advanced];
    }
}
@end
