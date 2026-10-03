#include <stddef.h>

#if defined(XPF_TEST_LARA_HEADER)
#include "../lara/headers/xpf.h"
#else
#include "../vendor/XPF/src/xpf.h"
#endif

_Static_assert(offsetof(XPF, firstItem) == 0x110, "AX 1.2.8 firstItem ABI");
_Static_assert(offsetof(XPF, ignoreBaseSet) == 0x118, "AX 1.2.8 ignoreBaseSet ABI");
_Static_assert(sizeof(XPF) == 0x120, "AX 1.2.8 XPF size");

int main(void)
{
    return 0;
}
