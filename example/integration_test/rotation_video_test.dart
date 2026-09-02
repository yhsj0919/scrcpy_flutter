import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:adb_client/adb_client.dart';
import 'package:scrcpy_flutter/scrcpy_flutter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('keeps rendering through 20 device rotations', (tester) async {
    const serial = String.fromEnvironment('SCRCPY_DEVICE_SERIAL');
    if (serial.isEmpty) return;

    final client = createDefaultScrcpyClient();
    final adb = client.adbClient;
    final originalAccelerometer = await _getSetting(
      adb,
      serial,
      'accelerometer_rotation',
    );
    final originalRotation = await _getSetting(adb, serial, 'user_rotation');
    final session = client.createSession(
      const ScrcpySessionConfiguration(
        deviceSerial: serial,
        video: ScrcpyVideoOptions(maxSize: 640, maxFps: 30, bitRate: 2000000),
        controlEnabled: true,
      ),
    );
    ScrcpyVideoController? controller;
    try {
      await _setWmRotation(adb, serial, '0');

      final connection = await session.start().timeout(
        const Duration(seconds: 15),
      );
      controller = createNativeScrcpyVideoController(connection);
      await controller.start().timeout(const Duration(seconds: 15));
      await tester.pumpWidget(
        MaterialApp(home: ScrcpyVideoView(controller: controller)),
      );
      await _waitForRenderedFrame(tester, controller);

      var previousWidth = controller.value.width!;
      var previousHeight = controller.value.height!;
      for (var iteration = 1; iteration <= 20; iteration++) {
        final rotation = iteration.isOdd ? '1' : '0';
        await _setWmRotation(adb, serial, rotation);
        await _waitForOrientationChange(
          tester,
          controller,
          previousWidth: previousWidth,
          previousHeight: previousHeight,
        );
        final frames = await _waitForRenderedFrame(tester, controller);
        previousWidth = controller.value.width!;
        previousHeight = controller.value.height!;
        debugPrint(
          'rotation-video: iteration=$iteration/20 rotation=$rotation '
          'size=${previousWidth}x$previousHeight frames=$frames',
        );
      }
    } finally {
      await _restoreWmRotation(
        adb,
        serial,
        accelerometerRotation: originalAccelerometer,
        userRotation: originalRotation,
      );
      await _restoreSetting(adb, serial, 'user_rotation', originalRotation);
      await _restoreSetting(
        adb,
        serial,
        'accelerometer_rotation',
        originalAccelerometer,
      );
      await controller?.stop();
      await session.stop();
      controller?.dispose();
      session.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}

Future<void> _setWmRotation(
  AdbShellService adb,
  String serial,
  String rotation,
) async {
  final result = await adb.shell(serial, <String>[
    'wm',
    'user-rotation',
    'lock',
    rotation,
  ]);
  _checkShellResult(result, 'lock wm rotation to $rotation');
}

Future<void> _restoreWmRotation(
  AdbShellService adb,
  String serial, {
  required String? accelerometerRotation,
  required String? userRotation,
}) async {
  final arguments = accelerometerRotation == '1'
      ? <String>['wm', 'user-rotation', 'free']
      : <String>['wm', 'user-rotation', 'lock', userRotation ?? '0'];
  final result = await adb.shell(serial, arguments);
  _checkShellResult(result, 'restore wm rotation');
}

Future<String?> _getSetting(
  AdbShellService adb,
  String serial,
  String name,
) async {
  final result = await adb.shell(serial, <String>[
    'settings',
    'get',
    'system',
    name,
  ]);
  _checkShellResult(result, 'read $name');
  final value = utf8.decode(result.stdout, allowMalformed: true).trim();
  return value.isEmpty || value == 'null' ? null : value;
}

Future<void> _restoreSetting(
  AdbShellService adb,
  String serial,
  String name,
  String? value,
) async {
  final arguments = value == null
      ? <String>['settings', 'delete', 'system', name]
      : <String>['settings', 'put', 'system', name, value];
  final result = await adb.shell(serial, arguments);
  _checkShellResult(result, 'restore $name');
}

void _checkShellResult(AdbCommandResult result, String operation) {
  if (!result.isSuccess) {
    throw StateError('$operation failed with exit code ${result.exitCode}');
  }
}

Future<void> _waitForOrientationChange(
  WidgetTester tester,
  ScrcpyVideoController controller, {
  required int previousWidth,
  required int previousHeight,
}) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.pump(const Duration(milliseconds: 100));
    final value = controller.value;
    if (value.status == ScrcpyVideoStatus.error) {
      throw StateError('Video failed while rotating: ${value.error}');
    }
    if (value.width == previousHeight && value.height == previousWidth) return;
  }
  throw TimeoutException(
    'Video size did not rotate from ${previousWidth}x$previousHeight',
  );
}

Future<int> _waitForRenderedFrame(
  WidgetTester tester,
  ScrcpyVideoController controller,
) async {
  const channel = MethodChannel('scrcpy_flutter/video');
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.pump(const Duration(milliseconds: 100));
    final textureId = controller.value.textureId;
    if (textureId == null) continue;
    try {
      final frames = await channel.invokeMethod<int>(
        'frameCount',
        <String, Object>{'textureId': textureId},
      );
      if ((frames ?? 0) > 0) return frames!;
    } on PlatformException {
      // A rotation may replace the texture between reading its id and query.
    }
  }
  throw TimeoutException('No decoded frame after rotation');
}
