import 'dart:async';

import 'package:adb_client/adb_client.dart';
import 'package:flutter/foundation.dart';

import 'scrcpy_error.dart';
import 'scrcpy_audio_packet.dart';
import 'scrcpy_audio.dart';
import 'scrcpy_display_source.dart';
import 'native_scrcpy_audio.dart';
import 'native_scrcpy_video.dart';
import 'scrcpy_input.dart';
import 'scrcpy_video.dart';
import 'scrcpy_video_connection.dart';

enum ScrcpySessionState {
  idle,
  preparing,
  ready,
  starting,
  streaming,
  stopping,
  disconnected,
  reconnecting,
  error,
  disposed,
}

final class ScrcpyReconnectPolicy {
  const ScrcpyReconnectPolicy({
    this.maxAttempts = 0,
    this.initialDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 8),
    this.multiplier = 2,
  });

  final int maxAttempts;
  final Duration initialDelay;
  final Duration maxDelay;
  final double multiplier;

  bool get enabled => maxAttempts > 0;

  void validate() {
    if (maxAttempts < 0) {
      throw RangeError.value(maxAttempts, 'maxAttempts', 'must be >= 0');
    }
    if (initialDelay.isNegative || maxDelay.isNegative) {
      throw ArgumentError('Reconnect delays must not be negative');
    }
    if (maxDelay < initialDelay) {
      throw ArgumentError('maxDelay must be >= initialDelay');
    }
    if (!multiplier.isFinite || multiplier < 1) {
      throw RangeError.value(multiplier, 'multiplier', 'must be >= 1');
    }
  }

  Duration delayForAttempt(int attempt) {
    final factor = multiplier == 1 ? 1.0 : _pow(multiplier, attempt - 1);
    final milliseconds = (initialDelay.inMilliseconds * factor).round();
    return Duration(
      milliseconds: milliseconds.clamp(0, maxDelay.inMilliseconds),
    );
  }

  static double _pow(double base, int exponent) {
    var value = 1.0;
    for (var index = 0; index < exponent; index++) {
      value *= base;
    }
    return value;
  }
}

enum ScrcpyVideoCodec {
  h264('h264', 0x68323634, 'H.264'),
  h265('h265', 0x68323635, 'H.265 / HEVC'),
  av1('av1', 0x61763031, 'AV1');

  const ScrcpyVideoCodec(this.serverName, this.codecId, this.label);

  final String serverName;
  final int codecId;
  final String label;
}

final class ScrcpyVideoOptions {
  const ScrcpyVideoOptions({
    this.maxSize = 1920,
    this.maxFps = 60,
    this.bitRate = 8 * 1000 * 1000,
    this.codec = ScrcpyVideoCodec.h264,
    this.encoder,
    this.lowLatency = true,
  });

  final int maxSize;
  final int maxFps;
  final int bitRate;
  final ScrcpyVideoCodec codec;

  /// Optional Android MediaCodec encoder name, for example
  /// `c2.android.avc.encoder`. Null lets scrcpy select the encoder.
  final String? encoder;

  /// Requests an encoder configuration suitable for interactive mirroring.
  final bool lowLatency;

  String? get codecOptions {
    if (!lowLatency) return null;
    return codec == ScrcpyVideoCodec.h264
        ? 'profile=1,max-bframes=0,latency=0'
        : 'max-bframes=0,latency=0';
  }

  void validate() {
    if (maxSize < 0 || maxSize > 16384) {
      throw RangeError.range(maxSize, 0, 16384, 'maxSize');
    }
    if (maxFps < 1 || maxFps > 240) {
      throw RangeError.range(maxFps, 1, 240, 'maxFps');
    }
    if (bitRate < 100000 || bitRate > 1000000000) {
      throw RangeError.range(bitRate, 100000, 1000000000, 'bitRate');
    }
    final selectedEncoder = encoder;
    if (selectedEncoder != null &&
        (selectedEncoder.trim().isEmpty ||
            selectedEncoder != selectedEncoder.trim() ||
            selectedEncoder.contains(RegExp(r'\s|=')))) {
      throw ArgumentError.value(
        selectedEncoder,
        'encoder',
        'must be a non-empty MediaCodec name without whitespace or =',
      );
    }
  }
}

