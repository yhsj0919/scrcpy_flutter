import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'scrcpy_audio.dart';
import 'scrcpy_session.dart';
import 'scrcpy_video.dart';

final class ScrcpySessionMetricsSnapshot {
  const ScrcpySessionMetricsSnapshot({
    required this.observedAt,
    required this.sessionState,
    required this.videoStatus,
    required this.audioStatus,
    required this.videoBytesReceived,
    required this.audioBytesReceived,
    required this.videoBitRate,
    required this.audioBitRate,
    required this.videoPacketsReceived,
    required this.audioPacketsReceived,
    required this.framesRendered,
    required this.framesPerSecond,
    required this.audioBuffersPlayed,
    required this.audioBuffersDropped,
    required this.audioBufferedBytes,
    required this.reconnectCount,
    required this.errorCount,
    required this.stallCount,
    this.width,
    this.height,
    this.videoCodec,
    this.audioCodec,
    this.decoder,
    this.estimatedLatencyMs,
    this.gpuUsagePercent,
  });

  final DateTime observedAt;
  final ScrcpySessionState sessionState;
  final ScrcpyVideoStatus? videoStatus;
  final ScrcpyAudioStatus? audioStatus;
  final int? width;
  final int? height;
  final String? videoCodec;
  final String? audioCodec;
  final String? decoder;
  final int videoBytesReceived;
  final int audioBytesReceived;
  final double videoBitRate;
  final double audioBitRate;
  final int videoPacketsReceived;
  final int audioPacketsReceived;
  final int framesRendered;
  final double framesPerSecond;
  final int audioBuffersPlayed;
  final int audioBuffersDropped;
  final int audioBufferedBytes;
  final int reconnectCount;
  final int errorCount;
  final int stallCount;

  /// Null until the transport and decoder expose a comparable capture clock.
  final double? estimatedLatencyMs;

  /// Null when the platform cannot attribute GPU work to this session.
  final double? gpuUsagePercent;

  Map<String, Object?> toJson() => <String, Object?>{
    'observedAt': observedAt.toIso8601String(),
    'sessionState': sessionState.name,
    'videoStatus': videoStatus?.name,
    'audioStatus': audioStatus?.name,
    'width': width,
    'height': height,
    'videoCodec': videoCodec,
    'audioCodec': audioCodec,
    'decoder': decoder,
    'videoBytesReceived': videoBytesReceived,
    'audioBytesReceived': audioBytesReceived,
    'videoBitRate': videoBitRate,
    'audioBitRate': audioBitRate,
    'videoPacketsReceived': videoPacketsReceived,
    'audioPacketsReceived': audioPacketsReceived,
    'framesRendered': framesRendered,
    'framesPerSecond': framesPerSecond,
    'audioBuffersPlayed': audioBuffersPlayed,
    'audioBuffersDropped': audioBuffersDropped,
    'audioBufferedBytes': audioBufferedBytes,
    'reconnectCount': reconnectCount,
    'errorCount': errorCount,
    'stallCount': stallCount,
    'estimatedLatencyMs': estimatedLatencyMs,
    'gpuUsagePercent': gpuUsagePercent,
  };
}

