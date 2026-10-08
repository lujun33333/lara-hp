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
+ (NSDictionary<NSString *, id> *)diagnosticSnapshot {
    @synchronized (self) {
        const BOOL nativeReady = ds_is_ready();
        NSString *osBuild = CSKernelSysctl(@"kern.osversion");
        NSString *device = CSKernelSysctl(@"hw.machine");
        // This only inspects a transport that is already ready. Diagnostics
        // must never initialize an exploit or install the observed offsets.
        NSUUID *uuid = nativeReady ? CSCurrentKernelUUID() : nil;
        NSDictionary<NSString *, NSNumber *> *observed = CSCurrentOffsets();
        NSMutableArray<NSString *> *failures = [NSMutableArray array];
        if (!nativeReady) [failures addObject:@"kernel_transport_not_ready"];
        if (!osBuild) [failures addObject:@"os_build_unavailable"];
        if (!device) [failures addObject:@"device_identifier_unavailable"];
        if (!uuid) [failures addObject:@"kernel_uuid_unavailable"];
        if (!sProfile) [failures addObject:@"audited_profile_not_installed"];
        const BOOL kernelShapeValid = kernel_base && (kernel_base & 0x3fff) == 0 && t1sz_boot < 64;
        if (getpagesize() != 0x4000) [failures addObject:@"page_size_unsupported"];
        if (!kernelShapeValid)
            [failures addObject:@"kernel_shape_invalid"];

        NSMutableArray<NSString *> *offsetMismatches = [NSMutableArray array];
        if (sProfile) {
            if (uuid && ![uuid isEqual:sProfile.kernelUUID])
                [failures addObject:@"kernel_uuid_mismatch"];
            if (osBuild && ![osBuild isEqualToString:sProfile.osBuild])
                [failures addObject:@"os_build_mismatch"];
            if (device && ![device isEqualToString:sProfile.device])
                [failures addObject:@"device_identifier_mismatch"];
            for (NSString *key in observed) {
                if (![observed[key] isEqual:sProfile.offsets[key]])
                    [offsetMismatches addObject:key];
            }
            if (offsetMismatches.count) [failures addObject:@"kernel_offsets_mismatch"];
        }
        const BOOL profileMatches = sProfile && nativeReady && kernelShapeValid && uuid &&
            [uuid isEqual:sProfile.kernelUUID] && [osBuild isEqualToString:sProfile.osBuild] &&
            [device isEqualToString:sProfile.device] && [observed isEqualToDictionary:sProfile.offsets];
        return @{
            @"schemaVersion": @1,
            @"readOnly": @YES,
            @"kernelTransportReady": @(nativeReady),
            @"osBuild": osBuild ?: (id)[NSNull null],
            @"deviceIdentifier": device ?: (id)[NSNull null],
            @"kernelUUID": uuid.UUIDString ?: (id)[NSNull null],
            @"profileInstalled": @(sProfile != nil),
            @"profileMatches": @(profileMatches),
            @"observedOffsetsAudited": @NO,
            @"observedOffsets": observed,
            @"offsetMismatchKeys": [offsetMismatches sortedArrayUsingSelector:@selector(compare:)],
            @"failureReasons": failures
        };
    }
}
@end
