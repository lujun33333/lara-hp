#include "../lara/headers/AXLauncherAuthorizationPolicy.h"

#include <assert.h>

#ifndef EXPECT_LOCAL_TEST_AUTH_BYPASS
#error EXPECT_LOCAL_TEST_AUTH_BYPASS must be defined by the host test
#endif

int main(void)
{
    assert(ax_launcher_local_test_authorization_bypass_enabled() ==
           (EXPECT_LOCAL_TEST_AUTH_BYPASS != 0));
    assert(ax_launcher_authorization_allows_functional_access(false) ==
           (EXPECT_LOCAL_TEST_AUTH_BYPASS != 0));
    assert(ax_launcher_authorization_allows_functional_access(true));
    return 0;
}
