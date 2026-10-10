#import "CoreSetImGuiMenuSurface.h"
#import <MetalKit/MetalKit.h>
#include "../third_party/imgui/imgui.h"
#include "../third_party/imgui/backends/imgui_impl_metal.h"
#include "CoreSetImGuiMenuPointer.h"
#include <algorithm>
#include <cmath>

@class CoreSetImGuiMenuViewController;

@interface CoreSetImGuiTouchView : MTKView
@property(nonatomic, weak) CoreSetImGuiMenuViewController *menuOwner;
@end

@interface CoreSetImGuiMenuViewController () <MTKViewDelegate>
- (BOOL)dispatchLocalPoint:(CGPoint)point phase:(CoreSetHostedPointerPhase)phase;
@end

@implementation CoreSetImGuiTouchView
- (void)dispatchTouches:(NSSet<UITouch *> *)touches phase:(CoreSetHostedPointerPhase)phase {
    UITouch *touch = touches.anyObject;
    if (touch) [self.menuOwner dispatchLocalPoint:[touch locationInView:self] phase:phase];
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self dispatchTouches:touches phase:CoreSetHostedPointerPhaseBegan];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self dispatchTouches:touches phase:CoreSetHostedPointerPhaseMoved];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self dispatchTouches:touches phase:CoreSetHostedPointerPhaseEnded];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self dispatchTouches:touches phase:CoreSetHostedPointerPhaseCancelled];
}
@end

static ImVec4 CSColor(NSArray *rgba, ImVec4 fallback) {
    if (![rgba isKindOfClass:NSArray.class] || rgba.count != 4) return fallback;
    float values[4] = {};
    for (NSUInteger index = 0; index < 4; ++index) {
        id value = rgba[index];
        if (![value respondsToSelector:@selector(doubleValue)] || !std::isfinite([value doubleValue]))
            return fallback;
        values[index] = (float)std::clamp([value doubleValue], 0.0, 1.0);
    }
    return ImVec4(values[0], values[1], values[2], values[3]);
}

static NSString *CSString(id value) {
    return [value isKindOfClass:NSString.class] ? value : @"";
}

@implementation CoreSetImGuiMenuViewController {
    __weak id<CoreSetImGuiMenuModel> _model;
    CoreSetImGuiTouchView *_metalView;
    id<MTLCommandQueue> _queue;
    ImGuiContext *_imgui;
    ImFont *_bodyFont;
    ImFont *_titleFont;
    ImFont *_brandFont;
    CADisplayLink *_displayLink;
    NSDictionary *_snapshot;
    uint64_t _renderedRevision;
    CoreSet::ImGuiMenuPointer _pointer;
    CGRect _inputBounds;
    uint64_t _frameSerial;
    uint64_t _widgetActionSerial;
}

- (instancetype)initWithModel:(id<CoreSetImGuiMenuModel>)model {
    if (!model) return nil;
    if ((self = [super initWithNibName:nil bundle:nil])) _model = model;
    return self;
}
- (id<CoreSetImGuiMenuModel>)model { return _model; }

