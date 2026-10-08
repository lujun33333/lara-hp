#import "CoreSetKernelMappedReadTransport.h"
#import "CoreSetKernelReadProfile.h"
#import "../kexploit/TaskRop/vm.h"
#import "../kexploit/darksword.h"
#import "../kexploit/offsets.h"
#import "../kexploit/utils.h"
#import <mach/mach.h>
#import <mach-o/loader.h>
#import <pthread.h>
#import <string.h>
#import <unistd.h>

extern "C" kern_return_t mach_vm_deallocate(task_t, mach_vm_address_t, mach_vm_size_t);

static const uint64_t CSKernelReadPageSize = 0x4000;
static const uint64_t CSMinimumUserAddress = 0x100000000ULL;
static const uint64_t CSMaximumUserAddress = 0x8000000000ULL;
static pthread_mutex_t CSKernelMappedReadLock = PTHREAD_MUTEX_INITIALIZER;

static BOOL CSOffsetIsUsable(uint32_t value, uint32_t alignment) {
    return value != 0 && value < 0x10000 && (value & (alignment - 1)) == 0;
}

static BOOL CSKernelMappedReadPrerequisites(void) {
    return [CoreSetKernelReadProfile matchesCurrentKernel] &&
        ds_is_ready() && kernel_base && ds_address_usable(kernel_base) &&
        getpagesize() == CSKernelReadPageSize &&
        CSOffsetIsUsable(off_proc_p_pid, 4) &&
        CSOffsetIsUsable(off_proc_p_proc_ro, 8) &&
        CSOffsetIsUsable(off_proc_ro_pr_task, 8) &&
        CSOffsetIsUsable(off_task_map, 8) &&
        CSOffsetIsUsable(off_vm_map_hdr, 8) &&
        CSOffsetIsUsable(off_vm_map_header_nentries, 4) &&
        CSOffsetIsUsable(off_vm_map_header_links_next, 8) &&
        CSOffsetIsUsable(off_vm_map_entry_links_next, 8) &&
        CSOffsetIsUsable(off_vm_object_ref_count, 4) &&
        CSOffsetIsUsable(off_vm_named_entry_backing_copy, 8) &&
        CSOffsetIsUsable(off_vm_named_entry_size, 8) &&
        smr_base && t1sz_boot > 0 && t1sz_boot < 64 &&
        VM_MIN_KERNEL_ADDRESS && VM_MAX_KERNEL_ADDRESS > VM_MIN_KERNEL_ADDRESS;
}

static BOOL CSReleaseMappedPage(struct vmshmem *mapping) {
    if (!mapping) return YES;
    BOOL released = YES;
    if (mapping->localAddress) {
        if (mach_vm_deallocate(mach_task_self(), mapping->localAddress,
                               CSKernelReadPageSize) == KERN_SUCCESS) {
            mapping->localAddress = 0;
        } else {
            released = NO;
        }
    }
    if (mapping->port) {
        if (mach_port_deallocate(mach_task_self(),
                                 (mach_port_name_t)mapping->port) == KERN_SUCCESS) {
            mapping->port = 0;
        } else {
            released = NO;
        }
    }
    if (released) memset(mapping, 0, sizeof(*mapping));
    return released;
}

@interface CoreSetKernelMappedReadTransport () {
    int32_t _processID;
    uint64_t _kernelProcess;
    uint64_t _kernelTask;
    uint64_t _kernelVMMap;
    NSString *_lastError;
    BOOL _connected;
    BOOL _pendingCleanup;
    struct vmshmem _pendingMapping;
}
@end

@implementation CoreSetKernelMappedReadTransport

- (instancetype)initWithKernelProcess:(uint64_t)kernelProcess
                           expectedPID:(int32_t)expectedPID {
    if (!CSKernelMappedReadPrerequisites() || expectedPID <= 0 ||
        !ds_address_usable(kernelProcess)) return nil;
    uint32_t pid = ds_kread32(kernelProcess + off_proc_p_pid);
    uint64_t task = taskbyproc(kernelProcess);
    uint64_t vmMap = task ? task_get_vm_map(task) : 0;
    if (pid != (uint32_t)expectedPID || !ds_address_usable(task) ||
        !ds_address_usable(vmMap)) return nil;
    if ((self = [super init])) {
        _processID = expectedPID;
        _kernelProcess = kernelProcess;
        _kernelTask = task;
        _kernelVMMap = vmMap;
        _lastError = @"none";
        _connected = YES;
    }
    return self;
}

