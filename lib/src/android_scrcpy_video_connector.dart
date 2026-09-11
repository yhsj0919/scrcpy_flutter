import 'dart:async';

import 'package:adb_client/adb_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'scrcpy_audio.dart';
import 'scrcpy_capture.dart';
import 'scrcpy_control_message.dart';
import 'scrcpy_display_source.dart';
import 'scrcpy_error.dart';
import 'scrcpy_input.dart';
import 'scrcpy_session.dart';
import 'scrcpy_video.dart';
import 'scrcpy_video_connection.dart';
import 'scrcpy_video_packet.dart';

final class AndroidScrcpyVideoConnector implements ScrcpyVideoConnector {
  AndroidScrcpyVideoConnector();

  static const _channel = MethodChannel('scrcpy_flutter/android_session');
  static final _connections = <String, _AndroidScrcpyVideoConnection>{};
  static bool _handlerInstalled = false;

  @override
  Future<ScrcpyVideoConnection> connect(
    ScrcpySessionConfiguration configuration, {
    AdbCancellationToken? cancellationToken,
  }) async {
    configuration.validate();
    _installHandler();
    if (cancellationToken?.isCancelled ?? false) {
      throw const ScrcpyException(
        ScrcpyErrorCode.cancelled,
        'scrcpy connection cancelled',
      );
    }
    final result = await _channel.invokeMapMethod<String, Object?>('start', {
      'deviceSerial': configuration.deviceSerial,
      'maxSize': configuration.video.maxSize,
      'maxFps': configuration.video.maxFps,
      'bitRate': configuration.video.bitRate,
      'videoCodec': configuration.video.codec.serverName,
      'videoEncoder': ?configuration.video.encoder,
      'videoCodecOptions': ?configuration.video.codecOptions,
      'control': configuration.controlEnabled,
      'audio': configuration.audioEnabled,
      'audioRequired': configuration.audioRequired,
      'audioCodec': configuration.audio.codec.serverName,
      'audioBitRate': configuration.audio.bitRate,
      'audioSource': ?configuration.audio.source.serverName,
      'audioDup': configuration.audio.duplicateOnDevice,
      for (final argument in configuration.displaySource.toServerArguments())
        argument.substring(0, argument.indexOf('=')): argument.substring(
          argument.indexOf('=') + 1,
        ),
    });
    if (result == null) throw StateError('Android session returned no result');
    final connection = _AndroidScrcpyVideoConnection(
      channel: _channel,
      sessionId: result['sessionId']! as String,
      textureId: result['textureId']! as int,
      codecId: result['codecId']! as int,
      width: result['width']! as int,
      height: result['height']! as int,
      controlEnabled: configuration.controlEnabled,
      audioEnabled: result['audioEnabled'] == true,
      audioCodec: result['audioCodec'] as String?,
    );
    _connections[connection.sessionId] = connection;
    try {
      final source = configuration.displaySource;
      if (source is ScrcpyVirtualDisplaySource) {
        final application = source.launchApplication;
        if (application != null) {
          final input = connection.input;
          if (input == null) {
            throw const ScrcpyException(
              ScrcpyErrorCode.unsupportedCapability,
              'Launching an application on a virtual display requires control',
            );
          }
          await input.startApplication(application);
        }
      }
      return connection;
    } catch (_) {
      await connection.close();
      rethrow;
    }
  }

  static void _installHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    try {
      _channel.setMethodCallHandler(_handleNativeCall);
    } catch (_) {
      _handlerInstalled = false;
      rethrow;
    }
  }

  static Future<void> _handleNativeCall(MethodCall call) async {
    final arguments = call.arguments;
    if (arguments is! Map) return;
    final sessionId = arguments['sessionId'];
    if (sessionId is! String) return;
    switch (call.method) {
      case 'disconnected':
        _connections.remove(sessionId)?._markDisconnected(arguments['error']);
        return;
      case 'resized':
        final width = arguments['width'];
        final height = arguments['height'];
        if (width is int && height is int) {
          _connections[sessionId]?._markResized(width, height);
        }
        return;
      case 'clipboard':
        final text = arguments['text'];
        final input = _connections[sessionId]?.input;
        if (text is String && input is _AndroidScrcpyInputController) {
          input._addClipboard(text);
        }
        return;
      case 'clipboardAck':
        final sequence = arguments['sequence'];
        final input = _connections[sessionId]?.input;
        if (sequence is int && input is _AndroidScrcpyInputController) {
          input._acknowledgeClipboard(sequence);
        }
        return;
      case 'recordingStopped':
        _connections[sessionId]?._markRecordingStopped(
          arguments['frames'] as int? ?? 0,
          arguments['error'] as String?,
        );
        return;
      case 'audioStopped':
        _connections[sessionId]?._markAudioStopped(
          arguments['error'] as String?,
        );
        return;
    }
  }
}

