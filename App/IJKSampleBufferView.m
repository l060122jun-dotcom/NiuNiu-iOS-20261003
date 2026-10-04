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
    BOOL _seekConfirmed;
    int _seekSerial;
    BOOL _seekAckPending;
    BOOL _hasAcceptedSerial;
    int _acceptedSerial;
    uint64_t _generation;
    CMTimebaseRef _timebase;
    CVPixelBufferPoolRef _pool;
    int _poolWidth, _poolHeight;
    BOOL _errorReported;
    double _lastDisplayAspect;
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
    BOOL reject = _closed || (_waitingSerial && _seekConfirmed && overlay->serial != _seekSerial) ||
        (!_waitingSerial && _hasAcceptedSerial && overlay->serial < _acceptedSerial);
    uint64_t generation = _generation;
    os_unfair_lock_unlock(&_lock);
    if (reject) return;
    if (overlay->w <= 0 || overlay->h <= 0 || overlay->w > 8192 || overlay->h > 8192) {
        [self reportError:@"IJK sample-buffer output: invalid frame dimensions or PTS"];
        return;
    }
    CVPixelBufferRef buffer = NULL;
    if (overlay->pixel_buffer) {
        if (CVPixelBufferGetWidth(overlay->pixel_buffer) != (size_t)overlay->w ||
            CVPixelBufferGetHeight(overlay->pixel_buffer) != (size_t)overlay->h) {
            [self reportError:@"IJK sample-buffer output: hardware buffer dimensions mismatch"]; return;
        }
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
        // Capacity comes from retained AVBufferRef storage, not inferred from
        // pitch alone. Last-row requirement avoids assuming trailing padding.
        for (int plane = 0; plane < 3; ++plane) {
            size_t rows = plane == 0 ? (size_t)h : (size_t)ch;
            size_t bytes = plane == 0 ? (size_t)w : (size_t)cw;
            size_t needed = (rows - 1) * (size_t)overlay->pitches[plane] + bytes;
            if (overlay->plane_bytes[plane] < needed) {
                [self reportError:@"IJK sample-buffer output: insufficient source plane capacity"]; return;
            }
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
        if (CVPixelBufferGetPlaneCount(buffer) != 2) {
            CVPixelBufferUnlockBaseAddress(buffer, 0); CVPixelBufferRelease(buffer);
            [self reportError:@"IJK sample-buffer output: destination is not two-plane NV12"]; return;
        }
        uint8_t *y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0), *uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1);
        size_t ys = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), uvs = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1);
        if (CVPixelBufferGetPlaneCount(buffer) != 2 || !y || !uv || ys < (size_t)w || uvs < (size_t)cw * 2 ||
            CVPixelBufferGetWidthOfPlane(buffer, 0) < (size_t)w || CVPixelBufferGetHeightOfPlane(buffer, 0) < (size_t)h ||
            CVPixelBufferGetWidthOfPlane(buffer, 1) < (size_t)cw || CVPixelBufferGetHeightOfPlane(buffer, 1) < (size_t)ch) {
            CVPixelBufferUnlockBaseAddress(buffer, 0); CVPixelBufferRelease(buffer);
            [self reportError:@"IJK sample-buffer output: insufficient NV12 destination plane capacity"]; return;
        }
        for (int row = 0; row < h; ++row) memcpy(y + row * ys, overlay->pixels[0] + row * overlay->pitches[0], w);
        for (int row = 0; row < ch; ++row) {
            const uint8_t *u = overlay->pixels[1] + row * overlay->pitches[1], *v = overlay->pixels[2] + row * overlay->pitches[2];
            for (int col = 0; col < cw; ++col) { uv[row * uvs + 2 * col] = u[col]; uv[row * uvs + 2 * col + 1] = v[col]; }
        }
        CVPixelBufferUnlockBaseAddress(buffer, 0);
    }
    // Always overwrite pooled/decoder attachments, including square-pixel
    // fallback, before creating the format description on the main thread.
    int sarNum = overlay->sar_num > 0 && overlay->sar_den > 0 ? overlay->sar_num : 1;
    int sarDen = overlay->sar_num > 0 && overlay->sar_den > 0 ? overlay->sar_den : 1;
    NSDictionary *aspect = @{(id)kCVImageBufferPixelAspectRatioHorizontalSpacingKey: @(sarNum),
                             (id)kCVImageBufferPixelAspectRatioVerticalSpacingKey: @(sarDen)};
    CVBufferSetAttachment(buffer, kCVImageBufferPixelAspectRatioKey, (__bridge CFDictionaryRef)aspect, kCVAttachmentMode_ShouldPropagate);
    os_unfair_lock_lock(&_lock);
    // Confirmation can arrive while pixels are copied outside the lock. Recheck
    // the exact serial under the SAME lock as acceptance, not just generation.
    if (_closed || generation != _generation ||
        (_waitingSerial && _seekConfirmed && overlay->serial != _seekSerial) ||
        (!_waitingSerial && _hasAcceptedSerial && overlay->serial < _acceptedSerial)) {
        os_unfair_lock_unlock(&_lock); CVPixelBufferRelease(buffer); return;
    }
    if (_waitingSerial && _seekConfirmed) {
        // Latch the exact completion serial at acceptance, NOT drain.
        // Subsequent seek increments generation even when this hasn't drained.
        _waitingSerial = NO; _hasSerial = NO;
    }
    _acceptedSerial = overlay->serial; _hasAcceptedSerial = YES;
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
    if (_waitingSerial && !_seekConfirmed) {
        _scheduled = NO; os_unfair_lock_unlock(&_lock); return;
    }
    CVPixelBufferRef buffer = _pending; _pending = NULL; _scheduled = NO;
    if (!buffer) { os_unfair_lock_unlock(&_lock); return; }
    double pts = _pts, duration = _duration;
    int serial = _serial;
    BOOL closed = _closed;
    BOOL discontinuity = _waitingSerial || (_hasSerial && serial != _lastSerial);
    _waitingSerial = NO; _lastSerial = serial; _hasSerial = YES;
    os_unfair_lock_unlock(&_lock);
    if (closed) { CVPixelBufferRelease(buffer); return; }
    // Keep the previous image until an actual replacement sample is ready.
    CMVideoFormatDescriptionRef description = NULL;
    CMSampleBufferRef sample = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, buffer, &description);
    CMSampleTimingInfo timing = {isfinite(duration) && duration > 0 ? CMTimeMakeWithSeconds(duration, 1000000) : kCMTimeInvalid,
                                isfinite(pts) ? CMTimeMakeWithSeconds(pts, 1000000) : kCMTimeInvalid, kCMTimeInvalid};
    if (status == noErr) status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, buffer, description, &timing, &sample);
    if (status == noErr) {
        // IJK has already waited/dropped against its audio master. Do not add a
        // second independent scheduler; preserve PTS for media/PiP time mapping.
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, true);
        CFDictionarySetValue((CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0), kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
        if (discontinuity || self.displayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) [self.displayLayer flush];
        if (self.displayLayer.readyForMoreMediaData) {
            [self.displayLayer enqueueSampleBuffer:sample];
            // Use the SAME accepted sample, not coded stream dimensions. CoreMedia
            // presentation dimensions include the propagated pixel-aspect ratio.
            // Filtered/autorotated overlays already have their final dimensions;
            // never apply stream rotation again to this sample-buffer layer.
            CGSize displaySize = CMVideoFormatDescriptionGetPresentationDimensions(description, true, false);
            double aspect = displaySize.height > 0 ? displaySize.width / displaySize.height : 0;
            if (isfinite(aspect) && aspect > 0 &&
                (_lastDisplayAspect == 0 || fabs(aspect - _lastDisplayAspect) > 0.0001)) {
                _lastDisplayAspect = aspect;
                if (self.videoDisplayAspectChanged) self.videoDisplayAspectChanged(aspect);
            }
            os_unfair_lock_lock(&_lock);
            BOOL acknowledge = _seekAckPending && _seekConfirmed && serial == _seekSerial;
            if (acknowledge) _seekAckPending = NO;
            os_unfair_lock_unlock(&_lock);
            if (acknowledge && self.seekFrameDisplayed) self.seekFrameDisplayed(serial);
        }
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
- (void)beginSeekTo:(double)target {
    NSAssert(NSThread.isMainThread, @"Seek invalidation requires main thread");
    os_unfair_lock_lock(&_lock);
    ++_generation; _waitingSerial = YES; _seekConfirmed = NO; _seekAckPending = YES;
    if (_pending) { CVPixelBufferRelease(_pending); _pending = NULL; }
    os_unfair_lock_unlock(&_lock);
    // No immediate image removal: retain last real frame while seek is pending.
}
- (void)confirmSeekWithSerial:(int)serial {
    NSAssert(NSThread.isMainThread, @"Seek confirmation requires main thread");
    os_unfair_lock_lock(&_lock);
    _seekSerial = serial; _seekConfirmed = YES;
    if (_pending && _serial != serial) { CVPixelBufferRelease(_pending); _pending = NULL; }
    BOOL schedule = _pending && !_scheduled;
    if (schedule) _scheduled = YES;
    os_unfair_lock_unlock(&_lock);
    if (schedule) dispatch_async(dispatch_get_main_queue(), ^{ [self drain]; });
}
- (void)cancelSeek {
    NSAssert(NSThread.isMainThread, @"Seek cancellation requires main thread");
    os_unfair_lock_lock(&_lock);
    ++_generation; _waitingSerial = NO; _seekConfirmed = NO; _seekAckPending = NO; _hasSerial = NO; _hasAcceptedSerial = NO;
    if (_pending) { CVPixelBufferRelease(_pending); _pending = NULL; }
    os_unfair_lock_unlock(&_lock);
    [self.displayLayer flush];
}
- (void)close {
    NSAssert(NSThread.isMainThread, @"Close requires main thread");
    os_unfair_lock_lock(&_lock);
    _closed = YES; ++_generation;
    if (_pending) { CVPixelBufferRelease(_pending); _pending = NULL; }
    os_unfair_lock_unlock(&_lock);
    self.renderError = nil;
    self.seekFrameDisplayed = nil;
    self.videoDisplayAspectChanged = nil;
    [self.displayLayer flushAndRemoveImage];
}
- (void)dealloc {
    if (_pending) CVPixelBufferRelease(_pending);
    if (_timebase) CFRelease(_timebase);
    if (_pool) CVPixelBufferPoolRelease(_pool);
}
@end
