import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:scrcpy_flutter/scrcpy_flutter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('compares two live H.264 quality profiles', (tester) async {
    const serial = String.fromEnvironment('SCRCPY_DEVICE_SERIAL');
    if (serial.isEmpty) return;
    final client = createDefaultScrcpyClient();
    final capabilities = await client.probeVideoCapabilities(serial);
    expect(
      capabilities.forCodec(ScrcpyVideoCodec.h264),
      isNotEmpty,
      reason: 'the H.264 profile requires a device encoder',
    );
    debugPrint(
      'video-capabilities: ${capabilities.encoders.map((encoder) => '${encoder.codec.serverName}:${encoder.name}:${encoder.hardware ? 'hw' : 'sw'}').join(',')}',
    );

    final low = await _measure(
      tester,
      client,
      serial,
      'low',
      const ScrcpyVideoOptions(maxSize: 720, maxFps: 15, bitRate: 2000000),
    );
    final high = await _measure(
      tester,
      client,
      serial,
      'high',
      const ScrcpyVideoOptions(maxSize: 1280, maxFps: 30, bitRate: 8000000),
    );

    expect(low.frames, greaterThan(0));
    expect(high.frames, greaterThan(0));
    expect(high.longEdge, greaterThanOrEqualTo(low.longEdge));
    debugPrint('quality-summary: low=[$low] high=[$high]');
  }, timeout: const Timeout(Duration(minutes: 3)));
}

Future<_QualityMetrics> _measure(
  WidgetTester tester,
  ScrcpyClient client,
  String serial,
  String name,
  ScrcpyVideoOptions options,
) async {
  final session = client.createSession(
    ScrcpySessionConfiguration(
      deviceSerial: serial,
      video: options,
      controlEnabled: false,
    ),
  );
  ScrcpyVideoController? video;
  try {
    final startedAt = DateTime.now();
    final connection = await session.start().timeout(
      const Duration(seconds: 15),
    );
    video = createNativeScrcpyVideoController(connection);
    await video.start().timeout(const Duration(seconds: 15));
    await tester.pumpWidget(
      MaterialApp(home: ScrcpyVideoView(controller: video)),
    );
    while (video.value.framesRendered == 0 &&
        DateTime.now().difference(startedAt) < const Duration(seconds: 10)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final firstFrameMs = DateTime.now().difference(startedAt).inMilliseconds;
    const sampleDuration = Duration(seconds: 6);
    final sampleStartedAt = DateTime.now();
    while (DateTime.now().difference(sampleStartedAt) < sampleDuration) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final value = video.value;
    final elapsed = DateTime.now().difference(startedAt);
    final seconds = elapsed.inMicroseconds / 1000000;
    final frames = value.framesRendered;
    final bytes = value.bytesReceived;
    final metrics = _QualityMetrics(
      name: name,
      width: value.width ?? 0,
      height: value.height ?? 0,
      frames: frames,
      averageFps: frames / seconds,
      megabitsPerSecond: bytes * 8 / seconds / 1000000,
      firstFrameMs: firstFrameMs,
    );
    debugPrint('quality-profile: $metrics');
    return metrics;
  } finally {
    await video?.stop();
    await session.stop();
    video?.dispose();
    session.dispose();
  }
}

final class _QualityMetrics {
  const _QualityMetrics({
    required this.name,
    required this.width,
    required this.height,
    required this.frames,
    required this.averageFps,
    required this.megabitsPerSecond,
    required this.firstFrameMs,
  });

  final String name;
  final int width;
  final int height;
  final int frames;
  final double averageFps;
  final double megabitsPerSecond;
  final int firstFrameMs;

  int get longEdge => width > height ? width : height;

  @override
  String toString() =>
      '$name ${width}x$height frames=$frames '
      'fps=${averageFps.toStringAsFixed(2)} '
      'Mbps=${megabitsPerSecond.toStringAsFixed(2)} '
      'firstFrameMs=$firstFrameMs';
}
