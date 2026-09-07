import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:scrcpy_flutter/scrcpy_advanced.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('records a 30 second native video baseline', (tester) async {
    const serial = String.fromEnvironment('SCRCPY_DEVICE_SERIAL');
    if (serial.isEmpty) return;

    const channel = MethodChannel('scrcpy_flutter/video');
    final total = Stopwatch()..start();
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
      final connectedMs = total.elapsedMilliseconds;
      controller = createNativeScrcpyVideoController(connection);
      await controller.start().timeout(const Duration(seconds: 15));
      final decoderReadyMs = total.elapsedMilliseconds;
      await tester.pumpWidget(
        MaterialApp(home: ScrcpyVideoView(controller: controller)),
      );
      final firstFrame = await _waitForFrame(tester, channel, controller);
      final firstFrameMs = total.elapsedMilliseconds;
      final initialProcess = await _processMetrics(channel);
      final initialVideo = await _videoMetrics(channel, controller);
      final sample = Stopwatch()..start();
      while (sample.elapsed < const Duration(seconds: 30)) {
        await tester.pump(const Duration(milliseconds: 250));
        if (controller.value.status == ScrcpyVideoStatus.error) {
          throw StateError('Video baseline failed: ${controller.value.error}');
        }
      }
      final finalProcess = await _processMetrics(channel);
      final finalVideo = await _videoMetrics(channel, controller);
      final seconds = sample.elapsedMicroseconds / 1000000;
      final frames = finalVideo.frames - initialVideo.frames;
      final inputs = finalVideo.inputs - initialVideo.inputs;
      final bytes = connection.bytesReceived;
      final cpuSeconds =
          (finalProcess.cpuTime100ns - initialProcess.cpuTime100ns) / 10000000;
      final normalizedCpuPercent =
          cpuSeconds / seconds / finalProcess.logicalProcessors * 100;
      final fps = frames / seconds;
      final megabitsPerSecond = bytes * 8 / seconds / 1000000;
      final workingSetMiB = finalProcess.workingSetBytes / 1024 / 1024;
      final privateMiB = finalProcess.privateBytes / 1024 / 1024;

      debugPrint(
        'video-baseline: connectMs=$connectedMs decoderReadyMs=$decoderReadyMs '
        'firstFrameMs=$firstFrameMs firstFrame=$firstFrame '
        'size=${controller.value.width}x${controller.value.height} '
        'fps=${fps.toStringAsFixed(2)} bitrateMbps=${megabitsPerSecond.toStringAsFixed(2)} '
        'frames=$frames inputs=$inputs needMore=${finalVideo.needMore - initialVideo.needMore} '
        'cpuNormalizedPercent=${normalizedCpuPercent.toStringAsFixed(2)} '
        'workingSetMiB=${workingSetMiB.toStringAsFixed(2)} '
        'privateMiB=${privateMiB.toStringAsFixed(2)}',
      );

      expect(firstFrame, greaterThan(0));
      expect(frames, greaterThan(0));
      expect(inputs, greaterThanOrEqualTo(frames));
      expect(controller.value.status, ScrcpyVideoStatus.ready);
    } finally {
      await controller?.stop();
      await session.stop();
      controller?.dispose();
      session.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}

Future<int> _waitForFrame(
  WidgetTester tester,
  MethodChannel channel,
  ScrcpyVideoController controller,
) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    final textureId = controller.value.textureId;
    if (textureId == null) continue;
    final frames = await channel.invokeMethod<int>(
      'frameCount',
      <String, Object>{'textureId': textureId},
    );
    if ((frames ?? 0) > 0) return frames!;
  }
  throw TimeoutException('No decoded video frame');
}

Future<_VideoMetrics> _videoMetrics(
  MethodChannel channel,
  ScrcpyVideoController controller,
) async {
  final stats = await channel.invokeMapMethod<String, Object?>(
    'videoStats',
    <String, Object>{'textureId': controller.value.textureId!},
  );
  if (stats == null) throw StateError('Missing native video metrics');
  return _VideoMetrics(
    frames: stats['frames'] as int,
    inputs: stats['inputs'] as int,
    needMore: stats['needMore'] as int,
  );
}

Future<_ProcessMetrics> _processMetrics(MethodChannel channel) async {
  final stats = await channel.invokeMapMethod<String, Object?>(
    'processMetrics',
    const <String, Object>{},
  );
  if (stats == null) throw StateError('Missing process metrics');
  return _ProcessMetrics(
    workingSetBytes: stats['workingSetBytes'] as int,
    privateBytes: stats['privateBytes'] as int,
    cpuTime100ns: stats['cpuTime100ns'] as int,
    logicalProcessors: stats['logicalProcessors'] as int,
  );
}

final class _VideoMetrics {
  const _VideoMetrics({
    required this.frames,
    required this.inputs,
    required this.needMore,
  });

  final int frames;
  final int inputs;
  final int needMore;
}

final class _ProcessMetrics {
  const _ProcessMetrics({
    required this.workingSetBytes,
    required this.privateBytes,
    required this.cpuTime100ns,
    required this.logicalProcessors,
  });

  final int workingSetBytes;
  final int privateBytes;
  final int cpuTime100ns;
  final int logicalProcessors;
}