- (void)loadView {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    UIView *fallback = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 838, 535)];
    fallback.backgroundColor = UIColor.clearColor;
    self.view = fallback;
    if (!device) return;
    _queue = [device newCommandQueue];
    _metalView = [[CoreSetImGuiTouchView alloc] initWithFrame:fallback.bounds device:device];
    _metalView.menuOwner = self;
    _metalView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _metalView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    _metalView.depthStencilPixelFormat = MTLPixelFormatInvalid;
    _metalView.framebufferOnly = YES;
    _metalView.opaque = NO; _metalView.layer.opaque = NO;
    _metalView.clearColor = MTLClearColorMake(0, 0, 0, 0);
    _metalView.paused = YES; _metalView.enableSetNeedsDisplay = YES;
    _metalView.delegate = self;
    [fallback addSubview:_metalView];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if (!_metalView || !_queue) return;
    _imgui = ImGui::CreateContext();
    if (!_imgui) return;
    ImGui::SetCurrentContext(_imgui);
    ImGuiIO &io = ImGui::GetIO();
    io.IniFilename = nullptr; io.LogFilename = nullptr;
    // Hosted apps can stop delivering CADisplayLink ticks in the background.
    // Each physical phase is rendered synchronously below, so one queued phase
    // must be fully consumed by one ImGui frame rather than trickled later.
    io.ConfigInputTrickleEventQueue = false;
    NSString *fontPath = [NSBundle.mainBundle pathForResource:@"OPPOSans-H" ofType:@"ttf"];
    if (fontPath.length) {
        const ImWchar *ranges = io.Fonts->GetGlyphRangesChineseFull();
        _bodyFont = io.Fonts->AddFontFromFileTTF(fontPath.UTF8String, 16.0f, nullptr, ranges);
        _titleFont = io.Fonts->AddFontFromFileTTF(fontPath.UTF8String, 17.0f, nullptr, ranges);
        _brandFont = io.Fonts->AddFontFromFileTTF(fontPath.UTF8String, 25.0f, nullptr, ranges);
    }
    if (!_bodyFont) _bodyFont = io.Fonts->AddFontDefault();
    if (!_titleFont) _titleFont = _bodyFont;
    if (!_brandFont) _brandFont = _bodyFont;
    if (!ImGui_ImplMetal_Init(_metalView.device)) {
        ImGui::DestroyContext(_imgui); _imgui = nullptr; return;
    }
    NSLog(@"Core-SET: ImGui runtime contract=core17-imgui-v13 size=838x535 contentOrigin=170,38 inputFrame=phase-driven semanticReceipt=widget-action");
    [self startDisplayLink];
}

