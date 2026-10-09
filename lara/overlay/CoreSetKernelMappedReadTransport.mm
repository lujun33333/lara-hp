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

static const uint64_t CSKernelReadPageSize = 0x4000;
static const uint64_t CSMinimumUserAddress = 0x100000000ULL;
static const uint64_t CSMaximumUserAddress = 0x8000000000ULL;
static pthread_mutex_t CSKernelMappedReadLock = PTHREAD_MUTEX_INITIALIZER;

static const uint64_t CSArmTTEValid = 0x1;
static const uint64_t CSArmTTETypeMask = 0x2;
static const uint64_t CSArmTTETypeBlock = 0x0;
static const uint64_t CSArmTTETypeL3Block = 0x2;
// 16 KB child translation tables are page-aligned.  The root table is not:
// with T1SZ=25 and the 0x7000000000 L1 mask it contains only eight entries,
// so a valid pmap.ttep may be merely 0x40-aligned (for example ...0x5280).
static const uint64_t CSArmTTETableMask = 0x0000FFFFFFFFC000ULL;
static const uint64_t CSArmTTEPhysicalMask = 0x0000FFFFFFFFF000ULL;
static const uint32_t CSPAPTMaximumEntries = 128;
static const uint32_t CSTranslationCacheEntryCount = 2048;
static const uint32_t CSTranslationCacheEntryMask =
    CSTranslationCacheEntryCount - 1;

typedef struct {
    uint64_t physicalStart;
    uint64_t apertureStart;
    uint64_t mappingCount;
} CSSPTMPAPTEntry;

typedef struct {
    uint64_t targetTTEP;
    uint64_t virtualPage;
    uint64_t physicalPage;
    const char *failureReason;
    uint32_t contextGeneration;
    uint32_t reserved;
} CSPageTranslationCacheEntry;
static_assert(sizeof(CSPageTranslationCacheEntry) == 0x28,
              "Core 1.7 translation cache record ABI changed");

static NSString *sCSPageTableInitError = @"not-attempted";

static void CSSetPageTableInitError(NSString *value) {
    @synchronized ([CoreSetKernelMappedReadTransport class]) {
        sCSPageTableInitError = [value copy] ?: @"unknown";
    }
}

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
        coreset_vm_map_pmap_offset == 0x40 &&
        coreset_arm_tt_l1_index_mask == 0x0000007000000000ULL &&
        coreset_libsptm_n_papt_ranges_offset != 0 &&
        coreset_libsptm_papt_ranges_offset != 0 &&
        CSOffsetIsUsable(off_vm_map_hdr, 8) &&
        CSOffsetIsUsable(off_vm_map_header_nentries, 4) &&
        CSOffsetIsUsable(off_vm_map_header_links_next, 8) &&
        CSOffsetIsUsable(off_vm_map_entry_links_next, 8) &&
        smr_base && t1sz_boot > 0 && t1sz_boot < 64 &&
        VM_MIN_KERNEL_ADDRESS && VM_MAX_KERNEL_ADDRESS > VM_MIN_KERNEL_ADDRESS;
}

@interface CoreSetKernelMappedReadTransport () {
    int32_t _processID;
    uint64_t _kernelProcess;
    uint64_t _kernelTask;
    uint64_t _kernelVMMap;
    uint64_t _kernelPmap;
    uint64_t _targetTTEP;
    BOOL _targetTTEPIsPhysical;
    CSSPTMPAPTEntry _paptEntries[CSPAPTMaximumEntries];
    uint32_t _paptEntryCount;
    uint32_t _contextGeneration;
    CSPageTranslationCacheEntry
        _translationCache[CSTranslationCacheEntryCount];
    NSString *_lastError;
    BOOL _connected;
}
@end

@implementation CoreSetKernelMappedReadTransport

+ (NSString *)lastInitializationError {
    @synchronized (self) { return [sCSPageTableInitError copy] ?: @"unknown"; }
}

