#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <IJKMediaFramework/IJKMediaFramework.h>
#import <IJKMediaFramework/IJKSDLGLViewProtocol.h>

NS_ASSUME_NONNULL_BEGIN
/// Actual IJK render frames. No screen capture and no secondary player.
@interface IJKSampleBufferView : UIView <IJKSDLGLViewProtocol>
@property(nonatomic, readonly) AVSampleBufferDisplayLayer *displayLayer;
@property(nonatomic, copy, nullable) void (^renderError)(NSString *message);
@property(nonatomic, copy, nullable) void (^seekFrameDisplayed)(int serial);
/// Main-thread callback for an actually enqueued frame's display aspect ratio (includes SAR).
@property(nonatomic, copy, nullable) void (^videoDisplayAspectChanged)(double aspect);
+ (IJKFFMoviePlayerController * _Nullable)makePlayerWithURL:(NSURL *)url
    options:(IJKFFOptions *)options renderer:(IJKSampleBufferView *)renderer NS_SWIFT_NAME(makePlayer(url:options:renderer:));
- (void)updateClock:(double)seconds rate:(double)rate NS_SWIFT_NAME(updateClock(_:rate:));
- (void)beginSeekTo:(double)target NS_SWIFT_NAME(beginSeek(to:));
- (void)confirmSeekWithSerial:(int)serial NS_SWIFT_NAME(confirmSeek(serial:));
- (void)cancelSeek NS_SWIFT_NAME(cancelSeek());
- (void)close;
@end
NS_ASSUME_NONNULL_END