enum ScrcpyAudioSource {
  automatic(null),
  output('output'),
  playback('playback');

  const ScrcpyAudioSource(this.serverName);
  final String? serverName;
}

final class ScrcpyAudioOptions {
  const ScrcpyAudioOptions({
    this.codec = ScrcpyAudioCodec.opus,
    this.bitRate = 128000,
    this.source = ScrcpyAudioSource.automatic,
    this.duplicateOnDevice = false,
    this.initiallyMuted = false,
    this.initialVolume = 1,
  });

  final ScrcpyAudioCodec codec;
  final int bitRate;
  final ScrcpyAudioSource source;
  final bool duplicateOnDevice;
  final bool initiallyMuted;
  final double initialVolume;

  /// Resolves [ScrcpyAudioSource.automatic] for the target Android SDK.
  ///
  /// Android 11 uses the system-output route for compatibility. Newer
  /// versions use playback capture, which preserves the behavior already
  /// validated by the demo on Android 12+ devices. An unknown SDK takes the
  /// conservative output route.
  ScrcpyAudioSource resolveSourceForAndroidSdk(int? androidSdk) {
    if (source != ScrcpyAudioSource.automatic) return source;
    return androidSdk != null && androidSdk >= 31
        ? ScrcpyAudioSource.playback
        : ScrcpyAudioSource.output;
  }

  void validate() {
    if (bitRate < 8000 || bitRate > 1000000) {
      throw RangeError.range(bitRate, 8000, 1000000, 'bitRate');
    }
    if (duplicateOnDevice && source != ScrcpyAudioSource.playback) {
      throw ArgumentError(
        'duplicateOnDevice requires ScrcpyAudioSource.playback',
      );
    }
    if (!initialVolume.isFinite || initialVolume < 0 || initialVolume > 1) {
      throw RangeError.range(initialVolume, 0, 1, 'initialVolume');
    }
  }
}

final class ScrcpySessionConfiguration {
  const ScrcpySessionConfiguration({
    required this.deviceSerial,
    this.video = const ScrcpyVideoOptions(),
    this.controlEnabled = true,
    this.audioEnabled = false,
    this.audioRequired = false,
    this.audio = const ScrcpyAudioOptions(),
    this.displaySource = const ScrcpyDisplaySource.main(),
    this.reconnectPolicy = const ScrcpyReconnectPolicy(),
  });

  final String deviceSerial;
  final ScrcpyVideoOptions video;
  final bool controlEnabled;
  final bool audioEnabled;
  final bool audioRequired;
  final ScrcpyAudioOptions audio;
  final ScrcpyDisplaySource displaySource;
  final ScrcpyReconnectPolicy reconnectPolicy;

  ScrcpySessionConfiguration withDeviceSerial(String deviceSerial) =>
      ScrcpySessionConfiguration(
        deviceSerial: deviceSerial,
        video: video,
        controlEnabled: controlEnabled,
        audioEnabled: audioEnabled,
        audioRequired: audioRequired,
        audio: audio,
        displaySource: displaySource,
        reconnectPolicy: reconnectPolicy,
      );

  void validate() {
    if (deviceSerial.trim().isEmpty) {
      throw ArgumentError.value(
        deviceSerial,
        'deviceSerial',
        'must not be empty',
      );
    }
    video.validate();
    audio.validate();
    reconnectPolicy.validate();
    displaySource.validate();
    if (audioRequired && !audioEnabled) {
      throw ArgumentError(
        'audioEnabled must be true when audioRequired is true',
      );
    }
    final source = displaySource;
    if (!controlEnabled &&
        source is ScrcpyVirtualDisplaySource &&
        source.launchApplication != null) {
      throw ArgumentError(
        'controlEnabled must be true when launchApplication is configured',
      );
    }
  }
}