- (void)dealloc { (void)[self disconnect]; }
- (int32_t)processID { @synchronized (self) { return _processID; } }
- (NSString *)lastError { @synchronized (self) { return [_lastError copy] ?: @"unknown"; } }

- (BOOL)identityValidLocked {
    if (!_connected || _pendingCleanup || !CSKernelMappedReadPrerequisites() ||
        _processID <= 0 || !ds_address_usable(_kernelProcess) ||
        !ds_address_usable(_kernelTask) || !ds_address_usable(_kernelVMMap)) return NO;
    return ds_kread32(_kernelProcess + off_proc_p_pid) == (uint32_t)_processID &&
        taskbyproc(_kernelProcess) == _kernelTask &&
        task_get_vm_map(_kernelTask) == _kernelVMMap;
}

- (BOOL)identityValid { @synchronized (self) { return [self identityValidLocked]; } }

- (BOOL)readAt:(uint64_t)address
             to:(void *)destination
         length:(size_t)length
 completedBytes:(size_t *)completedBytes {
    @synchronized (self) {
        if (completedBytes) *completedBytes = 0;
        if (!destination || !length || length > 0x10000) {
            _lastError = @"mapped-read-destination-invalid";
            return NO;
        }
        memset(destination, 0, length);
        if (address < CSMinimumUserAddress ||
            address >= CSMaximumUserAddress || address > UINT64_MAX - length ||
            address + length > CSMaximumUserAddress || ![self identityValidLocked]) {
            _lastError = @"mapped-read-arguments-or-identity-invalid";
            return NO;
        }
        NSMutableData *scratch = [NSMutableData dataWithLength:length];
        if (!scratch) {
            _lastError = @"mapped-read-allocation-failed";
            return NO;
        }
        pthread_mutex_lock(&CSKernelMappedReadLock);
        size_t completed = 0;
        BOOL success = YES;
        while (completed < length) {
            if (![self identityValidLocked]) {
                _lastError = @"mapped-read-identity-changed-before-page";
                success = NO;
                break;
            }
            const uint64_t current = address + completed;
            const uint64_t pageAddress = current & ~(CSKernelReadPageSize - 1);
            const size_t pageOffset = (size_t)(current - pageAddress);
            const size_t chunk = MIN(length - completed,
                                     (size_t)CSKernelReadPageSize - pageOffset);
            struct vmshmem mapping = {0};
            @try {
                mapping = vmmapremotepagereadonly(_kernelVMMap, pageAddress);
            } @catch (NSException *exception) {
                (void)exception;
                _lastError = @"mapped-read-alias-exception";
                success = NO;
            }
            if (!success) break;
            if (!mapping.used || !mapping.localAddress || !mapping.port ||
                mapping.remoteAddress != pageAddress) {
                _lastError = @"mapped-read-alias-invalid";
                success = NO;
            } else {
                memcpy((uint8_t *)scratch.mutableBytes + completed,
                       (const void *)(uintptr_t)(mapping.localAddress + pageOffset), chunk);
                completed += chunk;
            }
            if (!CSReleaseMappedPage(&mapping)) {
                _pendingMapping = mapping;
                _pendingCleanup = YES;
                _lastError = @"mapped-read-alias-release-failed";
                success = NO;
            }
            if (!success) break;
        }
        if (success && ![self identityValidLocked]) {
            _lastError = @"mapped-read-identity-changed-after-read";
            success = NO;
        }
        pthread_mutex_unlock(&CSKernelMappedReadLock);
        if (completedBytes) *completedBytes = completed;
        if (success && completed == length) {
            memcpy(destination, scratch.bytes, length);
            _lastError = @"none";
        }
        return success && completed == length;
    }
}

