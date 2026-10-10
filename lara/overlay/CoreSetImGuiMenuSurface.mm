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
    CADisplayLink *_displayLink;
    NSDictionary *_snapshot;
    uint64_t _renderedRevision;
    CoreSet::ImGuiMenuPointer _pointer;
    CGRect _inputBounds;
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
    NSString *fontPath = [NSBundle.mainBundle pathForResource:@"OPPOSans-H" ofType:@"ttf"];
    if (fontPath.length)
        _bodyFont = io.Fonts->AddFontFromFileTTF(fontPath.UTF8String, 19.0f, nullptr,
                                                 io.Fonts->GetGlyphRangesChineseFull());
    if (!_bodyFont) _bodyFont = io.Fonts->AddFontDefault();
    if (!ImGui_ImplMetal_Init(_metalView.device)) {
        ImGui::DestroyContext(_imgui); _imgui = nullptr; return;
    }
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

- (void)drawItem:(NSDictionary *)item {
    NSString *type = CSString(item[@"type"]), *title = CSString(item[@"title"]);
    NSString *action = CSString(item[@"action"]);
    const BOOL enabled = item[@"enabled"] == nil || [item[@"enabled"] boolValue];
    ImGui::PushID(action.UTF8String);
    if (!enabled) ImGui::BeginDisabled();
    if ([type isEqualToString:@"toggle"]) {
        bool selected = [item[@"value"] boolValue];
        if (ImGui::Checkbox(title.UTF8String, &selected) && enabled)
            [_model performImGuiMenuAction:action value:selected ? 1 : 0];
    } else if ([type isEqualToString:@"slider"]) {
        int value = [item[@"value"] intValue];
        const int minimum = [item[@"minimum"] intValue], maximum = [item[@"maximum"] intValue];
        ImGui::SetNextItemWidth(-1);
        // Core c9158 forwards the configuration pointer to scalar behavior;
        // publish its changed value each frame, including during a drag.
        if (ImGui::SliderInt(title.UTF8String, &value, minimum, maximum) && enabled)
            [_model performImGuiMenuAction:action value:value];
    } else if ([type isEqualToString:@"choice"]) {
        NSArray *options = [item[@"options"] isKindOfClass:NSArray.class] ? item[@"options"] : @[];
        const NSInteger selected = [item[@"value"] integerValue];
        ImGui::TextUnformatted(title.UTF8String);
        for (NSUInteger index = 0; index < options.count; ++index) {
            if (index && index % 4 != 0) ImGui::SameLine();
            NSString *option = CSString(options[index]);
            if ((NSInteger)index == selected) {
                ImVec4 accent = CSColor(item[@"accent"], ImVec4(.22f,.55f,.61f,1));
                ImGui::PushStyleColor(ImGuiCol_Button, accent);
            }
            NSString *label = [NSString stringWithFormat:@"%@##%@.%lu", option, action, (unsigned long)index];
            if (ImGui::Button(label.UTF8String) && enabled)
                [_model performImGuiMenuAction:action value:(double)index];
            if ((NSInteger)index == selected) ImGui::PopStyleColor();
        }
    } else if ([type isEqualToString:@"status"]) {
        NSString *value = CSString(item[@"text"]);
        ImGui::TextWrapped("%s  %s", title.UTF8String, value.UTF8String);
    } else {
        if (ImGui::Button(title.UTF8String, ImVec2(-1, 30)) && enabled)
            [_model performImGuiMenuAction:action value:[item[@"value"] doubleValue]];
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
    style.WindowRounding = 12; style.ChildRounding = 7; style.FrameRounding = 5;
    style.WindowPadding = ImVec2(0,0); style.ItemSpacing = ImVec2(8,7);
    style.Colors[ImGuiCol_WindowBg] = light ? ImVec4(.96f,.96f,.96f,.98f) : ImVec4(.10f,.10f,.10f,.98f);
    style.Colors[ImGuiCol_ChildBg] = light ? ImVec4(.91f,.91f,.91f,1) : ImVec4(.14f,.14f,.14f,1);
    style.Colors[ImGuiCol_Text] = light ? ImVec4(.20f,.20f,.20f,1) : ImVec4(1,1,1,1);
    style.Colors[ImGuiCol_Button] = light ? ImVec4(.82f,.82f,.82f,1) : ImVec4(.20f,.20f,.20f,1);
    style.Colors[ImGuiCol_ButtonHovered] = accent; style.Colors[ImGuiCol_ButtonActive] = accent;
    style.Colors[ImGuiCol_CheckMark] = accent; style.Colors[ImGuiCol_SliderGrab] = accent;
    ImGui::SetNextWindowPos(ImVec2(0,0)); ImGui::SetNextWindowSize(ImGui::GetIO().DisplaySize);
    ImGui::Begin("Core-SET", nullptr, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove |
        ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoBringToFrontOnFocus);
    ImGui::BeginChild("sidebar", ImVec2(160, 0), true);
    ImGui::SetCursorPos(ImVec2(16, 28));
    ImGui::PushStyleColor(ImGuiCol_Text, accent);
    ImGui::TextUnformatted("CORE  SET"); ImGui::PopStyleColor();
    ImGui::Dummy(ImVec2(0, 22));
    for (NSUInteger index = 0; index < pages.count; ++index) {
        NSDictionary *pageRecord = [pages[index] isKindOfClass:NSDictionary.class] ? pages[index] : @{};
        NSString *title = CSString(pageRecord[@"title"]);
        if ((NSInteger)index == selected) ImGui::PushStyleColor(ImGuiCol_Button, accent);
        NSString *label = [NSString stringWithFormat:@"%@##page.%lu", title, (unsigned long)index];
        if (ImGui::Button(label.UTF8String, ImVec2(132, 35)))
            [_model performImGuiMenuAction:@"page" value:(double)index];
        if ((NSInteger)index == selected) ImGui::PopStyleColor();
    }
    ImGui::SetCursorPosY(ImGui::GetWindowHeight() - 48);
    if (ImGui::Button("退出 HUD", ImVec2(132, 34)))
        [_model performImGuiMenuAction:@"exit" value:0];
    ImGui::EndChild();
    ImGui::SameLine();
    ImGui::BeginChild("content", ImVec2(0,0), false, ImGuiWindowFlags_AlwaysVerticalScrollbar);
    ImGui::SetCursorPos(ImVec2(10, 8));
    if (ImGui::Button("关闭##close", ImVec2(74, 28)))
        [_model performImGuiMenuAction:@"close" value:0];
    NSDictionary *page = pages.count ? pages[selected] : @{};
    NSArray *sections = [page[@"sections"] isKindOfClass:NSArray.class] ? page[@"sections"] : @[];
    for (NSDictionary *section in sections) {
        NSString *title = CSString(section[@"title"]);
        ImGui::PushStyleColor(ImGuiCol_Text, accent); ImGui::TextUnformatted(title.UTF8String); ImGui::PopStyleColor();
        NSArray *items = [section[@"items"] isKindOfClass:NSArray.class] ? section[@"items"] : @[];
        const float sectionHeight = std::max(58.0f, 34.0f + (float)items.count * 42.0f);
        ImGui::BeginChild([[NSString stringWithFormat:@"section.%@", title] UTF8String],
                          ImVec2(-1, sectionHeight), ImGuiChildFlags_Borders);
        for (NSDictionary *item in items) [self drawItem:item];
        ImGui::EndChild(); ImGui::Spacing();
    }
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
    if (phase == CoreSetHostedPointerPhaseBegan)
        return _pointer.begin(io, (float)point.x, (float)point.y);
    if (phase == CoreSetHostedPointerPhaseMoved)
        return _pointer.move(io, (float)point.x, (float)point.y);
    if (phase == CoreSetHostedPointerPhaseEnded)
        return _pointer.end(io, (float)point.x, (float)point.y);
    return NO;
}
- (BOOL)dispatchLocalPoint:(CGPoint)point phase:(CoreSetHostedPointerPhase)phase {
    NSString *identifier = _pointer.down() ? @"imgui.pointer" : [self hostedControlIDAtPoint:point];
    return identifier ? [self handleHostedControlID:identifier phase:phase atPoint:point] : NO;
}
@end