- (void)startDisplayLink {
    if (_displayLink || !_imgui) return;
    _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayTick:)];
    _displayLink.preferredFramesPerSecond = 60;
    [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)displayTick:(CADisplayLink *)link {
    if (_metalView.window && !self.view.hidden && !self.view.superview.hidden &&
        self.view.alpha > 0.01 && self.view.superview.alpha > 0.01) {
        [_metalView draw];
    } else if (_imgui && _pointer.down()) {
        ImGui::SetCurrentContext(_imgui);
        _pointer.cancel(ImGui::GetIO());
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (_imgui && !CGRectEqualToRect(_inputBounds, self.view.bounds)) {
        ImGui::SetCurrentContext(_imgui);
        _pointer.layoutChanged(ImGui::GetIO());
        _inputBounds = self.view.bounds;
    }
}

- (void)dealloc {
    [_displayLink invalidate];
    if (_imgui) {
        ImGui::SetCurrentContext(_imgui);
        ImGui_ImplMetal_Shutdown();
        ImGui::DestroyContext(_imgui);
    }
}

- (void)willMoveToParentViewController:(UIViewController *)parent {
    [super willMoveToParentViewController:parent];
    if (parent) [self startDisplayLink];
    else {
        [_displayLink invalidate]; _displayLink = nil;
        if (_imgui) {
            ImGui::SetCurrentContext(_imgui);
            _pointer.cancel(ImGui::GetIO());
        }
    }
}

- (BOOL)performWidgetAction:(NSString *)action value:(double)value {
    const BOOL accepted = [_model performImGuiMenuAction:action value:value];
    if (accepted) ++_widgetActionSerial;
    NSLog(@"Core-SET: ImGui action stage=widget action=%@ accepted=%d frame=%llu actionSerial=%llu",
          action, accepted, (unsigned long long)_frameSerial,
          (unsigned long long)_widgetActionSerial);
    return accepted;
}

- (void)drawItem:(NSDictionary *)item accent:(ImVec4)accent {
    NSString *type = CSString(item[@"type"]), *title = CSString(item[@"title"]);
    NSString *action = CSString(item[@"action"]);
    const BOOL enabled = item[@"enabled"] == nil || [item[@"enabled"] boolValue];
    ImGui::PushID(action.UTF8String);
    if (!enabled) ImGui::BeginDisabled();
    if ([type isEqualToString:@"toggle"]) {
        bool selected = [item[@"value"] boolValue];
        const ImVec2 start = ImGui::GetCursorScreenPos();
        const float width = ImGui::GetContentRegionAvail().x;
        ImGui::InvisibleButton("##toggle", ImVec2(width, 28));
        ImDrawList *draw = ImGui::GetWindowDrawList();
        const ImVec2 textSize = ImGui::CalcTextSize(title.UTF8String);
        draw->AddText(ImVec2(start.x, start.y + (28 - textSize.y) * .5f),
                      ImGui::GetColorU32(ImGuiCol_Text), title.UTF8String);
        const ImVec2 low(start.x + width - 41, start.y + 3.5f), high(low.x + 21, low.y + 21);
        const ImU32 border = ImGui::GetColorU32(ImGui::IsItemHovered() ? accent :
            ImGui::GetStyleColorVec4(ImGuiCol_Border));
        draw->AddRect(low, high, border, 3.0f, ImDrawFlags_None, 1.5f);
        if (selected) {
            draw->AddRectFilled(low, high, ImGui::GetColorU32(accent), 3);
            draw->AddLine(ImVec2(low.x + 5, low.y + 11), ImVec2(low.x + 9, low.y + 15),
                          IM_COL32(255,255,255,255), 2);
            draw->AddLine(ImVec2(low.x + 9, low.y + 15), ImVec2(low.x + 17, low.y + 6),
                          IM_COL32(255,255,255,255), 2);
        }
        if (ImGui::IsItemClicked(ImGuiMouseButton_Left) && enabled)
            [self performWidgetAction:action value:selected ? 0 : 1];
    } else if ([type isEqualToString:@"slider"]) {
        int value = [item[@"value"] intValue];
        const int minimum = [item[@"minimum"] intValue], maximum = [item[@"maximum"] intValue];
        const float rowY = ImGui::GetCursorPosY(), width = ImGui::GetContentRegionAvail().x;
        ImGui::TextUnformatted(title.UTF8String);
        ImGui::SetCursorPos(ImVec2(ImGui::GetCursorPosX() + width * .43f, rowY));
        ImGui::SetNextItemWidth(width * .57f);
        NSString *label = [NSString stringWithFormat:@"##%@", action];
        // Core c9158 forwards the configuration pointer to scalar behavior;
        // publish its changed value each frame, including during a drag.
        if (ImGui::SliderInt(label.UTF8String, &value, minimum, maximum) && enabled)
            [self performWidgetAction:action value:value];
        ImGui::SetCursorPosY(rowY + 29);
    } else if ([type isEqualToString:@"tabs"]) {
        NSArray *options = [item[@"options"] isKindOfClass:NSArray.class] ? item[@"options"] : @[];
        const NSInteger selected = [item[@"value"] integerValue];
        const float rowY = ImGui::GetCursorPosY(), rowX = ImGui::GetCursorPosX();
        for (NSUInteger index = 0; index < options.count; ++index) {
            if (index == 6) ImGui::SetCursorPos(ImVec2(rowX, rowY + 34));
            else if (index) ImGui::SameLine(0,6);
            NSString *option = CSString(options[index]);
            const float width = ImGui::CalcTextSize(option.UTF8String).x + 24;
            if ((NSInteger)index == selected) ImGui::PushStyleColor(ImGuiCol_Button, accent);
            NSString *label = [NSString stringWithFormat:@"%@##%@.%lu", option, action, (unsigned long)index];
            if (ImGui::Button(label.UTF8String, ImVec2(width, 28)) && enabled)
                [self performWidgetAction:action value:index];
            if ((NSInteger)index == selected) ImGui::PopStyleColor();
        }
        ImGui::SetCursorPosY(rowY + 68);
    } else if ([type isEqualToString:@"choice"]) {
        NSArray *options = [item[@"options"] isKindOfClass:NSArray.class] ? item[@"options"] : @[];
        const NSInteger selected = [item[@"value"] integerValue];
        const float rowY = ImGui::GetCursorPosY(), width = ImGui::GetContentRegionAvail().x;
        float optionWidth = 46;
        if ([action isEqualToString:@"aim.point"] || [action isEqualToString:@"aim.scene"]) optionWidth = 60;
        else if ([action isEqualToString:@"aim.lockStrength"]) optionWidth = 54;
        const float total = optionWidth * options.count + 6 * MAX(0, (NSInteger)options.count - 1);
        if (width - total - 20 >= ImGui::CalcTextSize(title.UTF8String).x)
            ImGui::TextUnformatted(title.UTF8String);
        ImGui::SetCursorPos(ImVec2(ImGui::GetCursorPosX() + MAX(0.0f, width - total - 20), rowY));
        for (NSUInteger index = 0; index < options.count; ++index) {
            if (index) ImGui::SameLine(0, 6);
            NSString *option = CSString(options[index]);
            if ((NSInteger)index == selected) ImGui::PushStyleColor(ImGuiCol_Button, accent);
            NSString *label = [NSString stringWithFormat:@"%@##%@.%lu", option, action, (unsigned long)index];
            if (ImGui::Button(label.UTF8String, ImVec2(optionWidth, 22)) && enabled)
                [self performWidgetAction:action value:(double)index];
            if ((NSInteger)index == selected) ImGui::PopStyleColor();
        }
        ImGui::SetCursorPosY(rowY + 29);
    } else if ([type isEqualToString:@"palette"]) {
        static const ImVec4 colors[] = {
            ImVec4(174/255.f,139/255.f,148/255.f,1), ImVec4(180/255.f,85/255.f,94/255.f,1),
            ImVec4(68/255.f,119/255.f,168/255.f,1), ImVec4(58/255.f,133/255.f,120/255.f,1),
            ImVec4(126/255.f,98/255.f,171/255.f,1), ImVec4(181/255.f,86/255.f,137/255.f,1),
            ImVec4(56/255.f,139/255.f,155/255.f,1)
        };
        const NSInteger selected = [item[@"value"] integerValue];
        const float rowY = ImGui::GetCursorPosY();
        ImGui::TextUnformatted(title.UTF8String);
        ImGui::SetCursorPos(ImVec2(90, rowY));
        for (NSInteger index = 0; index < 7; ++index) {
            if (index) ImGui::SameLine(0, 7);
            ImGui::PushStyleColor(ImGuiCol_Button, colors[index]);
            ImGui::PushStyleColor(ImGuiCol_ButtonHovered, colors[index]);
            ImGui::PushStyleColor(ImGuiCol_ButtonActive, colors[index]);
            NSString *label = [NSString stringWithFormat:@"##%@.%ld", action, (long)index];
            if (ImGui::Button(label.UTF8String, ImVec2(24,24)) && enabled)
                [self performWidgetAction:action value:index];
            if (index == selected) {
                ImDrawList *draw = ImGui::GetWindowDrawList();
                const ImVec2 low = ImGui::GetItemRectMin(), high = ImGui::GetItemRectMax();
                draw->AddRect(ImVec2(low.x - 2, low.y - 2), ImVec2(high.x + 2, high.y + 2),
                              ImGui::GetColorU32(ImGuiCol_Text), 6.0f, ImDrawFlags_None, 2.0f);
            }
            ImGui::PopStyleColor(3);
        }
        ImGui::SetCursorPosY(rowY + 31);
    } else if ([type isEqualToString:@"tagGrid"]) {
        NSArray *titles = [item[@"titles"] isKindOfClass:NSArray.class] ? item[@"titles"] : @[];
        NSArray *values = [item[@"values"] isKindOfClass:NSArray.class] ? item[@"values"] : @[];
        float rowY = ImGui::GetCursorPosY(), rowX = ImGui::GetCursorPosX();
        const float right = rowX + ImGui::GetContentRegionAvail().x - 18;
        for (NSUInteger index = 0; index < titles.count; ++index) {
            NSString *name = CSString(titles[index]);
            const float width = ImGui::CalcTextSize(name.UTF8String).x + 24;
            if (ImGui::GetCursorPosX() + width > right && index) {
                rowY += 32; ImGui::SetCursorPos(ImVec2(rowX, rowY));
            } else if (index) ImGui::SameLine(0,6);
            const BOOL selected = index < values.count && [values[index] boolValue];
            if (selected) ImGui::PushStyleColor(ImGuiCol_Button, accent);
            NSString *label = [NSString stringWithFormat:@"%@##material.group.%lu", name, (unsigned long)index];
            if (ImGui::Button(label.UTF8String, ImVec2(width, 26)) && enabled)
                [self performWidgetAction:[NSString stringWithFormat:@"material.group.%lu", (unsigned long)index]
                                     value:selected ? 0 : 1];
            if (selected) ImGui::PopStyleColor();
        }
        ImGui::SetCursorPosY(rowY + 32);
    } else if ([type isEqualToString:@"status"]) {
        NSString *value = CSString(item[@"text"]);
        ImGui::TextWrapped("%s: %s", title.UTF8String, value.UTF8String);
    } else if ([type isEqualToString:@"label"]) {
        ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(.58f,.58f,.58f,1));
        ImGui::TextUnformatted(title.UTF8String); ImGui::PopStyleColor();
    } else {
        const float startX = ImGui::GetCursorPosX();
        ImGui::SetCursorPosX(startX + 20);
        if (ImGui::Button(title.UTF8String, ImVec2(ImGui::GetContentRegionAvail().x - 20, 30)) && enabled)
            [self performWidgetAction:action value:[item[@"value"] doubleValue]];
    }
    if (!enabled) ImGui::EndDisabled();
    ImGui::PopID();
}

