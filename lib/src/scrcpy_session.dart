import 'dart:async';

import 'package:adb_client/adb_client.dart';
import 'package:flutter/foundation.dart';

import 'scrcpy_error.dart';
import 'scrcpy_video_connection.dart';

enum ScrcpySessionState {
  idle,
  preparing,
  ready,
  starting,
  streaming,
  stopping,
  disconnected,
  error,
  disposed,
}

final class ScrcpyVideoOptions {
  const ScrcpyVideoOptions({
    this.maxSize = 1920,
    this.maxFps = 60,
    this.bitRate = 8 * 1000 * 1000,
    this.codec = 'h264',
  });

  final int maxSize;
  final int maxFps;
  final int bitRate;
  final String codec;
}

final class ScrcpySessionConfiguration {
  const ScrcpySessionConfiguration({
    required this.deviceSerial,
    this.video = const ScrcpyVideoOptions(),
    this.controlEnabled = true,
    this.audioEnabled = false,
  });

  final String deviceSerial;
  final ScrcpyVideoOptions video;
  final bool controlEnabled;
  final bool audioEnabled;
}

/// Owns the lifecycle of one future scrcpy video/control connection.
///
/// P0 implements device preparation only. Video and control resources will be
/// attached behind this same lifecycle in P1-P3.
final class ScrcpySession {
  ScrcpySession({
    required this.adbDeviceService,
    required this.configuration,
    this.videoConnector,
  });

  final AdbDeviceService adbDeviceService;
  final ScrcpySessionConfiguration configuration;
  final ScrcpyVideoConnector? videoConnector;
  final ValueNotifier<ScrcpySessionState> _state = ValueNotifier(
    ScrcpySessionState.idle,
  );
  Future<void>? _preparing;
  Future<ScrcpyVideoConnection>? _starting;
  Future<void>? _stopping;
  ScrcpyVideoConnection? _connection;
  bool _stopRequested = false;
  bool _disposed = false;

  ValueListenable<ScrcpySessionState> get state => _state;

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
        configuration,
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
    _setState(ScrcpySessionState.stopping);
    try {
      await _starting;
    } catch (_) {
      // Startup errors are reported by the start caller.
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
    _connection = null;
    _setState(ScrcpySessionState.disconnected);
    await connection.close();
  }

  void _setState(ScrcpySessionState value) {
    if (!_disposed) _state.value = value;
  }

  Future<void> _prepare(AdbCancellationToken? cancellationToken) async {
    _setState(ScrcpySessionState.preparing);
    try {
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
        (candidate) => candidate.serial == configuration.deviceSerial,
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
      _setState(ScrcpySessionState.ready);
    } catch (_) {
      if (!_disposed) _setState(ScrcpySessionState.error);
      rethrow;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _state.value = ScrcpySessionState.disposed;
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
    _state.dispose();
  }
}
