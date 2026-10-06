#import "CoreSetMappedPageWriteBackend.h"
#import "CoreSetKernelWriteProfile.h"
#include "CoreSetTargetWriteContract.h"
#import "../kexploit/TaskRop/vm.h"
#import "../kexploit/darksword.h"
#import "../kexploit/offsets.h"
#import "../kexploit/utils.h"
#import <mach/mach.h>
#include <limits.h>
#include <string.h>
#include <unistd.h>

extern "C" kern_return_t mach_vm_deallocate(task_t, mach_vm_address_t, mach_vm_size_t);
static const uint64_t CSPageSize = 0x4000;
static BOOL CSOffset(uint32_t value, uint32_t alignment) {
    return value != 0 && value < 0x10000 && (value & (alignment - 1)) == 0;
}

// Exact UUID/build/device/offset equality is mandatory. There is no installed
// audited profile in the shipped source, so unknown kernels remain unavailable.
static BOOL CSVerifiedKernelProfile(void) {
    if (!ds_is_ready() || !kernel_base ||
        !CSOffset(off_proc_p_pid, 4) || !CSOffset(off_task_map, 8) ||
        !CSOffset(off_vm_map_hdr, 8) || !CSOffset(off_vm_map_header_nentries, 4) ||
        !CSOffset(off_vm_map_entry_links_next, 8) ||
        !CSOffset(off_vm_map_header_links_next, 8) ||
        !CSOffset(off_vm_object_ref_count, 4) ||
        !CSOffset(off_vm_named_entry_backing_copy, 8) ||
        !CSOffset(off_vm_named_entry_size, 8) || !smr_base || !t1sz_boot ||
        (kernel_base & (CSPageSize - 1)) != 0 ||
        t1sz_boot >= 64 || VM_MIN_KERNEL_ADDRESS == 0 ||
        (VM_MIN_KERNEL_ADDRESS & (CSPageSize - 1)) != 0 ||
        getpagesize() != CSPageSize) return NO;
    return [CoreSetKernelWriteProfileRegistry matchesCurrentKernel];
}

@interface CoreSetMappedPageWriteBackend () {
    CoreSetReadSession *_readSession;
    int32_t _pid;
    uint64_t _imageBase;
    uint64_t _generation;
    uint64_t _controller;
    uint64_t _proc;
    uint64_t _task;
    uint64_t _vmMap;
    BOOL _ready;
    BOOL _pendingCleanup;
    BOOL _aliasesReleased;
    struct vmshmem _mappings[2];
    size_t _mappingCount;
}
@end

@implementation CoreSetMappedPageWriteBackend
- (instancetype)initWithReadSession:(CoreSetReadSession *)readSession {
    if ((self = [super init])) {
        _readSession = readSession; _pid = -1; _aliasesReleased = YES;
    }
    return self;
}
- (void)dealloc { [self disconnect]; }
- (BOOL)ready { @synchronized (self) { return _ready && [self identityValid]; } }
- (BOOL)pendingCleanup { @synchronized (self) { return _pendingCleanup; } }
- (BOOL)aliasesReleased { @synchronized (self) { return _aliasesReleased; } }

- (NSDictionary<NSString *, id> *)diagnosticSnapshot {
    @synchronized (self) {
        NSMutableDictionary<NSString *, id> *result =
            [[CoreSetKernelWriteProfileRegistry diagnosticSnapshot] mutableCopy];
        NSMutableArray<NSString *> *failures = [result[@"failureReasons"] mutableCopy];
        const BOOL readReady = _readSession.ready;
        const BOOL identityMatches = _ready && readReady &&
            _readSession.processID == _pid && _readSession.imageBase == _imageBase &&
            _readSession.generation == _generation;
        const BOOL kernelShapeValid = CSVerifiedKernelProfile();
        const BOOL backendReady = _ready && [self identityValid];
        if (!readReady) [failures addObject:@"target_read_session_not_ready"];
        if (!kernelShapeValid) [failures addObject:@"mapped_backend_kernel_gate_rejected"];
        if (!_ready) [failures addObject:@"target_binding_not_created"];
        else if (!identityMatches || !backendReady) [failures addObject:@"target_binding_stale"];
        if (_pendingCleanup) [failures addObject:@"mapped_cleanup_pending"];
        result[@"readSessionReady"] = @(readReady);
        result[@"readIdentityMatches"] = @(identityMatches);
        result[@"backendReady"] = @(backendReady);
        result[@"pendingCleanup"] = @(_pendingCleanup);
        result[@"aliasesReleased"] = @(_aliasesReleased);
        result[@"failureReasons"] = failures;
        return result;
    }
}

- (BOOL)identityValid {
    if (!_ready || _pendingCleanup || !CSVerifiedKernelProfile() || !_readSession.ready ||
        _readSession.processID != _pid || _readSession.imageBase != _imageBase ||
        _readSession.generation != _generation || !_proc || !_task || !_vmMap ||
        !_controller || _controller > UINT64_MAX - 0x830) return NO;
    uint64_t currentProc = procbyname("ShadowTrackerExtra");
    return currentProc == _proc &&
        (int32_t)ds_kread32(_proc + off_proc_p_pid) == _pid &&
        taskbyproc(_proc) == _task && task_get_vm_map(_task) == _vmMap;
}

