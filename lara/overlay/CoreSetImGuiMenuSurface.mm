#import "CoreSetImGuiMenuSurface.h"
#import <MetalKit/MetalKit.h>
#include "../third_party/imgui/imgui.h"
#include "../third_party/imgui/backends/imgui_impl_metal.h"
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
    NSArray<NSDictionary *> *_hits;
    NSString *_activeControl;
    uint64_t _renderedRevision;
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
        self.view.alpha > 0.01 && self.view.superview.alpha > 0.01) [_metalView draw];
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
    else { [_displayLink invalidate]; _displayLink = nil; }
}

- (void)addHit:(NSMutableArray<NSDictionary *> *)hits action:(NSString *)action
          type:(NSString *)type value:(double)value minimum:(double)minimum maximum:(double)maximum {
    if (!action.length) return;
    const ImVec2 low = ImGui::GetItemRectMin(), high = ImGui::GetItemRectMax();
    if (!(high.x > low.x && high.y > low.y)) return;
    [hits addObject:@{@"id": [NSString stringWithFormat:@"%@.%lu", action, (unsigned long)hits.count],
                      @"action": action, @"type": type ?: @"button", @"value": @(value),
                      @"minimum": @(minimum), @"maximum": @(maximum),
                      @"x": @(low.x), @"y": @(low.y), @"w": @(high.x-low.x), @"h": @(high.y-low.y)}];
}

- (void)drawItem:(NSDictionary *)item hits:(NSMutableArray<NSDictionary *> *)hits {
    NSString *type = CSString(item[@"type"]), *title = CSString(item[@"title"]);
    NSString *action = CSString(item[@"action"]);
    const BOOL enabled = item[@"enabled"] == nil || [item[@"enabled"] boolValue];
    if (!enabled) ImGui::BeginDisabled();
    if ([type isEqualToString:@"toggle"]) {
        bool selected = [item[@"value"] boolValue];
        ImGui::Checkbox(title.UTF8String, &selected);
        [self addHit:hits action:action type:type value:selected ? 0 : 1 minimum:0 maximum:1];
    } else if ([type isEqualToString:@"slider"]) {
        float value = [item[@"value"] floatValue];
        const float minimum = [item[@"minimum"] floatValue], maximum = [item[@"maximum"] floatValue];
        ImGui::SetNextItemWidth(-1);
        ImGui::SliderFloat(title.UTF8String, &value, minimum, maximum, "%.0f");
        [self addHit:hits action:action type:type value:value minimum:minimum maximum:maximum];
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
            ImGui::Button(label.UTF8String);
            [self addHit:hits action:action type:@"button" value:(double)index minimum:0 maximum:options.count-1];
            if ((NSInteger)index == selected) ImGui::PopStyleColor();
        }
    } else if ([type isEqualToString:@"status"]) {
        NSString *value = CSString(item[@"text"]);
        ImGui::TextWrapped("%s  %s", title.UTF8String, value.UTF8String);
    } else {
        ImGui::Button(title.UTF8String, ImVec2(-1, 30));
        [self addHit:hits action:action type:@"button" value:[item[@"value"] doubleValue] minimum:0 maximum:0];
    }
    if (!enabled) ImGui::EndDisabled();
}

