#import "CoreSetImGuiMenuSurface.h"
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <objc/message.h>
#include "../third_party/imgui/imgui.h"
#include "../third_party/imgui/backends/imgui_impl_metal.h"
#include "CoreSetImGuiMenuPointer.h"
#include <algorithm>
#include <cstdint>
#include <cmath>
#include <vector>

@class CoreSetImGuiMenuViewController;

typedef struct CoreSetImGuiFrameResult {
    BOOL processed;
    BOOL presentScheduled;
    BOOL retainedScheduled;
} CoreSetImGuiFrameResult;

@interface CoreSetImGuiTouchView : UIView
@property(nonatomic, weak) CoreSetImGuiMenuViewController *menuOwner;
@property(nonatomic, readonly) CAMetalLayer *metalLayer;
@end

@interface CoreSetImGuiMenuViewController ()
- (BOOL)dispatchLocalPoint:(CGPoint)point phase:(CoreSetHostedPointerPhase)phase;
- (void)updateDrawableGeometry;
- (CoreSetImGuiFrameResult)renderFrameAttemptPresentation:(BOOL)attemptPresentation;
- (BOOL)renderSoftwareRetainedPresentation;
- (void)schedulePresentation;
@end

static void CSEnableHostedLayerUpdates(CALayer *layer) {
    if (!layer) return;
    SEL selector = NSSelectorFromString(@"setDisableUpdateMask:");
    if ([layer respondsToSelector:selector])
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(layer, selector, 0);
}

@implementation CoreSetImGuiTouchView
+ (Class)layerClass { return CAMetalLayer.class; }
- (CAMetalLayer *)metalLayer { return (CAMetalLayer *)self.layer; }
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

