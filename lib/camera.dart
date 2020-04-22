// Copyright 2018 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

part 'camera_image.dart';

final MethodChannel _channel = const MethodChannel('plugins.flutter.io/qr_camera');

enum CameraLensDirection { front, back, external }

/// Affect the quality of video recording and image capture:
///
/// If a preset is not available on the camera being used a preset of lower quality will be selected automatically.
enum ResolutionPreset {
  /// 352x288 on iOS, 240p (320x240) on Android
  low,

  /// 480p (640x480 on iOS, 720x480 on Android)
  medium,

  /// 720p (1280x720)
  high,

  /// 1080p (1920x1080)
  veryHigh,

  /// 2160p (3840x2160)
  ultraHigh,

  /// The highest resolution available.
  max,
}

// ignore: inference_failure_on_function_return_type
typedef onQrCodeScanned = Function(String qrCodeString);

/// Returns the resolution preset as a String.
String serializeResolutionPreset(ResolutionPreset resolutionPreset) {
  switch (resolutionPreset) {
    case ResolutionPreset.max:
      return 'max';
    case ResolutionPreset.ultraHigh:
      return 'ultraHigh';
    case ResolutionPreset.veryHigh:
      return 'veryHigh';
    case ResolutionPreset.high:
      return 'high';
    case ResolutionPreset.medium:
      return 'medium';
    case ResolutionPreset.low:
      return 'low';
  }
  throw ArgumentError('Unknown ResolutionPreset value');
}

CameraLensDirection _parseCameraLensDirection(String string) {
  switch (string) {
    case 'front':
      return CameraLensDirection.front;
    case 'back':
      return CameraLensDirection.back;
    case 'external':
      return CameraLensDirection.external;
  }
  throw ArgumentError('Unknown CameraLensDirection value');
}

/// Completes with a list of available cameras.
///
/// May throw a [CameraException].
Future<List<CameraDescription>> availableCameras() async {
  try {
    final List<Map<dynamic, dynamic>> cameras = await _channel
        .invokeListMethod<Map<dynamic, dynamic>>('availableCameras');
    return cameras.map((Map<dynamic, dynamic> camera) {
      return CameraDescription(
        name: camera['name'],
        lensDirection: _parseCameraLensDirection(camera['lensFacing']),
        sensorOrientation: camera['sensorOrientation'],
      );
    }).toList();
  } on PlatformException catch (e) {
    throw CameraException(e.code, e.message);
  }
}

class CameraDescription {
  CameraDescription({this.name, this.lensDirection, this.sensorOrientation});

  final String name;
  final CameraLensDirection lensDirection;

  /// Clockwise angle through which the output image needs to be rotated to be upright on the device screen in its native orientation.
  ///
  /// **Range of valid values:**
  /// 0, 90, 180, 270
  ///
  /// On Android, also defines the direction of rolling shutter readout, which
  /// is from top to bottom in the sensor's coordinate system.
  final int sensorOrientation;

  @override
  bool operator ==(Object o) {
    return o is CameraDescription &&
        o.name == name &&
        o.lensDirection == lensDirection;
  }

  @override
  int get hashCode {
    return hashValues(name, lensDirection);
  }

  @override
  String toString() {
    return '$runtimeType($name, $lensDirection, $sensorOrientation)';
  }
}

/// This is thrown when the plugin reports an error.
class CameraException implements Exception {
  CameraException(this.code, this.description);

  String code;
  String description;

  @override
  String toString() => '$runtimeType($code, $description)';
}

// Build the UI texture view of the video data with textureId.
class CameraPreview extends StatelessWidget {
  const CameraPreview(this.controller);

  final CameraController controller;

  @override
  Widget build(BuildContext context) {
    return controller.value.isInitialized
        ? Texture(textureId: controller._textureId)
        : Container();
  }
}

/// The state of a [CameraController].
class CameraValue {
  const CameraValue({
    this.isInitialized,
    this.errorDescription,
    this.previewSize,
    this.isScanningForQrCodes,
    bool isRecordingPaused,
  });

  const CameraValue.uninitialized()
      : this(
          isInitialized: false,
          isScanningForQrCodes: false,
          isRecordingPaused: false,
        );

  /// True after [CameraController.initialize] has completed successfully.
  final bool isInitialized;

  /// True when qr codes from the camera are being scanned.
  final bool isScanningForQrCodes;

  final String errorDescription;

  /// The size of the preview in pixels.
  ///
  /// Is `null` until  [isInitialized] is `true`.
  final Size previewSize;

  /// Convenience getter for `previewSize.height / previewSize.width`.
  ///
  /// Can only be called when [initialize] is done.
  double get aspectRatio => previewSize.height / previewSize.width;

  bool get hasError => errorDescription != null;

  CameraValue copyWith({
    bool isInitialized,
    bool isRecordingVideo,
    bool isTakingPicture,
    bool isStreamingImages,
    String errorDescription,
    Size previewSize,
    bool isRecordingPaused,
  }) {
    return CameraValue(
      isInitialized: isInitialized ?? this.isInitialized,
      errorDescription: errorDescription,
      previewSize: previewSize ?? this.previewSize,
      isScanningForQrCodes: isStreamingImages ?? this.isScanningForQrCodes,
    );
  }

  @override
  String toString() {
    return '$runtimeType('
        'isInitialized: $isInitialized, '
        'errorDescription: $errorDescription, '
        'previewSize: $previewSize, '
        'isStreamingImages: $isScanningForQrCodes)';
  }
}