final class _AndroidScrcpyVideoConnection extends ChangeNotifier
    implements
        ScrcpyVideoConnection,
        ScrcpyVideoControllerProvider,
        ScrcpyAudioControllerProvider {
  _AndroidScrcpyVideoConnection({
    required this.channel,
    required this.sessionId,
    required this.textureId,
    required this.codecId,
    required this.width,
    required this.height,
    required bool controlEnabled,
    required this.audioEnabled,
    required this.audioCodec,
  }) : input = controlEnabled
           ? _AndroidScrcpyInputController(channel, sessionId, width, height)
           : null;

  final MethodChannel channel;
  final String sessionId;
  final int textureId;
  final int codecId;
  final bool audioEnabled;
  final String? audioCodec;
  int width;
  int height;
  final Completer<void> _done = Completer<void>();
  final StreamController<({int frames, String? error})> _recordingEvents =
      StreamController<({int frames, String? error})>.broadcast(sync: true);
  final StreamController<String?> _audioEvents =
      StreamController<String?>.broadcast(sync: true);
  bool _closed = false;

  @override
  final ScrcpyInputController? input;

  @override
  ScrcpyVideoConnectionInfo get info => ScrcpyVideoConnectionInfo(
    scid: sessionId,
    localPort: 0,
    remoteServerPath: '/data/local/tmp/scrcpy-server-$sessionId.jar',
  );

  @override
  Future<ScrcpyVideoCodecInfo> get codec async =>
      ScrcpyVideoCodecInfo(codecId: codecId, width: width, height: height);

  @override
  Stream<ScrcpyVideoCodecInfo> get sessions => const Stream.empty();

  @override
  Stream<ScrcpyVideoPacket> get packets => const Stream.empty();

  @override
  ScrcpyAudioStream? get audio => null;

  @override
  ScrcpyAudioController createAudioController() =>
      _AndroidPlatformAudioController(this);

  @override
  int get bytesReceived => 0;

  @override
  Future<void> get done => _done.future;

  @override
  ScrcpyVideoController createVideoController() =>
      _AndroidPlatformVideoController(this);

  void _markDisconnected(Object? error) {
    if (_done.isCompleted) return;
    final controller = input;
    if (controller is _AndroidScrcpyInputController) {
      controller.markUnavailable();
    }
    if (error == null) {
      _done.complete();
    } else {
      _done.completeError(StateError('$error'));
    }
  }

  void _markResized(int width, int height) {
    if (_closed || width <= 0 || height <= 0) return;
    this.width = width;
    this.height = height;
    final controller = input;
    if (controller is _AndroidScrcpyInputController) {
      controller.updateVideoSize(width, height);
    }
    notifyListeners();
  }

  void _markRecordingStopped(int frames, String? error) {
    if (!_recordingEvents.isClosed) {
      _recordingEvents.add((frames: frames, error: error));
    }
  }

  void _markAudioStopped(String? error) {
    if (!_audioEvents.isClosed) _audioEvents.add(error);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await channel.invokeMethod<void>('stop', {'sessionId': sessionId});
    } finally {
      final controller = input;
      if (controller is _AndroidScrcpyInputController) {
        await controller.close();
      }
      await _recordingEvents.close();
      await _audioEvents.close();
      AndroidScrcpyVideoConnector._connections.remove(sessionId);
      _markDisconnected(null);
    }
  }
}