/// Owns the lifecycle of one future scrcpy video/control connection.
///
/// P0 implements device preparation only. Video and control resources will be
/// attached behind this same lifecycle in P1-P3.
final class ScrcpyRawSession extends ChangeNotifier {
  ScrcpyRawSession({
    required this.adbDeviceService,
    required this.configuration,
    this.videoConnector,
    String? id,
  }) : id =
           id ??
           'session-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}' {
    _state.addListener(notifyListeners);
  }

  final String id;
  final AdbDeviceService adbDeviceService;
  final ScrcpySessionConfiguration configuration;
  final ScrcpyVideoConnector? videoConnector;
  final ValueNotifier<ScrcpySessionState> _state = ValueNotifier(
    ScrcpySessionState.idle,
  );
  Future<void>? _preparing;
  Future<ScrcpyVideoConnection>? _starting;
  Future<void>? _stopping;
  Future<void>? _reconnecting;
  Completer<void>? _reconnectWake;
  int _reconnectGeneration = 0;
  final StreamController<ScrcpyVideoConnection> _reconnectedController =
      StreamController<ScrcpyVideoConnection>.broadcast(sync: true);
  ScrcpyVideoConnection? _connection;
  ScrcpyVideoController? _video;
  ScrcpyAudioController? _audio;
  ScrcpyVideoConnection? _mediaConnection;
  StreamSubscription<ScrcpyVideoConnection>? _managedReconnects;
  Future<void> _mediaChange = Future<void>.value();
  bool _stopRequested = false;
  bool _disposed = false;
  late String _deviceSerial = configuration.deviceSerial;
  String? _mdnsServiceName;
  bool _hasConnectedOnce = false;
  bool _networkDevice = false;

  ValueListenable<ScrcpySessionState> get state => _state;

  String get deviceSerial => _deviceSerial;
  ScrcpyVideoController? get video => _video;
  ScrcpyAudioController? get audio => _audio;
  ScrcpyInputController? get input => _connection?.input;
  bool get isConnected => _state.value == ScrcpySessionState.streaming;
  bool get isControllable => input != null;
  bool get hasAudio => _audio != null;

  /// Opens a complete, renderable session and owns its media controllers.
  Future<ScrcpyRawSession> open({
    AdbCancellationToken? cancellationToken,
  }) async {
    _managedReconnects ??= reconnectedConnections.listen(
      (connection) => _queueMediaReplacement(connection),
    );
    final connection = await start(cancellationToken: cancellationToken);
    await _replaceMedia(connection);
    return this;
  }

  void _queueMediaReplacement(ScrcpyVideoConnection connection) {
    _mediaChange = _mediaChange
        .catchError((_) {})
        .then((_) => _replaceMedia(connection));
    unawaited(
      _mediaChange.catchError((Object error, StackTrace stackTrace) {
        if (!_disposed && !_stopRequested) {
          _setState(ScrcpySessionState.error);
          if (kDebugMode) {
            debugPrint('scrcpy media replacement failed: $error');
          }
        }
      }),
    );
  }

  Future<void> _replaceMedia(ScrcpyVideoConnection connection) async {
    if (_disposed || _connection != connection) return;
    if (_video != null && identical(_mediaConnection, connection)) return;
    await _releaseMedia();
    final video = createNativeScrcpyVideoController(connection);
    ScrcpyAudioController? audio;
    try {
      await video.start();
      if (const bool.fromEnvironment('SCRCPY_DIAGNOSTICS')) {
        debugPrint('scrcpy media: video controller ready');
      }
      final stream = connection.audio;
      if (configuration.audioEnabled &&
          connection is ScrcpyAudioControllerProvider) {
        audio = (connection as ScrcpyAudioControllerProvider)
            .createAudioController();
      } else if (stream != null) {
        audio = createNativeScrcpyAudioController(
          stream,
          bitRate: configuration.audio.bitRate,
        );
      }
      if (audio != null) {
        try {
          await audio.setVolume(configuration.audio.initialVolume);
          await audio.setMuted(configuration.audio.initiallyMuted);
          await audio.start();
        } catch (error, stackTrace) {
          debugPrint('scrcpy audio startup failed: $error\n$stackTrace');
          audio.dispose();
          audio = null;
          if (configuration.audioRequired) rethrow;
        }
      }
      if (_disposed || _connection != connection) {
        await audio?.stop();
        audio?.dispose();
        await video.stop();
        video.dispose();
        return;
      }
      _video = video;
      _audio = audio;
      _mediaConnection = connection;
      if (const bool.fromEnvironment('SCRCPY_DIAGNOSTICS')) {
        debugPrint('scrcpy media: session media ready');
      }
      notifyListeners();
    } catch (_) {
      await audio?.stop();
      audio?.dispose();
      await video.stop();
      video.dispose();
      rethrow;
    }
  }

