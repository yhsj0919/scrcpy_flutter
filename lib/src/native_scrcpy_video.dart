import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'scrcpy_video.dart';
import 'scrcpy_video_connection.dart';
import 'scrcpy_video_packet.dart';

ScrcpyVideoController createNativeScrcpyVideoController(
  ScrcpyVideoConnection connection,
) => _NativeScrcpyVideoController(connection);

final class _NativeScrcpyVideoController extends ChangeNotifier
    implements ScrcpyVideoController {
  _NativeScrcpyVideoController(this._connection);

  static const MethodChannel _channel = MethodChannel('scrcpy_flutter/video');
  final ScrcpyVideoConnection _connection;
  StreamSubscription<ScrcpyVideoPacket>? _subscription;
  StreamSubscription<ScrcpyVideoCodecInfo>? _sessionSubscription;
  ScrcpyVideoState _value = const ScrcpyVideoState.idle();
  int? _textureId;
  bool _disposed = false;
  Uint8List? _pendingConfig;
  int _packetCount = 0;
  Timer? _statsTimer;
  int _lastFrameCount = 0;
  DateTime? _lastStatsAt;
  Future<void> _sessionChange = Future<void>.value();

  @override
  ScrcpyVideoState get value => _value;

  void _setValue(ScrcpyVideoState value) {
    if (_disposed) return;
    _value = value;
    notifyListeners();
  }

  @override
  Future<void> start() async {
    _setValue(const ScrcpyVideoState(status: ScrcpyVideoStatus.buffering));
    try {
      final codec = await _connection.codec.timeout(const Duration(seconds: 5));
      final textureId = await _channel.invokeMethod<int>(
        'create',
        <String, Object>{
          'codecId': codec.codecId,
          'width': codec.width,
          'height': codec.height,
        },
      );
      if (textureId == null || textureId < 0) {
        throw StateError('Native video backend did not create a texture');
      }
      _textureId = textureId;
      late final StreamSubscription<ScrcpyVideoPacket> subscription;
      subscription = _connection.packets.listen(
        (packet) {
          subscription.pause();
          final activeTextureId = _textureId;
          if (activeTextureId == null) {
            subscription.resume();
          } else {
            unawaited(
              _decode(
                activeTextureId,
                packet,
              ).whenComplete(subscription.resume),
            );
          }
        },
        onError: (Object error) => _setValue(
          ScrcpyVideoState(status: ScrcpyVideoStatus.error, error: error),
        ),
      );
      _subscription = subscription;
      _sessionSubscription = _connection.sessions.listen(
        (session) {
          _sessionChange = _sessionChange.then((_) => _handleSession(session));
        },
        onError: (Object error) => _setValue(
          ScrcpyVideoState(status: ScrcpyVideoStatus.error, error: error),
        ),
      );
      _setValue(
        ScrcpyVideoState(
          status: ScrcpyVideoStatus.ready,
          textureId: textureId,
          width: codec.width,
          height: codec.height,
          decoder: 'native',
        ),
      );
      _lastStatsAt = DateTime.now();
      _statsTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => unawaited(_updateStats()),
      );
    } catch (error) {
      try {
        await stop().timeout(const Duration(seconds: 5));
      } catch (_) {
        // Preserve the startup error if best-effort cleanup also fails.
      }
      _setValue(
        ScrcpyVideoState(status: ScrcpyVideoStatus.error, error: error),
      );
      rethrow;
    }
  }

  Future<void> _updateStats() async {
    final textureId = _textureId;
    if (_disposed || textureId == null) return;
    try {
      final stats = await _channel.invokeMapMethod<String, Object?>(
        'videoStats',
        <String, Object>{'textureId': textureId},
      );
      if (stats == null || _textureId != textureId) return;
      final frames = stats['frames'] as int? ?? 0;
      final now = DateTime.now();
      final previousAt = _lastStatsAt ?? now;
      final seconds = now.difference(previousAt).inMicroseconds / 1000000;
      final fps = seconds > 0 ? (frames - _lastFrameCount) / seconds : 0.0;
      _lastFrameCount = frames;
      _lastStatsAt = now;
      _setValue(
        ScrcpyVideoState(
          status: _value.status,
          textureId: _value.textureId,
          width: _value.width,
          height: _value.height,
          decoder: _value.decoder,
          bytesReceived: _connection.bytesReceived,
          packetsReceived: _packetCount,
          framesRendered: frames,
          framesPerSecond: fps,
          error: _value.error,
        ),
      );
    } catch (_) {
      // Diagnostics must not interrupt video playback.
    }
  }

  Future<void> _handleSession(ScrcpyVideoCodecInfo session) async {
    final current = _value;
    if (_disposed || _textureId == null) return;
    if (current.width == session.width && current.height == session.height) {
      return;
    }
    final packets = _subscription;
    packets?.pause();
    try {
      final oldTextureId = _textureId;
      if (oldTextureId != null) {
        await _channel.invokeMethod<void>('dispose', <String, Object>{
          'textureId': oldTextureId,
        });
      }
      final newTextureId = await _channel.invokeMethod<int>(
        'create',
        <String, Object>{
          'codecId': session.codecId,
          'width': session.width,
          'height': session.height,
        },
      );
      if (newTextureId == null || newTextureId < 0) {
        throw StateError('Native video backend did not recreate a texture');
      }
      _textureId = newTextureId;
      _pendingConfig = null;
      _lastFrameCount = 0;
      _lastStatsAt = DateTime.now();
      _setValue(
        ScrcpyVideoState(
          status: ScrcpyVideoStatus.ready,
          textureId: newTextureId,
          width: session.width,
          height: session.height,
          decoder: current.decoder,
          bytesReceived: _connection.bytesReceived,
          packetsReceived: _packetCount,
        ),
      );
    } catch (error) {
      _setValue(
        ScrcpyVideoState(status: ScrcpyVideoStatus.error, error: error),
      );
    } finally {
      packets?.resume();
    }
  }

  Future<void> _decode(int textureId, ScrcpyVideoPacket packet) async {
    try {
      _packetCount++;
      if (kDebugMode && _packetCount <= 5) {
        debugPrint(
          'scrcpy packet: bytes=${packet.data.length} '
          'config=${packet.isConfig} key=${packet.isKeyFrame} '
          'pts=${packet.presentationTimeUs} head='
          '${packet.data.take(16).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(' ')}',
        );
      }
      if (packet.isConfig) {
        _pendingConfig = packet.data;
        await _channel.invokeMethod<void>('decode', <String, Object>{
          'textureId': textureId,
          'data': packet.data,
          'pts': packet.presentationTimeUs,
          'config': true,
          'keyFrame': false,
        });
        return;
      }
      final config = _pendingConfig;
      await _channel.invokeMethod<void>('decode', <String, Object>{
        'textureId': textureId,
        'data': config == null
            ? packet.data
            : (Uint8List(config.length + packet.data.length)
                ..setRange(0, config.length, config)
                ..setRange(
                  config.length,
                  config.length + packet.data.length,
                  packet.data,
                )),
        'pts': packet.presentationTimeUs,
        'config': false,
        'keyFrame': packet.isKeyFrame,
      });
      _pendingConfig = null;
    } catch (error) {
      _setValue(
        ScrcpyVideoState(status: ScrcpyVideoStatus.error, error: error),
      );
    }
  }

  @override
  Future<void> stop() async {
    _statsTimer?.cancel();
    _statsTimer = null;
    await _sessionSubscription?.cancel();
    _sessionSubscription = null;
    await _sessionChange;
    await _subscription?.cancel();
    _subscription = null;
    _pendingConfig = null;
    _packetCount = 0;
    _lastFrameCount = 0;
    _lastStatsAt = null;
    final textureId = _textureId;
    _textureId = null;
    if (textureId != null) {
      await _channel.invokeMethod<void>('dispose', <String, Object>{
        'textureId': textureId,
      });
    }
    await _connection.close();
    _setValue(const ScrcpyVideoState.idle());
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}