- (void)drawMenu:(NSDictionary *)snapshot {
    NSArray *pages = [snapshot[@"pages"] isKindOfClass:NSArray.class] ? snapshot[@"pages"] : @[];
    NSInteger selected = [snapshot[@"selectedPage"] integerValue];
    if (selected < 0 || selected >= (NSInteger)pages.count) selected = 0;
    const ImVec4 accent = CSColor(snapshot[@"accent"], ImVec4(.22f,.55f,.61f,1));
    const BOOL light = [CSString(snapshot[@"theme"]) isEqualToString:@"light"];
    ImGuiStyle &style = ImGui::GetStyle();
    style.WindowRounding = 12; style.ChildRounding = 8; style.FrameRounding = 5;
    style.WindowPadding = ImVec2(0,0); style.ItemSpacing = ImVec2(8,6);
    style.FramePadding = ImVec2(7,3); style.ScrollbarSize = 8;
    style.Colors[ImGuiCol_WindowBg] = light ? ImVec4(.96f,.96f,.96f,.98f) : ImVec4(.10f,.10f,.10f,.98f);
    style.Colors[ImGuiCol_ChildBg] = light ? ImVec4(.91f,.91f,.91f,1) : ImVec4(.14f,.14f,.14f,1);
    style.Colors[ImGuiCol_Text] = light ? ImVec4(.20f,.20f,.20f,1) : ImVec4(1,1,1,1);
    style.Colors[ImGuiCol_Button] = light ? ImVec4(.82f,.82f,.82f,1) : ImVec4(.20f,.20f,.20f,1);
    style.Colors[ImGuiCol_ButtonHovered] = accent; style.Colors[ImGuiCol_ButtonActive] = accent;
    style.Colors[ImGuiCol_CheckMark] = accent; style.Colors[ImGuiCol_SliderGrab] = accent;
    style.Colors[ImGuiCol_Border] = light ? ImVec4(.76f,.76f,.76f,1) : ImVec4(.30f,.30f,.30f,1);
    ImGui::SetNextWindowPos(ImVec2(0,0)); ImGui::SetNextWindowSize(ImVec2(838,535));
    ImGui::Begin("Dear Core", nullptr, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove |
        ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoBringToFrontOnFocus);
    ImDrawList *rootDraw = ImGui::GetWindowDrawList();
    const ImVec2 root = ImGui::GetWindowPos();
    rootDraw->AddRectFilled(root, ImVec2(root.x + 160, root.y + 535),
        ImGui::GetColorU32(light ? ImVec4(.90f,.90f,.90f,1) : ImVec4(.12f,.12f,.12f,1)), 12,
        ImDrawFlags_RoundCornersLeft);
    ImGui::SetCursorPos(ImVec2(18, 24));
    ImGui::PushFont(_brandFont);
    ImGui::PushStyleColor(ImGuiCol_Text, accent); ImGui::TextUnformatted("C"); ImGui::PopStyleColor();
    ImGui::SameLine(0,0); ImGui::TextUnformatted("ORE");
    ImGui::SameLine(5,0); ImGui::PushStyleColor(ImGuiCol_Text, accent);
    ImGui::TextUnformatted("SET"); ImGui::PopStyleColor(); ImGui::PopFont();
    const char *groups[] = {"初始化", "视觉", "战斗"};
    const int groupStarts[] = {0, 1, 5};
    const int groupEnds[] = {1, 5, 7};
    float navY = 82;
    for (int group = 0; group < 3; ++group) {
        ImGui::SetCursorPos(ImVec2(18, navY));
        ImGui::PushStyleColor(ImGuiCol_Text, light ? ImVec4(.42f,.42f,.42f,1) : ImVec4(.55f,.55f,.55f,1));
        ImGui::TextUnformatted(groups[group]); ImGui::PopStyleColor(); navY += 22;
        for (int index = groupStarts[group]; index < groupEnds[group] && index < (int)pages.count; ++index) {
            NSDictionary *pageRecord = [pages[index] isKindOfClass:NSDictionary.class] ? pages[index] : @{};
            NSString *title = CSString(pageRecord[@"title"]);
            ImGui::SetCursorPos(ImVec2(14, navY));
            if (index == selected) ImGui::PushStyleColor(ImGuiCol_Button, accent);
            NSString *label = [NSString stringWithFormat:@"%@##page.%d", title, index];
            if (ImGui::Button(label.UTF8String, ImVec2(132, 32)))
                [self performWidgetAction:@"page" value:index];
            if (index == selected) ImGui::PopStyleColor();
            navY += 35;
        }
        navY += 8;
    }
    ImGui::SetCursorPos(ImVec2(798, 6));
    if (ImGui::Button("×##close", ImVec2(32, 26))) [self performWidgetAction:@"close" value:0];
    NSDictionary *page = pages.count ? pages[selected] : @{};
    NSArray *sections = [page[@"sections"] isKindOfClass:NSArray.class] ? page[@"sections"] : @[];
    ImGui::SetCursorPos(ImVec2(170,38));
    ImGui::BeginChild("content", ImVec2(668, 497), false, ImGuiWindowFlags_AlwaysVerticalScrollbar);
    float maximumY = 0;
    for (NSDictionary *section in sections) {
        NSArray *frame = [section[@"frame"] isKindOfClass:NSArray.class] ? section[@"frame"] : @[];
        if (frame.count != 4) continue;
        const float x = [frame[0] floatValue], y = [frame[1] floatValue];
        const float width = [frame[2] floatValue], height = [frame[3] floatValue];
        maximumY = MAX(maximumY, y + height);
        NSString *title = CSString(section[@"title"]);
        NSArray *items = [section[@"items"] isKindOfClass:NSArray.class] ? section[@"items"] : @[];
        const NSInteger columns = MAX(1, [section[@"columns"] integerValue]);
        ImGui::SetCursorPos(ImVec2(x, y));
        ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(10,8));
        ImGui::BeginChild([[NSString stringWithFormat:@"section.%@", title] UTF8String],
                          ImVec2(width, height), ImGuiChildFlags_Borders);
        ImGui::PushFont(_titleFont); ImGui::PushStyleColor(ImGuiCol_Text, accent);
        ImGui::TextUnformatted(title.UTF8String); ImGui::PopStyleColor(); ImGui::PopFont();
        ImGui::SetCursorPosY(34);
        if (columns == 1) {
            for (NSDictionary *item in items) [self drawItem:item accent:accent];
            // drawItem uses absolute cursor placement for Core's fixed rows.
            // Submit an item at the final cursor before EndChild so ImGui 1.92
            // does not treat SetCursorPos as an unsupported bounds extension.
            ImGui::Dummy(ImVec2(0,0));
        } else {
            const float cellWidth = (ImGui::GetContentRegionAvail().x - (columns - 1) * 8) / columns;
            for (NSUInteger index = 0; index < items.count; ++index) {
                if (index % columns) ImGui::SameLine(0,8);
                ImGui::BeginChild([[NSString stringWithFormat:@"cell.%lu", (unsigned long)index] UTF8String],
                                  ImVec2(cellWidth, 28), ImGuiChildFlags_None);
                [self drawItem:items[index] accent:accent];
                ImGui::Dummy(ImVec2(0,0));
                ImGui::EndChild();
            }
            ImGui::Dummy(ImVec2(0,0));
        }
        ImGui::EndChild(); ImGui::PopStyleVar();
    }
    ImGui::SetCursorPos(ImVec2(0, maximumY + 1)); ImGui::Dummy(ImVec2(1,1));
    ImGui::EndChild(); ImGui::End();
}

