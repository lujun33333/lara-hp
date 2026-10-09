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
    const char *required[] = {
        "kernelSymbol.cpu_ttep",
        "kernelSymbol.gVirtBase",
        "kernelSymbol.gPhysBase",
        "kernelSymbol.gPhysSize",
        "kernelSymbol.libsptm_n_papt_ranges",
        "kernelSymbol.libsptm_papt_ranges",
        "kernelConstant.ARM_TT_L1_INDEX_MASK",
        "kernelConstant.T1SZ_BOOT",
        "kernelStruct.vm_map.pmap",
        NULL,
    };
    int failed = 0;
    for (const char **name = required; *name; ++name) {
        uint64_t value = xpf_item_resolve(*name);
        printf("0x%016" PRIx64 " <- %s\n", value, *name);
        if (value == 0) failed = 1;
    }
    if (failed) fprintf(stderr, "xpf-required: %s\n", xpf_get_error() ?: "missing item");
    xpf_stop();
    return failed;
}
