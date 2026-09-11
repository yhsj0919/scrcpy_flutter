import 'package:adb_client/adb_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:scrcpy_flutter/scrcpy_advanced.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('repeatedly starts and stops a live scrcpy session', (
    tester,
  ) async {
    const serial = String.fromEnvironment('SCRCPY_DEVICE_SERIAL');
    const endpointValue = String.fromEnvironment('ADB_TEST_ENDPOINT');
    const iterations = int.fromEnvironment(
      'SCRCPY_STRESS_ITERATIONS',
      defaultValue: 1,
    );
    if (serial.isEmpty) return;
    if (iterations < 1 || iterations > 50) {
      throw ArgumentError.value(
        iterations,
        'SCRCPY_STRESS_ITERATIONS',
        '1..50',
      );
    }

    final client = createDefaultScrcpyClient();
    final endpoint = endpointValue.isEmpty
        ? null
        : AdbEndpoint.tryParse(endpointValue);
    if (endpointValue.isNotEmpty && endpoint == null) {
      throw ArgumentError.value(endpointValue, 'ADB_TEST_ENDPOINT');
    }
    if (endpoint != null) await client.adbClient.connect(endpoint);
    const channel = MethodChannel('scrcpy_flutter/video');
    try {
      for (var iteration = 1; iteration <= iterations; iteration++) {
        final session = client.createSession(
          const ScrcpySessionConfiguration(
            deviceSerial: serial,
            video: ScrcpyVideoOptions(
              maxSize: 320,
              maxFps: 15,
              bitRate: 1000000,
            ),
            controlEnabled: true,
          ),
        );
        ScrcpyVideoController? controller;
        try {
          final connection = await session.start().timeout(
            const Duration(seconds: 10),
          );
          controller = createNativeScrcpyVideoController(connection);
          await controller.start().timeout(const Duration(seconds: 10));
          expect(session.state.value, ScrcpySessionState.streaming);
          expect(controller.value.status, ScrcpyVideoStatus.ready);
          expect(connection.input, isNotNull);
          final textureId = controller.value.textureId!;

          await tester.pumpWidget(
            MaterialApp(home: ScrcpyVideoView(controller: controller)),
          );
          final frameCount = await _waitForFrame(tester, channel, textureId);
          expect(frameCount, greaterThan(0));
          debugPrint(
            'native-video: iteration=$iteration/$iterations '
            'scid=${connection.info.scid} port=${connection.info.localPort} '
            'frames=$frameCount',
          );

          await session.stop().timeout(const Duration(seconds: 10));
          await controller.stop().timeout(const Duration(seconds: 10));
          expect(session.state.value, ScrcpySessionState.ready);
          await expectLater(
            channel.invokeMethod<int>('frameCount', <String, Object>{
              'textureId': textureId,
            }),
            throwsA(isA<PlatformException>()),
            reason: 'iteration $iteration must release its native texture',
          );
        } finally {
          controller?.dispose();
          session.dispose();
        }
      }
    } finally {
      if (endpoint != null) await client.adbClient.disconnect(endpoint);
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}

Future<int> _waitForFrame(
  WidgetTester tester,
  MethodChannel channel,
  int textureId,
) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    await tester.pump(const Duration(milliseconds: 100));
    final frames = await channel.invokeMethod<int>(
      'frameCount',
      <String, Object>{'textureId': textureId},
    );
    if ((frames ?? 0) > 0) return frames!;
  }
  return 0;
}
