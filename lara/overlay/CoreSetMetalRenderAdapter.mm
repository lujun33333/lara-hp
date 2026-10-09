#import "CoreSetMetalRenderAdapter.h"
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#include "../third_party/imgui/imgui.h"
#include "../third_party/imgui/backends/imgui_impl_metal.h"
#include <algorithm>
#include <cfloat>
#include <cmath>
#include <initializer_list>

static NSError *CSMetalError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"CoreSetMetalRender" code:code
        userInfo:@{NSLocalizedDescriptionKey: message}];
}

static ImU32 CSImColor(UIColor *color) {
    CGFloat r = 1, g = 1, b = 1, a = 1;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) {
        CGFloat white = 1;
        [color getWhite:&white alpha:&a];
        r = g = b = white;
    }
    return IM_COL32((int)std::lround(r * 255.0), (int)std::lround(g * 255.0),
                    (int)std::lround(b * 255.0), (int)std::lround(a * 255.0));
}

static ImVec2 CSPoint(CGPoint point) { return ImVec2((float)point.x, (float)point.y); }
static ImVec2 CSRectMin(CGRect rect) { return ImVec2((float)CGRectGetMinX(rect), (float)CGRectGetMinY(rect)); }
static ImVec2 CSRectMax(CGRect rect) { return ImVec2((float)CGRectGetMaxX(rect), (float)CGRectGetMaxY(rect)); }
static BOOL CSMetalIconGlyphAllowed(NSString *text) {
    return text.length == 1 && [@"acersvwxz" containsString:text];
}

@interface CoreSetMetalRenderAdapter () <MTKViewDelegate>
@end

@implementation CoreSetMetalRenderAdapter {
    MTKView *_metalView;
    id<MTLCommandQueue> _queue;
    MTKTextureLoader *_textureLoader;
    NSMutableDictionary<NSString *, id<MTLTexture>> *_textures;
    CoreSetRenderFrame *_frame;
    ImGuiContext *_imgui;
    ImFont *_font;
    ImFont *_iconFont;
    BOOL _visible;
    BOOL _hasVisibleCommands;
    BOOL _lastDrawSucceeded;
    NSInteger _requestedFPS;
    CoreSetPresentationCadence::Window _presentationCadence;
}

- (CoreSetHUDBackend)backend { return CoreSetHUDBackendMetal; }
- (BOOL)renderSurfaceReady {
    return NSThread.isMainThread && _metalView.window != nil && _queue != nil && _imgui != nullptr;
}

- (void)attachToView:(UIView *)view {
    NSAssert(NSThread.isMainThread, @"Metal renderer requires the main thread");
    [self detach];
    if (!view) return;
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return;
    _queue = [device newCommandQueue];
    _textureLoader = [[MTKTextureLoader alloc] initWithDevice:device];
    _textures = [NSMutableDictionary dictionary];
    if (!_queue || !_textureLoader) { _queue = nil; _textureLoader = nil; return; }

    _imgui = ImGui::CreateContext();
    if (!_imgui) return;
    ImGui::SetCurrentContext(_imgui);
    ImGuiIO &io = ImGui::GetIO();
    io.IniFilename = nullptr;
    io.LogFilename = nullptr;
    NSString *fontPath = [NSBundle.mainBundle pathForResource:@"OPPOSans-H" ofType:@"ttf"];
    NSString *iconPath = [NSBundle.mainBundle pathForResource:@"IcoMoon" ofType:@"ttf"];
    if (fontPath.length)
        // Core v1.7 creates its HUD body face from this exact embedded font at
        // 25 points. AddText still applies each command's requested size.
        _font = io.Fonts->AddFontFromFileTTF(fontPath.UTF8String, 25.0f, nullptr,
                                             io.Fonts->GetGlyphRangesChineseFull());
    if (iconPath.length)
        _iconFont = io.Fonts->AddFontFromFileTTF(iconPath.UTF8String, 25.0f, nullptr,
                                                 io.Fonts->GetGlyphRangesDefault());
    if (!_font || !_iconFont || !ImGui_ImplMetal_Init(device)) { [self detach]; return; }

    _metalView = [[MTKView alloc] initWithFrame:view.bounds device:device];
    _metalView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _metalView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    _metalView.depthStencilPixelFormat = MTLPixelFormatInvalid;
    _metalView.framebufferOnly = YES;
    _metalView.opaque = NO;
    _metalView.layer.opaque = NO;
    _metalView.clearColor = MTLClearColorMake(0, 0, 0, 0);
    _metalView.delegate = self;
    _metalView.paused = YES;
    _metalView.enableSetNeedsDisplay = NO;
    _requestedFPS = MIN(60, MAX(30, view.window.screen.maximumFramesPerSecond ?: 60));
    _metalView.preferredFramesPerSecond = _requestedFPS;
    [view addSubview:_metalView];
    [self setVisible:NO];
}

