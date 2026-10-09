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

static const uint64_t CSMinimumUserAddress = 0x100000000ULL;
static pthread_mutex_t CSKernelMappedReadLock = PTHREAD_MUTEX_INITIALIZER;

static const uint64_t CSArmTTEValid = 0x1;
static const uint64_t CSArmTTETypeMask = 0x2;
static const uint64_t CSArmTTETypeBlock = 0x0;
static const uint64_t CSArmTTETypeL3Block = 0x2;
// 16 KB child translation tables are page-aligned.  The root table is not:
// with T1SZ=25 and the 0x7000000000 L1 mask it contains only eight entries,
// so a valid pmap.ttep may be merely 0x40-aligned (for example ...0x5280).
static const uint64_t CSArmTTEPhysicalMask = 0x0000FFFFFFFFF000ULL;
static const uint32_t CSPAPTMaximumEntries = 128;
static const uint32_t CSTranslationCacheEntryCount = 2048;
static const uint32_t CSTranslationCacheEntryMask =
    CSTranslationCacheEntryCount - 1;

typedef struct {
    uint64_t physicalStart;
    uint64_t apertureStart;
    uint64_t length;
} CSPhysicalMapEntry;
static_assert(sizeof(CSPhysicalMapEntry) == 0x18,
              "Core 1.7 physical-map record ABI changed");

typedef struct {
    uint64_t physicalStart;
    uint64_t apertureStart;
    uint64_t mappingCount;
} CSSPTMRawPAPTEntry;
static_assert(sizeof(CSSPTMRawPAPTEntry) == 0x18,
              "Core 1.7 SPTM PAPT record ABI changed");

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

static BOOL CSTranslationLayout(uint64_t *pageSizeOut,
                                uint64_t *tableMaskOut,
                                uint64_t shiftsOut[3],
                                uint64_t indexMasksOut[3],
                                uint64_t offsetMasksOut[3]) {
    const uint64_t pageSize = (uint64_t)getpagesize();
    if (pageSize == 0x4000 &&
        (t1sz_boot == 0x19 || t1sz_boot == 0x11)) {
        const uint64_t expectedL1 = t1sz_boot == 0x19
            ? 0x0000007000000000ULL : 0x00007FF000000000ULL;
        if (coreset_arm_tt_l1_index_mask != expectedL1) return NO;
        if (pageSizeOut) *pageSizeOut = pageSize;
        if (tableMaskOut) *tableMaskOut = 0x0000FFFFFFFFC000ULL;
        if (shiftsOut) { shiftsOut[0] = 36; shiftsOut[1] = 25; shiftsOut[2] = 14; }
        if (indexMasksOut) {
            indexMasksOut[0] = expectedL1;
            indexMasksOut[1] = 0x0000000FFE000000ULL;
            indexMasksOut[2] = 0x0000000001FFC000ULL;
        }
        if (offsetMasksOut) {
            offsetMasksOut[0] = 0x0000000FFFFFFFFFULL;
            offsetMasksOut[1] = 0x0000000001FFFFFFULL;
            offsetMasksOut[2] = 0x0000000000003FFFULL;
        }
        return YES;
    }
    if (pageSize == 0x1000 && t1sz_boot == 0x1A &&
        coreset_arm_tt_l1_index_mask == 0x0000003FC0000000ULL) {
        if (pageSizeOut) *pageSizeOut = pageSize;
        if (tableMaskOut) *tableMaskOut = 0x0000FFFFFFFFF000ULL;
        if (shiftsOut) { shiftsOut[0] = 30; shiftsOut[1] = 21; shiftsOut[2] = 12; }
        if (indexMasksOut) {
            indexMasksOut[0] = 0x0000003FC0000000ULL;
            indexMasksOut[1] = 0x000000003FE00000ULL;
            indexMasksOut[2] = 0x00000000001FF000ULL;
        }
        if (offsetMasksOut) {
            offsetMasksOut[0] = 0x000000003FFFFFFFULL;
            offsetMasksOut[1] = 0x00000000001FFFFFULL;
            offsetMasksOut[2] = 0x0000000000000FFFULL;
        }
        return YES;
    }
    return NO;
}