- (void)drawInMTKView:(MTKView *)view {
    if (!_imgui || !_queue || !view.currentRenderPassDescriptor || !view.currentDrawable) return;
    ImGui::SetCurrentContext(_imgui);
    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize = ImVec2((float)view.bounds.size.width, (float)view.bounds.size.height);
    io.DisplayFramebufferScale = ImVec2((float)(view.drawableSize.width/MAX(1.0,view.bounds.size.width)),
                                         (float)(view.drawableSize.height/MAX(1.0,view.bounds.size.height)));
    ImGui_ImplMetal_NewFrame(view.currentRenderPassDescriptor); ImGui::NewFrame();
    const uint64_t revision = _model.imguiMenuModelRevision;
    if (!_snapshot || revision != _renderedRevision) {
        _snapshot = [[_model imguiMenuSnapshot] copy] ?: @{};
        _renderedRevision = revision;
    }
    ImGui::PushFont(_bodyFont); [self drawMenu:_snapshot]; ImGui::PopFont();
    ImGui::Render();
    id<MTLCommandBuffer> buffer = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:view.currentRenderPassDescriptor];
    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), buffer, encoder);
    [encoder endEncoding]; [buffer presentDrawable:view.currentDrawable]; [buffer commit];
    ++_frameSerial;
}
- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}

