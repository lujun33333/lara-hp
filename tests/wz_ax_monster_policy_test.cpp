#include "../lara/kexploit/wz/WZAXMonsterPolicy.h"
#include <cassert>

int main() {
    using namespace AXMonsterPolicy;
    for (size_t i = 0; i < kSlotCount; ++i) {
        const auto marker = MinimapMarker(i, 204.0f);
        if (i == 0 || i == 8) assert(marker.abgr == 0xFFFF0000u && marker.radius == 5);
        else if (i == 4 || i == 12) assert(marker.abgr == 0xFF0000FFu && marker.radius == 5);
        else assert(marker.abgr == 0xFFFFFFFFu && marker.radius == 4);
        assert(TimerColor(i) == (i < 16 && (i & 3u) == 0 ? 0xFF00FFFFu : 0xFFFFFFFFu));
    }
    TimerCache cache;
    assert(cache.Seconds(0, true, 1000, 100) == 4);
    assert(cache.Seconds(0, true, 0, 101) == 3);
    assert(cache.Seconds(0, true, 90000, 102) == 2);
    assert(cache.Seconds(0, false, 0, 103) == 1);
    assert(cache.Seconds(0, true, 0, 104) == 0);
    assert(cache.Seconds(0, true, 89999, 105) == 93);
    assert(cache.Seconds(1, true, 70000, 105) == 0);
    assert(cache.Seconds(1, true, 69999, 105) == 73);
    assert(cache.Seconds(2, true, 90001, 105) == 0);
    assert(cache.Seconds(16, true, 1000, 105) == 0);
    assert(cache.Seconds(99, true, 1000, 105) == 0);
    assert(SelectTimerSource(false, false) == TimerSource::None);
    assert(SelectTimerSource(true, false) == TimerSource::Auxiliary);
    assert(SelectTimerSource(false, true) == TimerSource::Direct);
    assert(!kDrawWorldMarkers);
    assert(DrawableSlot(0) && DrawableSlot(15));
    assert(!DrawableSlot(-1) && !DrawableSlot(16) && !DrawableSlot(17) && !DrawableSlot(18));
}
