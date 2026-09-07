import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:scrcpy_flutter/scrcpy_advanced.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('decodes and plays live Opus audio on Windows', (tester) async {
    const serial = String.fromEnvironment('SCRCPY_DEVICE_SERIAL');
    if (serial.isEmpty) return;

    final client = createDefaultScrcpyClient();
    final session = client.createSession(
      const ScrcpySessionConfiguration(
        deviceSerial: serial,
        video: ScrcpyVideoOptions(maxSize: 320, maxFps: 15, bitRate: 1000000),
        audioEnabled: true,
        audioRequired: true,
        audio: ScrcpyAudioOptions(
          codec: ScrcpyAudioCodec.opus,
          source: ScrcpyAudioSource.playback,
          duplicateOnDevice: false,
        ),
        controlEnabled: false,
      ),
    );
    ScrcpyAudioController? controller;
    try {
      final connection = await session.start().timeout(
        const Duration(seconds: 15),
      );
      controller = createNativeScrcpyAudioController(connection.audio!);
      await controller.start().timeout(const Duration(seconds: 10));
      expect(controller.value.status, ScrcpyAudioStatus.ready);

      await controller.setVolume(0.5);
      await controller.setMuted(true);
      expect(controller.value.muted, isTrue);
      await tester.pump(const Duration(milliseconds: 250));
      await controller.setMuted(false);
      expect(controller.value.muted, isFalse);

      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (controller.value.decodedPackets < 10 &&
          controller.value.status != ScrcpyAudioStatus.error &&
          DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      final state = controller.value;
      debugPrint(
        'audio-playback: codec=${state.codec} packets=${state.packetsReceived} '
        'decoded=${state.decodedPackets} played=${state.playedBuffers} '
        'dropped=${state.droppedBuffers} bufferedBytes=${state.bufferedBytes} '
        'peakSample=${state.peakSample} '
        'transportBytes=${state.bytesReceived} volume=${state.volume} '
        'error=${state.error}',
      );
      expect(state.status, ScrcpyAudioStatus.ready);
      expect(state.decodedPackets, greaterThanOrEqualTo(10));
      expect(state.playedBuffers, greaterThan(0));
      expect(state.droppedBuffers, 0);
      expect(state.volume, 0.5);
    } finally {
      await controller?.stop();
      await session.stop();
      controller?.dispose();
      session.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
