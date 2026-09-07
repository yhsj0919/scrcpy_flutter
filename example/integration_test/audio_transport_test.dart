import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:scrcpy_flutter/scrcpy_advanced.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('records live scrcpy Opus packets', (tester) async {
    const serial = String.fromEnvironment('SCRCPY_DEVICE_SERIAL');
    if (serial.isEmpty) return;

    final client = createDefaultScrcpyClient();
    final session = client.createSession(
      const ScrcpySessionConfiguration(
        deviceSerial: serial,
        video: ScrcpyVideoOptions(maxSize: 320, maxFps: 15, bitRate: 1000000),
        audioEnabled: true,
        audioRequired: true,
        audio: ScrcpyAudioOptions(codec: ScrcpyAudioCodec.opus),
        controlEnabled: false,
      ),
    );
    StreamSubscription<ScrcpyAudioPacket>? subscription;
    try {
      final connection = await session.start().timeout(
        const Duration(seconds: 15),
      );
      final audio = connection.audio;
      expect(audio, isNotNull);
      final codec = await audio!.codec.timeout(const Duration(seconds: 5));
      expect(codec?.codec, ScrcpyAudioCodec.opus);

      var packets = 0;
      var payloadBytes = 0;
      var lastPts = -1;
      final samplePts = <int>[];
      subscription = audio.packets.listen((packet) {
        packets++;
        payloadBytes += packet.data.length;
        if (!packet.isConfig) {
          if (samplePts.length < 16) samplePts.add(packet.presentationTimeUs);
          lastPts = packet.presentationTimeUs;
        }
      });
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (packets < 10 && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      debugPrint(
        'audio-transport: codec=${codec!.codec.serverName} packets=$packets '
        'payloadBytes=$payloadBytes transportBytes=${audio.bytesReceived} '
        'lastPtsUs=$lastPts pts=$samplePts',
      );
      expect(packets, greaterThanOrEqualTo(10));
      expect(payloadBytes, greaterThan(0));
      expect(audio.bytesReceived, greaterThan(payloadBytes));
      expect(lastPts, greaterThanOrEqualTo(0));
    } finally {
      await subscription?.cancel();
      await session.stop();
      session.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
