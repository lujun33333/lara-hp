#pragma once

#include <cmath>

namespace coreset_hosted_hit {

struct Bounds {
    double minX;
    double minY;
    double maxX;
    double maxY;
    bool enabled;
};

enum class Owner {
    None,
    Floating,
    Panel,
};

inline bool contains(const Bounds &bounds, double x, double y) {
    return bounds.enabled && std::isfinite(x) && std::isfinite(y) &&
        std::isfinite(bounds.minX) && std::isfinite(bounds.minY) &&
        std::isfinite(bounds.maxX) && std::isfinite(bounds.maxY) &&
        bounds.minX <= bounds.maxX && bounds.minY <= bounds.maxY &&
        x >= bounds.minX && x <= bounds.maxX &&
        y >= bounds.minY && y <= bounds.maxY;
}

// Match Core's UIWindow hit-region order: the 44x44 floating control is the
// top surface, followed by the visible menu panel. Both the background HID
// prefilter and main-thread dispatch must use this same fixed-screen snapshot.
inline Owner ownerAtPoint(const Bounds &floating, const Bounds &panel,
                          double x, double y) {
    if (contains(floating, x, y)) return Owner::Floating;
    if (contains(panel, x, y)) return Owner::Panel;
    return Owner::None;
}

} // namespace coreset_hosted_hit