- (BOOL)connectForController:(uint64_t)controller {
    @synchronized (self) {
        if (_pendingCleanup || _ready || !CSVerifiedKernelProfile() ||
            !_readSession.ready || controller < 0x100000000ULL ||
            controller >= 0x8000000000ULL || controller > UINT64_MAX - 0x830) return NO;
        int32_t pid = _readSession.processID;
        uint64_t imageBase = _readSession.imageBase;
        uint64_t generation = _readSession.generation;
        uint64_t proc = procbyname("ShadowTrackerExtra");
        if (pid <= 0 || !imageBase || !generation || !proc ||
            (int32_t)ds_kread32(proc + off_proc_p_pid) != pid) return NO;
        uint64_t task = taskbyproc(proc);
        uint64_t vmMap = task ? task_get_vm_map(task) : 0;
        if (!task || !vmMap || !_readSession.ready ||
            _readSession.processID != pid || _readSession.imageBase != imageBase ||
            _readSession.generation != generation) return NO;
        _pid = pid; _imageBase = imageBase; _generation = generation;
        _controller = controller; _proc = proc; _task = task; _vmMap = vmMap;
        _ready = YES;
        if (![self identityValid]) { [self disconnect]; return NO; }
        return YES;
    }
}

- (BOOL)matchesPID:(int32_t)pid imageBase:(uint64_t)imageBase
        generation:(uint64_t)generation controller:(uint64_t)controller {
    @synchronized (self) {
        return _pid == pid && _imageBase == imageBase && _generation == generation &&
            _controller == controller && [self identityValid];
    }
}

- (BOOL)releaseMapping:(struct vmshmem *)mapping {
    BOOL released = YES;
    if (mapping->localAddress) {
        if (mach_vm_deallocate(mach_task_self(), mapping->localAddress,
                              CSPageSize) == KERN_SUCCESS) mapping->localAddress = 0;
        else released = NO;
    }
    if (mapping->port) {
        if (mach_port_deallocate(mach_task_self(),
                    (mach_port_name_t)mapping->port) == KERN_SUCCESS) mapping->port = 0;
        else released = NO;
    }
    if (released) memset(mapping, 0, sizeof(*mapping));
    _aliasesReleased = released;
    if (!released) _pendingCleanup = YES;
    return released;
}

- (size_t)writeControllerSlot:(CoreSetTargetWriteSlot)slot
                         axis:(CoreSetTargetWriteAxis)axis
                   controller:(uint64_t)controller
                        bytes:(const void *)bytes length:(size_t)length {
    @synchronized (self) {
        uint64_t offset = 0;
        size_t expectedLength = 0;
        if (!CoreSet::ControlRotationWriteGate::shape(
                static_cast<CoreSet::TargetActionSlot>(slot),
                static_cast<CoreSet::TargetActionAxis>(axis),
                &offset, &expectedLength) || !bytes || length != expectedLength ||
            controller != _controller || controller > UINT64_MAX - offset - length ||
            ![self identityValid]) return 0;
        const uint64_t address = controller + offset;
        size_t completed = 0;
        while (completed < length) {
            uint64_t current = address + completed;
            uint64_t page = current & ~(CSPageSize - 1);
            size_t offset = (size_t)(current - page);
            size_t chunk = MIN(length - completed, (size_t)CSPageSize - offset);
            if (![self identityValid]) { _pendingCleanup = YES; break; }
            if (_mappingCount >= 2) { _pendingCleanup = YES; break; }
            struct vmshmem *mapping = &_mappings[_mappingCount++];
            @try { *mapping = vmmapremotepage(_vmMap, page); }
            @catch (NSException *exception) { (void)exception; _pendingCleanup = YES; break; }
            if (!mapping->used || !mapping->localAddress || !mapping->port ||
                mapping->remoteAddress != page) {
                [self releaseMapping:mapping]; _pendingCleanup = YES; break;
            }
            memcpy((void *)(uintptr_t)(mapping->localAddress + offset),
                   (const uint8_t *)bytes + completed, chunk);
            completed += chunk;
            if (![self releaseMapping:mapping] || ![self identityValid]) {
                _pendingCleanup = YES; break;
            }
        }
        if (completed != length) _pendingCleanup = YES;
        if (!_pendingCleanup) _mappingCount = 0;
        return completed;
    }
}

- (BOOL)disconnect {
    @synchronized (self) {
        _ready = NO; _pid = -1; _imageBase = _generation = _controller = 0;
        _proc = _task = _vmMap = 0;
        BOOL released = YES;
        for (size_t index = 0; index < _mappingCount; ++index) {
            if (_mappings[index].localAddress || _mappings[index].port)
                released = [self releaseMapping:&_mappings[index]] && released;
        }
        _aliasesReleased = released;
        return _aliasesReleased && !_pendingCleanup;
    }
}
@end