final class _AndroidPlatformAudioController extends ChangeNotifier
    implements ScrcpyAudioController {
  _AndroidPlatformAudioController(this.connection) {
    _audioEvents = connection._audioEvents.stream.listen(_handleAudioStopped);
  }

  final _AndroidScrcpyVideoConnection connection;
  ScrcpyAudioState _value = const ScrcpyAudioState.idle();
  Timer? _statsTimer;
  late final StreamSubscription<String?> _audioEvents;

  @override
  ScrcpyAudioState get value => _value;

  void _update({
    bool? muted,
    double? volume,
    ScrcpyAudioStatus? status,
    int? packetsReceived,
    int? bytesReceived,
    int? decodedPackets,
    int? playedBuffers,
    int? droppedBuffers,
  }) {
    _value = ScrcpyAudioState(
      status: status ?? _value.status,
      codec: connection.audioCodec,
      muted: muted ?? _value.muted,
      volume: volume ?? _value.volume,
      packetsReceived: packetsReceived ?? _value.packetsReceived,
      bytesReceived: bytesReceived ?? _value.bytesReceived,
      decodedPackets: decodedPackets ?? _value.decodedPackets,
      playedBuffers: playedBuffers ?? _value.playedBuffers,
      droppedBuffers: droppedBuffers ?? _value.droppedBuffers,
    );
    notifyListeners();
  }

  @override
  Future<void> start() async {
    if (!connection.audioEnabled) {
      throw const ScrcpyException(
        ScrcpyErrorCode.unsupportedCapability,
        'scrcpy audio capture is unavailable',
      );
    }
    _update(status: ScrcpyAudioStatus.ready);
    _statsTimer ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_updateStats()),
    );
  }

  Future<void> _updateStats() async {
    try {
      final stats = await connection.channel.invokeMapMethod<String, Object?>(
        'audioStats',
        {'sessionId': connection.sessionId},
      );
      if (stats == null || _value.status != ScrcpyAudioStatus.ready) return;
      _update(
        packetsReceived: stats['packetsReceived'] as int? ?? 0,
        bytesReceived: stats['bytesReceived'] as int? ?? 0,
        decodedPackets: stats['decodedPackets'] as int? ?? 0,
        playedBuffers: stats['playedBuffers'] as int? ?? 0,
        droppedBuffers: stats['droppedBuffers'] as int? ?? 0,
      );
    } catch (_) {
      // Diagnostics must not interrupt playback.
    }
  }

  void _handleAudioStopped(String? error) {
    _statsTimer?.cancel();
    _statsTimer = null;
    _value = ScrcpyAudioState(
      status: error == null ? ScrcpyAudioStatus.ended : ScrcpyAudioStatus.error,
      codec: connection.audioCodec,
      muted: _value.muted,
      volume: _value.volume,
      packetsReceived: _value.packetsReceived,
      bytesReceived: _value.bytesReceived,
      decodedPackets: _value.decodedPackets,
      playedBuffers: _value.playedBuffers,
      droppedBuffers: _value.droppedBuffers,
      error: error,
    );
    notifyListeners();
  }

  @override
  Future<void> setMuted(bool muted) async {
    await connection.channel.invokeMethod<void>('audioMuted', {
      'sessionId': connection.sessionId,
      'muted': muted,
    });
    _update(muted: muted);
  }

  @override
  Future<void> setVolume(double volume) async {
    if (!volume.isFinite || volume < 0 || volume > 1) {
      throw RangeError.range(volume, 0, 1, 'volume');
    }
    await connection.channel.invokeMethod<void>('audioVolume', {
      'sessionId': connection.sessionId,
      'volume': volume,
    });
    _update(volume: volume);
  }

  @override
  Future<void> stop() async {
    _statsTimer?.cancel();
    _statsTimer = null;
    _update(status: ScrcpyAudioStatus.idle);
  }

  @override
  void dispose() {
    _statsTimer?.cancel();
    _statsTimer = null;
    unawaited(_audioEvents.cancel());
    super.dispose();
  }
}