// CPU renderer for the single Dear ImGui font-atlas texture used by this menu.
// Adapted from emilk/imgui_software_renderer (public domain/perpetual license),
// with ImGui 1.92 offsets and premultiplied RGBA output for CoreGraphics.
struct CSSoftwarePoint { float x, y; };
static float CSEdge(CSSoftwarePoint a, CSSoftwarePoint b, CSSoftwarePoint p) {
    return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x);
}
static uint8_t CSByte(float value) {
    return (uint8_t)std::clamp((int)std::lround(value * 255.0f), 0, 255);
}
static void CSBlendSoftwarePixel(uint32_t &destination, float red, float green,
                                 float blue, float alpha) {
    alpha = std::clamp(alpha, 0.0f, 1.0f);
    const float keep = 1.0f - alpha;
    const float dr = (destination & 0xff) / 255.0f;
    const float dg = ((destination >> 8) & 0xff) / 255.0f;
    const float db = ((destination >> 16) & 0xff) / 255.0f;
    const float da = ((destination >> 24) & 0xff) / 255.0f;
    const float outA = alpha + da * keep;
    const uint32_t r = CSByte(red * alpha + dr * keep);
    const uint32_t g = CSByte(green * alpha + dg * keep);
    const uint32_t b = CSByte(blue * alpha + db * keep);
    const uint32_t a = CSByte(outA);
    destination = r | (g << 8) | (b << 16) | (a << 24);
}
static BOOL CSRasterizeImGui(ImDrawData *drawData, const uint8_t *atlas,
                             int atlasWidth, int atlasHeight,
                             uint32_t *pixels, int width, int height) {
    if (!drawData || !drawData->Valid || !atlas || atlasWidth <= 0 || atlasHeight <= 0 ||
        !pixels || width <= 0 || height <= 0 || drawData->DisplaySize.x <= 0 ||
        drawData->DisplaySize.y <= 0) return NO;
    const float scaleX = width / drawData->DisplaySize.x;
    const float scaleY = height / drawData->DisplaySize.y;
    const ImVec2 origin = drawData->DisplayPos;
    for (int listIndex = 0; listIndex < drawData->CmdListsCount; ++listIndex) {
        const ImDrawList *list = drawData->CmdLists[listIndex];
        if (!list) continue;
        for (const ImDrawCmd &command : list->CmdBuffer) {
            if (command.UserCallback || command.ElemCount < 3) continue;
            if ((size_t)command.IdxOffset + (size_t)command.ElemCount >
                (size_t)list->IdxBuffer.Size) return NO;
            const int clipMinX = std::clamp((int)std::floor(
                (command.ClipRect.x - origin.x) * scaleX), 0, width);
            const int clipMinY = std::clamp((int)std::floor(
                (command.ClipRect.y - origin.y) * scaleY), 0, height);
            const int clipMaxX = std::clamp((int)std::ceil(
                (command.ClipRect.z - origin.x) * scaleX), 0, width);
            const int clipMaxY = std::clamp((int)std::ceil(
                (command.ClipRect.w - origin.y) * scaleY), 0, height);
            if (clipMinX >= clipMaxX || clipMinY >= clipMaxY) continue;
            const ImDrawIdx *indices = list->IdxBuffer.Data + command.IdxOffset;
            for (unsigned int element = 0; element + 2 < command.ElemCount; element += 3) {
                const size_t i0 = (size_t)command.VtxOffset + indices[element];
                const size_t i1 = (size_t)command.VtxOffset + indices[element + 1];
                const size_t i2 = (size_t)command.VtxOffset + indices[element + 2];
                if (i0 >= (size_t)list->VtxBuffer.Size ||
                    i1 >= (size_t)list->VtxBuffer.Size ||
                    i2 >= (size_t)list->VtxBuffer.Size) return NO;
                const ImDrawVert &v0 = list->VtxBuffer[(int)i0];
                const ImDrawVert &v1 = list->VtxBuffer[(int)i1];
                const ImDrawVert &v2 = list->VtxBuffer[(int)i2];
                const CSSoftwarePoint p0{(v0.pos.x - origin.x) * scaleX,
                                         (v0.pos.y - origin.y) * scaleY};
                const CSSoftwarePoint p1{(v1.pos.x - origin.x) * scaleX,
                                         (v1.pos.y - origin.y) * scaleY};
                const CSSoftwarePoint p2{(v2.pos.x - origin.x) * scaleX,
                                         (v2.pos.y - origin.y) * scaleY};
                if (!std::isfinite(p0.x) || !std::isfinite(p0.y) ||
                    !std::isfinite(p1.x) || !std::isfinite(p1.y) ||
                    !std::isfinite(p2.x) || !std::isfinite(p2.y)) return NO;
                const float area = CSEdge(p0, p1, p2);
                if (!std::isfinite(area) || std::fabs(area) < 0.0001f) continue;
                const int minX = std::max(clipMinX, (int)std::floor(
                    std::min({p0.x, p1.x, p2.x})));
                const int minY = std::max(clipMinY, (int)std::floor(
                    std::min({p0.y, p1.y, p2.y})));
                const int maxX = std::min(clipMaxX, (int)std::ceil(
                    std::max({p0.x, p1.x, p2.x})));
                const int maxY = std::min(clipMaxY, (int)std::ceil(
                    std::max({p0.y, p1.y, p2.y})));
                const float colors[3][4] = {
                    {(float)((v0.col >> IM_COL32_R_SHIFT) & 0xff) / 255.0f,
                     (float)((v0.col >> IM_COL32_G_SHIFT) & 0xff) / 255.0f,
                     (float)((v0.col >> IM_COL32_B_SHIFT) & 0xff) / 255.0f,
                     (float)((v0.col >> IM_COL32_A_SHIFT) & 0xff) / 255.0f},
                    {(float)((v1.col >> IM_COL32_R_SHIFT) & 0xff) / 255.0f,
                     (float)((v1.col >> IM_COL32_G_SHIFT) & 0xff) / 255.0f,
                     (float)((v1.col >> IM_COL32_B_SHIFT) & 0xff) / 255.0f,
                     (float)((v1.col >> IM_COL32_A_SHIFT) & 0xff) / 255.0f},
                    {(float)((v2.col >> IM_COL32_R_SHIFT) & 0xff) / 255.0f,
                     (float)((v2.col >> IM_COL32_G_SHIFT) & 0xff) / 255.0f,
                     (float)((v2.col >> IM_COL32_B_SHIFT) & 0xff) / 255.0f,
                     (float)((v2.col >> IM_COL32_A_SHIFT) & 0xff) / 255.0f}
                };
                for (int y = minY; y < maxY; ++y) for (int x = minX; x < maxX; ++x) {
                    const CSSoftwarePoint sample{(float)x + 0.5f, (float)y + 0.5f};
                    const float w0 = CSEdge(p1, p2, sample) / area;
                    const float w1 = CSEdge(p2, p0, sample) / area;
                    const float w2 = 1.0f - w0 - w1;
                    if (w0 < -0.0001f || w1 < -0.0001f || w2 < -0.0001f) continue;
                    const float u = w0 * v0.uv.x + w1 * v1.uv.x + w2 * v2.uv.x;
                    const float v = w0 * v0.uv.y + w1 * v1.uv.y + w2 * v2.uv.y;
                    const int tx = std::clamp((int)std::lround(u * (atlasWidth - 1)),
                                              0, atlasWidth - 1);
                    const int ty = std::clamp((int)std::lround(v * (atlasHeight - 1)),
                                              0, atlasHeight - 1);
                    const float textureAlpha = atlas[ty * atlasWidth + tx] / 255.0f;
                    const float r = w0 * colors[0][0] + w1 * colors[1][0] + w2 * colors[2][0];
                    const float g = w0 * colors[0][1] + w1 * colors[1][1] + w2 * colors[2][1];
                    const float b = w0 * colors[0][2] + w1 * colors[1][2] + w2 * colors[2][2];
                    const float a = (w0 * colors[0][3] + w1 * colors[1][3] +
                                     w2 * colors[2][3]) * textureAlpha;
                    if (a > 0) CSBlendSoftwarePixel(pixels[y * width + x], r, g, b, a);
                }
            }
        }
    }
    return YES;
}