final class ScrcpySessionMetricsCollector extends ChangeNotifier {
  ScrcpySessionMetricsCollector({
    required this.sessionState,
    required this.videoCodec,
    this.interval = const Duration(seconds: 1),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    if (interval <= Duration.zero) {
      throw ArgumentError.value(interval, 'interval');
    }
    sessionState.addListener(_sample);
    _timer = Timer.periodic(interval, (_) => _sample());
    _sample();
  }

  final ValueListenable<ScrcpySessionState> sessionState;
  final String videoCodec;
  final Duration interval;
  final DateTime Function() _clock;
  ScrcpyVideoController? _video;
  ScrcpyAudioController? _audio;
  Timer? _timer;
  DateTime? _previousAt;
  int _previousVideoBytes = 0;
  int _previousAudioBytes = 0;
  int _previousFrames = 0;
  int _reconnectCount = 0;
  int _errorCount = 0;
  int _stallCount = 0;
  bool _wasVideoError = false;
  bool _wasStalled = false;
  bool _disposed = false;
  ScrcpySessionMetricsSnapshot? _value;

  ScrcpySessionMetricsSnapshot? get value => _value;

  @visibleForTesting
  void sampleNow() => _sample();

  void attach({
    ScrcpyVideoController? video,
    ScrcpyAudioController? audio,
    int? reconnectCount,
  }) {
    if (identical(video, _video) &&
        identical(audio, _audio) &&
        (reconnectCount == null || reconnectCount == _reconnectCount)) {
      return;
    }
    _video = video;
    _audio = audio;
    if (reconnectCount != null) _reconnectCount = reconnectCount;
    _resetRateBaseline();
    _sample();
  }

  void updateReconnectCount(int value) {
    if (value == _reconnectCount) return;
    _reconnectCount = value;
    _sample();
  }

  void _resetRateBaseline() {
    _previousAt = null;
    _previousVideoBytes = _video?.value.bytesReceived ?? 0;
    _previousAudioBytes = _audio?.value.bytesReceived ?? 0;
    _previousFrames = _video?.value.framesRendered ?? 0;
    _wasStalled = false;
  }

  void _sample() {
    if (_disposed) return;
    final now = _clock();
    final video = _video?.value;
    final audio = _audio?.value;
    final videoBytes = video?.bytesReceived ?? 0;
    final audioBytes = audio?.bytesReceived ?? 0;
    final frames = video?.framesRendered ?? 0;
    final elapsed = _previousAt == null
        ? 0.0
        : now.difference(_previousAt!).inMicroseconds / 1000000;
    final videoRate = elapsed <= 0 || videoBytes < _previousVideoBytes
        ? 0.0
        : (videoBytes - _previousVideoBytes) * 8 / elapsed;
    final audioRate = elapsed <= 0 || audioBytes < _previousAudioBytes
        ? 0.0
        : (audioBytes - _previousAudioBytes) * 8 / elapsed;
    final isVideoError = video?.status == ScrcpyVideoStatus.error;
    if (isVideoError && !_wasVideoError) _errorCount++;
    _wasVideoError = isVideoError;
    final stalled =
        elapsed > 0 &&
        sessionState.value == ScrcpySessionState.streaming &&
        videoBytes > _previousVideoBytes &&
        frames == _previousFrames;
    if (stalled && !_wasStalled) _stallCount++;
    _wasStalled = stalled;
    _previousAt = now;
    _previousVideoBytes = videoBytes;
    _previousAudioBytes = audioBytes;
    _previousFrames = frames;
    _value = ScrcpySessionMetricsSnapshot(
      observedAt: now,
      sessionState: sessionState.value,
      videoStatus: video?.status,
      audioStatus: audio?.status,
      width: video?.width,
      height: video?.height,
      videoCodec: videoCodec,
      audioCodec: audio?.codec,
      decoder: video?.decoder,
      videoBytesReceived: videoBytes,
      audioBytesReceived: audioBytes,
      videoBitRate: videoRate,
      audioBitRate: audioRate,
      videoPacketsReceived: video?.packetsReceived ?? 0,
      audioPacketsReceived: audio?.packetsReceived ?? 0,
      framesRendered: frames,
      framesPerSecond: video?.framesPerSecond ?? 0,
      audioBuffersPlayed: audio?.playedBuffers ?? 0,
      audioBuffersDropped: audio?.droppedBuffers ?? 0,
      audioBufferedBytes: audio?.bufferedBytes ?? 0,
      reconnectCount: _reconnectCount,
      errorCount: _errorCount,
      stallCount: _stallCount,
    );
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    sessionState.removeListener(_sample);
    super.dispose();
  }
}

final class ScrcpyProcessMetricsSnapshot {
  const ScrcpyProcessMetricsSnapshot({
    required this.observedAt,
    required this.cpuUsagePercent,
    required this.workingSetBytes,
    required this.privateBytes,
    required this.threadCount,
    this.gpuUsagePercent,
  });

  final DateTime observedAt;
  final double cpuUsagePercent;
  final int workingSetBytes;
  final int privateBytes;
  final int threadCount;
  final double? gpuUsagePercent;

  Map<String, Object?> toJson() => <String, Object?>{
    'observedAt': observedAt.toIso8601String(),
    'cpuUsagePercent': cpuUsagePercent,
    'workingSetBytes': workingSetBytes,
    'privateBytes': privateBytes,
    'threadCount': threadCount,
    'gpuUsagePercent': gpuUsagePercent,
  };
}

final class ScrcpyProcessMetricsCollector extends ChangeNotifier {
  ScrcpyProcessMetricsCollector({this.interval = const Duration(seconds: 1)}) {
    if (interval <= Duration.zero) {
      throw ArgumentError.value(interval, 'interval');
    }
    _timer = Timer.periodic(interval, (_) => unawaited(sample()));
    unawaited(sample());
  }

  static const MethodChannel _channel = MethodChannel('scrcpy_flutter/video');
  final Duration interval;
  Timer? _timer;
  DateTime? _previousAt;
  int? _previousCpuTime100ns;
  bool _sampling = false;
  bool _disposed = false;
  ScrcpyProcessMetricsSnapshot? _value;

  ScrcpyProcessMetricsSnapshot? get value => _value;

  Future<void> sample() async {
    if (_disposed || _sampling) return;
    _sampling = true;
    try {
      final values = await _channel.invokeMapMethod<String, Object?>(
        'processMetrics',
      );
      if (_disposed || values == null) return;
      final now = DateTime.now();
      final cpuTime = values['cpuTime100ns'] as int? ?? 0;
      final processors = (values['logicalProcessors'] as int? ?? 1).clamp(
        1,
        1024,
      );
      var cpu = 0.0;
      if (_previousAt != null && _previousCpuTime100ns != null) {
        final wallSeconds =
            now.difference(_previousAt!).inMicroseconds / 1000000;
        final cpuSeconds = (cpuTime - _previousCpuTime100ns!) / 10000000;
        if (wallSeconds > 0 && cpuSeconds >= 0) {
          cpu = (cpuSeconds / wallSeconds / processors * 100).clamp(0, 100);
        }
      }
      _previousAt = now;
      _previousCpuTime100ns = cpuTime;
      _value = ScrcpyProcessMetricsSnapshot(
        observedAt: now,
        cpuUsagePercent: cpu,
        workingSetBytes: values['workingSetBytes'] as int? ?? 0,
        privateBytes: values['privateBytes'] as int? ?? 0,
        threadCount: values['threadCount'] as int? ?? 0,
      );
      notifyListeners();
    } on MissingPluginException {
      // Process metrics are optional on platforms without a native sampler.
    } on PlatformException {
      // Diagnostics must never interrupt active sessions.
    } finally {
      _sampling = false;
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
