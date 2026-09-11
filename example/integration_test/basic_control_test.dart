import 'dart:async';

import 'package:adb_client/adb_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:scrcpy_flutter/scrcpy_advanced.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sends the complete basic control checklist to a real device', (
    tester,
  ) async {
    const serial = String.fromEnvironment('SCRCPY_DEVICE_SERIAL');
    const endpointValue = String.fromEnvironment('ADB_TEST_ENDPOINT');
    if (serial.isEmpty) return;

    const channel = MethodChannel('scrcpy_flutter/video');
    final client = createDefaultScrcpyClient();
    final endpoint = endpointValue.isEmpty
        ? null
        : AdbEndpoint.tryParse(endpointValue);
    if (endpointValue.isNotEmpty && endpoint == null) {
      throw ArgumentError.value(endpointValue, 'ADB_TEST_ENDPOINT');
    }
    if (endpoint != null) await client.adbClient.connect(endpoint);
    final session = client.createSession(
      const ScrcpySessionConfiguration(
        deviceSerial: serial,
        video: ScrcpyVideoOptions(maxSize: 1280, maxFps: 30),
        controlEnabled: true,
      ),
    );
    ScrcpyVideoController? video;
    ScrcpyInputController? input;
    var poweredOff = false;
    try {
      final connection = await session.start().timeout(
        const Duration(seconds: 15),
      );
      input = connection.input;
      if (input == null) throw StateError('Control socket is unavailable');
      video = createNativeScrcpyVideoController(connection);
      await video.start().timeout(const Duration(seconds: 15));
      await tester.pumpWidget(
        MaterialApp(home: ScrcpyVideoView(controller: video)),
      );
      final firstFrames = await _waitForFrames(tester, channel, video);
      const clipboardFixture = 'scrcpy Flutter 剪贴板\n!@# 123';
      try {
        await input.setClipboard(clipboardFixture);
        expect(await _readClipboard(input), clipboardFixture);
      } finally {
        await input.setClipboard('');
      }

      await _pointer(input, ScrcpyPointerAction.down, 0.5, 0.5);
      await _pointer(input, ScrcpyPointerAction.up, 0.5, 0.5);

      await _pointer(input, ScrcpyPointerAction.down, 0.5, 0.5);
      await tester.pump(const Duration(milliseconds: 600));
      await _pointer(input, ScrcpyPointerAction.up, 0.5, 0.5);

      await _pointer(input, ScrcpyPointerAction.down, 0.25, 0.5);
      for (var step = 1; step <= 5; step++) {
        await _pointer(input, ScrcpyPointerAction.move, 0.25 + step * 0.1, 0.5);
      }
      await _pointer(input, ScrcpyPointerAction.up, 0.75, 0.5);
      await input.sendPointer(
        const ScrcpyPointerEvent(
          pointerId: 1,
          action: ScrcpyPointerAction.scroll,
          normalizedX: 0.5,
          normalizedY: 0.5,
          buttons: 0,
          scrollDeltaY: 20,
        ),
      );
      final gestures = ScrcpyGestureSimulator(input);
      await gestures.pinch(
        startSpan: 0.18,
        endSpan: 0.5,
        duration: const Duration(milliseconds: 160),
      );
      await gestures.pinch(
        startSpan: 0.5,
        endSpan: 0.18,
        duration: const Duration(milliseconds: 160),
      );

      for (final keyCode in <int>[
        ScrcpyAndroidKeyCode.home,
        ScrcpyAndroidKeyCode.appSwitch,
        ScrcpyAndroidKeyCode.back,
        ScrcpyAndroidKeyCode.volumeDown,
        ScrcpyAndroidKeyCode.volumeUp,
        ScrcpyAndroidKeyCode.enter,
        ScrcpyAndroidKeyCode.backspace,
        ScrcpyAndroidKeyCode.forwardDelete,
      ]) {
        await _key(input, keyCode);
        await tester.pump(const Duration(milliseconds: 150));
      }
      await input.sendText('scrcpy_flutter_123');

      await _key(input, ScrcpyAndroidKeyCode.power);
      poweredOff = true;
      await tester.pump(const Duration(milliseconds: 500));
      await _key(input, ScrcpyAndroidKeyCode.wakeUp);
      poweredOff = false;

      final finalFrames = await _waitForFrames(
        tester,
        channel,
        video,
        greaterThan: firstFrames,
      );
      expect(session.state.value, ScrcpySessionState.streaming);
      expect(video.value.status, ScrcpyVideoStatus.ready);
      debugPrint(
        'basic-control: serial=$serial frames=$firstFrames->$finalFrames '
        'pointer=click,longPress,drag,scroll,pinchOut,pinchIn '
        'keys=home,recent,back,volume,power,wake,enter,delete,text '
        'clipboard=set,ack,get,restore',
      );
    } finally {
      if (poweredOff && input != null) {
        await _key(input, ScrcpyAndroidKeyCode.wakeUp);
      }
      await video?.stop();
      await session.stop();
      video?.dispose();
      session.dispose();
      if (endpoint != null) await client.adbClient.disconnect(endpoint);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}

Future<String> _readClipboard(ScrcpyInputController input) async {
  final response = input.clipboardChanges.first.timeout(
    const Duration(seconds: 3),
  );
  await input.requestClipboard();
  return response;
}

Future<void> _pointer(
  ScrcpyInputController input,
  ScrcpyPointerAction action,
  double x,
  double y,
) => input.sendPointer(
  ScrcpyPointerEvent(
    pointerId: 1,
    action: action,
    normalizedX: x,
    normalizedY: y,
    buttons: action == ScrcpyPointerAction.up ? 0 : 1,
  ),
);

Future<void> _key(ScrcpyInputController input, int keyCode) async {
  await input.sendKey(keyCode: keyCode);
  await input.sendKey(keyCode: keyCode, down: false);
}

Future<int> _waitForFrames(
  WidgetTester tester,
  MethodChannel channel,
  ScrcpyVideoController video, {
  int greaterThan = 0,
}) async {
  final textureId = video.value.textureId;
  if (textureId == null) throw StateError('Native texture is unavailable');
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    final frames = await channel.invokeMethod<int>(
      'frameCount',
      <String, Object>{'textureId': textureId},
    );
    if ((frames ?? 0) > greaterThan) return frames!;
  }
  throw TimeoutException('Video frame count did not advance');
}
