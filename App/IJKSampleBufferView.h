#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <IJKMediaFramework/IJKMediaFramework.h>
#import <IJKMediaFramework/IJKSDLGLViewProtocol.h>

NS_ASSUME_NONNULL_BEGIN
/// Actual IJK render frames. No screen capture and no secondary player.
@interface IJKSampleBufferView : UIView <IJKSDLGLViewProtocol>
@property(nonatomic, readonly) AVSampleBufferDisplayLayer *displayLayer;
@property(nonatomic, copy, nullable) void (^renderError)(NSString *message);
+ (IJKFFMoviePlayerController * _Nullable)makePlayerWithURL:(NSURL *)url
    options:(IJKFFOptions *)options renderer:(IJKSampleBufferView *)renderer NS_SWIFT_NAME(makePlayer(url:options:renderer:));
- (void)updateClock:(double)seconds rate:(double)rate NS_SWIFT_NAME(updateClock(_:rate:));
- (void)beginSeekTo:(double)target NS_SWIFT_NAME(beginSeek(to:));
- (void)confirmSeek NS_SWIFT_NAME(confirmSeek());
- (void)cancelSeek NS_SWIFT_NAME(cancelSeek());
- (void)close;
@end
NS_ASSUME_NONNULL_END
