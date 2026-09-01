import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:scrcpy_flutter/scrcpy_flutter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native backend decodes a live scrcpy H264 stream', (
    tester,
  ) async {
    const serial = String.fromEnvironment('SCRCPY_DEVICE_SERIAL');
    if (serial.isEmpty) return;
    final client = createDefaultScrcpyClient();
    final connection = await client.createVideoConnector().connect(
      const ScrcpySessionConfiguration(
        deviceSerial: serial,
        video: ScrcpyVideoOptions(maxSize: 320, maxFps: 15, bitRate: 1000000),
        controlEnabled: true,
      ),
    );
    final controller = createNativeScrcpyVideoController(connection);
    addTearDown(controller.dispose);

    debugPrint('native-video: starting controller');
    await controller.start().timeout(const Duration(seconds: 10));
    debugPrint('native-video: controller ready');
    expect(controller.value.status, ScrcpyVideoStatus.ready);
    expect(controller.value.decoder, 'native');
    expect(connection.input, isNotNull);
    await connection.input!.sendPointer(
      const ScrcpyPointerEvent(
        pointerId: 1,
        action: ScrcpyPointerAction.cancel,
        normalizedX: 0.5,
        normalizedY: 0.5,
        buttons: 0,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(home: ScrcpyVideoView(controller: controller)),
    );
    await tester.pump(const Duration(seconds: 5));
    debugPrint('native-video: frames pumped');
    expect(find.byType(Texture), findsOneWidget);
    expect(controller.value.status, ScrcpyVideoStatus.ready);
    const channel = MethodChannel('scrcpy_flutter/video');
    final frameCount = await channel.invokeMethod<int>(
      'frameCount',
      <String, Object>{'textureId': controller.value.textureId!},
    );
    final stats = await channel.invokeMapMethod<String, Object?>(
      'videoStats',
      <String, Object>{'textureId': controller.value.textureId!},
    );
    debugPrint('native-video: stats=$stats');
    debugPrint('native-video: decoded frames=$frameCount');
    expect(frameCount, isNotNull);
    expect(frameCount!, greaterThan(0));
    await controller.stop().timeout(const Duration(seconds: 10));
    debugPrint('native-video: stopped');
  }, timeout: const Timeout(Duration(seconds: 30)));
}
