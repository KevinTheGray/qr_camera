// Copyright 2019 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "CameraPlugin.h"
#import <AVFoundation/AVFoundation.h>
#import <Accelerate/Accelerate.h>
#import <CoreMotion/CoreMotion.h>
#import <libkern/OSAtomic.h>
#import <VideoToolbox/VideoToolbox.h>

static FlutterError *getFlutterError(NSError *error) {
  return [FlutterError errorWithCode:[NSString stringWithFormat:@"Error %d", (int)error.code]
                             message:error.localizedDescription
                             details:error.domain];
}

@interface FLTSavePhotoDelegate : NSObject <AVCapturePhotoCaptureDelegate>
@property(readonly, nonatomic) NSString *path;
@property(readonly, nonatomic) FlutterResult result;
@property(readonly, nonatomic) AVCaptureDevicePosition cameraPosition;

- initWithPath:(NSString *)filename
            result:(FlutterResult)result
    cameraPosition:(AVCaptureDevicePosition)cameraPosition;
@end

@interface FLTImageStreamHandler : NSObject <FlutterStreamHandler>
@property FlutterEventSink eventSink;
@end

@implementation FLTImageStreamHandler

- (FlutterError *_Nullable)onCancelWithArguments:(id _Nullable)arguments {
  _eventSink = nil;
  return nil;
}

- (FlutterError *_Nullable)onListenWithArguments:(id _Nullable)arguments
                                       eventSink:(nonnull FlutterEventSink)events {
  _eventSink = events;
  return nil;
}
@end

@implementation FLTSavePhotoDelegate {
  /// Used to keep the delegate alive until didFinishProcessingPhotoSampleBuffer.
  FLTSavePhotoDelegate *selfReference;
}

- initWithPath:(NSString *)path
            result:(FlutterResult)result
    cameraPosition:(AVCaptureDevicePosition)cameraPosition {
  self = [super init];
  NSAssert(self, @"super init cannot be nil");
  _path = path;
  _result = result;
  _cameraPosition = cameraPosition;
  selfReference = self;
  return self;
}
@end

// Mirrors ResolutionPreset in camera.dart
typedef enum {
  veryLow,
  low,
  medium,
  high,
  veryHigh,
  ultraHigh,
  max,
} ResolutionPreset;

static ResolutionPreset getResolutionPresetForString(NSString *preset) {
  if ([preset isEqualToString:@"veryLow"]) {
    return veryLow;
  } else if ([preset isEqualToString:@"low"]) {
    return low;
  } else if ([preset isEqualToString:@"medium"]) {
    return medium;
  } else if ([preset isEqualToString:@"high"]) {
    return high;
  } else if ([preset isEqualToString:@"veryHigh"]) {
    return veryHigh;
  } else if ([preset isEqualToString:@"ultraHigh"]) {
    return ultraHigh;
  } else if ([preset isEqualToString:@"max"]) {
    return max;
  } else {
    NSError *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:NSURLErrorUnknown
                                     userInfo:@{
                                       NSLocalizedDescriptionKey : [NSString
                                           stringWithFormat:@"Unknown resolution preset %@", preset]
                                     }];
    @throw error;
  }
}

@interface FLTCam : NSObject <FlutterTexture,
                              AVCaptureVideoDataOutputSampleBufferDelegate,
                              AVCaptureAudioDataOutputSampleBufferDelegate,
                              FlutterStreamHandler>
@property(readonly, nonatomic) int64_t textureId;
@property(nonatomic, copy) void (^onFrameAvailable)();
@property(nonatomic) FlutterEventChannel *eventChannel;
@property(nonatomic) FLTImageStreamHandler *imageStreamHandler;
@property(nonatomic) FlutterEventSink eventSink;
@property(readonly, nonatomic) AVCaptureSession *captureSession;
@property(readonly, nonatomic) AVCaptureDevice *captureDevice;
@property(readonly, nonatomic) AVCaptureVideoDataOutput *captureVideoOutput;
@property(readonly, nonatomic) AVCaptureInput *captureVideoInput;
@property(readonly) CVPixelBufferRef volatile latestPixelBuffer;
@property(readonly, nonatomic) CGSize previewSize;
@property(readonly, nonatomic) CGSize captureSize;
@property(strong, nonatomic) AVCaptureVideoDataOutput *videoOutput;
@property(strong, nonatomic) AVCaptureAudioDataOutput *audioOutput;
@property(assign, nonatomic) BOOL isScanningQrCodes;
@property(assign, nonatomic) ResolutionPreset resolutionPreset;
- (instancetype)initWithCameraName:(NSString *)cameraName
                  resolutionPreset:(NSString *)resolutionPreset
                     dispatchQueue:(dispatch_queue_t)dispatchQueue
                             error:(NSError **)error;