static BOOL CSPhysicalMapEntriesValid(const CSPhysicalMapEntry *entries,
                                      uint32_t count, uint64_t pageSize,
                                      BOOL rejectOverlap) {
    if (!entries || count == 0 || count > CSPAPTMaximumEntries ||
        (pageSize != 0x1000 && pageSize != 0x4000)) return NO;
    uint64_t covered = 0;
    for (uint32_t index = 0; index < count; ++index) {
        const CSPhysicalMapEntry entry = entries[index];
        if (!entry.length ||
            (entry.physicalStart & (pageSize - 1)) != 0 ||
            (entry.apertureStart & (pageSize - 1)) != 0 ||
            (entry.length & (pageSize - 1)) != 0 ||
            !ds_address_usable(entry.apertureStart) ||
            entry.physicalStart > UINT64_MAX - entry.length ||
            entry.apertureStart > UINT64_MAX - entry.length) return NO;
        if (covered > UINT64_MAX - entry.length) return NO;
        covered += entry.length;
        if (!rejectOverlap) continue;
        for (uint32_t previous = 0; previous < index; ++previous) {
            const CSPhysicalMapEntry other = entries[previous];
            const BOOL physicalOverlap =
                entry.physicalStart < other.physicalStart + other.length &&
                other.physicalStart < entry.physicalStart + entry.length;
            const BOOL apertureOverlap =
                entry.apertureStart < other.apertureStart + other.length &&
                other.apertureStart < entry.apertureStart + entry.length;
            if (physicalOverlap || apertureOverlap) return NO;
        }
    }
    return YES;
}

static BOOL CSLoadDirectPhysicalMap(uint64_t tableAddress, uint64_t pageSize,
                                    CSPhysicalMapEntry *entries,
                                    uint32_t *countOut) {
    if (countOut) *countOut = 0;
    if (!entries || !countOut || !ds_address_usable(tableAddress)) return NO;
    CSPhysicalMapEntry first[8] = {0};
    CSPhysicalMapEntry second[8] = {0};
    uint32_t count = 0;
    for (; count < 8; ++count) {
        if (tableAddress > UINT64_MAX - (uint64_t)count * sizeof(CSPhysicalMapEntry))
            return NO;
        const uint64_t address = tableAddress +
            (uint64_t)count * sizeof(CSPhysicalMapEntry);
        if (!ds_kreadbuf_checked(address, &first[count], sizeof(first[count])) ||
            !ds_kreadbuf_checked(address, &second[count], sizeof(second[count])) ||
            memcmp(&first[count], &second[count], sizeof(first[count])) != 0)
            return NO;
        if (first[count].length == 0) break;
    }
    if (count == 0 ||
        !CSPhysicalMapEntriesValid(first, count, pageSize, YES)) return NO;
    memcpy(entries, first, (size_t)count * sizeof(CSPhysicalMapEntry));
    *countOut = count;
    return YES;
}

static BOOL CSPhysicalMapWithinRange(const CSPhysicalMapEntry *entries,
                                     uint32_t count, uint64_t physicalBase,
                                     uint64_t physicalSize) {
    if (!entries || !count || !physicalSize ||
        physicalBase > UINT64_MAX - physicalSize) return NO;
    for (uint32_t index = 0; index < count; ++index) {
        const CSPhysicalMapEntry entry = entries[index];
        if (entry.physicalStart < physicalBase ||
            entry.physicalStart - physicalBase >= physicalSize ||
            entry.length > physicalSize - (entry.physicalStart - physicalBase))
            return NO;
    }
    return YES;
}

