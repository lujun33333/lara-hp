#pragma once

#include <cmath>

namespace CoreSet {

struct CenteredTextSpan {
    double originX;
    double width;
};

inline bool centeredTextSpan(double anchorX, double measuredWidth,
                             CenteredTextSpan *output) {
    if (!output || !std::isfinite(anchorX) || !std::isfinite(measuredWidth) ||
        measuredWidth < 0 || measuredWidth > 32768) return false;
    const double width = std::ceil(measuredWidth) + 2.0;
    const double originX = anchorX - width / 2.0;
    if (!std::isfinite(width) || !std::isfinite(originX)) return false;
    *output = {originX, width};
    return true;
}

} // namespace CoreSet