  Future<void> _releaseMedia() async {
    final audio = _audio;
    final video = _video;
    _audio = null;
    _video = null;
    _mediaConnection = null;
    if (!_disposed) notifyListeners();
    Object? firstError;
    StackTrace? firstStackTrace;
    try {
      await audio?.stop();
    } catch (error, stackTrace) {
      firstError = error;
      firstStackTrace = stackTrace;
    } finally {
      audio?.dispose();
    }
    try {
      await video?.stop();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    } finally {
      video?.dispose();
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }

  Future<void> setMuted(bool muted) async => _audio?.setMuted(muted);

  Future<void> setVolume(double volume) async => _audio?.setVolume(volume);

  Future<void> home() => _sendKeyClick(ScrcpyAndroidKeyCode.home);

  Future<void> back() => _sendKeyClick(ScrcpyAndroidKeyCode.back);

  Future<void> power() => _sendKeyClick(ScrcpyAndroidKeyCode.power);

  Future<void> key(int keyCode) => _sendKeyClick(keyCode);

  Future<void> sendText(String text) => _requireInput().sendText(text);

  Future<void> startApplication(
    String packageName, {
    bool forceStopBeforeStart = false,
  }) => _requireInput().startApplication(
    ScrcpyApplicationLaunch(
      packageName,
      forceStopBeforeStart: forceStopBeforeStart,
    ),
  );

  Future<void> resizeDisplay({required int width, required int height}) =>
      _requireInput().resizeDisplay(width: width, height: height);

  Future<void> pinch({required double startSpan, required double endSpan}) =>
      ScrcpyGestureSimulator(_requireInput())
          .pinch(startSpan: startSpan, endSpan: endSpan);

  Future<void> _sendKeyClick(int keyCode) async {
    final controller = _requireInput();
    await controller.sendKey(keyCode: keyCode);
    await controller.sendKey(keyCode: keyCode, down: false);
  }

  ScrcpyInputController _requireInput() {
    final controller = input;
    if (controller == null) {
      throw StateError('Session input is not available: $id');
    }
    return controller;
  }

  /// Emits only replacement connections created after an unexpected
  /// disconnect. The initial connection is returned by [start].
  Stream<ScrcpyVideoConnection> get reconnectedConnections =>
      _reconnectedController.stream;

  Future<void> prepare({AdbCancellationToken? cancellationToken}) {
    if (_disposed) {
      return Future<void>.error(
        const ScrcpyException(
          ScrcpyErrorCode.cancelled,
          'Session has been disposed',
        ),
      );
    }
    if (_state.value == ScrcpySessionState.ready ||
        _state.value == ScrcpySessionState.streaming) {
      return Future<void>.value();
    }
    return _preparing ??= _prepare(cancellationToken).whenComplete(() {
      _preparing = null;
    });
  }

  Future<ScrcpyVideoConnection> start({
    AdbCancellationToken? cancellationToken,
  }) {
    if (_disposed) {
      return Future<ScrcpyVideoConnection>.error(
        const ScrcpyException(
          ScrcpyErrorCode.cancelled,
          'Session has been disposed',
        ),
      );
    }
    final active = _connection;
    if (active != null && _state.value == ScrcpySessionState.streaming) {
      return Future<ScrcpyVideoConnection>.value(active);
    }
    return _starting ??= _start(cancellationToken).whenComplete(() {
      _starting = null;
    });
  }

  Future<ScrcpyVideoConnection> _start(
    AdbCancellationToken? cancellationToken,
  ) async {
    final connector = videoConnector;
    if (connector == null) {
      throw const ScrcpyException(
        ScrcpyErrorCode.unsupportedCapability,
        'Video connection is unavailable for this session',
      );
    }
    _stopRequested = false;
    if (_hasConnectedOnce && _networkDevice) {
      await _refreshWirelessEndpoint(cancellationToken);
    }
    await prepare(cancellationToken: cancellationToken);
    if (_disposed) {
      throw const ScrcpyException(
        ScrcpyErrorCode.cancelled,
        'Session was disposed while starting',
      );
    }
    _setState(ScrcpySessionState.starting);
    try {
      final connection = await connector.connect(
        configuration.withDeviceSerial(_deviceSerial),
        cancellationToken: cancellationToken,
      );
      if (_disposed) {
        await connection.close();
        throw const ScrcpyException(
          ScrcpyErrorCode.cancelled,
          'Session was disposed while starting',
        );
      }
      _connection = connection;
      _hasConnectedOnce = true;
      unawaited(
        connection.done.then(
          (_) => _handleDisconnected(connection),
          onError: (Object error, StackTrace stackTrace) =>
              _handleDisconnected(connection, error),
        ),
      );
      if (!_stopRequested) _setState(ScrcpySessionState.streaming);
      return connection;
    } catch (_) {
      if (!_disposed && !_stopRequested) _setState(ScrcpySessionState.error);
      rethrow;
    }
  }

  Future<void> stop() {
    if (_disposed) return Future<void>.value();
    return _stopping ??= _stop().whenComplete(() => _stopping = null);
  }

  Future<void> _stop() async {
    _stopRequested = true;
    _cancelReconnect();
    _setState(ScrcpySessionState.stopping);
    try {
      await _starting;
    } catch (_) {
      // Startup errors are reported by the start caller.
    }
    await _managedReconnects?.cancel();
    _managedReconnects = null;
    try {
      await _mediaChange;
    } catch (_) {
      // The media error was already reported by the operation which started it.
    }
    try {
      await _releaseMedia();
    } catch (_) {
      // Disconnected native sinks are still disposed by _releaseMedia().
    }
    final connection = _connection;
    _connection = null;
    await connection?.close();
    if (!_disposed) _setState(ScrcpySessionState.ready);
  }

  Future<void> _handleDisconnected(
    ScrcpyVideoConnection connection, [
    Object? error,
  ]) async {
    if (_disposed || _connection != connection || _stopRequested) return;
    if (kDebugMode) {
      debugPrint(
        'scrcpy session disconnected${error == null ? '' : ': $error'}',
      );
    }
    _connection = null;
    _setState(ScrcpySessionState.disconnected);
    await connection.close();
    final policy = configuration.reconnectPolicy;
    if (!_disposed && !_stopRequested && policy.enabled) {
      policy.validate();
      _reconnecting ??= _reconnect(policy)
          .whenComplete(() => _reconnecting = null);
      unawaited(_reconnecting);
    }
  }

  Future<void> _reconnect(ScrcpyReconnectPolicy policy) async {
    final generation = ++_reconnectGeneration;
    for (var attempt = 1; attempt <= policy.maxAttempts; attempt++) {
      if (_disposed || _stopRequested || generation != _reconnectGeneration) {
        return;
      }
      _setState(ScrcpySessionState.reconnecting);
      final wake = Completer<void>();
      _reconnectWake = wake;
      await Future.any<void>(<Future<void>>[
        Future<void>.delayed(policy.delayForAttempt(attempt)),
        wake.future,
      ]);
      if (identical(_reconnectWake, wake)) _reconnectWake = null;
      if (_disposed || _stopRequested || generation != _reconnectGeneration) {
        return;
      }
      try {
        final connection = await start();
        if (_disposed || _stopRequested || generation != _reconnectGeneration) {
          await connection.close();
          return;
        }
        _reconnectedController.add(connection);
        return;
      } catch (error, stackTrace) {
        if (attempt == policy.maxAttempts && !_disposed && !_stopRequested) {
          _setState(ScrcpySessionState.error);
          _reconnectedController.addError(error, stackTrace);
        }
      }
    }
  }

  void _cancelReconnect() {
    _reconnectGeneration++;
    final wake = _reconnectWake;
    _reconnectWake = null;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  void _setState(ScrcpySessionState value) {
    if (!_disposed) _state.value = value;
  }

  Future<void> _prepare(AdbCancellationToken? cancellationToken) async {
    _setState(ScrcpySessionState.preparing);
    try {
      configuration.validate();
      final devices = await adbDeviceService.listDevices(
        cancellationToken: cancellationToken,
      );
      if (_disposed) {
        throw const ScrcpyException(
          ScrcpyErrorCode.cancelled,
          'Session was disposed while preparing',
        );
      }
      final device = devices.where(
        (candidate) => candidate.serial == _deviceSerial,
      );
      if (device.isEmpty) {
        throw const ScrcpyException(
          ScrcpyErrorCode.connectionFailure,
          'Selected device is no longer connected',
        );
      }
      final selectedDevice = device.first;
      if (selectedDevice.state != AdbDeviceState.device) {
        throw ScrcpyException(
          ScrcpyErrorCode.connectionFailure,
          'Selected device is not ready: ${selectedDevice.state.name}',
        );
      }
      _networkDevice =
          selectedDevice.connectionType == AdbConnectionType.network;
      _mdnsServiceName ??= selectedDevice.attributes['mdns_service_name'];
      _setState(ScrcpySessionState.ready);
    } catch (_) {
      if (!_disposed) _setState(ScrcpySessionState.error);
      rethrow;
    }
  }

  Future<void> _refreshWirelessEndpoint(
    AdbCancellationToken? cancellationToken,
  ) async {
    final adb = adbDeviceService;
    if (adb is! AdbClient) return;
    final previous = AdbEndpoint.tryParse(_deviceSerial);
    if (previous == null) return;
    try {
      final services = await adb.discoverMdnsServices(
        cancellationToken: cancellationToken,
      );
      final candidates = services.where(
        (service) => service.type == AdbMdnsServiceType.connect,
      );
      AdbMdnsService? selected;
      final serviceName = _mdnsServiceName;
      if (serviceName != null) {
        for (final service in candidates) {
          if (service.name == serviceName) selected = service;
        }
      } else {
        for (final service in candidates) {
          if (service.endpoint.host.toLowerCase() ==
              previous.host.toLowerCase()) {
            selected = service;
          }
        }
      }
      if (selected == null) return;
      _mdnsServiceName = selected.name;
      final endpoint = selected.endpoint;
      if (endpoint.authority == previous.authority) return;
      await adb.connect(endpoint, cancellationToken: cancellationToken);
      _deviceSerial = endpoint.authority;
    } on AdbException catch (error) {
      if (error.code == AdbErrorCode.cancelled) rethrow;
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _stopRequested = true;
    _cancelReconnect();
    _state.value = ScrcpySessionState.disposed;
    unawaited(_managedReconnects?.cancel());
    _managedReconnects = null;
    final video = _video;
    final audio = _audio;
    _video = null;
    _audio = null;
    _mediaConnection = null;
    audio?.dispose();
    video?.dispose();
    final starting = _starting;
    final connection = _connection;
    _connection = null;
    unawaited(() async {
      try {
        await starting;
      } catch (_) {}
      await (_connection ?? connection)?.close();
      _connection = null;
    }());
    _state.removeListener(notifyListeners);
    _state.dispose();
    unawaited(_reconnectedController.close());
    super.dispose();
  }

  Future<void> close() async {
    await stop();
    dispose();
  }
}