static BOOL CSKernelMappedReadPrerequisites(void) {
    uint64_t pageSize = 0, tableMask = 0;
    // XPF also exposes papt_ranges_compressed, but that 0x18-byte SPTM table
    // maps 16K root pages to SPTM frame metadata. It is not a physical-memory
    // aperture. Only the kernel-domain libsptm split globals qualify here.
    const BOOL hasPAPT = coreset_libsptm_n_papt_ranges_offset != 0 &&
        coreset_libsptm_papt_ranges_offset != 0;
    const BOOL hasLinear = coreset_g_virt_base_offset != 0 &&
        coreset_g_phys_base_offset != 0 && coreset_g_phys_size_offset != 0;
    const BOOL hasDirect = coreset_ptov_table_offset != 0;
    return [CoreSetKernelReadProfile matchesCurrentKernel] &&
        ds_is_ready() && kernel_base && ds_address_usable(kernel_base) &&
        CSTranslationLayout(&pageSize, &tableMask, NULL, NULL, NULL) &&
        CSOffsetIsUsable(off_proc_p_pid, 4) &&
        CSOffsetIsUsable(off_proc_p_proc_ro, 8) &&
        CSOffsetIsUsable(off_proc_ro_pr_task, 8) &&
        CSOffsetIsUsable(off_task_map, 8) &&
        coreset_vm_map_pmap_offset == 0x40 &&
        (hasPAPT || hasLinear || hasDirect) &&
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
    uint64_t _pageSize;
    uint64_t _maximumUserAddress;
    uint64_t _tableMask;
    uint64_t _shifts[3];
    uint64_t _indexMasks[3];
    uint64_t _offsetMasks[3];
    CSPhysicalMapEntry _paptEntries[CSPAPTMaximumEntries];
    uint32_t _paptEntryCount;
    uint64_t _linearPhysicalBase;
    uint64_t _linearPhysicalSize;
    uint64_t _linearVirtualBase;
    BOOL _linearMappingReady;
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
        uint64_t pageSize = 0, tableMask = 0;
        uint64_t shifts[3] = {0}, indexMasks[3] = {0}, offsetMasks[3] = {0};
        if (!CSTranslationLayout(&pageSize, &tableMask, shifts,
                                 indexMasks, offsetMasks)) {
            CSSetPageTableInitError(@"page-table-translation-layout-invalid");
            return nil;
        }
        _processID = expectedPID;
        _kernelProcess = kernelProcess;
        _kernelTask = task;
        _kernelVMMap = vmMap;
        _kernelPmap = pmap;
        _targetTTEP = ttep;
        _targetTTEPIsPhysical = ttepIsPhysical;
        _pageSize = pageSize;
        _maximumUserAddress = UINT64_C(1) << (64 - t1sz_boot);
        _tableMask = tableMask;
        memcpy(_shifts, shifts, sizeof(_shifts));
        memcpy(_indexMasks, indexMasks, sizeof(_indexMasks));
        memcpy(_offsetMasks, offsetMasks, sizeof(_offsetMasks));
        _lastError = @"none";

        NSString *physicalMapSource = @"none";
        if (coreset_g_virt_base_offset && coreset_g_phys_base_offset &&
            coreset_g_phys_size_offset &&
            kernel_base <= UINT64_MAX - coreset_g_virt_base_offset &&
            kernel_base <= UINT64_MAX - coreset_g_phys_base_offset &&
            kernel_base <= UINT64_MAX - coreset_g_phys_size_offset) {
            uint64_t virtLeft = 0, virtRight = 0, physLeft = 0, physRight = 0;
            uint64_t sizeLeft = 0, sizeRight = 0;
            const uint64_t virtSymbol = kernel_base + coreset_g_virt_base_offset;
            const uint64_t physSymbol = kernel_base + coreset_g_phys_base_offset;
            const uint64_t sizeSymbol = kernel_base + coreset_g_phys_size_offset;
            if (ds_kread64_checked(virtSymbol, &virtLeft) &&
                ds_kread64_checked(virtSymbol, &virtRight) && virtLeft == virtRight &&
                ds_kread64_checked(physSymbol, &physLeft) &&
                ds_kread64_checked(physSymbol, &physRight) && physLeft == physRight &&
                ds_kread64_checked(sizeSymbol, &sizeLeft) &&
                ds_kread64_checked(sizeSymbol, &sizeRight) && sizeLeft == sizeRight &&
                sizeLeft != 0 && (physLeft & (pageSize - 1)) == 0 &&
                (virtLeft & (pageSize - 1)) == 0 &&
                (sizeLeft & (pageSize - 1)) == 0 &&
                ds_address_usable(virtLeft) &&
                physLeft <= UINT64_MAX - sizeLeft &&
                virtLeft <= UINT64_MAX - sizeLeft &&
                ds_address_usable(virtLeft + sizeLeft - 1)) {
                _linearPhysicalBase = physLeft;
                _linearPhysicalSize = sizeLeft;
                _linearVirtualBase = virtLeft;
                _linearMappingReady = YES;
                physicalMapSource = @"linear-gphys";
            }
        }

        if (coreset_libsptm_n_papt_ranges_offset &&
            coreset_libsptm_papt_ranges_offset &&
            kernel_base <= UINT64_MAX - coreset_libsptm_n_papt_ranges_offset &&
            kernel_base <= UINT64_MAX - coreset_libsptm_papt_ranges_offset) {
            const uint64_t countSymbol = kernel_base +
                coreset_libsptm_n_papt_ranges_offset;
            const uint64_t tableSymbol = kernel_base +
                coreset_libsptm_papt_ranges_offset;
            uint64_t countAddress = 0, tableAddress = 0;
            uint32_t count = 0, confirmedCount = 0;
            if (ds_kreadptr_checked(countSymbol, &countAddress) &&
                ds_kreadptr_checked(tableSymbol, &tableAddress) &&
                ds_address_usable(countAddress) && ds_address_usable(tableAddress) &&
                ds_kread32_checked(countAddress, &count) && count > 0 &&
                count <= CSPAPTMaximumEntries) {
                CSSPTMRawPAPTEntry first[CSPAPTMaximumEntries] = {0};
                CSSPTMRawPAPTEntry second[CSPAPTMaximumEntries] = {0};
                CSPhysicalMapEntry normalized[CSPAPTMaximumEntries] = {0};
                const size_t rawLength =
                    (size_t)count * sizeof(CSSPTMRawPAPTEntry);
                BOOL stable = ds_kreadbuf_checked(tableAddress, first, rawLength) &&
                    ds_kreadbuf_checked(tableAddress, second, rawLength) &&
                    memcmp(first, second, rawLength) == 0 &&
                    ds_kread32_checked(countAddress, &confirmedCount) &&
                    confirmedCount == count;
                if (stable) {
                    for (uint32_t index = 0; index < count; ++index) {
                        if (!first[index].mappingCount ||
                            first[index].mappingCount > UINT64_MAX / pageSize) {
                            stable = NO;
                            break;
                        }
                        normalized[index] = {
                            first[index].physicalStart,
                            first[index].apertureStart,
                            first[index].mappingCount * pageSize
                        };
                    }
                }
                if (stable &&
                    CSPhysicalMapEntriesValid(normalized, count, pageSize, NO)) {
                    memcpy(_paptEntries, normalized,
                           (size_t)count * sizeof(CSPhysicalMapEntry));
                    _paptEntryCount = count;
                    physicalMapSource = @"sptm-split-globals";
                }
            }
        }

        if (_paptEntryCount == 0 && _linearMappingReady &&
            coreset_ptov_table_offset &&
            kernel_base <= UINT64_MAX - coreset_ptov_table_offset) {
            const uint64_t directTable = kernel_base + coreset_ptov_table_offset;
            CSPhysicalMapEntry directEntries[8] = {0};
            uint32_t directCount = 0;
            if (CSLoadDirectPhysicalMap(directTable, pageSize,
                                        directEntries, &directCount) &&
                CSPhysicalMapWithinRange(directEntries, directCount,
                    _linearPhysicalBase, _linearPhysicalSize)) {
                memcpy(_paptEntries, directEntries,
                       (size_t)directCount * sizeof(CSPhysicalMapEntry));
                _paptEntryCount = directCount;
                physicalMapSource = @"ptov-direct-table";
            } else if (directTable <= UINT64_MAX - 0x10 &&
                       CSLoadDirectPhysicalMap(directTable + 0x10, pageSize,
                                               directEntries, &directCount) &&
                       CSPhysicalMapWithinRange(directEntries, directCount,
                           _linearPhysicalBase, _linearPhysicalSize)) {
                memcpy(_paptEntries, directEntries,
                       (size_t)directCount * sizeof(CSPhysicalMapEntry));
                _paptEntryCount = directCount;
                physicalMapSource = @"ptov-legacy-wrapper+0x10";
            }
        }
        if (_paptEntryCount == 0 && !_linearMappingReady) {
            CSSetPageTableInitError(@"page-table-no-verified-physical-map");
            return nil;
        }
        _contextGeneration = 1;
        memset(_translationCache, 0, sizeof(_translationCache));
        _connected = YES;
        CSSetPageTableInitError([NSString stringWithFormat:
            @"none map=%@ paptCount=%u linear=%d page=0x%llx t1sz=0x%llx ttepKind=%@",
            physicalMapSource, _paptEntryCount, _linearMappingReady,
            (unsigned long long)_pageSize, (unsigned long long)t1sz_boot,
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
        !ds_address_usable(_kernelPmap) || !_targetTTEP || !_pageSize ||
        (!_paptEntryCount && !_linearMappingReady)) return NO;
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
    const uint64_t pageNumber = virtualPage / _pageSize;
    const uint64_t rootHash = (_targetTTEP >> 12) ^ (_targetTTEP >> 29);
    const uint64_t value = rootHash ^ pageNumber ^ (pageNumber >> 17);
    return (uint32_t)(value & CSTranslationCacheEntryMask);
}

- (uint64_t)kernelVirtualForPhysicalLocked:(uint64_t)physicalAddress {
    for (uint32_t index = 0; index < _paptEntryCount; ++index) {
        const CSPhysicalMapEntry entry = _paptEntries[index];
        const uint64_t length = entry.length;
        if (physicalAddress >= entry.physicalStart &&
            physicalAddress - entry.physicalStart < length) {
            const uint64_t delta = physicalAddress - entry.physicalStart;
            if (entry.apertureStart <= UINT64_MAX - delta) {
                const uint64_t address = entry.apertureStart + delta;
                return ds_address_usable(address) ? address : 0;
            }
        }
    }
    if (_linearMappingReady && physicalAddress >= _linearPhysicalBase &&
        physicalAddress - _linearPhysicalBase < _linearPhysicalSize) {
        const uint64_t delta = physicalAddress - _linearPhysicalBase;
        if (_linearVirtualBase <= UINT64_MAX - delta) {
            const uint64_t address = _linearVirtualBase + delta;
            return ds_address_usable(address) ? address : 0;
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
    uint64_t tablePhysical = _targetTTEP;
    BOOL tableIsPhysical = _targetTTEPIsPhysical;
    for (uint32_t level = 0; level < 3; ++level) {
        const uint64_t index =
            (virtualAddress & _indexMasks[level]) >> _shifts[level];
        const uint64_t maximumIndex = _pageSize / sizeof(uint64_t) - 1;
        if (index > maximumIndex ||
            tablePhysical > UINT64_MAX - index * sizeof(uint64_t)) {
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
        if ((entry >> 62) != 0) {
            _lastError = @"page-table-entry-high-bits-invalid";
            return 0;
        }
        const uint64_t expectedBlockType = level == 2
            ? CSArmTTETypeL3Block : CSArmTTETypeBlock;
        if ((entry & CSArmTTETypeMask) == expectedBlockType) {
            return (entry & CSArmTTEPhysicalMask & ~_offsetMasks[level]) |
                (virtualAddress & _offsetMasks[level]);
        }
        const uint64_t nextPhysical = entry & _tableMask;
        if (!nextPhysical || (nextPhysical & (_pageSize - 1)) != 0) {
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
    const uint64_t pageOffset = virtualAddress & (_pageSize - 1);
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
            address >= _maximumUserAddress || address > UINT64_MAX - length ||
            address + length > _maximumUserAddress) {
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
            const uint64_t pageAddress = current & ~(_pageSize - 1);
            const size_t pageOffset = (size_t)(current - pageAddress);
            const size_t chunk = MIN(length - completed,
                                     (size_t)_pageSize - pageOffset);
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
                start < _maximumUserAddress &&
                (start & (_pageSize - 1)) == 0 &&
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
        _pageSize = _maximumUserAddress = _tableMask = 0;
        memset(_shifts, 0, sizeof(_shifts));
        memset(_indexMasks, 0, sizeof(_indexMasks));
        memset(_offsetMasks, 0, sizeof(_offsetMasks));
        _paptEntryCount = 0;
        memset(_paptEntries, 0, sizeof(_paptEntries));
        _linearPhysicalBase = _linearPhysicalSize = _linearVirtualBase = 0;
        _linearMappingReady = NO;
        [self invalidateTranslationCacheLocked];
        _lastError = @"disconnected";
        pthread_mutex_unlock(&CSKernelMappedReadLock);
        return YES;
    }
}

@end
