#import "CoreSetKernelWriteProfile.h"
#import "../kexploit/darksword.h"
#import "../kexploit/offsets.h"
#import <mach-o/loader.h>
#import <sys/sysctl.h>
#include <string.h>
#include <unistd.h>

@implementation CoreSetKernelWriteProfile
- (instancetype)initWithKernelUUID:(NSUUID *)kernelUUID osBuild:(NSString *)osBuild
                            device:(NSString *)device
                           offsets:(NSDictionary<NSString *, NSNumber *> *)offsets {
    if ((self = [super init])) {
        _kernelUUID = [kernelUUID copy]; _osBuild = [osBuild copy];
        _device = [device copy]; _offsets = [offsets copy];
    }
    return self;
}
@end

static NSString *CSKernelSysctl(NSString *name) {
    size_t size = 0;
    if (sysctlbyname(name.UTF8String, NULL, &size, NULL, 0) != 0 || size < 2 || size > 256)
        return nil;
    char bytes[256] = {0};
    if (sysctlbyname(name.UTF8String, bytes, &size, NULL, 0) != 0 ||
        size < 2 || size > sizeof(bytes) || bytes[size - 1] != '\0') return nil;
    return [NSString stringWithUTF8String:bytes];
}

static NSUUID *CSCurrentKernelUUID(void) {
    if (!ds_is_ready() || !kernel_base || !ds_address_usable(kernel_base)) return nil;
    struct mach_header_64 header = {0};
    ds_kreadbuf(kernel_base, &header, sizeof(header));
    if (header.magic != MH_MAGIC_64 || header.cputype != CPU_TYPE_ARM64 ||
        (header.filetype != MH_FILESET && header.filetype != MH_EXECUTE) ||
        !header.ncmds || header.ncmds > 1024 ||
        header.sizeofcmds < sizeof(struct uuid_command) || header.sizeofcmds > 0x20000 ||
        kernel_base > UINT64_MAX - sizeof(header) - header.sizeofcmds ||
        !ds_address_usable(kernel_base + sizeof(header))) return nil;
    NSMutableData *commands = [NSMutableData dataWithLength:header.sizeofcmds];
    NSMutableData *confirm = [NSMutableData dataWithLength:header.sizeofcmds];
    if (!commands || !confirm) return nil;
    ds_kreadbuf(kernel_base + sizeof(header), commands.mutableBytes, commands.length);
    ds_kreadbuf(kernel_base + sizeof(header), confirm.mutableBytes, confirm.length);
    if (![commands isEqualToData:confirm]) return nil;
    const uint8_t *bytes = (const uint8_t *)commands.bytes;
    size_t offset = 0;
    for (uint32_t index = 0; index < header.ncmds; ++index) {
        if (offset > commands.length || commands.length - offset < sizeof(struct load_command)) return nil;
        const struct load_command *load = (const struct load_command *)(bytes + offset);
        if (load->cmdsize < sizeof(*load) || load->cmdsize > commands.length - offset) return nil;
        if (load->cmd == LC_UUID) {
            if (load->cmdsize < sizeof(struct uuid_command)) return nil;
            const struct uuid_command *uuid = (const struct uuid_command *)load;
            return [[NSUUID alloc] initWithUUIDBytes:uuid->uuid];
        }
        offset += load->cmdsize;
    }
    return nil;
}

static NSDictionary<NSString *, NSNumber *> *CSCurrentOffsets(void) {
    return @{
        @"off_proc_p_pid": @(off_proc_p_pid), @"off_task_map": @(off_task_map),
        @"off_vm_map_hdr": @(off_vm_map_hdr),
        @"off_vm_map_header_nentries": @(off_vm_map_header_nentries),
        @"off_vm_map_entry_links_next": @(off_vm_map_entry_links_next),
        @"off_vm_map_entry_vme_object_or_delta": @(off_vm_map_entry_vme_object_or_delta),
        @"off_vm_map_entry_vme_alias": @(off_vm_map_entry_vme_alias),
        @"off_vm_map_header_links_next": @(off_vm_map_header_links_next),
        @"off_vm_object_vo_un1_vou_size": @(off_vm_object_vo_un1_vou_size),
        @"off_vm_object_ref_count": @(off_vm_object_ref_count),
        @"off_vm_named_entry_backing_copy": @(off_vm_named_entry_backing_copy),
        @"off_vm_named_entry_size": @(off_vm_named_entry_size),
        @"smr_base": @(smr_base), @"t1sz_boot": @(t1sz_boot),
        @"VM_MIN_KERNEL_ADDRESS": @(VM_MIN_KERNEL_ADDRESS),
        @"VM_MAX_KERNEL_ADDRESS": @(VM_MAX_KERNEL_ADDRESS),
        @"page_size": @(getpagesize())
    };
}

static CoreSetKernelWriteProfile *sProfile;
@implementation CoreSetKernelWriteProfileRegistry
+ (BOOL)installAuditedProfile:(CoreSetKernelWriteProfile *)profile {
    @synchronized (self) {
        if (sProfile || !profile.kernelUUID || !profile.osBuild.length ||
            !profile.device.length || profile.offsets.count != [CSCurrentOffsets() count]) return NO;
        for (NSNumber *value in profile.offsets.allValues) if (!value.unsignedLongLongValue) return NO;
        sProfile = profile;
        return YES;
    }
}
+ (BOOL)matchesCurrentKernel {
    @synchronized (self) {
        if (!sProfile || !ds_is_ready() || !kernel_base ||
            (kernel_base & 0x3fff) != 0 || t1sz_boot >= 64) return NO;
        NSUUID *uuid = CSCurrentKernelUUID();
        NSString *osBuild = CSKernelSysctl(@"kern.osversion");
        NSString *device = CSKernelSysctl(@"hw.machine");
        NSDictionary *offsets = CSCurrentOffsets();
        return uuid && [uuid isEqual:sProfile.kernelUUID] &&
            [osBuild isEqualToString:sProfile.osBuild] &&
            [device isEqualToString:sProfile.device] &&
            [offsets isEqualToDictionary:sProfile.offsets];
    }
}
@end
