import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:scrcpy_flutter/scrcpy_advanced.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('keeps native video stable for 30 minutes', (tester) async {
    const serial = String.fromEnvironment('SCRCPY_DEVICE_SERIAL');
    const minutes = int.fromEnvironment(
      'SCRCPY_STABILITY_MINUTES',
      defaultValue: 30,
    );
    if (serial.isEmpty) return;
    if (minutes < 1 || minutes > 120) {
      throw ArgumentError.value(minutes, 'SCRCPY_STABILITY_MINUTES', '1..120');
    }

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
      controller = createNativeScrcpyVideoController(connection);
      await controller.start().timeout(const Duration(seconds: 15));
      await tester.pumpWidget(
        MaterialApp(home: ScrcpyVideoView(controller: controller)),
      );
      await _waitForFrame(tester, channel, controller);

      final startedAt = DateTime.now();
      final firstProcess = await _processMetrics(channel);
      var previousProcess = firstProcess;
      var previousSampleAt = startedAt;
      var peakWorkingSet = firstProcess.workingSetBytes;
      var peakPrivateBytes = firstProcess.privateBytes;
      var lastVideo = await _videoMetrics(channel, controller);

      for (var minute = 1; minute <= minutes; minute++) {
        final target = startedAt.add(Duration(minutes: minute));
        while (DateTime.now().isBefore(target)) {
          await tester.pump(const Duration(milliseconds: 500));
          if (controller.value.status == ScrcpyVideoStatus.error) {
            throw StateError(
              'Video failed at minute $minute: ${controller.value.error}',
            );
          }
        }

        final now = DateTime.now();
        final process = await _processMetrics(channel);
        final video = await _videoMetrics(channel, controller);
        final sampleSeconds =
            now.difference(previousSampleAt).inMicroseconds / 1000000;
        final cpuSeconds =
            (process.cpuTime100ns - previousProcess.cpuTime100ns) / 10000000;
        final cpuPercent =
            cpuSeconds / sampleSeconds / process.logicalProcessors * 100;
        peakWorkingSet = process.workingSetBytes > peakWorkingSet
            ? process.workingSetBytes
            : peakWorkingSet;
        peakPrivateBytes = process.privateBytes > peakPrivateBytes
            ? process.privateBytes
            : peakPrivateBytes;
        debugPrint(
          'video-stability: minute=$minute/$minutes '
          'status=${controller.value.status.name} '
          'frames=${video.frames} inputs=${video.inputs} '
          'needMore=${video.needMore} bytes=${connection.bytesReceived} '
          'cpuPercent=${cpuPercent.toStringAsFixed(2)} '
          'workingSetMiB=${(process.workingSetBytes / 1024 / 1024).toStringAsFixed(2)} '
          'privateMiB=${(process.privateBytes / 1024 / 1024).toStringAsFixed(2)}',
        );
        expect(video.frames, greaterThanOrEqualTo(lastVideo.frames));
        expect(video.inputs, greaterThanOrEqualTo(lastVideo.inputs));
        previousProcess = process;
        previousSampleAt = now;
        lastVideo = video;
      }

      final finalProcess = await _processMetrics(channel);
      final workingSetGrowth =
          finalProcess.workingSetBytes - firstProcess.workingSetBytes;
      final privateGrowth =
          finalProcess.privateBytes - firstProcess.privateBytes;
      debugPrint(
        'video-stability-summary: minutes=$minutes '
        'frames=${lastVideo.frames} inputs=${lastVideo.inputs} '
        'workingSetGrowthMiB=${(workingSetGrowth / 1024 / 1024).toStringAsFixed(2)} '
        'privateGrowthMiB=${(privateGrowth / 1024 / 1024).toStringAsFixed(2)} '
        'peakWorkingSetMiB=${(peakWorkingSet / 1024 / 1024).toStringAsFixed(2)} '
        'peakPrivateMiB=${(peakPrivateBytes / 1024 / 1024).toStringAsFixed(2)}',
      );
      expect(controller.value.status, ScrcpyVideoStatus.ready);
      expect(lastVideo.frames, greaterThan(0));
      expect(workingSetGrowth, lessThan(256 * 1024 * 1024));
      expect(privateGrowth, lessThan(256 * 1024 * 1024));
    } finally {
      await controller?.stop();
      await session.stop();
      controller?.dispose();
      session.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 125)));
}

Future<void> _waitForFrame(
  WidgetTester tester,
  MethodChannel channel,
  ScrcpyVideoController controller,
) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    final video = await _videoMetrics(channel, controller);
    if (video.frames > 0) return;
  }
  throw TimeoutException('No decoded video frame');
}

Future<_VideoMetrics> _videoMetrics(
  MethodChannel channel,
  ScrcpyVideoController controller,
) async {
  final textureId = controller.value.textureId;
  if (textureId == null) return const _VideoMetrics(0, 0, 0);
  final stats = await channel.invokeMapMethod<String, Object?>(
    'videoStats',
    <String, Object>{'textureId': textureId},
  );
  if (stats == null) throw StateError('Missing native video metrics');
  return _VideoMetrics(
    stats['frames'] as int,
    stats['inputs'] as int,
    stats['needMore'] as int,
  );
}

Future<_ProcessMetrics> _processMetrics(MethodChannel channel) async {
  final stats = await channel.invokeMapMethod<String, Object?>(
    'processMetrics',
    const <String, Object>{},
  );
  if (stats == null) throw StateError('Missing process metrics');
  return _ProcessMetrics(
    stats['workingSetBytes'] as int,
    stats['privateBytes'] as int,
    stats['cpuTime100ns'] as int,
    stats['logicalProcessors'] as int,
  );
}

final class _VideoMetrics {
  const _VideoMetrics(this.frames, this.inputs, this.needMore);

  final int frames;
  final int inputs;
  final int needMore;
}

final class _ProcessMetrics {
  const _ProcessMetrics(
    this.workingSetBytes,
    this.privateBytes,
    this.cpuTime100ns,
    this.logicalProcessors,
  );

  final int workingSetBytes;
  final int privateBytes;
  final int cpuTime100ns;
  final int logicalProcessors;
}
