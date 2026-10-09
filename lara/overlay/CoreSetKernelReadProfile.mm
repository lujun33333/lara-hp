#import "CoreSetKernelReadProfile.h"
#import "../kexploit/darksword.h"
#import "../kexploit/offsets.h"
#import <mach-o/loader.h>
#import <sys/sysctl.h>
#import <string.h>
#import <unistd.h>

static NSString *CSReadProfileSysctl(const char *name) {
    size_t size = 0;
    if (sysctlbyname(name, NULL, &size, NULL, 0) != 0 || size < 2 || size > 512) return nil;
    char bytes[512] = {0};
    if (sysctlbyname(name, bytes, &size, NULL, 0) != 0 ||
        size < 2 || size > sizeof(bytes) || bytes[size - 1] != '\0') return nil;
    return [NSString stringWithUTF8String:bytes];
}

static NSUUID *CSReadProfileKernelUUID(void) {
    if (!ds_is_ready() || !kernel_base || !ds_address_usable(kernel_base)) return nil;
    struct mach_header_64 header = {0};
    ds_kreadbuf(kernel_base, &header, sizeof(header));
    if (header.magic != MH_MAGIC_64 || header.cputype != CPU_TYPE_ARM64 ||
        (header.filetype != MH_FILESET && header.filetype != MH_EXECUTE) ||
        !header.ncmds || header.ncmds > 1024 || header.sizeofcmds < sizeof(struct uuid_command) ||
        header.sizeofcmds > 0x20000 ||
        kernel_base > UINT64_MAX - sizeof(header) - header.sizeofcmds) return nil;
    NSMutableData *left = [NSMutableData dataWithLength:header.sizeofcmds];
    NSMutableData *right = [NSMutableData dataWithLength:header.sizeofcmds];
    if (!left || !right) return nil;
    ds_kreadbuf(kernel_base + sizeof(header), left.mutableBytes, left.length);
    ds_kreadbuf(kernel_base + sizeof(header), right.mutableBytes, right.length);
    if (![left isEqualToData:right]) return nil;
    const uint8_t *bytes = (const uint8_t *)left.bytes;
    size_t offset = 0;
    for (uint32_t index = 0; index < header.ncmds; ++index) {
        if (offset > left.length || left.length - offset < sizeof(struct load_command)) return nil;
        const struct load_command *command = (const struct load_command *)(bytes + offset);
        if (command->cmdsize < sizeof(*command) || command->cmdsize > left.length - offset)
            return nil;
        if (command->cmd == LC_UUID) {
            if (command->cmdsize < sizeof(struct uuid_command)) return nil;
            return [[NSUUID alloc] initWithUUIDBytes:
                ((const struct uuid_command *)command)->uuid];
        }
        offset += command->cmdsize;
    }
    return nil;
}

static NSString *sReadProfileFailure = @"not-checked";
static NSUUID *sPinnedKernelUUID;
static uint64_t sPinnedKernelBase = 0;
static BOOL sReadProfileValidated = NO;

@implementation CoreSetKernelReadProfile

+ (BOOL)matchesCurrentKernel {
    @synchronized (self) {
        if (!ds_is_ready()) { sReadProfileFailure = @"kernel-transport-not-ready"; return NO; }
        const size_t pageSize = (size_t)getpagesize();
        const BOOL translationLayoutMatch =
            (pageSize == 0x4000 &&
             ((t1sz_boot == 0x19 &&
               coreset_arm_tt_l1_index_mask == 0x0000007000000000ULL) ||
              (t1sz_boot == 0x11 &&
               coreset_arm_tt_l1_index_mask == 0x00007FF000000000ULL))) ||
            (pageSize == 0x1000 && t1sz_boot == 0x1A &&
             coreset_arm_tt_l1_index_mask == 0x0000003FC0000000ULL);
        const BOOL offsetsMatch =
            off_proc_p_pid == 0x60 && off_proc_p_proc_ro == 0x18 &&
            off_proc_ro_pr_task == 0x8 && off_task_map == 0x28 &&
            off_task_itk_space == 0x310 && off_ipc_space_is_table == 0x48 &&
            sizeof_ipc_entry == 0x18 && off_ipc_entry_ie_object == 0 &&
            off_ipc_port_ip_kobject == 0x50 &&
            off_vm_map_hdr == 0x10 && off_vm_map_header_nentries == 0x20 &&
            off_vm_map_header_links_next == 0x8 && off_vm_map_entry_links_next == 0x8 &&
            off_vm_map_entry_vme_object_or_delta == 0x3c &&
            off_vm_map_entry_vme_alias == 0x40 &&
            off_vm_object_vo_un1_vou_size == 0x18 &&
            off_vm_object_ref_count == 0x28 &&
            off_vm_named_entry_backing_copy == 0x10 && off_vm_named_entry_size == 0x20 &&
            smr_base == 2 && translationLayoutMatch &&
            VM_MIN_KERNEL_ADDRESS == 0xFFFFFFDC00000000ULL &&
            VM_MAX_KERNEL_ADDRESS == 0xFFFFFFFBFFFFFFFFULL;
        if (!offsetsMatch) {
            sReadProfileValidated = NO;
            sReadProfileFailure = @"kernel-offset-profile-mismatch";
            return NO;
        }
        if (sReadProfileValidated && kernel_base == sPinnedKernelBase) return YES;
        sReadProfileValidated = NO;
        NSString *build = CSReadProfileSysctl("kern.osversion");
        NSString *device = CSReadProfileSysctl("hw.machine");
        NSString *version = CSReadProfileSysctl("kern.version");
        if (![build isEqualToString:@"23A341"] ||
            ![device isEqualToString:@"iPhone17,2"] ||
            ![version isEqualToString:
                @"Darwin Kernel Version 25.0.0: Tue Aug 26 20:30:59 PDT 2025; root:xnu-12377.2.8~1/RELEASE_ARM64_T8140"]) {
            sReadProfileFailure = @"kernel-build-device-version-mismatch";
            return NO;
        }
        NSUUID *left = CSReadProfileKernelUUID();
        NSUUID *right = CSReadProfileKernelUUID();
        if (!left || !right || ![left isEqual:right]) {
            sReadProfileFailure = @"kernel-uuid-unavailable-or-unstable";
            return NO;
        }
        if (!sPinnedKernelUUID) sPinnedKernelUUID = left;
        if (![sPinnedKernelUUID isEqual:left]) {
            sReadProfileFailure = @"kernel-uuid-changed";
            return NO;
        }
        sPinnedKernelBase = kernel_base;
        sReadProfileValidated = YES;
        sReadProfileFailure = @"none";
        NSLog(@"Core-SET: kernel-read-profile matched=1 build=23A341 device=iPhone17,2 uuid=%@ offsets=exact",
              sPinnedKernelUUID.UUIDString);
        return YES;
    }
}

+ (NSString *)lastFailure { @synchronized (self) { return [sReadProfileFailure copy]; } }

@end
