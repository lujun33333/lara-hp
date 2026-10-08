#include "../lara/overlay/CoreSetReadDisplaySemantics.h"
#include <cassert>
#include <cstdio>
#include <limits>

int main() {
    using namespace CoreSet;
    int32_t value = 42;
    assert(displayDistanceMeters(12.99, false, &value) && value == 12);
    assert(displayDistanceMeters(12.5, true, &value) && value == 13);
    assert(displayDistanceMeters(0, false, &value) && value == 0);
    assert(displayDistanceMeters(0.5, true, &value) && value == 1);
    assert(!displayDistanceMeters(1, true, nullptr));
    for (double bad : {-1.0, std::numeric_limits<double>::quiet_NaN(),
                       std::numeric_limits<double>::infinity(),
                       double(std::numeric_limits<int32_t>::max())}) {
        value = 42;
        assert(!displayDistanceMeters(bad, false, &value) && value == 0);
        assert(referencePlayerDistanceText(bad).empty());
        assert(referenceWarningText("name", false, "AKM", 101001, bad).empty());
    }
    assert(referencePlayerDistanceText(12.99) == "12 米");
    assert(referencePlayerDistanceText(0) == "0 米");
    assert(referenceWarningText("姓名", false, "AKM", 101001, 12.5) == "姓名 使用 AKM 瞄准您 13m");
    assert(referenceWarningText(nullptr, true, "M416", 101004, 12.49) == "人机 使用 M416 瞄准您 12m");
    assert(referenceWarningText("", false, nullptr, 123456, 12.5) == "未知玩家 使用 未知武器(123456) 瞄准您 13m");
    assert(referenceWarningText("A", false, "", 9999999, 0) == "A 使用 未知武器(9999999) 瞄准您 0m");
    assert(referenceWarningText("A", false, nullptr, 10000000, 0) == "A 正在瞄准您 0m");
    assert(referenceWarningText("A", false, nullptr, 0, 0) == "A 正在瞄准您 0m");
    std::puts("PASS: production read-only display helper, truncation/rounding, invalid values and warning branches");
}