- (void)start;
- (void)stop;
- (void)startScanningForQrCodesWithMessenger:(NSObject<FlutterBinaryMessenger> *)messenger;
- (void)stopScanningForQrCodes;
@end

@implementation FLTCam {
  dispatch_queue_t _dispatchQueue;
}
// Format used for video and image streaming.
FourCharCode const videoFormat = kCVPixelFormatType_32BGRA;

- (instancetype)initWithCameraName:(NSString *)cameraName
                  resolutionPreset:(NSString *)resolutionPreset
                     dispatchQueue:(dispatch_queue_t)dispatchQueue
                             error:(NSError **)error {
  self = [super init];
  NSAssert(self, @"super init cannot be nil");
  @try {
    _resolutionPreset = getResolutionPresetForString(resolutionPreset);
  } @catch (NSError *e) {
    *error = e;
  }
  _dispatchQueue = dispatchQueue;
  _captureSession = [[AVCaptureSession alloc] init];

  _captureDevice = [AVCaptureDevice deviceWithUniqueID:cameraName];
  NSError *localError = nil;
  _captureVideoInput = [AVCaptureDeviceInput deviceInputWithDevice:_captureDevice
                                                             error:&localError];
  if (localError) {
    *error = localError;
    return nil;
  }

  _captureVideoOutput = [AVCaptureVideoDataOutput new];
  _captureVideoOutput.videoSettings =
      @{(NSString *)kCVPixelBufferPixelFormatTypeKey : @(videoFormat)};
  [_captureVideoOutput setAlwaysDiscardsLateVideoFrames:YES];
  [_captureVideoOutput setSampleBufferDelegate:self queue:dispatch_get_main_queue()];

  AVCaptureConnection *connection =
      [AVCaptureConnection connectionWithInputPorts:_captureVideoInput.ports
                                             output:_captureVideoOutput];
  if ([_captureDevice position] == AVCaptureDevicePositionFront) {
    connection.videoMirrored = YES;
  }
  connection.videoOrientation = AVCaptureVideoOrientationPortrait;
  [_captureSession addInputWithNoConnections:_captureVideoInput];
  [_captureSession addOutputWithNoConnections:_captureVideoOutput];
  [_captureSession addConnection:connection];

  [self setCaptureSessionPreset:_resolutionPreset];
  return self;
}

- (void)start {
  [_captureSession startRunning];
}

- (void)stop {
  [_captureSession stopRunning];
}

- (void)setCaptureSessionPreset:(ResolutionPreset)resolutionPreset {
  switch (resolutionPreset) {
    case max:
      if ([_captureSession canSetSessionPreset:AVCaptureSessionPresetHigh]) {
        _captureSession.sessionPreset = AVCaptureSessionPresetHigh;
        _previewSize =
            CGSizeMake(_captureDevice.activeFormat.highResolutionStillImageDimensions.width,
                       _captureDevice.activeFormat.highResolutionStillImageDimensions.height);
        break;
      }
    case ultraHigh:
      if ([_captureSession canSetSessionPreset:AVCaptureSessionPreset3840x2160]) {
        _captureSession.sessionPreset = AVCaptureSessionPreset3840x2160;
        _previewSize = CGSizeMake(3840, 2160);
        break;
      }
    case veryHigh:
      if ([_captureSession canSetSessionPreset:AVCaptureSessionPreset1920x1080]) {
        _captureSession.sessionPreset = AVCaptureSessionPreset1920x1080;
        _previewSize = CGSizeMake(1920, 1080);
        break;
      }
    case high:
      if ([_captureSession canSetSessionPreset:AVCaptureSessionPreset1280x720]) {
        _captureSession.sessionPreset = AVCaptureSessionPreset1280x720;
        _previewSize = CGSizeMake(1280, 720);
        break;
      }
    case medium:
      if ([_captureSession canSetSessionPreset:AVCaptureSessionPreset640x480]) {
        _captureSession.sessionPreset = AVCaptureSessionPreset640x480;
        _previewSize = CGSizeMake(640, 480);
        break;
      }
    case low:
      if ([_captureSession canSetSessionPreset:AVCaptureSessionPreset352x288]) {
        _captureSession.sessionPreset = AVCaptureSessionPreset352x288;
        _previewSize = CGSizeMake(352, 288);
        break;
      }
    default:
      if ([_captureSession canSetSessionPreset:AVCaptureSessionPresetLow]) {
        _captureSession.sessionPreset = AVCaptureSessionPresetLow;
        _previewSize = CGSizeMake(352, 288);
      } else {
        NSError *error =
            [NSError errorWithDomain:NSCocoaErrorDomain
                                code:NSURLErrorUnknown
                            userInfo:@{
                              NSLocalizedDescriptionKey :
                                  @"No capture session available for current capture session."
                            }];
        @throw error;
      }
  }
}

- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection {
  if (output == _captureVideoOutput) {
    CVPixelBufferRef newBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    CFRetain(newBuffer);
    CVPixelBufferRef old = _latestPixelBuffer;
    while (!OSAtomicCompareAndSwapPtrBarrier(old, newBuffer, (void **)&_latestPixelBuffer)) {
      old = _latestPixelBuffer;
    }
    if (old != nil) {
      CFRelease(old);
    }
    if (_onFrameAvailable) {
      _onFrameAvailable();
    }
  }
  if (!CMSampleBufferDataIsReady(sampleBuffer)) {
    _eventSink(@{
      @"event" : @"error",
      @"errorDescription" : @"sample buffer is not ready. Skipping sample"
    });
    return;
  }
  if (_isScanningQrCodes) {
    if (_imageStreamHandler.eventSink) {
      CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
      CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
      
      NSDictionary* options;
      CIContext* context = [CIContext context];
      options = @{ CIDetectorAccuracy : CIDetectorAccuracyHigh };

      CIDetector* qrDetector = [CIDetector detectorOfType:CIDetectorTypeQRCode
                                                  context:context
                                                  options:options];
      if ([[ciImage properties] valueForKey:(NSString*) kCGImagePropertyOrientation] == nil) {
          options = @{ CIDetectorImageOrientation : @1};
      } else {
          options = @{ CIDetectorImageOrientation : [[ciImage properties] valueForKey:(NSString*) kCGImagePropertyOrientation]};
      }
      NSArray * features = [qrDetector featuresInImage:ciImage
                                               options:options];
      if (features != nil && features.count > 0) {
        CIQRCodeFeature* qrFeature = features[0];
        _imageStreamHandler.eventSink([NSString stringWithFormat:@"%@", qrFeature.messageString]);
      }
    }
  }
}

- (void)close {
  [_captureSession stopRunning];
  for (AVCaptureInput *input in [_captureSession inputs]) {
    [_captureSession removeInput:input];
  }
  for (AVCaptureOutput *output in [_captureSession outputs]) {
    [_captureSession removeOutput:output];
  }
}

- (void)dealloc {
  if (_latestPixelBuffer) {
    CFRelease(_latestPixelBuffer);
  }
}

- (CVPixelBufferRef)copyPixelBuffer {
  CVPixelBufferRef pixelBuffer = _latestPixelBuffer;
  while (!OSAtomicCompareAndSwapPtrBarrier(pixelBuffer, nil, (void **)&_latestPixelBuffer)) {
    pixelBuffer = _latestPixelBuffer;
  }

  return pixelBuffer;
}

- (FlutterError *_Nullable)onCancelWithArguments:(id _Nullable)arguments {
  _eventSink = nil;
  // need to unregister stream handler when disposing the camera
  [_eventChannel setStreamHandler:nil];
  return nil;
}

- (FlutterError *_Nullable)onListenWithArguments:(id _Nullable)arguments
                                       eventSink:(nonnull FlutterEventSink)events {
  _eventSink = events;
  return nil;
}

- (void)startScanningForQrCodesWithMessenger:(NSObject<FlutterBinaryMessenger> *)messenger {
  if (!_isScanningQrCodes) {
    FlutterEventChannel *eventChannel =
        [FlutterEventChannel eventChannelWithName:@"plugins.flutter.io/qr_camera/qrCodeStream"
                                  binaryMessenger:messenger];

    _imageStreamHandler = [[FLTImageStreamHandler alloc] init];
    [eventChannel setStreamHandler:_imageStreamHandler];

    _isScanningQrCodes = YES;
  } else {
    _eventSink(
        @{@"event" : @"error", @"errorDescription" : @"Images from camera are already streaming!"});
  }
}

- (void)stopScanningForQrCodes {
  if (_isScanningQrCodes) {
    _isScanningQrCodes = NO;
    _imageStreamHandler = nil;
  } else {
    _eventSink(
        @{@"event" : @"error", @"errorDescription" : @"Images from camera are not streaming!"});
  }
}
@end

@interface CameraPlugin ()
@property(readonly, nonatomic) NSObject<FlutterTextureRegistry> *registry;
@property(readonly, nonatomic) NSObject<FlutterBinaryMessenger> *messenger;
@property(readonly, nonatomic) FLTCam *camera;
@end

