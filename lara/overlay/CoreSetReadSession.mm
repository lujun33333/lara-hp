#import "CoreSetReadSession.h"
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

@implementation CoreSetReadCleanupResult
- (instancetype)initWithTaskPortReleased:(BOOL)released generationAdvanced:(BOOL)advanced {
    if ((self = [super init])) { _taskPortReleased = released; _generationAdvanced = advanced; }
    return self;
}
@end

@interface CoreSetReadSession () {
    task_t _task;
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
}
@end

@implementation CoreSetReadSession

- (instancetype)init {
    if ((self = [super init])) {
        _task = MACH_PORT_NULL; _pid = -1; _generation = 1;
        _diagnosticLabel = @"unassigned";
        _lastConnectDiagnostic = @"尚未尝试连接目标只读会话";
        _lastReadDiagnostic = @"no-read-failure";
    }
    return self;
}

- (void)dealloc { [self disconnect]; }

- (BOOL)ready {
    @synchronized (self) {
        if (_task == MACH_PORT_NULL) return NO;
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

// Called only while this session's lock is held. Never log the read buffer.
- (void)recordReadFailure:(NSString *)kind address:(uint64_t)address
                  length:(size_t)length generation:(uint64_t)generation
               completed:(size_t)completed result:(kern_return_t)result {
    ++_readFailureSequence;
    _lastReadDiagnostic = [NSString stringWithFormat:
        @"%@ captureGeneration=%llu sessionGeneration=%llu address=0x%llx length=%zu completed=%zu kr=0x%x",
        kind, (unsigned long long)generation, (unsigned long long)_generation,
        (unsigned long long)address, length, completed, (unsigned)result];
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
    if (_task == MACH_PORT_NULL || _pid <= 0 || !_path || !_base) return NO;
    int currentPID = -1;
    if (pid_for_task(_task, &currentPID) != KERN_SUCCESS || currentPID != _pid) return NO;
    NSString *currentPath = [CoreSetReadSession pathForPID:_pid];
    return [currentPath isEqualToString:_path] &&
        (!verifyImage || ([CoreSetReadSession profileMatchesPath:currentPath] &&
                          [CoreSetReadSession imageAt:_base task:_task]));
}

- (BOOL)connect {
    @synchronized (self) {
        if ([self identityStillValid:YES]) {
            [self publishConnectDiagnostic:[NSString stringWithFormat:@"ready pid=%d base=0x%llx profile=1 uuid=1",
                _pid, (unsigned long long)_base] ready:YES];
            return YES;
        }
        CoreSetReadCleanupResult *cleanup = [self disconnect];
        if (!cleanup.taskPortReleased || _generation == UINT64_MAX) {
            [self publishConnectDiagnostic:@"cleanup-or-generation-failed" ready:NO]; return NO;
        }
        int pids[4096] = {0};
        int count = proc_listallpids(pids, sizeof(pids));
        if (count <= 0) {
            [self publishConnectDiagnostic:[NSString stringWithFormat:@"proc-list-failed count=%d", count]
                                     ready:NO];
            return NO;
        }
        count = MIN(count, (int)(sizeof(pids) / sizeof(pids[0])));
        BOOL sawProcess = NO, sawPath = NO, sawProfile = NO, sawTask = NO, sawPID = NO;
        BOOL readSymbolAvailable = NO;
        kern_return_t lastTaskResult = KERN_FAILURE;
        NSString *lastProfile = nil;
        for (int index = 0; index < count; ++index) {
            int pid = pids[index];
            if (pid <= 0) continue;
            char name[64] = {0};
            if (proc_name(pid, name, sizeof(name)) <= 0 || strcmp(name, CSProcessName) != 0) continue;
            sawProcess = YES;
            NSString *path = [CoreSetReadSession pathForPID:pid];
            if (!path) continue;
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
            task_t task = MACH_PORT_NULL;
            typedef kern_return_t (*task_read_for_pid_fn)(mach_port_t, int, mach_port_t *);
            task_read_for_pid_fn readForPID = (task_read_for_pid_fn)dlsym(RTLD_DEFAULT, "task_read_for_pid");
            readSymbolAvailable = readForPID != NULL;
            kern_return_t kr = readForPID ? readForPID(mach_task_self(), pid, &task) : KERN_FAILURE;
            lastTaskResult = kr;
            if (kr != KERN_SUCCESS || task == MACH_PORT_NULL) {
                if (task != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), task);
                continue;
            }
            sawTask = YES;
            int verifiedPID = -1;
            if (pid_for_task(task, &verifiedPID) != KERN_SUCCESS || verifiedPID != pid) {
                mach_port_deallocate(mach_task_self(), task); continue;
            }
            sawPID = YES;
            uint64_t base = [CoreSetReadSession findImageInTask:task];
            if (!base) { mach_port_deallocate(mach_task_self(), task); continue; }
            _task = task; _pid = pid; _base = base; _path = [path copy];
            if ([self identityStillValid:YES]) {
                ++_generation;
                [self publishConnectDiagnostic:[NSString stringWithFormat:@"ready pid=%d base=0x%llx profile=1 uuid=1",
                    _pid, (unsigned long long)_base] ready:YES];
                return YES;
            }
            [self disconnect];
        }
        NSString *reason = nil;
        if (!sawProcess) reason = @"process-not-found name=ShadowTrackerExtra";
        else if (!sawPath) reason = @"process-path-unavailable";
        else if (!sawProfile) reason = [NSString stringWithFormat:@"profile-mismatch expected=1.38.12/15915 actual={%@}",
            lastProfile ?: @"unreadable"];
        else if (!readSymbolAvailable) reason = @"task-read-symbol-missing";
        else if (!sawTask) reason = [NSString stringWithFormat:@"task-read-denied kr=0x%x", lastTaskResult];
        else if (!sawPID) reason = @"task-port-pid-verification-failed";
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
        if (!destination || length == 0 || length > 0x10000 || address == 0 ||
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
            if (_task != MACH_PORT_NULL) {
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
        kern_return_t kr = mach_vm_read_overwrite(_task, address, length,
            (mach_vm_address_t)(uintptr_t)scratch.mutableBytes, &done);
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
        const BOOL hadIdentity = _task != MACH_PORT_NULL || _pid > 0 || _base != 0 || _path.length != 0;
        if (_task != MACH_PORT_NULL) {
            released = mach_port_deallocate(mach_task_self(), _task) == KERN_SUCCESS;
        }
        if (released) _task = MACH_PORT_NULL;
        _pid = -1; _base = 0; _path = nil;
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
        BOOL advanced = _generation != UINT64_MAX;
        if (advanced) ++_generation;
        return [[CoreSetReadCleanupResult alloc] initWithTaskPortReleased:released generationAdvanced:advanced];
    }
}
@end
