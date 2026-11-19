#import "AmerBackgroundPlugin.h"
#import <Vision/Vision.h>
#import <CoreImage/CoreImage.h>
#import <flutter_webrtc/FlutterWebRTCPlugin.h>
#import <flutter_webrtc/LocalVideoTrack.h>
#import <flutter_webrtc/VideoProcessingAdapter.h>
#import <WebRTC/WebRTC.h>

/// One frame: person mask (Vision, iOS 15+) -> blurred background + sharp person, optional brightening.
@interface AmerBlur : NSObject<ExternalVideoProcessingDelegate>
@property(nonatomic) int radius; @property(nonatomic) BOOL lowLight; @property(nonatomic, strong) CIContext *ctx;
@end
@implementation AmerBlur
- (RTCVideoFrame *)onFrame:(RTCVideoFrame *)frame {
  @try {
    if (![frame.buffer isKindOfClass:[RTCCVPixelBuffer class]]) return frame;
    CVPixelBufferRef pb = ((RTCCVPixelBuffer *)frame.buffer).pixelBuffer;
    CIImage *img = [CIImage imageWithCVPixelBuffer:pb]; CIImage *out = img;
    if (self.lowLight) out = [out imageByApplyingFilter:@"CIColorControls" withInputParameters:@{@"inputBrightness": @0.08, @"inputContrast": @1.1}];
    if (self.radius > 0) {
      if (@available(iOS 15.0, *)) {
        VNGeneratePersonSegmentationRequest *req = [VNGeneratePersonSegmentationRequest new];
        req.qualityLevel = VNGeneratePersonSegmentationRequestQualityLevelBalanced;
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8;
        [[[VNImageRequestHandler alloc] initWithCVPixelBuffer:pb options:@{}] performRequests:@[req] error:nil];
        CVPixelBufferRef m = req.results.firstObject.pixelBuffer;
        if (m) {
          CIImage *mask = [CIImage imageWithCVPixelBuffer:m];
          mask = [mask imageByApplyingTransform:CGAffineTransformMakeScale(img.extent.size.width / mask.extent.size.width, img.extent.size.height / mask.extent.size.height)];
          CIImage *bg = [[[out imageByClampingToExtent] imageByApplyingGaussianBlurWithSigma:self.radius] imageByCroppingToRect:img.extent];
          out = [out imageByApplyingFilter:@"CIBlendWithMask" withInputParameters:@{kCIInputBackgroundImageKey: bg, kCIInputMaskImageKey: mask}];
        }
      }
    }
    CVPixelBufferRef dst = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault, CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), CVPixelBufferGetPixelFormatType(pb),
                        (__bridge CFDictionaryRef)@{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}}, &dst);
    if (!dst) return frame;
    [self.ctx render:out toCVPixelBuffer:dst];
    RTCCVPixelBuffer *rb = [[RTCCVPixelBuffer alloc] initWithPixelBuffer:dst]; CVPixelBufferRelease(dst);
    return [[RTCVideoFrame alloc] initWithBuffer:rb rotation:frame.rotation timeStampNs:frame.timeStampNs];
  } @catch (NSException *e) { return frame; }   // never drop video because of an effect
}
@end

@implementation AmerBackgroundPlugin { NSMutableDictionary<NSString *, AmerBlur *> *_active; }
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)r {
  AmerBackgroundPlugin *p = [AmerBackgroundPlugin new]; p->_active = [NSMutableDictionary new];
  [r addMethodCallDelegate:p channel:[FlutterMethodChannel methodChannelWithName:@"com.amerteams/background" binaryMessenger:[r messenger]]];
}
- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  if (![call.method isEqualToString:@"apply"]) { result(FlutterMethodNotImplemented); return; }
  NSString *tid = call.arguments[@"trackId"]; int blur = [call.arguments[@"blur"] intValue]; BOOL low = [call.arguments[@"lowLight"] boolValue];
  id t = [FlutterWebRTCPlugin sharedSingleton].localTracks[tid];
  if (![t isKindOfClass:[LocalVideoTrack class]]) { result(@NO); return; }
  LocalVideoTrack *track = t;
  AmerBlur *old = _active[tid]; if (old) { [track removeProcessing:old]; [_active removeObjectForKey:tid]; }
  if (blur > 0 || low) { AmerBlur *b = [AmerBlur new]; b.radius = blur; b.lowLight = low; b.ctx = [CIContext context]; [track addProcessing:b]; _active[tid] = b; }
  result(@YES);
}
@end
