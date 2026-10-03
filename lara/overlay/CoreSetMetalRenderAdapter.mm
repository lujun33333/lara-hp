#import "CoreSetMetalRenderAdapter.h"
#import <CoreImage/CoreImage.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#include <cmath>

static NSError *CSMetalError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"CoreSetMetalRender" code:code
        userInfo:@{NSLocalizedDescriptionKey: message}];
}

@interface CoreSetMetalRenderAdapter () <MTKViewDelegate>
@end

@implementation CoreSetMetalRenderAdapter {
    MTKView *_metalView;
    UIView *_rasterView;
    CoreSetCoreAnimationConsumer *_raster;
    id<MTLCommandQueue> _queue;
    CIContext *_ciContext;
    CGImageRef _lastImage;
    BOOL _visible;
    BOOL _lastDrawSucceeded;
    NSInteger _requestedFPS;
}

- (CoreSetHUDBackend)backend { return CoreSetHUDBackendMetal; }
- (BOOL)renderSurfaceReady {
    return NSThread.isMainThread && _metalView != nil && _metalView.window != nil &&
        _queue != nil && _ciContext != nil;
}

- (void)attachToView:(UIView *)view {
    NSAssert(NSThread.isMainThread, @"Metal renderer requires the main thread");
    [self detach];
    if (!view) return;
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return;
    _queue = [device newCommandQueue];
    _ciContext = [CIContext contextWithMTLDevice:device];
    if (!_queue || !_ciContext) { _queue = nil; _ciContext = nil; return; }
    _metalView = [[MTKView alloc] initWithFrame:view.bounds device:device];
    _metalView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _metalView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    _metalView.framebufferOnly = NO;
    _metalView.opaque = NO;
    _metalView.layer.opaque = NO;
    _metalView.clearColor = MTLClearColorMake(0, 0, 0, 0);
    _metalView.delegate = self;
    _metalView.paused = YES;
    _metalView.enableSetNeedsDisplay = NO;
    _requestedFPS = MIN(60, MAX(30, view.window.screen.maximumFramesPerSecond ?: 60));
    _metalView.preferredFramesPerSecond = _requestedFPS;
    [view addSubview:_metalView];
    _rasterView = [[UIView alloc] initWithFrame:view.bounds];
    _rasterView.opaque = NO;
    _raster = [CoreSetCoreAnimationConsumer new];
    [_raster attachToView:_rasterView];
    [self setVisible:NO];
}

- (BOOL)renderLastImage:(MTKView *)view {
    if (!_visible || !_lastImage || !view.window || !view.currentDrawable || !_queue || !_ciContext)
        return NO;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    id<MTLCommandBuffer> buffer = [_queue commandBuffer];
    if (!drawable || !buffer) return NO;
    const CGSize size = view.drawableSize;
    if (!(size.width > 0 && size.height > 0) ||
        !std::isfinite(size.width) || !std::isfinite(size.height)) return NO;
    CIImage *image = [CIImage imageWithCGImage:_lastImage];
    if (!image) return NO;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    [_ciContext render:image toMTLTexture:drawable.texture commandBuffer:buffer
                 bounds:CGRectMake(0, 0, size.width, size.height) colorSpace:space];
    CGColorSpaceRelease(space);
    [buffer presentDrawable:drawable];
    [buffer commit];
    [buffer waitUntilCompleted];
    return buffer.status == MTLCommandBufferStatusCompleted && buffer.error == nil;
}

- (void)drawInMTKView:(MTKView *)view {
    if (view != _metalView) return;
    _lastDrawSucceeded = [self renderLastImage:view];
}
- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    (void)view; (void)size;
    // Never stretch coordinates from an old drawable into a new geometry.
    [self clear];
}

- (BOOL)consumeFrame:(CoreSetRenderFrame *)frame error:(NSError **)error {
    if (!NSThread.isMainThread || !_visible || !_metalView || !_metalView.window ||
        !_raster || !_queue || !_ciContext) {
        if (error) *error = CSMetalError(1, @"Metal surface or drawable is unavailable");
        return NO;
    }
    const CGSize drawable = _metalView.drawableSize;
    if (drawable.width <= 0 || drawable.height <= 0 ||
        !std::isfinite(drawable.width) || !std::isfinite(drawable.height) ||
        drawable.width > 8192 || drawable.height > 8192) {
        if (error) *error = CSMetalError(2, @"Invalid drawable dimensions");
        return NO;
    }
    _rasterView.frame = CGRectMake(0, 0, frame.canvasSize.width, frame.canvasSize.height);
    NSError *rasterError = nil;
    if (![_raster consumeFrame:frame error:&rasterError]) {
        if (error) *error = rasterError ?: CSMetalError(3, @"Command rasterization failed");
        return NO;
    }
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.opaque = NO;
    format.scale = 1;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
        initWithSize:drawable format:format];
    UIImage *bitmap = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGContextRef cg = context.CGContext;
        CGContextScaleCTM(cg, drawable.width / frame.canvasSize.width,
                               drawable.height / frame.canvasSize.height);
        [self->_rasterView.layer renderInContext:cg];
    }];
    if (!bitmap.CGImage) {
        if (error) *error = CSMetalError(4, @"Bitmap rasterization failed");
        return NO;
    }
    if (_lastImage) CGImageRelease(_lastImage);
    _lastImage = CGImageRetain(bitmap.CGImage);
    _lastDrawSucceeded = NO;
    [_metalView draw];
    if (!_lastDrawSucceeded && error) *error = CSMetalError(5, @"Metal drawable was not presented");
    return _lastDrawSucceeded;
}

- (void)setVisible:(BOOL)visible {
    _visible = visible && _metalView != nil;
    _metalView.hidden = !_visible;
    // Only the visible, foreground Metal surface owns a running scheduler.
    _metalView.paused = !_visible;
}
- (NSInteger)observedRenderFPS {
    if (!NSThread.isMainThread || !_visible || !_metalView || !_metalView.window ||
        _metalView.paused || _metalView.hidden || !_lastDrawSucceeded) return 0;
    return _metalView.preferredFramesPerSecond;
}
- (BOOL)setPreferredRenderFPS:(NSInteger)fps {
    if (!NSThread.isMainThread || !_visible || !_metalView || !_metalView.window ||
        fps < 30 || fps > 144 || fps > _metalView.window.screen.maximumFramesPerSecond) return NO;
    _metalView.preferredFramesPerSecond = fps;
    _requestedFPS = fps;
    return [self observedRenderFPS] == fps;
}
- (void)clear {
    [_raster clear];
    if (_lastImage) { CGImageRelease(_lastImage); _lastImage = nil; }
    _lastDrawSucceeded = NO;
    [_metalView setNeedsDisplay];
}
- (void)detach {
    [self clear];
    _metalView.paused = YES;
    _metalView.delegate = nil;
    [_metalView removeFromSuperview];
    _metalView = nil;
    [_raster detach]; _raster = nil; _rasterView = nil;
    _queue = nil; _ciContext = nil;
    _visible = NO; _requestedFPS = 0;
}
- (void)dealloc { if (_lastImage) CGImageRelease(_lastImage); }
@end
