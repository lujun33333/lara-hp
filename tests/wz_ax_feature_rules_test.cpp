#include "../lara/kexploit/WZAXFeatureRules.h"
#include <cassert>
#include <limits>

int main() {
    // A missing-health calculation, not a fraction of maximum HP.
    assert(wzax_auto_kill_eligible(100, 1000, 0, 0, 1, 1));
    assert(!wzax_auto_kill_eligible(200, 1000, 0, 0, 1, 1));
    assert(wzax_auto_kill_eligible(30, 230, 0, 0, 1, 1));
    // The original distance uses the float32 squared bound, not radius 5.
    assert(wzax_auto_kill_eligible(100, 1000, 0, 0, 4.7f, 0));
    assert(!wzax_auto_kill_eligible(100, 1000, 0, 0, 4.71f, 0));
    assert(!wzax_auto_kill_eligible(100, 1000, 1, 1, 1, 1));
    assert(!wzax_auto_kill_eligible(0, 1000, 0, 0, 1, 1));
    assert(!wzax_auto_kill_eligible(100, 99, 0, 0, 1, 1));
    const float nan = std::numeric_limits<float>::quiet_NaN();
    assert(!wzax_auto_kill_eligible(nan, 1000, 0, 0, 1, 1));
    assert(!wzax_auto_kill_eligible(100, 1000, 0, 0, nan, 1));
}