- (void)drawMenu:(NSDictionary *)snapshot {
    NSMutableArray<NSDictionary *> *hits = [NSMutableArray array];
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
        ImGui::Button(label.UTF8String, ImVec2(132, 35));
        [self addHit:hits action:@"page" type:@"button" value:(double)index minimum:0 maximum:pages.count-1];
        if ((NSInteger)index == selected) ImGui::PopStyleColor();
    }
    ImGui::SetCursorPosY(ImGui::GetWindowHeight() - 48);
    ImGui::Button("退出 HUD", ImVec2(132, 34));
    [self addHit:hits action:@"exit" type:@"button" value:0 minimum:0 maximum:0];
    ImGui::EndChild();
    ImGui::SameLine();
    ImGui::BeginChild("content", ImVec2(0,0), false, ImGuiWindowFlags_AlwaysVerticalScrollbar);
    ImGui::SetCursorPos(ImVec2(10, 8));
    ImGui::Button("关闭##close", ImVec2(74, 28));
    [self addHit:hits action:@"close" type:@"button" value:0 minimum:0 maximum:0];
    NSDictionary *page = pages.count ? pages[selected] : @{};
    NSArray *sections = [page[@"sections"] isKindOfClass:NSArray.class] ? page[@"sections"] : @[];
    for (NSDictionary *section in sections) {
        NSString *title = CSString(section[@"title"]);
        ImGui::PushStyleColor(ImGuiCol_Text, accent); ImGui::TextUnformatted(title.UTF8String); ImGui::PopStyleColor();
        NSArray *items = [section[@"items"] isKindOfClass:NSArray.class] ? section[@"items"] : @[];
        const float sectionHeight = std::max(58.0f, 34.0f + (float)items.count * 42.0f);
        ImGui::BeginChild([[NSString stringWithFormat:@"section.%@", title] UTF8String],
                          ImVec2(-1, sectionHeight), ImGuiChildFlags_Borders);
        for (NSDictionary *item in items) [self drawItem:item hits:hits];
        ImGui::EndChild(); ImGui::Spacing();
    }
    ImGui::EndChild(); ImGui::End();
    _hits = [hits copy];
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

- (uint64_t)hostedMenuRevision { return _renderedRevision; }
- (NSDictionary *)hitForIdentifier:(NSString *)identifier {
    for (NSDictionary *hit in _hits) if ([hit[@"id"] isEqualToString:identifier]) return hit;
    return nil;
}
- (NSString *)hostedControlIDAtPoint:(CGPoint)point {
    for (NSDictionary *hit in [_hits reverseObjectEnumerator]) {
        CGRect rect = CGRectMake([hit[@"x"] doubleValue], [hit[@"y"] doubleValue],
                                 [hit[@"w"] doubleValue], [hit[@"h"] doubleValue]);
        if (CGRectContainsPoint(rect, point)) return hit[@"id"];
    }
    return nil;
}
- (BOOL)hostedControlAllowsDrag:(NSString *)identifier {
    return [[[self hitForIdentifier:identifier] objectForKey:@"type"] isEqualToString:@"slider"];
}
- (BOOL)handleHostedControlID:(NSString *)identifier phase:(CoreSetHostedPointerPhase)phase atPoint:(CGPoint)point {
    NSDictionary *hit = [self hitForIdentifier:identifier];
    if (!hit || !_model || _model.imguiMenuModelRevision != _renderedRevision) return NO;
    if (phase == CoreSetHostedPointerPhaseCancelled) { _activeControl = nil; return YES; }
    if (phase == CoreSetHostedPointerPhaseBegan) { _activeControl = identifier; return YES; }
    if (![_activeControl isEqualToString:identifier]) return NO;
    NSString *type = hit[@"type"];
    // Commit sliders once on End. Rebuilding the immutable model on every Move
    // would advance hostedMenuRevision and cancel the same physical pointer.
    if (phase == CoreSetHostedPointerPhaseMoved) return YES;
    if (phase != CoreSetHostedPointerPhaseEnded) return YES;
    double value = [hit[@"value"] doubleValue];
    if ([type isEqualToString:@"slider"]) {
        const double width = MAX(1.0, [hit[@"w"] doubleValue]);
        const double ratio = std::clamp((point.x - [hit[@"x"] doubleValue]) / width, 0.0, 1.0);
        value = [hit[@"minimum"] doubleValue] + ratio * ([hit[@"maximum"] doubleValue] - [hit[@"minimum"] doubleValue]);
    }
    BOOL handled = [_model performImGuiMenuAction:hit[@"action"] value:value];
    if (phase == CoreSetHostedPointerPhaseEnded) _activeControl = nil;
    return handled;
}
- (BOOL)dispatchLocalPoint:(CGPoint)point phase:(CoreSetHostedPointerPhase)phase {
    NSString *identifier = _activeControl ?: [self hostedControlIDAtPoint:point];
    return identifier ? [self handleHostedControlID:identifier phase:phase atPoint:point] : NO;
}
@end