/// Controls a device camera.
///
/// Use [availableCameras] to get a list of available cameras.
///
/// Before using a [CameraController] a call to [initialize] must complete.
///
/// To show the camera preview on the screen use a [CameraPreview] widget.
class CameraController extends ValueNotifier<CameraValue> {
  CameraController(
    this.description,
    this.resolutionPreset, {
    this.enableAudio = true,
  }) : super(const CameraValue.uninitialized());

  final CameraDescription description;
  final ResolutionPreset resolutionPreset;

  /// Whether to include audio when recording a video.
  final bool enableAudio;

  int _textureId;
  bool _isDisposed = false;
  StreamSubscription<dynamic> _eventSubscription;
  StreamSubscription<dynamic> _qrCodeStringStreamSubscription;
  Completer<void> _creatingCompleter;

  /// Initializes the camera on the device.
  ///
  /// Throws a [CameraException] if the initialization fails.
  Future<void> initialize() async {
    if (_isDisposed) {
      return Future<void>.value();
    }
    try {
      _creatingCompleter = Completer<void>();
      final Map<String, dynamic> reply =
          await _channel.invokeMapMethod<String, dynamic>(
        'initialize',
        <String, dynamic>{
          'cameraName': description.name,
          'resolutionPreset': serializeResolutionPreset(resolutionPreset),
          'enableAudio': enableAudio,
        },
      );
      _textureId = reply['textureId'];
      value = value.copyWith(
        isInitialized: true,
        previewSize: Size(
          reply['previewWidth'].toDouble(),
          reply['previewHeight'].toDouble(),
        ),
      );
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
    _eventSubscription =
        EventChannel('flutter.io/cameraPlugin/cameraEvents$_textureId')
            .receiveBroadcastStream()
            .listen(_listener);
    _creatingCompleter.complete();
    return _creatingCompleter.future;
  }

  /// Prepare the capture session for video recording.
  ///
  /// Use of this method is optional, but it may be called for performance
  /// reasons on iOS.
  ///
  /// Preparing audio can cause a minor delay in the CameraPreview view on iOS.
  /// If video recording is intended, calling this early eliminates this delay
  /// that would otherwise be experienced when video recording is started.
  /// This operation is a no-op on Android.
  ///
  /// Throws a [CameraException] if the prepare fails.
  Future<void> prepareForVideoRecording() async {
    await _channel.invokeMethod<void>('prepareForVideoRecording');
  }

  /// Listen to events from the native plugins.
  ///
  /// A "cameraClosing" event is sent when the camera is closed automatically by the system (for example when the app go to background). The plugin will try to reopen the camera automatically but any ongoing recording will end.
  void _listener(dynamic event) {
    final Map<dynamic, dynamic> map = event;
    if (_isDisposed) {
      return;
    }

    switch (map['eventType']) {
      case 'error':
        value = value.copyWith(errorDescription: event['errorDescription']);
        break;
      case 'cameraClosing':
        value = value.copyWith(isRecordingVideo: false);
        break;
    }
  }

  /// Start scanning for qr codes and return the raw value
  /// from platform camera.
  ///
  /// Settings for capturing images on iOS and Android is set to always use the
  /// latest image available from the camera and will drop all other images.
  ///
  /// When running continuously with [CameraPreview] widget, this function runs
  /// best with [ResolutionPreset.low]. Running on [ResolutionPreset.high] can
  /// have significant frame rate drops for [CameraPreview] on lower end
  /// devices.
  ///
  /// Throws a [CameraException] if qr code scanning has
  /// already started.
  // TODO(bmparr): Add settings for resolution and fps.
  Future<void> startScanningForQrCodes(onQrCodeScanned onScanned) async {
    if (!value.isInitialized || _isDisposed) {
      throw CameraException(
        'Uninitialized CameraController',
        'startScanningForQrCodes was called on uninitialized CameraController.',
      );
    }
    if (value.isScanningForQrCodes) {
      throw CameraException(
        'A camera has started scanning qr codes.',
        'startScanningForQrCodes was called while a camera was scanning.',
      );
    }

    try {
      await _channel.invokeMethod<void>('startScanningForQrCodes');
      value = value.copyWith(isStreamingImages: true);
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
    const EventChannel cameraEventChannel =
        EventChannel('plugins.flutter.io/qr_camera/qrCodeStream');
    _qrCodeStringStreamSubscription =
        cameraEventChannel.receiveBroadcastStream().listen(
      (dynamic imageData) {
        onScanned(imageData);
      },
    );
  }

  /// Stop scanning for qr codes from platform camera.
  ///
  /// Throws a [CameraException] if scanning was not started or video
  /// recording was started.
  Future<void> stopScanningForQrCodes() async {
    if (!value.isInitialized || _isDisposed) {
      throw CameraException(
        'Uninitialized CameraController',
        'stopScanningForQrCodes was called on uninitialized CameraController.',
      );
    }
    if (!value.isScanningForQrCodes) {
      throw CameraException(
        'No camera is scanning for qr codes',
        'stopScanningForQrCodes was called when no camera is scanning.',
      );
    }

    try {
      value = value.copyWith(isStreamingImages: false);
      await _channel.invokeMethod<void>('stopScanningForQrCodes');
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }

    await _qrCodeStringStreamSubscription.cancel();
    _qrCodeStringStreamSubscription = null;
  }

  /// Releases the resources of this camera.
  @override
  Future<void> dispose() async {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    super.dispose();
    if (_creatingCompleter != null) {
      await _creatingCompleter.future;
      await _channel.invokeMethod<void>(
        'dispose',
        <String, dynamic>{'textureId': _textureId},
      );
      await _eventSubscription?.cancel();
    }
  }
}