final class _AndroidPlatformVideoController extends ChangeNotifier
    implements ScrcpyVideoController {
  _AndroidPlatformVideoController(this.connection) {
    connection.addListener(_handleSizeChanged);
    _recordingEvents = connection._recordingEvents.stream.listen(
      _handleRecordingStopped,
    );
  }

  final _AndroidScrcpyVideoConnection connection;
  ScrcpyVideoState _value = const ScrcpyVideoState.idle();
  bool _recording = false;
  Timer? _statsTimer;
  int _lastFrames = 0;
  DateTime? _lastStatsAt;
  late final StreamSubscription<({int frames, String? error})> _recordingEvents;

  @override
  ScrcpyVideoState get value => _value;

  @override
  bool get isRecording => _recording;

  @override
  Future<void> start() async {
    _setReadyState();
    _statsTimer ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_updateStats()),
    );
  }

  Future<void> _updateStats() async {
    try {
      final stats = await connection.channel.invokeMapMethod<String, Object?>(
        'videoStats',
        {'sessionId': connection.sessionId},
      );
      if (stats == null || _value.status != ScrcpyVideoStatus.ready) return;
      final now = DateTime.now();
      final frames = stats['framesRendered'] as int? ?? 0;
      final elapsed = _lastStatsAt == null
          ? 0.0
          : now.difference(_lastStatsAt!).inMicroseconds / 1000000;
      final fps = elapsed > 0 ? (frames - _lastFrames) / elapsed : 0.0;
      _lastFrames = frames;
      _lastStatsAt = now;
      _value = ScrcpyVideoState(
        status: ScrcpyVideoStatus.ready,
        textureId: connection.textureId,
        width: connection.width,
        height: connection.height,
        decoder: 'android-mediacodec',
        bytesReceived: stats['bytesReceived'] as int? ?? 0,
        packetsReceived: stats['packetsReceived'] as int? ?? 0,
        framesRendered: frames,
        framesPerSecond: fps,
        decoderInputsDropped: stats['decoderInputsDropped'] as int? ?? 0,
      );
      notifyListeners();
    } catch (_) {
      // Diagnostics must not interrupt playback.
    }
  }

  void _handleSizeChanged() {
    if (_value.status == ScrcpyVideoStatus.ready) _setReadyState();
  }

  void _handleRecordingStopped(({int frames, String? error}) event) {
    if (!_recording) return;
    _recording = false;
    notifyListeners();
    if (event.error case final error?) {
      debugPrint('Android video recording stopped: $error');
    }
  }

  void _setReadyState() {
    _value = ScrcpyVideoState(
      status: ScrcpyVideoStatus.ready,
      textureId: connection.textureId,
      width: connection.width,
      height: connection.height,
      decoder: 'android-mediacodec',
      bytesReceived: _value.bytesReceived,
      packetsReceived: _value.packetsReceived,
      framesRendered: _value.framesRendered,
      framesPerSecond: _value.framesPerSecond,
      decoderInputsDropped: _value.decoderInputsDropped,
    );
    notifyListeners();
  }

  @override
  void dispose() {
    _statsTimer?.cancel();
    _statsTimer = null;
    connection.removeListener(_handleSizeChanged);
    unawaited(_recordingEvents.cancel());
    super.dispose();
  }

  @override
  Future<void> stop() {
    _statsTimer?.cancel();
    _statsTimer = null;
    return connection.close();
  }

  @override
  Future<ScrcpyScreenshot> captureFrame() async {
    final frame = await connection.channel.invokeMapMethod<String, Object?>(
      'capture',
      {'sessionId': connection.sessionId},
    );
    if (frame == null || frame['png'] is! Uint8List) {
      throw const ScrcpyException(
        ScrcpyErrorCode.captureFailure,
        'Android frame capture returned no image',
      );
    }
    return ScrcpyScreenshot(
      width: frame['width']! as int,
      height: frame['height']! as int,
      pngBytes: frame['png']! as Uint8List,
    );
  }

  @override
  Future<void> startRecording(String path) async {
    if (_recording) throw StateError('Video recording is already active');
    try {
      await connection.channel.invokeMethod<void>('startRecording', {
        'sessionId': connection.sessionId,
        'path': path,
      });
      _recording = true;
      notifyListeners();
    } catch (error) {
      throw ScrcpyException(
        ScrcpyErrorCode.recordingFailure,
        'Unable to start video recording',
        cause: error,
      );
    }
  }

  @override
  Future<int> stopRecording() async {
    if (!_recording) return 0;
    try {
      final frames = await connection.channel.invokeMethod<int>(
        'stopRecording',
        {'sessionId': connection.sessionId},
      );
      return frames ?? 0;
    } catch (error) {
      throw ScrcpyException(
        ScrcpyErrorCode.recordingFailure,
        'Unable to finalize video recording',
        cause: error,
      );
    } finally {
      _recording = false;
      notifyListeners();
    }
  }
}