@implementation CoreSetImGuiMenuViewController {
    __weak id<CoreSetImGuiMenuModel> _model;
    CoreSetImGuiTouchView *_surfaceView;
    CALayer *_retainedLayer;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    MTLRenderPassDescriptor *_renderPass;
    id<MTLTexture> _fallbackTexture;
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
    uint64_t _scheduledPresentationSerial;
    uint64_t _widgetActionSerial;
    uint64_t _retainedRequestSerial;
    BOOL _retainedPresentationNeeded;
    BOOL _presentationQueued;
}

- (instancetype)initWithModel:(id<CoreSetImGuiMenuModel>)model {
    if (!model) return nil;
    if ((self = [super initWithNibName:nil bundle:nil])) _model = model;
    return self;
}
- (id<CoreSetImGuiMenuModel>)model { return _model; }

- (void)loadView {
    _device = MTLCreateSystemDefaultDevice();
    UIView *fallback = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 838, 535)];
    fallback.backgroundColor = UIColor.clearColor;
    self.view = fallback;
    if (!_device) return;
    _queue = [_device newCommandQueue];
    _surfaceView = [[CoreSetImGuiTouchView alloc] initWithFrame:fallback.bounds];
    _surfaceView.menuOwner = self;
    _surfaceView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _surfaceView.backgroundColor = UIColor.clearColor;
    _surfaceView.opaque = NO; _surfaceView.layer.opaque = NO;
    CAMetalLayer *layer = _surfaceView.metalLayer;
    layer.device = _device;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = YES;
    layer.opaque = NO;
    layer.maximumDrawableCount = 3;
    layer.allowsNextDrawableTimeout = YES;
    [fallback addSubview:_surfaceView];
    _retainedLayer = [CALayer layer];
    _retainedLayer.name = @"CoreSetHostedImGuiSnapshot";
    _retainedLayer.frame = fallback.bounds;
    _retainedLayer.contentsGravity = kCAGravityResize;
    _retainedLayer.masksToBounds = YES;
    _retainedLayer.hidden = YES;
    CSEnableHostedLayerUpdates(fallback.layer);
    CSEnableHostedLayerUpdates(layer);
    CSEnableHostedLayerUpdates(_retainedLayer);
    [fallback.layer addSublayer:_retainedLayer];
    _renderPass = [MTLRenderPassDescriptor renderPassDescriptor];
    _renderPass.colorAttachments[0].loadAction = MTLLoadActionClear;
    _renderPass.colorAttachments[0].storeAction = MTLStoreActionStore;
    _renderPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if (!_surfaceView || !_device || !_queue || !_renderPass) return;
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
    if (!ImGui_ImplMetal_Init(_device)) {
        ImGui::DestroyContext(_imgui); _imgui = nullptr; return;
    }
    NSLog(@"Core-SET: ImGui runtime contract=core17-imgui-v15 surface=CAMetalLayer/nextDrawable+software-CA size=838x535 contentOrigin=170,38 inputFrame=phase-driven semanticReceipt=cpu-frame widgetReceipt=action presentationReceipt=metal-or-software-ca");
    [self startDisplayLink];
}

