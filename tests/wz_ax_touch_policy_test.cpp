#include "../lara/kexploit/wz/WZAXTouch.h"
#include <cassert>
#include <limits>

int main() {
    using namespace wzax_touch_policy;
    static_assert(state(Down).fingerMask == 0x23 && state(Down).parentMask == 0x23, "down");
    static_assert(state(Move).fingerMask == 4 && state(Move).parentMask == 4, "move");
    static_assert(state(Up).fingerMask == 0x23 && state(Up).parentMask == 0x27, "up");
    static_assert(!state(Up).touching && state(Up).pressure == 0, "release contact");
    static_assert(tapPointer == 9 && holdSeconds == 0.035, "AX tap action");
    static_assert(ownsSession(7, 7, 11, 11), "current session");
    static_assert(!ownsSession(0, 0, 0, 0), "zero is never a session");
    static_assert(!ownsSession(7, 8, 11, 11), "stale sender generation");
    static_assert(!ownsSession(7, 7, 11, 12), "foreign reservation");
    assert(allocationSize(1) == 0x4000);
    assert(allocationSize(0x4000) == 0x4000);
    assert(allocationSize(0x4001) == 0x8000);
    assert(allocationSize(0) == 0 && allocationSize(SIZE_MAX) == 0);
    double x, y;
    assert(normalize(100, 200, 390, 844, 3, x, y));
    assert(x == double((float(100)/(float(390)*3.f))*3.f));
    assert(y == double((float(200)/(float(844)*3.f))*3.f));
    double a, b;
    assert(normalize(100, 200, 844, 390, 3, a, b) && a == x && b == y);
    assert(normalize(-100, 20000, 390, 844, 3, x, y) && x < 0 && y > 1);
    assert(!normalize(std::numeric_limits<double>::quiet_NaN(), 1, 390, 844, 3, x, y));
    assert(!normalize(1, 1, 0, 844, 3, x, y));
    assert(!normalize(1, 1, 390, 844, 0, x, y));
}
