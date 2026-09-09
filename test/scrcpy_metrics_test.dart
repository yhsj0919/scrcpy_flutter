import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrcpy_flutter/scrcpy_advanced.dart';

void main() {
  test('samples per-session rates, stalls, errors and reconnects', () {
    var now = DateTime(2026);
    final session = ValueNotifier<ScrcpySessionState>(
      ScrcpySessionState.streaming,
    );
    final video = _FakeVideoController();
    final audio = _FakeAudioController();
    final collector = ScrcpySessionMetricsCollector(
      sessionState: session,
      videoCodec: 'h264',
      interval: const Duration(days: 1),
      clock: () => now,
    );
    addTearDown(collector.dispose);
    addTearDown(session.dispose);
    collector.attach(video: video, audio: audio, reconnectCount: 2);

    now = now.add(const Duration(seconds: 1));
    video.state = const ScrcpyVideoState(
      status: ScrcpyVideoStatus.ready,
      width: 1080,
      height: 1920,
      decoder: 'native',
      bytesReceived: 125000,
      packetsReceived: 30,
      framesRendered: 20,
      framesPerSecond: 20,
    );
    audio.state = const ScrcpyAudioState(
      status: ScrcpyAudioStatus.ready,
      codec: 'opus',
      bytesReceived: 16000,
      packetsReceived: 50,
      playedBuffers: 48,
      droppedBuffers: 2,
    );
    collector.sampleNow();

    expect(collector.value!.videoBitRate, 1000000);
    expect(collector.value!.audioBitRate, 128000);
    expect(collector.value!.framesPerSecond, 20);
    expect(collector.value!.reconnectCount, 2);
    expect(collector.value!.stallCount, 0);

    now = now.add(const Duration(seconds: 1));
    video.state = const ScrcpyVideoState(
      status: ScrcpyVideoStatus.ready,
      bytesReceived: 250000,
      packetsReceived: 60,
      framesRendered: 20,
    );
    collector.sampleNow();
    expect(collector.value!.stallCount, 1);

    now = now.add(const Duration(seconds: 1));
    video.state = const ScrcpyVideoState(
      status: ScrcpyVideoStatus.error,
      bytesReceived: 250000,
      framesRendered: 20,
    );
    collector.sampleNow();
    collector.sampleNow();
    expect(collector.value!.errorCount, 1);
  });

  test('serializes unavailable latency and GPU as null', () {
    final snapshot = ScrcpySessionMetricsSnapshot(
      observedAt: DateTime(2026),
      sessionState: ScrcpySessionState.streaming,
      videoStatus: ScrcpyVideoStatus.ready,
      audioStatus: null,
      videoBytesReceived: 0,
      audioBytesReceived: 0,
      videoBitRate: 0,
      audioBitRate: 0,
      videoPacketsReceived: 0,
      audioPacketsReceived: 0,
      framesRendered: 0,
      framesPerSecond: 0,
      audioBuffersPlayed: 0,
      audioBuffersDropped: 0,
      audioBufferedBytes: 0,
      reconnectCount: 0,
      errorCount: 0,
      stallCount: 0,
    );

    expect(snapshot.toJson()['estimatedLatencyMs'], isNull);
    expect(snapshot.toJson()['gpuUsagePercent'], isNull);
  });

  test('keeps bounded session history and aggregates latest values', () {
    var now = DateTime(2026);
    final session = ValueNotifier<ScrcpySessionState>(
      ScrcpySessionState.streaming,
    );
    final video = _FakeVideoController();
    final collector = ScrcpySessionMetricsCollector(
      sessionState: session,
      videoCodec: 'h264',
      interval: const Duration(days: 1),
      historyLimit: 2,
      clock: () => now,
    );
    addTearDown(collector.dispose);
    addTearDown(session.dispose);
    collector.attach(video: video);
    for (var index = 1; index <= 3; index++) {
      now = now.add(const Duration(seconds: 1));
      video.state = ScrcpyVideoState(
        status: ScrcpyVideoStatus.ready,
        bytesReceived: index * 125000,
        framesRendered: index * 30,
        framesPerSecond: 30,
      );
      collector.sampleNow();
    }

    expect(collector.history, hasLength(2));
    expect(collector.history.last.framesRendered, 90);
    final aggregate = ScrcpyMetricsAggregate.fromSessions(collector.history);
    expect(aggregate.sessionCount, 2);
    expect(aggregate.streamingCount, 2);
    expect(aggregate.totalFramesPerSecond, 60);
  });

  test('diagnostics report exports versioned histories and aggregate', () {
    final snapshot = ScrcpySessionMetricsSnapshot(
      observedAt: DateTime(2026),
      sessionState: ScrcpySessionState.streaming,
      videoStatus: ScrcpyVideoStatus.ready,
      audioStatus: null,
      videoBytesReceived: 100,
      audioBytesReceived: 0,
      videoBitRate: 800,
      audioBitRate: 0,
      videoPacketsReceived: 1,
      audioPacketsReceived: 0,
      framesRendered: 1,
      framesPerSecond: 1,
      audioBuffersPlayed: 0,
      audioBuffersDropped: 0,
      audioBufferedBytes: 0,
      reconnectCount: 0,
      errorCount: 0,
      stallCount: 0,
    );
    final report = ScrcpyDiagnosticsReport(
      generatedAt: DateTime(2026),
      sessions: <String, List<ScrcpySessionMetricsSnapshot>>{
        'session-1': <ScrcpySessionMetricsSnapshot>[snapshot],
      },
      process: const <ScrcpyProcessMetricsSnapshot>[],
      metadata: const <String, Object?>{'platform': 'windows'},
    );

    final json = report.toJson();
    expect(json['schemaVersion'], 1);
    expect((json['aggregate']! as Map<String, Object?>)['sessionCount'], 1);
    expect(report.encode(), contains('session-1'));
  });
}

final class _FakeVideoController extends ChangeNotifier
    implements ScrcpyVideoController {
  ScrcpyVideoState state = const ScrcpyVideoState.idle();

  @override
  ScrcpyVideoState get value => state;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<ScrcpyScreenshot> captureFrame() =>
      throw UnimplementedError('Not used by this test');

  @override
  bool get isRecording => false;

  @override
  Future<void> startRecording(String path) async {}

  @override
  Future<int> stopRecording() async => 0;
}

final class _FakeAudioController extends ChangeNotifier
    implements ScrcpyAudioController {
  ScrcpyAudioState state = const ScrcpyAudioState.idle();

  @override
  ScrcpyAudioState get value => state;

  @override
  Future<void> setMuted(bool muted) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
}