- (BOOL)imageAt:(uint64_t)address matchesUUID:(const uint8_t[16])uuid {
    if (!uuid) return NO;
    struct mach_header_64 header = {0};
    size_t done = 0;
    if (![self readAt:address to:&header length:sizeof(header) completedBytes:&done] ||
        done != sizeof(header) || header.magic != MH_MAGIC_64 ||
        header.cputype != CPU_TYPE_ARM64 || header.filetype != MH_EXECUTE ||
        header.ncmds == 0 || header.ncmds >= 0x1000 ||
        header.sizeofcmds < sizeof(struct uuid_command) ||
        header.sizeofcmds > 0x20000 ||
        address > UINT64_MAX - sizeof(header) - header.sizeofcmds) return NO;
    NSMutableData *commands = [NSMutableData dataWithLength:header.sizeofcmds];
    if (!commands || ![self readAt:address + sizeof(header)
                                  to:commands.mutableBytes
                              length:commands.length
                      completedBytes:&done] || done != commands.length) return NO;
    const uint8_t *bytes = (const uint8_t *)commands.bytes;
    size_t offset = 0;
    for (uint32_t index = 0; index < header.ncmds; ++index) {
        if (offset > commands.length ||
            commands.length - offset < sizeof(struct load_command)) return NO;
        const struct load_command *command =
            (const struct load_command *)(bytes + offset);
        if (command->cmdsize < sizeof(*command) ||
            command->cmdsize > commands.length - offset) return NO;
        if (command->cmd == LC_UUID) {
            if (command->cmdsize < sizeof(struct uuid_command)) return NO;
            const struct uuid_command *value = (const struct uuid_command *)command;
            return memcmp(value->uuid, uuid, 16) == 0;
        }
        offset += command->cmdsize;
    }
    return NO;
}

- (uint64_t)findImageWithUUID:(const uint8_t[16])uuid {
    @synchronized (self) {
        if (!uuid || ![self identityValidLocked]) return 0;
        if (_kernelVMMap > UINT64_MAX - off_vm_map_hdr) {
            _lastError = @"mapped-read-vm-map-header-overflow";
            return 0;
        }
        const uint64_t headerAddress = _kernelVMMap + off_vm_map_hdr;
        uint64_t entry = ds_kreadptr(headerAddress + off_vm_map_header_links_next);
        uint32_t count = ds_kread32(headerAddress + off_vm_map_header_nentries);
        if (!ds_address_usable(entry) || count == 0 || count > 8192) {
            _lastError = @"mapped-read-vm-map-header-invalid";
            return 0;
        }
        uint64_t previousStart = 0;
        for (uint32_t visited = 0; visited < count; ++visited) {
            if (![self identityValidLocked]) {
                _lastError = @"mapped-read-identity-changed-during-vm-map-walk";
                return 0;
            }
            if (!ds_address_usable(entry) || entry > UINT64_MAX - sizeof(struct vmmapentry) ||
                entry > UINT64_MAX - off_vm_map_entry_links_next) break;
            struct vmmapentry targetEntry = {0};
            ds_kreadbuf(entry, &targetEntry, sizeof(targetEntry));
            const uint64_t start = targetEntry.links.start, end = targetEntry.links.end;
            if ((visited > 0 && start <= previousStart) || end <= start) {
                _lastError = @"mapped-read-vm-map-range-invalid";
                return 0;
            }
            previousStart = start;
            const BOOL readableExecutable = !targetEntry.is_sub_map &&
                !targetEntry.vme_kernel_object &&
                (targetEntry.protection & (VM_PROT_READ | VM_PROT_EXECUTE)) ==
                    (VM_PROT_READ | VM_PROT_EXECUTE);
            if (readableExecutable && start >= CSMinimumUserAddress &&
                start < CSMaximumUserAddress &&
                (start & (CSKernelReadPageSize - 1)) == 0 &&
                end - start >= sizeof(struct mach_header_64) &&
                [self imageAt:start matchesUUID:uuid]) return start;
            uint64_t next = ds_kreadptr(entry + off_vm_map_entry_links_next);
            if (next == entry) {
                _lastError = @"mapped-read-vm-map-cycle";
                return 0;
            }
            entry = next;
        }
        _lastError = @"mapped-read-main-image-not-found";
        return 0;
    }
}

- (BOOL)disconnect {
    @synchronized (self) {
        pthread_mutex_lock(&CSKernelMappedReadLock);
        BOOL released = !_pendingCleanup || CSReleaseMappedPage(&_pendingMapping);
        if (released) {
            _pendingCleanup = NO;
            _connected = NO;
            _processID = -1;
            _kernelProcess = _kernelTask = _kernelVMMap = 0;
            _lastError = @"disconnected";
        } else {
            _lastError = @"mapped-read-alias-release-retry-failed";
        }
        pthread_mutex_unlock(&CSKernelMappedReadLock);
        return released;
    }
}

@end
