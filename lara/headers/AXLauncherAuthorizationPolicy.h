#ifndef AXLauncherAuthorizationPolicy_h
#define AXLauncherAuthorizationPolicy_h

#include <stdbool.h>

// Production and ordinary Xcode builds are fail-closed. The canonical build
// script defines this to 1 only for an explicitly requested local-test IPA.
#ifndef AX_LOCAL_TEST_AUTH_BYPASS
#define AX_LOCAL_TEST_AUTH_BYPASS 0
#endif

static inline bool ax_launcher_local_test_authorization_bypass_enabled(void)
{
    return AX_LOCAL_TEST_AUTH_BYPASS == 1;
}

static inline bool ax_launcher_authorization_allows_functional_access(
    bool verified)
{
    return ax_launcher_local_test_authorization_bypass_enabled() || verified;
}

#endif /* AXLauncherAuthorizationPolicy_h */