- (void)startDisplayLink {
    if (_displayLink || !_imgui) return;
    _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayTick:)];
    _displayLink.preferredFramesPerSecond = 60;
    [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)displayTick:(CADisplayLink *)link {
    if (_surfaceView.window && !self.view.hidden && !self.view.superview.hidden &&
        self.view.alpha > 0.01 && self.view.superview.alpha > 0.01) {
        const BOOL background = UIApplication.sharedApplication.applicationState !=
            UIApplicationStateActive;
        const BOOL modelChanged = _model.imguiMenuModelRevision != _renderedRevision;
        if (background && !_retainedPresentationNeeded && !modelChanged) return;
        [self renderFrameAttemptPresentation:YES];
    } else if (_imgui && _pointer.down()) {
        ImGui::SetCurrentContext(_imgui);
        _pointer.cancel(ImGui::GetIO());
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self updateDrawableGeometry];
    if (_imgui && !CGRectEqualToRect(_inputBounds, self.view.bounds)) {
        ImGui::SetCurrentContext(_imgui);
        _pointer.layoutChanged(ImGui::GetIO());
        _inputBounds = self.view.bounds;
    }
}

- (void)updateDrawableGeometry {
    if (!_surfaceView) return;
    const CGFloat scale = self.view.window.screen.scale ?: UIScreen.mainScreen.scale;
    const CGSize bounds = _surfaceView.bounds.size;
    const CGSize drawableSize = CGSizeMake(MAX(1, round(bounds.width * scale)),
                                           MAX(1, round(bounds.height * scale)));
    CAMetalLayer *layer = _surfaceView.metalLayer;
    layer.contentsScale = scale;
    _retainedLayer.frame = _surfaceView.frame;
    _retainedLayer.contentsScale = scale;
    if (!CGSizeEqualToSize(layer.drawableSize, drawableSize)) {
        layer.drawableSize = drawableSize;
        _fallbackTexture = nil;
        ++_retainedRequestSerial;
        _retainedPresentationNeeded = YES;
    }
}

- (id<MTLTexture>)fallbackTexture {
    [self updateDrawableGeometry];
    const CGSize size = _surfaceView.metalLayer.drawableSize;
    const NSUInteger width = MAX((NSUInteger)1, (NSUInteger)llround(size.width));
    const NSUInteger height = MAX((NSUInteger)1, (NSUInteger)llround(size.height));
    if (_fallbackTexture && _fallbackTexture.width == width && _fallbackTexture.height == height)
        return _fallbackTexture;
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:width height:height mipmapped:NO];
    descriptor.storageMode = MTLStorageModePrivate;
    descriptor.usage = MTLTextureUsageRenderTarget;
    _fallbackTexture = [_device newTextureWithDescriptor:descriptor];
    return _fallbackTexture;
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

