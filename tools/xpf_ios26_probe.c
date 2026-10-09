#include <inttypes.h>
#include <stdio.h>
#include "xpf.h"

int main(int argc, char **argv)
{
    if (argc != 3) {
        fprintf(stderr, "usage: %s <kernelcache.im4p> <sptm.im4p>\n", argv[0]);
        return 64;
    }
    if (xpf_start_with_kernel_path(argv[1], argv[2], NULL) != 0) {
        fprintf(stderr, "xpf-start: %s\n", xpf_get_error() ?: "unknown");
        return 1;
    }
    printf("0x%016" PRIx64 " <- gXPF.kernelBase\n", gXPF.kernelBase);
    printf("0x%016" PRIx64 " <- gXPF.sptmBase\n", gXPF.sptmBase);
    struct {
        const char *name;
        uint64_t expected;
    } required[] = {
        { "kernelSymbol.cpu_ttep", 0xfffffff007c14f60ULL },
        { "kernelSymbol.gVirtBase", 0xfffffff007c38c68ULL },
        { "kernelSymbol.gPhysBase", 0xfffffff007c69dc0ULL },
        { "kernelSymbol.gPhysSize", 0xfffffff007c69dc8ULL },
        { "kernelSymbol.libsptm_n_papt_ranges", 0xfffffff007cace30ULL },
        { "kernelSymbol.libsptm_papt_ranges", 0xfffffff007cace38ULL },
        { "kernelConstant.ARM_TT_L1_INDEX_MASK", 0x0000007000000000ULL },
        { "kernelConstant.T1SZ_BOOT", 0x19ULL },
        { "kernelStruct.vm_map.pmap", 0x40ULL },
    };
    int failed = gXPF.kernelBase != 0xfffffff007004000ULL ||
        gXPF.sptmBase != 0xfffffff027004000ULL;
    for (size_t index = 0; index < sizeof(required) / sizeof(required[0]); ++index) {
        uint64_t value = xpf_item_resolve(required[index].name);
        printf("0x%016" PRIx64 " <- %s\n", value, required[index].name);
        if (value != required[index].expected) failed = 1;
    }
    if (failed) fprintf(stderr, "xpf-required: %s\n", xpf_get_error() ?: "missing item");
    xpf_stop();
    return failed;
}