- (BOOL)validateFrame:(CoreSetRenderFrame *)frame {
    const CGSize size = frame.canvasSize;
    if (!frame || !std::isfinite(size.width) || !std::isfinite(size.height) ||
        size.width <= 0 || size.height <= 0 || frame.commands.count > 8192) return NO;
    for (CoreSetRenderCommand *command in frame.commands) {
        const CGRect r = command.rect;
        if (![command isKindOfClass:CoreSetRenderCommand.class] ||
            command.kind < CoreSetRenderKindLine || command.kind > CoreSetRenderKindBackGlyph ||
            !std::isfinite(r.origin.x) || !std::isfinite(r.origin.y) ||
            !std::isfinite(r.size.width) || !std::isfinite(r.size.height) ||
            r.size.width < 0 || r.size.height < 0 ||
            !std::isfinite(command.endpoint.x) || !std::isfinite(command.endpoint.y) ||
            !std::isfinite(command.lineWidth) || command.lineWidth < 0 || command.lineWidth > 1024 ||
            !std::isfinite(command.cornerRadius) || command.cornerRadius < 0 ||
            command.cornerRadius > 256 ||
            !std::isfinite(command.fontSize) || command.fontSize <= 0 || command.fontSize > 512 ||
            !command.color) return NO;
        if (command.kind != CoreSetRenderKindRectangle && command.cornerRadius != 0) return NO;
        const BOOL hasGradient = command.gradientLeftColor || command.gradientRightColor;
        if (hasGradient && (command.kind != CoreSetRenderKindRectangle || !command.isFilled ||
            command.cornerRadius != 0 || !command.gradientLeftColor ||
            !command.gradientRightColor)) return NO;
        if (command.kind == CoreSetRenderKindText && command.text.length > 4096) return NO;
        if (command.kind == CoreSetRenderKindText &&
            (command.fontRole < CoreSetRenderFontRoleBody ||
             command.fontRole > CoreSetRenderFontRoleIcon ||
             !std::isfinite(command.textBackgroundHorizontalPadding) ||
             !std::isfinite(command.textBackgroundVerticalPadding) ||
             command.textBackgroundHorizontalPadding < 0 ||
             command.textBackgroundHorizontalPadding > 64 ||
             command.textBackgroundVerticalPadding < 0 ||
             command.textBackgroundVerticalPadding > 64)) return NO;
        if (command.kind == CoreSetRenderKindText &&
            command.fontRole == CoreSetRenderFontRoleIcon &&
            !CSMetalIconGlyphAllowed(command.text)) return NO;
        if (command.kind != CoreSetRenderKindText &&
            (command.fontRole != CoreSetRenderFontRoleBody || command.textBackgroundColor)) return NO;
        if (command.kind == CoreSetRenderKindImage && command.weaponID == 0 &&
            ![command.localImageName isEqualToString:@"CoreSetLoading.png"]) return NO;
        if (command.kind == CoreSetRenderKindBackGlyph &&
            (command.glyphStyle < 0 || command.glyphStyle > 5 ||
             !std::isfinite(command.glyphAngle))) return NO;
    }
    return YES;
}

- (id<MTLTexture>)textureForCommand:(CoreSetRenderCommand *)command {
    NSString *key = command.weaponID ? [NSString stringWithFormat:@"weapon-%u", command.weaponID]
                                     : command.localImageName;
    id<MTLTexture> texture = _textures[key];
    if (texture) return texture;
    UIImage *image = command.weaponID ? [CoreSetWeaponImageCatalog imageForWeaponID:command.weaponID]
                                      : [UIImage imageNamed:command.localImageName];
    if (!image.CGImage) return nil;
    NSError *error = nil;
    texture = [_textureLoader newTextureWithCGImage:image.CGImage
        options:@{MTKTextureLoaderOptionSRGB: @NO, MTKTextureLoaderOptionOrigin: MTKTextureLoaderOriginTopLeft}
        error:&error];
    if (texture && !error) _textures[key] = texture;
    return texture;
}