- (BOOL)renderSoftwareRetainedPresentation {
    if (!_retainedLayer || !_imgui || !NSThread.isMainThread) return NO;
    ImGui::SetCurrentContext(_imgui);
    ImGuiIO &io = ImGui::GetIO();
    unsigned char *atlas = nullptr;
    int atlasWidth = 0, atlasHeight = 0;
    io.Fonts->GetTexDataAsAlpha8(&atlas, &atlasWidth, &atlasHeight);
    const CGSize bounds = _surfaceView.bounds.size;
    const int width = MAX(1, (int)std::lround(bounds.width));
    const int height = MAX(1, (int)std::lround(bounds.height));
    if ((size_t)width > SIZE_MAX / (size_t)height ||
        (size_t)width * (size_t)height > SIZE_MAX / sizeof(uint32_t)) return NO;
    std::vector<uint32_t> pixels((size_t)width * (size_t)height, 0);
    if (!CSRasterizeImGui(ImGui::GetDrawData(), atlas, atlasWidth, atlasHeight,
                          pixels.data(), width, height)) return NO;
    NSData *data = [NSData dataWithBytes:pixels.data()
                                  length:pixels.size() * sizeof(uint32_t)];
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo bitmap = (CGBitmapInfo)kCGBitmapByteOrder32Big |
        (CGBitmapInfo)kCGImageAlphaPremultipliedLast;
    CGImageRef image = provider && colorSpace
        ? CGImageCreate(width, height, 8, 32, (size_t)width * sizeof(uint32_t),
                        colorSpace, bitmap, provider, nullptr, false,
                        kCGRenderingIntentDefault)
        : nullptr;
    if (provider) CGDataProviderRelease(provider);
    if (colorSpace) CGColorSpaceRelease(colorSpace);
    if (!image) return NO;
    ++_retainedRequestSerial;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _retainedLayer.contents = (__bridge id)image;
    _retainedLayer.contentsScale = 1;
    _retainedLayer.hidden = NO;
    [CATransaction commit];
    [CATransaction flush];
    CGImageRelease(image);
    NSLog(@"Core-SET: ImGui presentation stage=software-ca committed=1 request=%llu frame=%llu pixels=%dx%d",
          (unsigned long long)_retainedRequestSerial,
          (unsigned long long)_frameSerial, width, height);
    return YES;
}

- (CoreSetImGuiFrameResult)renderFrameAttemptPresentation:(BOOL)attemptPresentation {
    CoreSetImGuiFrameResult result = { NO, NO, NO };
    if (!NSThread.isMainThread || !_imgui || !_device || !_queue || !_surfaceView || !_renderPass)
        return result;
    [self updateDrawableGeometry];
    CAMetalLayer *layer = _surfaceView.metalLayer;
    const BOOL background = UIApplication.sharedApplication.applicationState !=
        UIApplicationStateActive;
    id<CAMetalDrawable> drawable = attemptPresentation && !background
        ? [layer nextDrawable] : nil;
    id<MTLTexture> texture = drawable ? drawable.texture : [self fallbackTexture];
    if (!texture) return result;
    _renderPass.colorAttachments[0].texture = texture;
    ImGui::SetCurrentContext(_imgui);
    ImGuiIO &io = ImGui::GetIO();
    const CGSize bounds = _surfaceView.bounds.size;
    io.DisplaySize = ImVec2((float)bounds.width, (float)bounds.height);
    io.DisplayFramebufferScale = ImVec2((float)(texture.width / MAX(1.0, bounds.width)),
                                         (float)(texture.height / MAX(1.0, bounds.height)));
    ImGui_ImplMetal_NewFrame(_renderPass); ImGui::NewFrame();
    const uint64_t revision = _model.imguiMenuModelRevision;
    if (!_snapshot || revision != _renderedRevision) {
        _retainedPresentationNeeded = YES;
        _snapshot = [[_model imguiMenuSnapshot] copy] ?: @{};
        _renderedRevision = revision;
    }
    ImGui::PushFont(_bodyFont); [self drawMenu:_snapshot]; ImGui::PopFont();
    ImGui::Render();
    ++_frameSerial;
    result.processed = YES;
    if (!attemptPresentation) return result;
    if (background) {
        if (_retainedPresentationNeeded && [self renderSoftwareRetainedPresentation]) {
            _retainedPresentationNeeded = NO;
            ++_scheduledPresentationSerial;
            result.presentScheduled = YES;
            result.retainedScheduled = YES;
        }
        return result;
    }
    if (!drawable) return result;
    id<MTLCommandBuffer> buffer = [_queue commandBuffer];
    if (!buffer) return result;
    id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:_renderPass];
    if (!encoder) return result;
    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), buffer, encoder);
    [encoder endEncoding];
    _retainedLayer.hidden = YES;
    _retainedPresentationNeeded = NO;
    [buffer presentDrawable:drawable];
    ++_scheduledPresentationSerial;
    result.presentScheduled = YES;
    [buffer commit];
    return result;
}

