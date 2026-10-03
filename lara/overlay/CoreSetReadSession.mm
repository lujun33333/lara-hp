#import "CoreSetReadSession.h"
#import <dlfcn.h>
#import <limits.h>
#import <mach/mach.h>
#import <mach-o/loader.h>
#import <pthread.h>
#import <stdlib.h>
#import <string.h>

extern kern_return_t mach_vm_read_overwrite(vm_map_read_t, mach_vm_address_t,
    mach_vm_size_t, mach_vm_address_t, mach_vm_size_t *);
extern kern_return_t mach_vm_region_recurse(vm_map_read_t, mach_vm_address_t *,
    mach_vm_size_t *, natural_t *, vm_region_recurse_info_t, mach_msg_type_number_t *);
extern int proc_listallpids(void *, int);
extern int proc_name(int, void *, uint32_t);

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
}
@end

@implementation CoreSetReadSession

- (instancetype)init {
    if ((self = [super init])) { _task = MACH_PORT_NULL; _pid = -1; _generation = 1; }
    return self;
}

- (void)dealloc { [self disconnect]; }

- (BOOL)ready {
    @synchronized (self) {
        if (_task == MACH_PORT_NULL) return NO;
        if ([self identityStillValid:YES]) return YES;
        [self disconnect];
        return NO;
    }
}
- (uint64_t)generation { @synchronized (self) { return _generation; } }
- (uint64_t)imageBase { @synchronized (self) { return _base; } }
- (int32_t)processID { @synchronized (self) { return _pid; } }
- (uint64_t)capabilities { return self.ready ? UINT64_C(1) : 0; }

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
        if ([self identityStillValid:YES]) return YES;
        CoreSetReadCleanupResult *cleanup = [self disconnect];
        if (!cleanup.taskPortReleased || _generation == UINT64_MAX) return NO;
        int pids[4096] = {0};
        int count = proc_listallpids(pids, sizeof(pids));
        if (count <= 0) return NO;
        count = MIN(count, (int)(sizeof(pids) / sizeof(pids[0])));
        for (int index = 0; index < count; ++index) {
            int pid = pids[index];
            if (pid <= 0) continue;
            char name[64] = {0};
            if (proc_name(pid, name, sizeof(name)) <= 0 || strcmp(name, CSProcessName) != 0) continue;
            NSString *path = [CoreSetReadSession pathForPID:pid];
            if (![CoreSetReadSession profileMatchesPath:path]) continue;
            task_t task = MACH_PORT_NULL;
            typedef kern_return_t (*task_read_for_pid_fn)(mach_port_t, int, mach_port_t *);
            task_read_for_pid_fn readForPID = (task_read_for_pid_fn)dlsym(RTLD_DEFAULT, "task_read_for_pid");
            kern_return_t kr = readForPID ? readForPID(mach_task_self(), pid, &task) : KERN_FAILURE;
            if (kr != KERN_SUCCESS || task == MACH_PORT_NULL) {
                if (task != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), task);
                continue;
            }
            int verifiedPID = -1;
            if (pid_for_task(task, &verifiedPID) != KERN_SUCCESS || verifiedPID != pid) {
                mach_port_deallocate(mach_task_self(), task); continue;
            }
            uint64_t base = [CoreSetReadSession findImageInTask:task];
            if (!base) { mach_port_deallocate(mach_task_self(), task); continue; }
            _task = task; _pid = pid; _base = base; _path = [path copy];
            if ([self identityStillValid:YES]) { ++_generation; return YES; }
            [self disconnect];
        }
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
            address > UINT64_MAX - length || generation != _generation || ![self identityStillValid:NO]) {
            if (error) *error = @"lease/identity/arguments invalid";
            if (generation == _generation && _task != MACH_PORT_NULL && ![self identityStillValid:NO]) [self disconnect];
            return NO;
        }
        NSMutableData *scratch = [NSMutableData dataWithLength:length];
        if (!scratch) { if (error) *error = @"scratch allocation failed"; return NO; }
        mach_vm_size_t done = 0;
        kern_return_t kr = mach_vm_read_overwrite(_task, address, length,
            (mach_vm_address_t)(uintptr_t)scratch.mutableBytes, &done);
        if (completedBytes) *completedBytes = (size_t)done;
        if (kr != KERN_SUCCESS || done != length || ![self identityStillValid:NO] || generation != _generation) {
            if (error) *error = @"partial read or identity changed";
            if (![self identityStillValid:NO]) [self disconnect];
            return NO; // Never expose a partially filled destination.
        }
        memcpy(destination, scratch.bytes, length);
        return YES;
    }
}

- (CoreSetReadCleanupResult *)disconnect {
    @synchronized (self) {
        BOOL released = YES;
        if (_task != MACH_PORT_NULL) {
            released = mach_port_deallocate(mach_task_self(), _task) == KERN_SUCCESS;
        }
        if (released) _task = MACH_PORT_NULL;
        _pid = -1; _base = 0; _path = nil;
        BOOL advanced = _generation != UINT64_MAX;
        if (advanced) ++_generation;
        return [[CoreSetReadCleanupResult alloc] initWithTaskPortReleased:released generationAdvanced:advanced];
    }
}
@end