- (void)addBackGlyph:(CoreSetRenderCommand *)command to:(ImDrawList *)draw {
    CGRect rect = command.rect;
    ImU32 color = CSImColor(command.color);
    ImU32 black = IM_COL32(0, 0, 0, 255);
    float outline = std::max(1.0f, (float)rect.size.width / 80.0f * 1.35f);
    ImVec2 center((float)CGRectGetMidX(rect), (float)CGRectGetMidY(rect));
    auto transform = [&](float x, float y) {
        float px = (float)rect.origin.x + x * (float)rect.size.width;
        float py = (float)CGRectGetMidY(rect) + y * (float)rect.size.height;
        float dx = px - center.x, dy = py - center.y;
        float c = std::cos((float)command.glyphAngle), s = std::sin((float)command.glyphAngle);
        return ImVec2(center.x + dx * c - dy * s, center.y + dx * s + dy * c);
    };
    auto polygon = [&](std::initializer_list<ImVec2> source, ImU32 fill, bool border) {
        ImVector<ImVec2> points;
        for (const ImVec2 &p : source) points.push_back(transform(p.x, p.y));
        if (fill) draw->AddConvexPolyFilled(points.Data, points.Size, fill);
        if (border) draw->AddPolyline(points.Data, points.Size, black, ImDrawFlags_Closed, outline);
    };
    auto arc = [&](float centerX, float radiusFactor, float from, float to, int points) {
        ImVector<ImVec2> vertices;
        const float radius = std::max(0.0f, radiusFactor * (float)rect.size.height);
        for (int index = 0; index < points; ++index) {
            const float fraction = points > 1 ? (float)index / (float)(points - 1) : 0;
            const float angle = from + (to - from) * fraction;
            const float x = centerX + std::cos(angle) * radius / (float)rect.size.width;
            const float y = std::sin(angle) * radius / (float)rect.size.height;
            vertices.push_back(transform(x, y));
        }
        draw->AddPolyline(vertices.Data, vertices.Size, black, 0,
                          std::max(.18f * (float)rect.size.height, 2.4f));
        draw->AddPolyline(vertices.Data, vertices.Size, color, 0,
                          std::max(.095f * (float)rect.size.height, 1.3f));
    };
    auto dot = [&](float centerX, float radiusFactor, float minimumRadius,
                   float alpha, float borderFactor) {
        const float radius = std::max(radiusFactor * (float)rect.size.height, minimumRadius);
        const float outer = radius + outline * borderFactor;
        const ImU32 foreground = (color & 0x00FFFFFFu) |
            ((ImU32)std::lround(std::clamp(alpha, 0.0f, 1.0f) * 255.0f) << 24);
        draw->AddCircleFilled(transform(centerX, 0), outer, black, 12);
        draw->AddCircleFilled(transform(centerX, 0), radius, foreground, 12);
    };
    switch (command.glyphStyle) {
        case 0: polygon({{0,0},{.42f,-.5f},{.42f,-.19f},{1,-.19f},{1,.19f},{.42f,.19f},{.42f,.5f}}, color, true); break;
        case 1: polygon({{0,0},{.38f,-.5f},{.34f,-.26f},{1,-.26f},{.76f,0},{1,.26f},{.34f,.26f},{.38f,.5f}}, color, true); break;
        case 2:
            polygon({{0,0},{.48f,-.5f},{.48f,.5f}}, color, false);
            polygon({{.48f,-.5f},{1,0},{.48f,.5f}}, color & 0x75FFFFFFu, false);
            polygon({{0,0},{.48f,-.5f},{1,0},{.48f,.5f}}, 0, true);
            break;
        case 3:
            arc(.67f, .43f, -2.5215926f, 2.5215926f, 21);
            polygon({{0,0},{.52f,-.26f},{.52f,.26f}}, color, true);
            break;
        case 4:
            dot(.48f, .15f, 1.1f, .90f, .72f);
            dot(.67f, .11f, 1.1f, .65f, .72f);
            dot(.83f, .075f, 1.1f, .40f, .72f);
            polygon({{0,0},{.30f,-.46f},{.30f,.46f}}, color, true);
            break;
        case 5:
            arc(.65f, .46f, -2.4215927f, -.18f, 13);
            arc(.65f, .46f, .18f, 2.4215927f, 13);
            dot(.65f, .075f, 1.0f, 1.0f, .65f);
            polygon({{0,0},{.53f,-.18f},{.53f,.18f}}, color, true);
            break;
    }
}