@implementation CameraPlugin {
  dispatch_queue_t _dispatchQueue;
}
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  FlutterMethodChannel *channel =
      [FlutterMethodChannel methodChannelWithName:@"plugins.flutter.io/qr_camera"
                                  binaryMessenger:[registrar messenger]];
  CameraPlugin *instance = [[CameraPlugin alloc] initWithRegistry:[registrar textures]
                                                        messenger:[registrar messenger]];
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (instancetype)initWithRegistry:(NSObject<FlutterTextureRegistry> *)registry
                       messenger:(NSObject<FlutterBinaryMessenger> *)messenger {
  self = [super init];
  NSAssert(self, @"super init cannot be nil");
  _registry = registry;
  _messenger = messenger;
  return self;
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  if (_dispatchQueue == nil) {
    _dispatchQueue = dispatch_queue_create("io.flutter.camera.dispatchqueue", NULL);
  }

  // Invoke the plugin on another dispatch queue to avoid blocking the UI.
  dispatch_async(_dispatchQueue, ^{
    [self handleMethodCallAsync:call result:result];
  });
}

- (void)handleMethodCallAsync:(FlutterMethodCall *)call result:(FlutterResult)result {
  if ([@"availableCameras" isEqualToString:call.method]) {
    AVCaptureDeviceDiscoverySession *discoverySession = [AVCaptureDeviceDiscoverySession
        discoverySessionWithDeviceTypes:@[ AVCaptureDeviceTypeBuiltInWideAngleCamera ]
                              mediaType:AVMediaTypeVideo
                               position:AVCaptureDevicePositionUnspecified];
    NSArray<AVCaptureDevice *> *devices = discoverySession.devices;
    NSMutableArray<NSDictionary<NSString *, NSObject *> *> *reply =
        [[NSMutableArray alloc] initWithCapacity:devices.count];
    for (AVCaptureDevice *device in devices) {
      NSString *lensFacing;
      switch ([device position]) {
        case AVCaptureDevicePositionBack:
          lensFacing = @"back";
          break;
        case AVCaptureDevicePositionFront:
          lensFacing = @"front";
          break;
        case AVCaptureDevicePositionUnspecified:
          lensFacing = @"external";
          break;
      }
      [reply addObject:@{
        @"name" : [device uniqueID],
        @"lensFacing" : lensFacing,
        @"sensorOrientation" : @90,
      }];
    }
    result(reply);
  } else if ([@"initialize" isEqualToString:call.method]) {
    NSString *cameraName = call.arguments[@"cameraName"];
    NSString *resolutionPreset = call.arguments[@"resolutionPreset"];
    NSError *error;
    FLTCam *cam = [[FLTCam alloc] initWithCameraName:cameraName
                                    resolutionPreset:resolutionPreset
                                       dispatchQueue:_dispatchQueue
                                               error:&error];
    if (error) {
      result(getFlutterError(error));
    } else {
      if (_camera) {
        [_camera close];
      }
      int64_t textureId = [_registry registerTexture:cam];
      _camera = cam;
      cam.onFrameAvailable = ^{
        [_registry textureFrameAvailable:textureId];
      };
      FlutterEventChannel *eventChannel = [FlutterEventChannel
          eventChannelWithName:[NSString
                                   stringWithFormat:@"flutter.io/cameraPlugin/cameraEvents%lld",
                                                    textureId]
               binaryMessenger:_messenger];
      [eventChannel setStreamHandler:cam];
      cam.eventChannel = eventChannel;
      result(@{
        @"textureId" : @(textureId),
        @"previewWidth" : @(cam.previewSize.width),
        @"previewHeight" : @(cam.previewSize.height),
        @"captureWidth" : @(cam.captureSize.width),
        @"captureHeight" : @(cam.captureSize.height),
      });
      [cam start];
    }
  } else if ([@"startScanningForQrCodes" isEqualToString:call.method]) {
    [_camera startScanningForQrCodesWithMessenger:_messenger];
    result(nil);
  } else if ([@"stopScanningForQrCodes" isEqualToString:call.method]) {
    [_camera stopScanningForQrCodes];
    result(nil);
  } else {
    NSDictionary *argsMap = call.arguments;
    NSUInteger textureId = ((NSNumber *)argsMap[@"textureId"]).unsignedIntegerValue;
    if ([@"dispose" isEqualToString:call.method]) {
      [_registry unregisterTexture:textureId];
      [_camera close];
      _dispatchQueue = nil;
      result(nil);
    } else {
      result(FlutterMethodNotImplemented);
    }
  }
}

@end
