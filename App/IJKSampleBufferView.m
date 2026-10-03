#import "IJKSampleBufferView.h"
#import <os/lock.h>
#include <math.h>
#include <string.h>

@implementation IJKSampleBufferView {
    os_unfair_lock _lock;
    CVPixelBufferRef _pending;
    double _pts, _duration;
    int _serial, _lastSerial;
    BOOL _scheduled, _closed, _waitingSerial, _hasSerial;
    uint64_t _generation;
    CMTimebaseRef _timebase;
    CVPixelBufferPoolRef _pool;
    int _poolWidth, _poolHeight;
    BOOL _errorReported;
    CGFloat _fps, _scaleFactor;
    BOOL _isThirdGLView;
}
@synthesize fps = _fps, scaleFactor = _scaleFactor, isThirdGLView = _isThirdGLView;
+ (Class)layerClass { return AVSampleBufferDisplayLayer.class; }
- (AVSampleBufferDisplayLayer *)displayLayer { return (AVSampleBufferDisplayLayer *)self.layer; }
+ (IJKFFMoviePlayerController *)makePlayerWithURL:(NSURL *)url options:(IJKFFOptions *)options renderer:(IJKSampleBufferView *)renderer {
    return [[IJKFFMoviePlayerController alloc] initWithMoreContent:url withOptions:options withGLView:renderer];
}
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _scaleFactor = 1;
        self.backgroundColor = UIColor.blackColor;
        self.displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
        OSStatus status = CMTimebaseCreateWithSourceClock(kCFAllocatorDefault, CMClockGetHostTimeClock(), &_timebase);
        if (status == noErr) {
            self.displayLayer.controlTimebase = _timebase;
            CMTimebaseSetRate(_timebase, 0);
        }
    }
    return self;
}
- (UIImage *)snapshot { return nil; } // Protocol compatibility; never used as a frame source.
- (void)setContentMode:(UIViewContentMode)mode {
    [super setContentMode:mode];
    self.displayLayer.videoGravity = mode == UIViewContentModeScaleAspectFill ? AVLayerVideoGravityResizeAspectFill : AVLayerVideoGravityResizeAspect;
}
- (void)reportError:(NSString *)message {
    os_unfair_lock_lock(&_lock);
    BOOL report = !_closed && !_errorReported;
    _errorReported = YES;
    os_unfair_lock_unlock(&_lock);
    if (report) dispatch_async(dispatch_get_main_queue(), ^{ if (self.renderError) self.renderError(message); });
}
// Called synchronously under IJK's vout mutex. Never call IJK or dispatch_sync here.
- (void)display_pixels:(IJKOverlay *)overlay {
    if (!overlay) return;
    os_unfair_lock_lock(&_lock);
    BOOL reject = _closed || (_waitingSerial && _hasSerial && overlay->serial == _lastSerial);
    uint64_t generation = _generation;
    os_unfair_lock_unlock(&_lock);
    if (reject) return;
    if (!isfinite(overlay->pts) || overlay->w <= 0 || overlay->h <= 0) {
        [self reportError:@"IJK sample-buffer output: invalid frame dimensions or PTS"];
        return;
    }
    CVPixelBufferRef buffer = NULL;
    if (overlay->pixel_buffer) {
        buffer = CVPixelBufferRetain(overlay->pixel_buffer);
    } else {
        // Explicitly request I420 in Player.swift. Convert Y/U/V to real NV12,
        // respecting source and destination strides, including odd dimensions.
        const uint32_t i420 = ((uint32_t)'I') | ((uint32_t)'4' << 8) | ((uint32_t)'2' << 16) | ((uint32_t)'0' << 24);
        int w = overlay->w, h = overlay->h, cw = (w + 1) / 2, ch = (h + 1) / 2;
        if (overlay->format != i420 || overlay->planes != 3 || !overlay->pixels || !overlay->pitches ||
            !overlay->pixels[0] || !overlay->pixels[1] || !overlay->pixels[2] ||
            overlay->pitches[0] < w || overlay->pitches[1] < cw || overlay->pitches[2] < cw || w > 8192 || h > 8192) {
            [self reportError:@"IJK sample-buffer output: unsupported software overlay (requires valid I420)"];
            return;
        }
        // Only ff_vout touches the software pool; queued buffers retain their
        // own storage across pool rebuilds. Allocation cap bounds producer load.
        if (!_pool || _poolWidth != w || _poolHeight != h) {
            if (_pool) { CVPixelBufferPoolRelease(_pool); _pool = NULL; }
            NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{},
                (id)kCVPixelBufferWidthKey: @(w), (id)kCVPixelBufferHeightKey: @(h),
                (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)};
            CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)attributes, &_pool);
            _poolWidth = w; _poolHeight = h;
        }
        NSDictionary *limits = @{(id)kCVPixelBufferPoolAllocationThresholdKey: @6};
        CVReturn result = _pool ? CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, _pool,
            (__bridge CFDictionaryRef)limits, &buffer) : kCVReturnAllocationFailed;
        if (result == kCVReturnWouldExceedAllocationThreshold) return; // Backpressure, never invent a frame.
        if (result != kCVReturnSuccess || !buffer) {
            [self reportError:@"IJK sample-buffer output: pixel-buffer allocation failed"]; return;
        }
        if (CVPixelBufferLockBaseAddress(buffer, 0) != kCVReturnSuccess) {
            CVPixelBufferRelease(buffer); [self reportError:@"IJK sample-buffer output: pixel-buffer lock failed"]; return;
        }
        uint8_t *y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0), *uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1);
        size_t ys = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), uvs = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1);
        for (int row = 0; row < h; ++row) memcpy(y + row * ys, overlay->pixels[0] + row * overlay->pitches[0], w);
        for (int row = 0; row < ch; ++row) {
            const uint8_t *u = overlay->pixels[1] + row * overlay->pitches[1], *v = overlay->pixels[2] + row * overlay->pitches[2];
            for (int col = 0; col < cw; ++col) { uv[row * uvs + 2 * col] = u[col]; uv[row * uvs + 2 * col + 1] = v[col]; }
        }
        CVPixelBufferUnlockBaseAddress(buffer, 0);
    }
    os_unfair_lock_lock(&_lock);
    if (_closed || generation != _generation) { os_unfair_lock_unlock(&_lock); CVPixelBufferRelease(buffer); return; }
    if (_pending) CVPixelBufferRelease(_pending);
    _pending = buffer;
    _pts = overlay->pts; _duration = overlay->duration; _serial = overlay->serial;
    BOOL schedule = !_scheduled;
    _scheduled = YES;
    os_unfair_lock_unlock(&_lock);
    if (schedule) dispatch_async(dispatch_get_main_queue(), ^{ [self drain]; });
}
- (void)drain {
    NSAssert(NSThread.isMainThread, @"Layer operations require main thread");
    os_unfair_lock_lock(&_lock);
    CVPixelBufferRef buffer = _pending; _pending = NULL; _scheduled = NO;
    if (!buffer) { os_unfair_lock_unlock(&_lock); return; }
    double pts = _pts, duration = _duration;
    int serial = _serial;
    BOOL closed = _closed;
    BOOL discontinuity = _waitingSerial || (_hasSerial && serial != _lastSerial);
    _waitingSerial = NO; _lastSerial = serial; _hasSerial = YES;
    os_unfair_lock_unlock(&_lock);
    if (closed) { CVPixelBufferRelease(buffer); return; }
    if (discontinuity || self.displayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) [self.displayLayer flushAndRemoveImage];
    CMVideoFormatDescriptionRef description = NULL;
    CMSampleBufferRef sample = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, buffer, &description);
    CMSampleTimingInfo timing = {isfinite(duration) && duration > 0 ? CMTimeMakeWithSeconds(duration, 1000000) : kCMTimeInvalid,
                                CMTimeMakeWithSeconds(pts, 1000000), kCMTimeInvalid};
    if (status == noErr) status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, buffer, description, &timing, &sample);
    if (status == noErr) {
        // IJK has already waited/dropped against its audio master. Do not add a
        // second independent scheduler; preserve PTS for media/PiP time mapping.
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, true);
        CFDictionarySetValue((CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0), kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
        if (self.displayLayer.readyForMoreMediaData) [self.displayLayer enqueueSampleBuffer:sample];
    } else [self reportError:@"IJK sample-buffer output: sample creation failed"];
    if (sample) CFRelease(sample);
    if (description) CFRelease(description);
    CVPixelBufferRelease(buffer);
}
- (void)updateClock:(double)seconds rate:(double)rate {
    NSAssert(NSThread.isMainThread, @"Timebase operations require main thread");
    if (_timebase && isfinite(seconds) && isfinite(rate)) {
        CMTimebaseSetTime(_timebase, CMTimeMakeWithSeconds(seconds, 1000000));
        CMTimebaseSetRate(_timebase, rate);
    }
}
- (void)invalidateForSeek {
    NSAssert(NSThread.isMainThread, @"Seek invalidation requires main thread");
    os_unfair_lock_lock(&_lock);
    ++_generation; _waitingSerial = YES;
    if (_pending) { CVPixelBufferRelease(_pending); _pending = NULL; }
    os_unfair_lock_unlock(&_lock);
    [self.displayLayer flushAndRemoveImage];
}
- (void)close {
    NSAssert(NSThread.isMainThread, @"Close requires main thread");
    os_unfair_lock_lock(&_lock);
    _closed = YES; ++_generation;
    if (_pending) { CVPixelBufferRelease(_pending); _pending = NULL; }
    os_unfair_lock_unlock(&_lock);
    self.renderError = nil;
    [self.displayLayer flushAndRemoveImage];
}
- (void)dealloc {
    if (_pending) CVPixelBufferRelease(_pending);
    if (_timebase) CFRelease(_timebase);
    if (_pool) CVPixelBufferPoolRelease(_pool);
}
@end