- (uint64_t)hostedMenuRevision { return _pointer.layoutRevision(); }
- (NSString *)hostedControlIDAtPoint:(CGPoint)point {
    // The host captures one surface pointer. Widget hit testing and disabled
    // controls are resolved by ImGui, never by a second semantic action map.
    return _imgui && CGRectContainsPoint(self.view.bounds, point) ? @"imgui.pointer" : nil;
}
- (BOOL)hostedControlAllowsDrag:(NSString *)identifier {
    return [identifier isEqualToString:@"imgui.pointer"];
}
- (BOOL)handleHostedControlID:(NSString *)identifier phase:(CoreSetHostedPointerPhase)phase atPoint:(CGPoint)point {
    if (!_imgui || ![identifier isEqualToString:@"imgui.pointer"]) return NO;
    ImGui::SetCurrentContext(_imgui);
    ImGuiIO &io = ImGui::GetIO();
    if (phase == CoreSetHostedPointerPhaseCancelled) {
        _pointer.cancel(io);
        return YES;
    }
    BOOL queued = NO;
    if (phase == CoreSetHostedPointerPhaseBegan)
        queued = _pointer.begin(io, (float)point.x, (float)point.y);
    else if (phase == CoreSetHostedPointerPhaseMoved)
        queued = _pointer.move(io, (float)point.x, (float)point.y);
    else if (phase == CoreSetHostedPointerPhaseEnded)
        queued = _pointer.end(io, (float)point.x, (float)point.y);
    if (!queued || !_metalView) return NO;
    const uint64_t beforeFrame = _frameSerial;
    const uint64_t beforeAction = _widgetActionSerial;
    // A hosted source keeps its last pixels while the owner app is backgrounded,
    // but CADisplayLink may tick seconds late. Drive the exact ImGui context now
    // so Down/Move/Up and widget behavior share a deterministic frame sequence.
    [_metalView draw];
    const BOOL rendered = _frameSerial > beforeFrame;
    const BOOL actionChanged = _widgetActionSerial > beforeAction;
    BOOL refreshed = !actionChanged;
    // The changed widget publishes a new immutable model revision during the
    // first frame. Render that revision immediately as well; otherwise a
    // backgrounded CADisplayLink could leave the old page/value visible.
    if (rendered && actionChanged) {
        const uint64_t actionFrame = _frameSerial;
        [_metalView draw];
        refreshed = _frameSerial > actionFrame;
    }
    NSLog(@"Core-SET: ImGui input stage=frame phase=%ld queued=1 rendered=%d refreshed=%d frame=%llu actionChanged=%d actionSerial=%llu",
          (long)phase, rendered, refreshed, (unsigned long long)_frameSerial, actionChanged,
          (unsigned long long)_widgetActionSerial);
    if (!rendered) {
        _pointer.cancel(io);
        return NO;
    }
    return YES;
}
- (BOOL)dispatchLocalPoint:(CGPoint)point phase:(CoreSetHostedPointerPhase)phase {
    NSString *identifier = _pointer.down() ? @"imgui.pointer" : [self hostedControlIDAtPoint:point];
    return identifier ? [self handleHostedControlID:identifier phase:phase atPoint:point] : NO;
}
@end