- (instancetype)initWithKernelProcess:(uint64_t)kernelProcess
                           expectedPID:(int32_t)expectedPID {
    if (!CSKernelMappedReadPrerequisites() || expectedPID <= 0 ||
        !ds_address_usable(kernelProcess)) {
        CSSetPageTableInitError(@"page-table-prerequisites-or-process-invalid");
        return nil;
    }
    uint32_t pid = 0;
    if (!ds_kread32_checked(kernelProcess + off_proc_p_pid, &pid)) {
        CSSetPageTableInitError(@"page-table-pid-read-failed");
        return nil;
    }
    uint64_t task = taskbyproc(kernelProcess);
    uint64_t vmMap = task ? task_get_vm_map(task) : 0;
    uint64_t pmap = 0;
    uint64_t ttep = 0;
    if (!vmMap || !ds_kreadptr_checked(vmMap + coreset_vm_map_pmap_offset, &pmap) ||
        !pmap || !ds_kread64_checked(pmap + 0x8, &ttep)) {
        CSSetPageTableInitError(@"page-table-pmap-or-ttep-read-failed");
        return nil;
    }
    if (pid != (uint32_t)expectedPID || !ds_address_usable(task) ||
        !ds_address_usable(vmMap) || !ds_address_usable(pmap) || ttep == 0) {
        CSSetPageTableInitError([NSString stringWithFormat:
            @"page-table-identity-or-ttep-invalid pid=%u expected=%d "
             "task=0x%llx/%d vmMap=0x%llx/%d pmap=0x%llx/%d "
             "ttep=0x%llx",
            pid, expectedPID,
            (unsigned long long)task, ds_address_usable(task),
            (unsigned long long)vmMap, ds_address_usable(vmMap),
            (unsigned long long)pmap, ds_address_usable(pmap),
            (unsigned long long)ttep]);
        return nil;
    }
    const BOOL ttepIsPhysical = (ttep & 0xF000000000000000ULL) == 0;
    if (!ttepIsPhysical && !ds_address_usable(ttep)) {
        CSSetPageTableInitError(@"page-table-virtual-ttep-invalid");
        return nil;
    }
    if ((self = [super init])) {
        _processID = expectedPID;
        _kernelProcess = kernelProcess;
        _kernelTask = task;
        _kernelVMMap = vmMap;
        _kernelPmap = pmap;
        _targetTTEP = ttep;
        _targetTTEPIsPhysical = ttepIsPhysical;
        _lastError = @"none";

        if (kernel_base > UINT64_MAX - coreset_libsptm_n_papt_ranges_offset ||
            kernel_base > UINT64_MAX - coreset_libsptm_papt_ranges_offset) {
            CSSetPageTableInitError(@"page-table-papt-symbol-overflow");
            return nil;
        }
        const uint64_t countSymbol = kernel_base +
            coreset_libsptm_n_papt_ranges_offset;
        const uint64_t tableSymbol = kernel_base +
            coreset_libsptm_papt_ranges_offset;
        uint64_t countAddress = 0;
        uint64_t tableAddress = 0;
        uint32_t count = 0;
        if (!ds_kreadptr_checked(countSymbol, &countAddress) ||
            !ds_kreadptr_checked(tableSymbol, &tableAddress) ||
            !ds_address_usable(countAddress) ||
            !ds_kread32_checked(countAddress, &count)) {
            CSSetPageTableInitError(@"page-table-papt-globals-read-failed");
            return nil;
        }
        if (!ds_address_usable(tableAddress) || count == 0 ||
            count > CSPAPTMaximumEntries) {
            CSSetPageTableInitError([NSString stringWithFormat:
                @"page-table-papt-count-invalid count=%u", count]);
            return nil;
        }
        CSSPTMPAPTEntry first[CSPAPTMaximumEntries] = {0};
        CSSPTMPAPTEntry second[CSPAPTMaximumEntries] = {0};
        const size_t tableLength = (size_t)count * sizeof(CSSPTMPAPTEntry);
        if (!ds_kreadbuf_checked(tableAddress, first, tableLength) ||
            !ds_kreadbuf_checked(tableAddress, second, tableLength) ||
            memcmp(first, second, tableLength) != 0) {
            CSSetPageTableInitError(@"page-table-papt-table-read-or-stability-failed");
            return nil;
        }
        uint32_t confirmedCount = 0;
        if (!ds_kread32_checked(countAddress, &confirmedCount) || confirmedCount != count) {
            CSSetPageTableInitError(@"page-table-papt-count-changed");
            return nil;
        }
        for (uint32_t index = 0; index < count; ++index) {
            const CSSPTMPAPTEntry entry = first[index];
            if ((entry.physicalStart & (CSKernelReadPageSize - 1)) != 0 ||
                (entry.apertureStart & (CSKernelReadPageSize - 1)) != 0 ||
                !ds_address_usable(entry.apertureStart) ||
                entry.mappingCount == 0 ||
                entry.mappingCount > UINT64_MAX / CSKernelReadPageSize) {
                CSSetPageTableInitError([NSString stringWithFormat:
                    @"page-table-papt-entry-invalid index=%u", index]);
                return nil;
            }
        }
        memcpy(_paptEntries, first, tableLength);
        _paptEntryCount = count;
        _contextGeneration = 1;
        memset(_translationCache, 0, sizeof(_translationCache));
        _connected = YES;
        CSSetPageTableInitError([NSString stringWithFormat:
            @"none paptCount=%u ttepKind=%@", count,
            ttepIsPhysical ? @"physical" : @"virtual"]);
    }
    return self;
}