- (void)schedulePresentation {
    if (_presentationQueued || !_imgui || !_surfaceView) return;
    _presentationQueued = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_presentationQueued = NO;
        if (!self->_imgui || !self->_surfaceView.window || self.view.hidden || self.view.superview.hidden)
            return;
        CoreSetImGuiFrameResult result = [self renderFrameAttemptPresentation:YES];
        NSLog(@"Core-SET: ImGui presentation stage=hosted-frame processed=%d presentScheduled=%d retainedScheduled=%d frame=%llu scheduledFrame=%llu",
              result.processed, result.presentScheduled, result.retainedScheduled,
              (unsigned long long)self->_frameSerial,
              (unsigned long long)self->_scheduledPresentationSerial);
    });
}

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
    if (!queued || !_surfaceView) return NO;
    const uint64_t beforeFrame = _frameSerial;
    const uint64_t beforeScheduled = _scheduledPresentationSerial;
    const uint64_t beforeAction = _widgetActionSerial;
    // Core drives the ImGui frame and the CAMetalLayer presentation as separate
    // receipts.  A backgrounded source can temporarily have no drawable; the
    // pointer must still advance through the real ImGui widget state machine.
    CoreSetImGuiFrameResult frame = [self renderFrameAttemptPresentation:NO];
    const BOOL processed = frame.processed && _frameSerial > beforeFrame;
    BOOL presentScheduled = frame.presentScheduled && _scheduledPresentationSerial > beforeScheduled;
    const BOOL actionChanged = _widgetActionSerial > beforeAction;
    if (actionChanged || phase == CoreSetHostedPointerPhaseBegan ||
        phase == CoreSetHostedPointerPhaseEnded)
        _retainedPresentationNeeded = YES;
    BOOL refreshed = !actionChanged;
    // The changed widget publishes a new immutable model revision during the
    // first frame. Render that revision immediately as well; otherwise a
    // backgrounded CADisplayLink could leave the old page/value visible.
    if (processed && actionChanged) {
        const uint64_t actionFrame = _frameSerial;
        CoreSetImGuiFrameResult refresh = [self renderFrameAttemptPresentation:NO];
        refreshed = refresh.processed && _frameSerial > actionFrame;
        presentScheduled = presentScheduled || refresh.presentScheduled;
    }
    [self schedulePresentation];
    NSLog(@"Core-SET: ImGui input stage=frame phase=%ld queued=1 processed=%d presentationQueued=1 presentScheduled=%d refreshed=%d frame=%llu scheduledFrame=%llu actionChanged=%d actionSerial=%llu",
          (long)phase, processed, presentScheduled, refreshed, (unsigned long long)_frameSerial,
          (unsigned long long)_scheduledPresentationSerial, actionChanged,
          (unsigned long long)_widgetActionSerial);
    if (!processed) {
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
