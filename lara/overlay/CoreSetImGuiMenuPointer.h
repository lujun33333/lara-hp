#pragma once

#include "../third_party/imgui/imgui.h"
#include <cstdint>
#include <cmath>

namespace CoreSet {

// Model publication is independent of a physical pointer's layout lifetime.
// ImGui owns widget hit testing, disabled state, scalar values and changed.
class ImGuiMenuPointer {
public:
    uint64_t layoutRevision() const { return layoutRevision_; }
    bool down() const { return down_; }

    bool begin(ImGuiIO &io, float x, float y) {
        if (down_ || !std::isfinite(x) || !std::isfinite(y)) return false;
        io.AddMouseSourceEvent(ImGuiMouseSource_TouchScreen);
        io.AddMousePosEvent(x, y);
        io.AddMouseButtonEvent(ImGuiMouseButton_Left, true);
        down_ = true;
        return true;
    }
    bool move(ImGuiIO &io, float x, float y) {
        if (!down_ || !std::isfinite(x) || !std::isfinite(y)) return false;
        io.AddMousePosEvent(x, y);
        return true;
    }
    bool end(ImGuiIO &io, float x, float y) {
        if (!move(io, x, y)) return false;
        io.AddMouseButtonEvent(ImGuiMouseButton_Left, false);
        down_ = false;
        return true;
    }
    void cancel(ImGuiIO &io) {
        // A cancelled queued click must never become a release-over-widget.
        io.ClearEventsQueue();
        io.ClearInputMouse();
        down_ = false;
    }
    void layoutChanged(ImGuiIO &io) {
        cancel(io);
        if (++layoutRevision_ == 0) ++layoutRevision_;
    }

private:
    uint64_t layoutRevision_ = 1;
    bool down_ = false;
};

} // namespace CoreSet