- (void)dealloc { (void)[self disconnect]; }
- (int32_t)processID { @synchronized (self) { return _processID; } }
- (NSString *)lastError { @synchronized (self) { return [_lastError copy] ?: @"unknown"; } }

- (BOOL)identityValidLocked {
    if (!_connected || !CSKernelMappedReadPrerequisites() ||
        _processID <= 0 || !ds_address_usable(_kernelProcess) ||
        !ds_address_usable(_kernelTask) || !ds_address_usable(_kernelVMMap) ||
        !ds_address_usable(_kernelPmap) || !_targetTTEP || !_paptEntryCount) return NO;
    uint32_t currentPID = 0;
    uint64_t currentPmap = 0;
    uint64_t currentTTEP = 0;
    if (!ds_kread32_checked(_kernelProcess + off_proc_p_pid, &currentPID) ||
        !ds_kreadptr_checked(_kernelVMMap + coreset_vm_map_pmap_offset, &currentPmap) ||
        !ds_kread64_checked(_kernelPmap + 0x8, &currentTTEP)) return NO;
    return currentPID == (uint32_t)_processID &&
        taskbyproc(_kernelProcess) == _kernelTask &&
        task_get_vm_map(_kernelTask) == _kernelVMMap &&
        currentPmap == _kernelPmap && currentTTEP == _targetTTEP;
}

- (BOOL)identityValid { @synchronized (self) { return [self identityValidLocked]; } }

- (void)invalidateTranslationCacheLocked {
    memset(_translationCache, 0, sizeof(_translationCache));
    if (_contextGeneration == UINT32_MAX) _contextGeneration = 1;
    else ++_contextGeneration;
    if (_contextGeneration == 0) _contextGeneration = 1;
}

- (uint32_t)translationCacheIndexForVirtualPageLocked:(uint64_t)virtualPage {
    const uint64_t pageNumber = virtualPage / CSKernelReadPageSize;
    const uint64_t rootHash = (_targetTTEP >> 12) ^ (_targetTTEP >> 29);
    const uint64_t value = rootHash ^ pageNumber ^ (pageNumber >> 17);
    return (uint32_t)(value & CSTranslationCacheEntryMask);
}

- (uint64_t)kernelVirtualForPhysicalLocked:(uint64_t)physicalAddress {
    for (uint32_t index = 0; index < _paptEntryCount; ++index) {
        const CSSPTMPAPTEntry entry = _paptEntries[index];
        const uint64_t length = entry.mappingCount * CSKernelReadPageSize;
        if (physicalAddress >= entry.physicalStart &&
            physicalAddress - entry.physicalStart < length) {
            const uint64_t delta = physicalAddress - entry.physicalStart;
            if (entry.apertureStart <= UINT64_MAX - delta) {
                const uint64_t address = entry.apertureStart + delta;
                return ds_address_usable(address) ? address : 0;
            }
        }
    }
    return 0;
}

