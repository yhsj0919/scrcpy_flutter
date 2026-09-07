import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:scrcpy_flutter/scrcpy_advanced.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('measures control-to-changed-frame latency', (tester) async {
    const serial = String.fromEnvironment('SCRCPY_DEVICE_SERIAL');
    if (serial.isEmpty) return;

    const channel = MethodChannel('scrcpy_flutter/video');
    final client = createDefaultScrcpyClient();
    final session = client.createSession(
      const ScrcpySessionConfiguration(
        deviceSerial: serial,
        video: ScrcpyVideoOptions(maxSize: 1920, maxFps: 60, bitRate: 8000000),
        controlEnabled: true,
      ),
    );
    ScrcpyVideoController? controller;
    try {
      final connection = await session.start().timeout(
        const Duration(seconds: 15),
      );
      final input = connection.input;
      if (input == null) throw StateError('Control socket is unavailable');
      controller = createNativeScrcpyVideoController(connection);
      await controller.start().timeout(const Duration(seconds: 15));
      await tester.pumpWidget(
        MaterialApp(home: ScrcpyVideoView(controller: controller)),
      );
      await _waitForFirstFingerprint(tester, channel, controller);

      final latencies = <double>[];
      for (var iteration = 1; iteration <= 20; iteration++) {
        final before = await _waitForStableFingerprint(
          tester,
          channel,
          controller,
        );
        final clock = await _clock(channel);
        final keyCode = iteration.isOdd ? 187 : 4;
        await input.sendKey(keyCode: keyCode);
        await input.sendKey(keyCode: keyCode, down: false);
        final changed = await _waitForChangedFingerprint(
          tester,
          channel,
          controller,
          before.fingerprint,
        );
        final latencyMs =
            (changed.lastFrameTicks - clock.ticks) / clock.frequency * 1000;
        if (latencyMs < 0) {
          throw StateError('Changed frame predates the control message');
        }
        latencies.add(latencyMs);
        debugPrint(
          'control-latency: iteration=$iteration/20 keyCode=$keyCode '
          'latencyMs=${latencyMs.toStringAsFixed(2)}',
        );
        await tester.pump(const Duration(milliseconds: 300));
      }

      final sorted = <double>[...latencies]..sort();
      final average = latencies.reduce((a, b) => a + b) / latencies.length;
      final p95 =
          sorted[((sorted.length * 0.95).ceil() - 1).clamp(
            0,
            sorted.length - 1,
          )];
      debugPrint(
        'control-latency-summary: samples=${latencies.length} '
        'averageMs=${average.toStringAsFixed(2)} '
        'p95Ms=${p95.toStringAsFixed(2)} '
        'minMs=${sorted.first.toStringAsFixed(2)} '
        'maxMs=${sorted.last.toStringAsFixed(2)}',
      );
      expect(latencies, hasLength(20));
      expect(p95, lessThan(500));
    } finally {
      await controller?.stop();
      await session.stop();
      controller?.dispose();
      session.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}

Future<_FrameStats> _waitForFirstFingerprint(
  WidgetTester tester,
  MethodChannel channel,
  ScrcpyVideoController controller,
) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    final stats = await _frameStats(channel, controller);
    if (stats.fingerprint != 0) return stats;
  }
  throw TimeoutException('No fingerprinted video frame');
}

Future<_FrameStats> _waitForStableFingerprint(
  WidgetTester tester,
  MethodChannel channel,
  ScrcpyVideoController controller,
) async {
  _FrameStats? previous;
  var stableSamples = 0;
  for (var attempt = 0; attempt < 50; attempt++) {
    await tester.pump(const Duration(milliseconds: 100));
    final current = await _frameStats(channel, controller);
    if (previous?.fingerprint == current.fingerprint) {
      stableSamples++;
      if (stableSamples >= 2) return current;
    } else {
      stableSamples = 0;
    }
    previous = current;
  }
  throw TimeoutException('Video did not become visually stable');
}

Future<_FrameStats> _waitForChangedFingerprint(
  WidgetTester tester,
  MethodChannel channel,
  ScrcpyVideoController controller,
  int fingerprint,
) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.pump(const Duration(milliseconds: 5));
    final current = await _frameStats(channel, controller);
    if (current.fingerprint != 0 && current.fingerprint != fingerprint) {
      return current;
    }
  }
  throw TimeoutException('Control did not produce a changed video frame');
}

Future<_FrameStats> _frameStats(
  MethodChannel channel,
  ScrcpyVideoController controller,
) async {
  final textureId = controller.value.textureId;
  if (textureId == null) return const _FrameStats(0, 0);
  final stats = await channel.invokeMapMethod<String, Object?>(
    'videoStats',
    <String, Object>{'textureId': textureId},
  );
  if (stats == null) throw StateError('Missing native video stats');
  return _FrameStats(
    stats['fingerprint'] as int,
    stats['lastFrameTicks'] as int,
  );
}

Future<_Clock> _clock(MethodChannel channel) async {
  final value = await channel.invokeMapMethod<String, Object?>(
    'clockMetrics',
    const <String, Object>{},
  );
  if (value == null) throw StateError('Missing native clock metrics');
  return _Clock(value['ticks'] as int, value['frequency'] as int);
}

final class _FrameStats {
  const _FrameStats(this.fingerprint, this.lastFrameTicks);

  final int fingerprint;
  final int lastFrameTicks;
}

final class _Clock {
  const _Clock(this.ticks, this.frequency);

  final int ticks;
  final int frequency;
}