- (void)buildDrawListForFrame:(CoreSetRenderFrame *)frame {
    ImDrawList *draw = ImGui::GetBackgroundDrawList();
    for (CoreSetRenderCommand *command in frame.commands) {
        const ImU32 color = CSImColor(command.color);
        switch (command.kind) {
            case CoreSetRenderKindLine:
                draw->AddLine(CSRectMin(command.rect), CSPoint(command.endpoint), color,
                              std::max(1.0f, (float)command.lineWidth));
                break;
            case CoreSetRenderKindRectangle:
                if (command.gradientLeftColor && command.gradientRightColor) {
                    const ImU32 left = CSImColor(command.gradientLeftColor);
                    const ImU32 right = CSImColor(command.gradientRightColor);
                    draw->AddRectFilledMultiColor(CSRectMin(command.rect), CSRectMax(command.rect),
                                                  left, right, right, left);
                } else if (command.filled) draw->AddRectFilled(CSRectMin(command.rect), CSRectMax(command.rect), color,
                                                              (float)command.cornerRadius);
                else draw->AddRect(CSRectMin(command.rect), CSRectMax(command.rect), color,
                                   (float)command.cornerRadius, 0,
                                   std::max(1.0f, (float)command.lineWidth));
                break;
            case CoreSetRenderKindEllipse: {
                ImVec2 center((float)CGRectGetMidX(command.rect), (float)CGRectGetMidY(command.rect));
                ImVec2 radius((float)command.rect.size.width * .5f, (float)command.rect.size.height * .5f);
                if (command.filled) draw->AddEllipseFilled(center, radius, color);
                else draw->AddEllipse(center, radius, color, 0, 0,
                                      std::max(1.0f, (float)command.lineWidth));
                break;
            }
            case CoreSetRenderKindText: {
                const char *utf8 = command.text.UTF8String ?: "";
                ImFont *font = command.fontRole == CoreSetRenderFontRoleIcon ? _iconFont : _font;
                if (!font) break;
                ImVec2 pos = CSRectMin(command.rect);
                ImVec2 measured = font->CalcTextSizeA((float)command.fontSize, FLT_MAX, 0, utf8);
                if (command.horizontallyCenteredText) {
                    pos.x = (float)CGRectGetMidX(command.rect) - measured.x * .5f;
                }
                if (command.textBackgroundColor) {
                    const float horizontal = (float)command.textBackgroundHorizontalPadding;
                    const float vertical = (float)command.textBackgroundVerticalPadding;
                    draw->AddRectFilled(ImVec2(pos.x - horizontal, pos.y - vertical),
                        ImVec2(pos.x + measured.x + horizontal, pos.y + measured.y + vertical),
                        CSImColor(command.textBackgroundColor));
                }
                draw->AddText(font, (float)command.fontSize, pos, color, utf8);
                break;
            }
            case CoreSetRenderKindImage: {
                id<MTLTexture> texture = [self textureForCommand:command];
                if (texture) draw->AddImage(ImTextureRef((ImTextureID)(uintptr_t)(__bridge void *)texture),
                                            CSRectMin(command.rect), CSRectMax(command.rect));
                break;
            }
            case CoreSetRenderKindBackGlyph:
                [self addBackGlyph:command to:draw];
                break;
        }
    }
}

