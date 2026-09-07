import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:scrcpy_flutter/scrcpy_advanced.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders and controls an application on a virtual display', (
    tester,
  ) async {
    const serial = String.fromEnvironment('SCRCPY_DEVICE_SERIAL');
    const packageName = String.fromEnvironment(
      'SCRCPY_TEST_PACKAGE',
      defaultValue: 'com.android.calculator2',
    );
    if (serial.isEmpty) return;

    final client = createDefaultScrcpyClient();
    final session = client.createSession(
      const ScrcpySessionConfiguration(
        deviceSerial: serial,
        video: ScrcpyVideoOptions(maxSize: 1280, maxFps: 30, bitRate: 4000000),
        displaySource: ScrcpyDisplaySource.virtual(
          width: 1280,
          height: 720,
          dpi: 240,
          systemDecorations: false,
          keepActive: true,
          launchApplication: ScrcpyApplicationLaunch(
            packageName,
            forceStopBeforeStart: true,
          ),
        ),
      ),
    );
    ScrcpyVideoController? video;
    try {
      final connection = await session.start().timeout(
        const Duration(seconds: 20),
      );
      final input = connection.input;
      if (input == null) throw StateError('Control socket is unavailable');
      video = createNativeScrcpyVideoController(connection);
      await video.start().timeout(const Duration(seconds: 20));
      await tester.pumpWidget(
        MaterialApp(home: ScrcpyVideoView(controller: video)),
      );
      final frames = await _waitForFrames(tester, video);
      expect(video.value.width, greaterThan(0));
      expect(video.value.height, greaterThan(0));

      await input.sendPointer(
        const ScrcpyPointerEvent(
          pointerId: 1,
          action: ScrcpyPointerAction.down,
          normalizedX: 0.5,
          normalizedY: 0.5,
          buttons: 1,
        ),
      );
      await input.sendPointer(
        const ScrcpyPointerEvent(
          pointerId: 1,
          action: ScrcpyPointerAction.up,
          normalizedX: 0.5,
          normalizedY: 0.5,
          buttons: 0,
        ),
      );
      debugPrint(
        'virtual-display: package=$packageName '
        'video=${video.value.width}x${video.value.height} frames=$frames',
      );
    } finally {
      await video?.stop();
      await session.stop();
      video?.dispose();
      session.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}

Future<int> _waitForFrames(
  WidgetTester tester,
  ScrcpyVideoController video,
) async {
  const channel = MethodChannel('scrcpy_flutter/video');
  for (var attempt = 0; attempt < 200; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    final textureId = video.value.textureId;
    if (textureId == null) continue;
    int? frames;
    try {
      frames = await channel.invokeMethod<int>('frameCount', <String, Object>{
        'textureId': textureId,
      });
    } on PlatformException catch (error) {
      if (error.code != 'native_video_error' ||
          error.message != 'Unknown texture') {
        rethrow;
      }
      continue;
    }
    if ((frames ?? 0) > 0) return frames!;
  }
  throw TimeoutException('Virtual display produced no decoded frame');
}