- (BOOL)readPhysical64Locked:(uint64_t)physicalAddress value:(uint64_t *)value {
    if (!value) return NO;
    const uint64_t address = [self kernelVirtualForPhysicalLocked:physicalAddress];
    if (!address || !ds_kread64_checked(address, value)) {
        _lastError = @"page-table-physical-read-failed";
        return NO;
    }
    return YES;
}

- (uint64_t)walkPhysicalAddressForUserAddressLocked:(uint64_t)virtualAddress {
    static const uint64_t shifts[] = {36, 25, 14};
    static const uint64_t indexMasksFixed[] = {
        0, 0x0000000FFE000000ULL, 0x0000000001FFC000ULL
    };
    static const uint64_t offsetMasks[] = {
        0x0000000FFFFFFFFFULL,
        0x0000000001FFFFFFULL,
        0x0000000000003FFFULL,
    };
    uint64_t tablePhysical = _targetTTEP;
    BOOL tableIsPhysical = _targetTTEPIsPhysical;
    for (uint32_t level = 0; level < 3; ++level) {
        const uint64_t indexMask = level == 0
            ? coreset_arm_tt_l1_index_mask : indexMasksFixed[level];
        const uint64_t index = (virtualAddress & indexMask) >> shifts[level];
        if (index > 0x7FF || tablePhysical > UINT64_MAX - index * sizeof(uint64_t)) {
            _lastError = @"page-table-index-invalid";
            return 0;
        }
        uint64_t entry = 0;
        const uint64_t entryAddress = tablePhysical + index * sizeof(uint64_t);
        if (tableIsPhysical) {
            if (![self readPhysical64Locked:entryAddress value:&entry]) return 0;
        } else if (!ds_kread64_checked(entryAddress, &entry)) {
            _lastError = @"page-table-virtual-read-failed";
            return 0;
        }
        if ((entry & CSArmTTEValid) != CSArmTTEValid) {
            _lastError = @"page-table-entry-invalid";
            return 0;
        }
        const uint64_t expectedBlockType = level == 2
            ? CSArmTTETypeL3Block : CSArmTTETypeBlock;
        if ((entry & CSArmTTETypeMask) == expectedBlockType) {
            return (entry & CSArmTTEPhysicalMask & ~offsetMasks[level]) |
                (virtualAddress & offsetMasks[level]);
        }
        const uint64_t nextPhysical = entry & CSArmTTETableMask;
        if (!nextPhysical || (nextPhysical & (CSKernelReadPageSize - 1)) != 0) {
            _lastError = @"page-table-next-level-invalid";
            return 0;
        }
        tablePhysical = tableIsPhysical ? nextPhysical
            : [self kernelVirtualForPhysicalLocked:nextPhysical];
        if (!tablePhysical) {
            _lastError = @"page-table-next-level-aperture-missing";
            return 0;
        }
    }
    _lastError = @"page-table-leaf-missing";
    return 0;
}