- (void)drawInMTKView:(MTKView *)view {
    _lastDrawSucceeded = NO;
    if (view != _metalView || !_visible || !_frame || !_queue || !_imgui ||
        !view.window || !view.currentRenderPassDescriptor || !view.currentDrawable) return;
    ImGui::SetCurrentContext(_imgui);
    const CGSize canvas = _frame.canvasSize;
    const CGSize drawable = view.drawableSize;
    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize = ImVec2((float)canvas.width, (float)canvas.height);
    io.DisplayFramebufferScale = ImVec2((float)(drawable.width / canvas.width),
                                        (float)(drawable.height / canvas.height));
    io.DeltaTime = 1.0f / (float)MAX(1, _requestedFPS);
    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    ImGui_ImplMetal_NewFrame(pass);
    ImGui::NewFrame();
    [self buildDrawListForFrame:_frame];
    ImGui::Render();
    id<MTLCommandBuffer> buffer = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
    if (!buffer || !encoder) return;
    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), buffer, encoder);
    [encoder endEncoding];
    const uint64_t presentationEpoch = _presentationCadence.epoch();
    __weak CoreSetMetalRenderAdapter *weakSelf = self;
    [view.currentDrawable addPresentedHandler:^(id<MTLDrawable> drawableValue) {
        CFTimeInterval presented = drawableValue.presentedTime;
        dispatch_async(dispatch_get_main_queue(), ^{
            CoreSetMetalRenderAdapter *owner = weakSelf;
            if (owner && owner->_visible && owner->_metalView.window)
                (void)owner->_presentationCadence.accept(presentationEpoch, presented, CACurrentMediaTime());
        });
    }];
    [buffer presentDrawable:view.currentDrawable];
    [buffer commit];
    _lastDrawSucceeded = YES;
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    (void)view; (void)size;
    _presentationCadence.reset();
}

- (BOOL)consumeFrame:(CoreSetRenderFrame *)frame error:(NSError **)error {
    if (!NSThread.isMainThread || !_visible || !_metalView.window || !_queue || !_imgui) {
        if (error) *error = CSMetalError(1, @"ImGui Metal surface is unavailable");
        return NO;
    }
    if (![self validateFrame:frame]) {
        if (error) *error = CSMetalError(2, @"Invalid render frame");
        return NO;
    }
    _frame = frame;
    _hasVisibleCommands = frame.commands.count > 0;
    // Geometry producers submit complete frames. Draw exactly once here;
    // leaving MTKView unpaused would also redraw the same stale screen-space
    // commands every display tick and compete with hosted input on main.
    _metalView.paused = YES;
    _lastDrawSucceeded = NO;
    [_metalView draw];
    if (!_lastDrawSucceeded && error) *error = CSMetalError(3, @"ImGui Metal submission failed");
    return _lastDrawSucceeded;
}

- (void)setVisible:(BOOL)visible {
    if (_visible != (visible && _metalView != nil)) _presentationCadence.reset();
    _visible = visible && _metalView != nil;
    _metalView.hidden = !_visible;
    _metalView.paused = YES;
}
- (NSInteger)observedRenderFPS {
    if (!NSThread.isMainThread || !_visible || !_metalView.window ||
        !_lastDrawSucceeded) return 0;
    return _metalView.preferredFramesPerSecond;
}
- (CoreSetPresentationCadenceSample)observedPresentationCadence {
    if (!NSThread.isMainThread || !_visible || !_metalView.window)
        return CoreSetPresentationCadenceSample{};
    return _presentationCadence.observe(CACurrentMediaTime());
}
- (BOOL)setPreferredRenderFPS:(NSInteger)fps {
    if (!NSThread.isMainThread || !_visible || !_metalView.window || fps < 30 || fps > 144 ||
        fps > _metalView.window.screen.maximumFramesPerSecond) return NO;
    if (_metalView.preferredFramesPerSecond != fps) _presentationCadence.reset();
    _metalView.preferredFramesPerSecond = fps;
    _requestedFPS = fps;
    return [self observedRenderFPS] == fps;
}
- (void)clear {
    _presentationCadence.reset();
    _frame = nil;
    _hasVisibleCommands = NO;
    _lastDrawSucceeded = NO;
    _metalView.paused = YES;
}
- (void)detach {
    [self clear];
    _metalView.delegate = nil;
    [_metalView removeFromSuperview];
    _metalView = nil;
    if (_imgui) {
        ImGui::SetCurrentContext(_imgui);
        ImGui_ImplMetal_Shutdown();
        ImGui::DestroyContext(_imgui);
        _imgui = nullptr;
    }
    _font = nullptr;
    _iconFont = nullptr;
    [_textures removeAllObjects];
    _textures = nil;
    _textureLoader = nil;
    _queue = nil;
    _visible = NO;
    _requestedFPS = 0;
}
@end
