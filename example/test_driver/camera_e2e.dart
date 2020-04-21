import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:camera/camera.dart';
import 'package:path_provider/path_provider.dart';
import 'package:e2e/e2e.dart';

void main() {
  Directory testDir;

  E2EWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final Directory extDir = await getTemporaryDirectory();
    testDir = await Directory('${extDir.path}/test').create(recursive: true);
  });

  tearDownAll(() async {
    await testDir.delete(recursive: true);
  });

  testWidgets(
    'Android image streaming',
    (WidgetTester tester) async {
      final List<CameraDescription> cameras = await availableCameras();
      if (cameras.isEmpty) {
        return;
      }

      final CameraController controller = CameraController(
        cameras[0],
        ResolutionPreset.low,
        enableAudio: false,
      );

      await controller.initialize();
      bool _isDetecting = false;

      await controller.startImageStream((String image) {
        if (_isDetecting) return;

        _isDetecting = true;

        expectLater(image, isNotNull).whenComplete(() => _isDetecting = false);
      });

      expect(controller.value.isStreamingImages, true);

      sleep(const Duration(milliseconds: 500));

      await controller.stopImageStream();
      await controller.dispose();
    },
    skip: !Platform.isAndroid,
  );
}