final class _AndroidScrcpyInputController
    implements
        ScrcpyInputController,
        ScrcpyScreenPowerInputController,
        ScrcpyVideoResetInputController,
        ScrcpyInputTransportStatus {
  _AndroidScrcpyInputController(
    this.channel,
    this.sessionId,
    this.width,
    this.height,
  );

  final MethodChannel channel;
  final String sessionId;
  final StreamController<String> _clipboard =
      StreamController<String>.broadcast(sync: true);
  final Map<int, Completer<void>> _clipboardAcks = <int, Completer<void>>{};
  bool _available = true;
  int width;
  int height;

  void updateVideoSize(int width, int height) {
    this.width = width;
    this.height = height;
  }

  @override
  bool get isAvailable => _available;

  Future<void> _send(Uint8List data) {
    if (!_available) {
      return Future<void>.error(
        const ScrcpyException(
          ScrcpyErrorCode.connectionFailure,
          'scrcpy control connection is closed',
        ),
      );
    }
    return channel.invokeMethod<void>('control', {
      'sessionId': sessionId,
      'data': data,
    });
  }

  void markUnavailable() {
    if (!_available) return;
    _available = false;
    final error = StateError('scrcpy control connection is closed');
    for (final acknowledgement in _clipboardAcks.values) {
      if (!acknowledgement.isCompleted) acknowledgement.completeError(error);
    }
    _clipboardAcks.clear();
  }

  void _addClipboard(String text) {
    if (!_clipboard.isClosed) _clipboard.add(text);
  }

  void _acknowledgeClipboard(int sequence) {
    _clipboardAcks.remove(sequence)?.complete();
  }

  Future<void> close() async {
    markUnavailable();
    await _clipboard.close();
  }

  @override
  Future<void> sendKey({required int keyCode, bool down = true}) =>
      _send(ScrcpyControlMessageSerializer.key(keyCode: keyCode, down: down));

  @override
  Future<void> sendBackOrScreenOn({bool down = true}) =>
      _send(ScrcpyControlMessageSerializer.backOrScreenOn(down: down));

  @override
  Future<void> sendPointer(ScrcpyPointerEvent event) => _send(
    event.action == ScrcpyPointerAction.scroll
        ? ScrcpyControlMessageSerializer.scroll(
            normalizedX: event.normalizedX,
            normalizedY: event.normalizedY,
            videoWidth: width,
            videoHeight: height,
            horizontal: -event.scrollDeltaX / 20,
            vertical: -event.scrollDeltaY / 20,
            buttons: event.buttons,
          )
        : ScrcpyControlMessageSerializer.pointer(
            event,
            videoWidth: width,
            videoHeight: height,
          ),
  );

  @override
  Future<void> sendText(String text) =>
      _send(ScrcpyControlMessageSerializer.text(text));

  @override
  Future<void> startApplication(ScrcpyApplicationLaunch application) => _send(
    ScrcpyControlMessageSerializer.startApplication(application.controlName),
  );

  @override
  Future<void> resizeDisplay({required int width, required int height}) async {
    await _send(
      ScrcpyControlMessageSerializer.resizeDisplay(
        width: width,
        height: height,
      ),
    );
    this.width = width;
    this.height = height;
  }

  @override
  Future<void> resetVideo() =>
      _send(ScrcpyControlMessageSerializer.resetVideo());

  @override
  Stream<String> get clipboardChanges => _clipboard.stream;

  @override
  Future<void> requestClipboard({ScrcpyCopyKey copyKey = ScrcpyCopyKey.none}) =>
      _send(ScrcpyControlMessageSerializer.getClipboard(copyKey: copyKey));

  @override
  Future<void> setClipboard(String text, {bool paste = false}) async {
    final sequence = DateTime.now().microsecondsSinceEpoch;
    final acknowledgement = Completer<void>();
    _clipboardAcks[sequence] = acknowledgement;
    try {
      await _send(
        ScrcpyControlMessageSerializer.setClipboard(
          text: text,
          sequence: sequence,
          paste: paste,
        ),
      );
      await acknowledgement.future.timeout(const Duration(seconds: 5));
    } finally {
      _clipboardAcks.remove(sequence);
    }
  }
}
