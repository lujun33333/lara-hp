#include <stddef.h>

#if defined(XPF_TEST_LARA_HEADER)
#include "../../lara/headers/xpf.h"
#else
#include "../../vendor/XPF/src/xpf.h"
#endif

_Static_assert(offsetof(XPF, firstItem) == 0x1a8, "SPTM XPF firstItem ABI");
_Static_assert(offsetof(XPF, ignoreBaseSet) == 0x1b0, "SPTM XPF ignoreBaseSet ABI");
_Static_assert(sizeof(XPF) == 0x1b8, "SPTM XPF size");

int main(void)
{
    return 0;
}
