#import "AmerBackgroundPlugin.h"
#import <Vision/Vision.h>
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/message.h>

// flutter_webrtc ships as a Swift package and this plugin as a CocoaPod, which cannot link to each other. So the
// WebRTC classes are reached at run time through the Objective-C runtime: FlutterWebRTCPlugin.sharedSingleton,
// its localTracks, LocalVideoTrack addProcessing:/removeProcessing:, and RTCCVPixelBuffer / RTCVideoFrame.
// The processor implements flutter_webrtc's ExternalVideoProcessingDelegate method -onFrame:.

@interface AmerBlur : NSObject
@property(nonatomic) int radius; @property(nonatomic) BOOL lowLight; @property(nonatomic, strong) CIContext *ctx;
- (id)onFrame:(id)frame;
@end

@implementation AmerBlur
- (id)onFrame:(id)frame {
  @try {
    id buffer = [frame valueForKey:@"buffer"];
    Class pbClass = NSClassFromString(@"RTCCVPixelBuffer");
    if (!pbClass || ![buffer isKindOfClass:pbClass]) return frame;
    CVPixelBufferRef pb = ((CVPixelBufferRef (*)(id, SEL))objc_msgSend)(buffer, NSSelectorFromString(@"pixelBuffer"));
    if (!pb) return frame;
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
    id rb = ((id (*)(id, SEL, CVPixelBufferRef))objc_msgSend)([pbClass alloc], NSSelectorFromString(@"initWithPixelBuffer:"), dst);
    CVPixelBufferRelease(dst);
    NSInteger rotation = ((NSInteger (*)(id, SEL))objc_msgSend)(frame, NSSelectorFromString(@"rotation"));
    int64_t ts = ((int64_t (*)(id, SEL))objc_msgSend)(frame, NSSelectorFromString(@"timeStampNs"));
    Class fc = NSClassFromString(@"RTCVideoFrame"); if (!fc || !rb) return frame;
    return ((id (*)(id, SEL, id, NSInteger, int64_t))objc_msgSend)([fc alloc], NSSelectorFromString(@"initWithBuffer:rotation:timeStampNs:"), rb, rotation, ts);
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
  Class pc = NSClassFromString(@"FlutterWebRTCPlugin"); Class vt = NSClassFromString(@"LocalVideoTrack");
  if (!pc || !vt) { result(@NO); return; }
  id plugin = ((id (*)(id, SEL))objc_msgSend)(pc, NSSelectorFromString(@"sharedSingleton"));
  id track = [[plugin valueForKey:@"localTracks"] objectForKey:tid];
  if (![track isKindOfClass:vt]) { result(@NO); return; }
  SEL add = NSSelectorFromString(@"addProcessing:"), rm = NSSelectorFromString(@"removeProcessing:");
  AmerBlur *old = _active[tid]; if (old) { ((void (*)(id, SEL, id))objc_msgSend)(track, rm, old); [_active removeObjectForKey:tid]; }
  if (blur > 0 || low) { AmerBlur *b = [AmerBlur new]; b.radius = blur; b.lowLight = low; b.ctx = [CIContext context]; ((void (*)(id, SEL, id))objc_msgSend)(track, add, b); _active[tid] = b; }
  result(@YES);
}
@end