- (uint64_t)physicalAddressForUserAddressLocked:(uint64_t)virtualAddress {
    const uint64_t pageOffset = virtualAddress & (CSKernelReadPageSize - 1);
    const uint64_t virtualPage = virtualAddress - pageOffset;
    const uint32_t index =
        [self translationCacheIndexForVirtualPageLocked:virtualPage];
    const CSPageTranslationCacheEntry cached = _translationCache[index];
    if (cached.contextGeneration == _contextGeneration &&
        cached.targetTTEP == _targetTTEP &&
        cached.virtualPage == virtualPage && cached.physicalPage != 0 &&
        cached.physicalPage <= UINT64_MAX - pageOffset) {
        return cached.physicalPage + pageOffset;
    }

    const uint64_t physical =
        [self walkPhysicalAddressForUserAddressLocked:virtualAddress];
    if (!physical || physical < pageOffset) {
        memset(&_translationCache[index], 0,
               sizeof(_translationCache[index]));
        return 0;
    }
    const uint64_t physicalPage = physical - pageOffset;
    _translationCache[index] = {
        _targetTTEP, virtualPage, physicalPage, NULL,
        _contextGeneration, 0
    };
    return physical;
}

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
            address + length > CSMaximumUserAddress) {
            _lastError = @"mapped-read-arguments-or-identity-invalid";
            return NO;
        }
        if (![self identityValidLocked]) {
            pthread_mutex_lock(&CSKernelMappedReadLock);
            [self invalidateTranslationCacheLocked];
            pthread_mutex_unlock(&CSKernelMappedReadLock);
            _lastError = @"mapped-read-arguments-or-identity-invalid";
            return NO;
        }
        NSMutableData *scratch = [NSMutableData dataWithLength:length];
        if (!scratch) {
            _lastError = @"mapped-read-allocation-failed";
            return NO;
        }
        pthread_mutex_lock(&CSKernelMappedReadLock);
        const uint32_t readGeneration = _contextGeneration;
        const uint64_t readTTEP = _targetTTEP;
        size_t completed = 0;
        BOOL success = YES;
        BOOL cacheInvalidated = NO;
        while (completed < length) {
            const uint64_t current = address + completed;
            const uint64_t pageAddress = current & ~(CSKernelReadPageSize - 1);
            const size_t pageOffset = (size_t)(current - pageAddress);
            const size_t chunk = MIN(length - completed,
                                     (size_t)CSKernelReadPageSize - pageOffset);
            const uint64_t physical =
                [self physicalAddressForUserAddressLocked:current];
            const uint64_t kernelAddress = physical
                ? [self kernelVirtualForPhysicalLocked:physical] : 0;
            if (!physical || !kernelAddress) {
                if ([_lastError isEqualToString:@"none"]) {
                    _lastError = @"page-table-physical-aperture-missing";
                }
                success = NO;
            } else {
                if (!ds_kreadbuf_checked(kernelAddress,
                        (uint8_t *)scratch.mutableBytes + completed, chunk)) {
                    _lastError = @"page-table-data-read-failed";
                    success = NO;
                }
                if (success) {
                    const uint64_t retranslated =
                        [self walkPhysicalAddressForUserAddressLocked:current];
                    if (retranslated != physical) {
                        _lastError = @"page-table-mapping-changed-during-read";
                        [self invalidateTranslationCacheLocked];
                        cacheInvalidated = YES;
                        success = NO;
                    } else {
                        completed += chunk;
                    }
                }
            }
            if (!success) break;
        }
        const BOOL identityValidAfter = [self identityValidLocked];
        const BOOL contextStable = _contextGeneration == readGeneration &&
            _targetTTEP == readTTEP;
        if (success &&
            (!identityValidAfter || !contextStable)) {
            _lastError = @"mapped-read-identity-changed-after-read";
            success = NO;
        }
        if (!success && !cacheInvalidated &&
            (!contextStable || !identityValidAfter)) {
            [self invalidateTranslationCacheLocked];
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
        uint64_t entry = 0;
        uint32_t count = 0;
        if (!ds_kreadptr_checked(headerAddress + off_vm_map_header_links_next, &entry) ||
            !ds_kread32_checked(headerAddress + off_vm_map_header_nentries, &count)) {
            _lastError = @"page-table-vm-map-header-read-failed";
            return 0;
        }
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
            if (!ds_kreadbuf_checked(entry, &targetEntry, sizeof(targetEntry))) {
                _lastError = @"page-table-vm-map-entry-read-failed";
                return 0;
            }
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
            uint64_t next = 0;
            if (!ds_kreadptr_checked(entry + off_vm_map_entry_links_next, &next)) {
                _lastError = @"page-table-vm-map-next-read-failed";
                return 0;
            }
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
        _connected = NO;
        _processID = -1;
        _kernelProcess = _kernelTask = _kernelVMMap = 0;
        _kernelPmap = _targetTTEP = 0;
        _targetTTEPIsPhysical = NO;
        _paptEntryCount = 0;
        memset(_paptEntries, 0, sizeof(_paptEntries));
        [self invalidateTranslationCacheLocked];
        _lastError = @"disconnected";
        pthread_mutex_unlock(&CSKernelMappedReadLock);
        return YES;
    }
}

@end
