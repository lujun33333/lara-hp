#include "../lara/overlay/CoreSetImGuiMenuPointer.h"
#include <cassert>
#include <cstdio>

namespace {
int value = 20;
bool enabled = true;
bool checked = false;
bool sliderChanged = false;
bool checkboxChanged = false;
ImVec2 sliderLow, sliderHigh, checkboxLow, checkboxHigh;

void frame() {
    ImGui::NewFrame();
    ImGui::SetNextWindowPos(ImVec2(0, 0));
    ImGui::SetNextWindowSize(ImVec2(500, 250));
    ImGui::Begin("Core menu input", nullptr, ImGuiWindowFlags_NoDecoration);
    if (!enabled) ImGui::BeginDisabled();
    ImGui::SetNextItemWidth(260);
    sliderChanged = ImGui::SliderInt("scalar", &value, 0, 100) && enabled;
    sliderLow = ImGui::GetItemRectMin(); sliderHigh = ImGui::GetItemRectMax();
    checkboxChanged = ImGui::Checkbox("toggle", &checked) && enabled;
    checkboxLow = ImGui::GetItemRectMin(); checkboxHigh = ImGui::GetItemRectMax();
    if (!enabled) ImGui::EndDisabled();
    ImGui::End();
    ImGui::Render();
}
}

int main() {
    ImGui::CreateContext();
    ImGuiIO &io = ImGui::GetIO();
    io.IniFilename = nullptr; io.LogFilename = nullptr;
    io.DisplaySize = ImVec2(500, 250); io.DeltaTime = 1.0f / 60;
    unsigned char *pixels; int width, height;
    io.Fonts->GetTexDataAsRGBA32(&pixels, &width, &height);
    CoreSet::ImGuiMenuPointer pointer;
    frame(); frame();
    const uint64_t revision = pointer.layoutRevision();
    const float y = (sliderLow.y + sliderHigh.y) / 2;
    assert(pointer.begin(io, sliderLow.x + 30, y));
    // Default ImGui input trickling may separate the first position/down.
    frame(); frame();
    assert(pointer.down());
    const int first = value;
    assert(pointer.move(io, sliderLow.x + 190, y));
    frame();
    assert(sliderChanged && value > first && pointer.down());
    assert(pointer.layoutRevision() == revision); // Value/model update is not layout change.
    unsigned liveUpdates = 0;
    for (int index = 0; index < 100; ++index) {
        assert(pointer.move(io, sliderLow.x + (index % 2 ? 40.0f : 210.0f), y));
        frame();
        if (sliderChanged) ++liveUpdates;
        assert(pointer.down() && pointer.layoutRevision() == revision);
    }
    assert(liveUpdates == 100); // Continuous changed values, before any End.
    const int duringDrag = value;
    assert(pointer.end(io, sliderLow.x + 40, y));
    frame();
    assert(!pointer.down() && value == duringDrag);

    // A label is part of GetItemRect, but not the scalar's interactive frame.
    assert(pointer.begin(io, sliderHigh.x - 4, y)); frame(); frame();
    assert(value == duringDrag && !sliderChanged);
    assert(pointer.end(io, sliderHigh.x - 4, y)); frame();

    enabled = false;
    frame();
    const int disabledValue = value;
    assert(pointer.begin(io, sliderLow.x + 25, y)); frame(); frame();
    assert(pointer.move(io, sliderLow.x + 210, y)); frame();
    assert(!sliderChanged && value == disabledValue);
    assert(pointer.end(io, sliderLow.x + 210, y)); frame();
    const float cx = (checkboxLow.x + checkboxHigh.x) / 2;
    const float cy = (checkboxLow.y + checkboxHigh.y) / 2;
    assert(pointer.begin(io, cx, cy)); frame(); frame();
    assert(pointer.end(io, cx, cy)); frame();
    assert(!checkboxChanged && !checked);

    enabled = true; frame();
    // Both a queued cancellation and an active cancellation must not click.
    assert(pointer.begin(io, cx, cy));
    pointer.cancel(io); frame();
    assert(!checkboxChanged && !checked && !pointer.down());
    assert(pointer.begin(io, cx, cy)); frame(); frame();
    pointer.cancel(io); frame();
    assert(!checkboxChanged && !checked);
    assert(pointer.begin(io, cx, cy)); frame(); frame();
    pointer.layoutChanged(io); frame();
    assert(pointer.layoutRevision() != revision && !pointer.down() && !checked);

    assert(pointer.begin(io, cx, cy)); frame(); frame();
    assert(pointer.end(io, cx, cy)); frame();
    assert(checkboxChanged && checked);
    ImGui::DestroyContext();
    std::puts("PASS: real ImGui live slider changed, disabled rejection, stable pointer and cancellation");
}
