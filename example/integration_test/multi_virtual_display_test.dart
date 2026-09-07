import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:scrcpy_flutter/scrcpy_advanced.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('runs two independent virtual displays on one device', (
    tester,
  ) async {
    const serial = String.fromEnvironment('SCRCPY_DEVICE_SERIAL');
    const firstPackage = String.fromEnvironment(
      'SCRCPY_TEST_PACKAGE',
      defaultValue: 'com.miui.calculator',
    );
    const secondPackage = String.fromEnvironment(
      'SCRCPY_TEST_PACKAGE_2',
      defaultValue: 'com.android.settings',
    );
    if (serial.isEmpty) return;

    final client = createDefaultScrcpyClient();
    final first = _createSession(client, serial, firstPackage, 960, 540);
    final second = _createSession(client, serial, secondPackage, 540, 960);
    ScrcpyVideoController? firstVideo;
    ScrcpyVideoController? secondVideo;
    try {
      final connections = await Future.wait(<Future<ScrcpyVideoConnection>>[
        first.start(),
        second.start(),
      ]).timeout(const Duration(seconds: 30));
      expect(connections[0].info.scid, isNot(connections[1].info.scid));
      expect(
        connections[0].info.localPort,
        isNot(connections[1].info.localPort),
      );

      firstVideo = createNativeScrcpyVideoController(connections[0]);
      secondVideo = createNativeScrcpyVideoController(connections[1]);
      await Future.wait(<Future<void>>[firstVideo.start(), secondVideo.start()])
          .timeout(const Duration(seconds: 20));
      await tester.pumpWidget(
        MaterialApp(
          home: Row(
            children: <Widget>[
              Expanded(child: ScrcpyVideoView(controller: firstVideo)),
              Expanded(child: ScrcpyVideoView(controller: secondVideo)),
            ],
          ),
        ),
      );
      final firstFrames = await _waitForFrames(tester, firstVideo);
      final secondFrames = await _waitForFrames(tester, secondVideo);

      for (final size in <(int, int)>[
        (720, 720),
        (1024, 576),
        (576, 1024),
        (1200, 400),
      ]) {
        await connections[0].input!.resizeDisplay(
          width: size.$1,
          height: size.$2,
        );
        await tester.pump(const Duration(milliseconds: 150));
        await connections[0].input!.sendPointer(
          const ScrcpyPointerEvent(
            pointerId: 1,
            action: ScrcpyPointerAction.down,
            normalizedX: 0.5,
            normalizedY: 0.5,
            buttons: 1,
          ),
        );
        await connections[0].input!.sendPointer(
          const ScrcpyPointerEvent(
            pointerId: 1,
            action: ScrcpyPointerAction.up,
            normalizedX: 0.5,
            normalizedY: 0.5,
            buttons: 0,
          ),
        );
      }
      await first.stop();
      await firstVideo.stop();
      firstVideo.dispose();
      firstVideo = null;

      final secondFramesAfterClose = await _waitForFrames(
        tester,
        secondVideo,
        greaterThan: secondFrames,
      );
      expect(second.state.value, ScrcpySessionState.streaming);
      debugPrint(
        'multi-virtual-display: first=$firstPackage frames=$firstFrames '
        'second=$secondPackage frames=$secondFrames->$secondFramesAfterClose',
      );
    } finally {
      await firstVideo?.stop();
      await secondVideo?.stop();
      await first.stop();
      await second.stop();
      firstVideo?.dispose();
      secondVideo?.dispose();
      first.dispose();
      second.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}

ScrcpyRawSession _createSession(
  ScrcpyClient client,
  String serial,
  String packageName,
  int width,
  int height,
) => client.createSession(
  ScrcpySessionConfiguration(
    deviceSerial: serial,
    video: const ScrcpyVideoOptions(
      maxSize: 1280,
      maxFps: 30,
      bitRate: 4000000,
    ),
    displaySource: ScrcpyDisplaySource.virtual(
      width: width,
      height: height,
      dpi: 240,
      systemDecorations: false,
      keepActive: true,
      flexDisplay: true,
      launchApplication: ScrcpyApplicationLaunch(
        packageName,
        forceStopBeforeStart: true,
      ),
    ),
  ),
);

Future<int> _waitForFrames(
  WidgetTester tester,
  ScrcpyVideoController video, {
  int greaterThan = 0,
}) async {
  const channel = MethodChannel('scrcpy_flutter/video');
  for (var attempt = 0; attempt < 300; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    final textureId = video.value.textureId;
    if (textureId == null) continue;
    try {
      final frames = await channel.invokeMethod<int>(
        'frameCount',
        <String, Object>{'textureId': textureId},
      );
      if ((frames ?? 0) > greaterThan) return frames!;
    } on PlatformException catch (error) {
      if (error.code != 'native_video_error' ||
          error.message != 'Unknown texture') {
        rethrow;
      }
    }
  }
  throw TimeoutException('Video frame count did not advance');
}
