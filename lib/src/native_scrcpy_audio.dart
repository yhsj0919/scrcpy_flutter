import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'scrcpy_audio.dart';
import 'scrcpy_audio_packet.dart';
import 'scrcpy_error.dart';
import 'scrcpy_video_connection.dart';

ScrcpyAudioController createNativeScrcpyAudioController(
  ScrcpyAudioStream audio, {
  int bitRate = 128000,
}) => _NativeScrcpyAudioController(audio, bitRate);

final class _NativeScrcpyAudioController extends ChangeNotifier
    implements ScrcpyAudioController {
  _NativeScrcpyAudioController(this._audio, this._bitRate);

  static const MethodChannel _channel = MethodChannel('scrcpy_flutter/audio');
  final ScrcpyAudioStream _audio;
  final int _bitRate;
  StreamSubscription<ScrcpyAudioPacket>? _subscription;
  ScrcpyAudioState _value = const ScrcpyAudioState.idle();
  int? _audioId;
  int _packets = 0;
  Timer? _statsTimer;
  bool _disposed = false;
  Future<void>? _stopping;

  @override
  ScrcpyAudioState get value => _value;

  void _setValue(ScrcpyAudioState value) {
    if (_disposed) return;
    _value = value;
    notifyListeners();
  }

  @override
  Future<void> start() async {
    _setValue(
      ScrcpyAudioState(
        status: ScrcpyAudioStatus.buffering,
        muted: _value.muted,
        volume: _value.volume,
      ),
    );
    try {
      final codec = await _audio.codec.timeout(const Duration(seconds: 5));
      if (const bool.fromEnvironment('SCRCPY_DIAGNOSTICS')) {
        debugPrint('scrcpy audio: metadata received; creating player');
      }
      if (codec == null) {
        throw const ScrcpyException(
          ScrcpyErrorCode.unsupportedCapability,
          'scrcpy audio capture is unavailable',
        );
      }
      if (codec.codec != ScrcpyAudioCodec.opus) {
        throw ScrcpyException(
          ScrcpyErrorCode.unsupportedCapability,
          'The native audio backend currently supports Opus only; '
          'received ${codec.codec.label}',
        );
      }
      final audioId = await _channel.invokeMethod<int>(
        'create',
        <String, Object>{'bitRate': _bitRate},
      );
      if (audioId == null || audioId < 0) {
        throw StateError('Native audio backend did not create a player');
      }
      _audioId = audioId;
      if (const bool.fromEnvironment('SCRCPY_DIAGNOSTICS')) {
        debugPrint('scrcpy audio: player $audioId created');
      }
      await _channel.invokeMethod<void>('setMuted', <String, Object>{
        'audioId': audioId,
        'muted': _value.muted,
      });
      await _channel.invokeMethod<void>('setVolume', <String, Object>{
        'audioId': audioId,
        'volume': _value.volume,
      });
      late final StreamSubscription<ScrcpyAudioPacket> subscription;
      subscription = _audio.packets.listen(
        (packet) {
          subscription.pause();
          unawaited(_decode(audioId, packet).whenComplete(subscription.resume));
        },
        onError: (Object error) => _setError(error),
        onDone: () {
          if (!_disposed && _value.status != ScrcpyAudioStatus.error) {
            _setValue(_copyState(status: ScrcpyAudioStatus.ended));
          }
        },
      );
      _subscription = subscription;
      _setValue(
        ScrcpyAudioState(
          status: ScrcpyAudioStatus.ready,
          codec: codec.codec.serverName,
          muted: _value.muted,
          volume: _value.volume,
        ),
      );
      _statsTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => unawaited(_updateStats()),
      );
    } catch (error) {
      await stop();
      _setError(error);
      rethrow;
    }
  }

  Future<void> _decode(int audioId, ScrcpyAudioPacket packet) async {
    try {
      _packets++;
      await _channel.invokeMethod<void>('decode', <String, Object>{
        'audioId': audioId,
        'data': packet.data,
        'pts': packet.presentationTimeUs,
        'config': packet.isConfig,
      });
    } catch (error) {
      _setError(error);
    }
  }

  Future<void> _updateStats() async {
    final audioId = _audioId;
    if (_disposed || audioId == null) return;
    try {
      final stats = await _channel.invokeMapMethod<String, Object?>(
        'audioStats',
        <String, Object>{'audioId': audioId},
      );
      if (stats == null || _audioId != audioId) return;
      _setValue(
        _copyState(
          packetsReceived: _packets,
          bytesReceived: _audio.bytesReceived,
          decodedPackets: stats['decodedPackets'] as int? ?? 0,
          playedBuffers: stats['playedBuffers'] as int? ?? 0,
          droppedBuffers: stats['droppedBuffers'] as int? ?? 0,
          bufferedBytes: stats['bufferedBytes'] as int? ?? 0,
          peakSample: stats['peakSample'] as int? ?? 0,
        ),
      );
    } catch (_) {
      // Diagnostics must not interrupt playback.
    }
  }

  @override
  Future<void> setMuted(bool muted) async {
    final audioId = _audioId;
    if (audioId != null) {
      await _channel.invokeMethod<void>('setMuted', <String, Object>{
        'audioId': audioId,
        'muted': muted,
      });
    }
    _setValue(_copyState(muted: muted));
  }

  @override
  Future<void> setVolume(double volume) async {
    if (!volume.isFinite || volume < 0 || volume > 1) {
      throw RangeError.range(volume, 0, 1, 'volume');
    }
    final audioId = _audioId;
    if (audioId != null) {
      await _channel.invokeMethod<void>('setVolume', <String, Object>{
        'audioId': audioId,
        'volume': volume,
      });
    }
    _setValue(_copyState(volume: volume));
  }

  ScrcpyAudioState _copyState({
    ScrcpyAudioStatus? status,
    bool? muted,
    double? volume,
    int? packetsReceived,
    int? bytesReceived,
    int? decodedPackets,
    int? playedBuffers,
    int? droppedBuffers,
    int? bufferedBytes,
    int? peakSample,
    Object? error,
  }) => ScrcpyAudioState(
    status: status ?? _value.status,
    codec: _value.codec,
    muted: muted ?? _value.muted,
    volume: volume ?? _value.volume,
    packetsReceived: packetsReceived ?? _value.packetsReceived,
    bytesReceived: bytesReceived ?? _value.bytesReceived,
    decodedPackets: decodedPackets ?? _value.decodedPackets,
    playedBuffers: playedBuffers ?? _value.playedBuffers,
    droppedBuffers: droppedBuffers ?? _value.droppedBuffers,
    bufferedBytes: bufferedBytes ?? _value.bufferedBytes,
    peakSample: peakSample ?? _value.peakSample,
    error: error ?? _value.error,
  );

  void _setError(Object error) {
    _setValue(_copyState(status: ScrcpyAudioStatus.error, error: error));
  }

  @override
  Future<void> stop() => _stopping ??= _stop().whenComplete(() {
    _stopping = null;
  });

  Future<void> _stop() async {
    _statsTimer?.cancel();
    _statsTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    final audioId = _audioId;
    _audioId = null;
    if (audioId != null) {
      await _channel.invokeMethod<void>('dispose', <String, Object>{
        'audioId': audioId,
      });
    }
    _packets = 0;
    _setValue(const ScrcpyAudioState.idle());
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(stop().catchError((Object _) {}));
    super.dispose();
  }
}
