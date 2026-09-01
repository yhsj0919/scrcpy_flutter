import 'dart:async';

import 'package:adb_client/adb_client.dart';
import 'package:flutter/foundation.dart';

import 'scrcpy_error.dart';

enum ScrcpySessionState {
  idle,
  preparing,
  ready,
  starting,
  streaming,
  stopping,
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
  ScrcpySession({required this.adbDeviceService, required this.configuration});

  final AdbDeviceService adbDeviceService;
  final ScrcpySessionConfiguration configuration;
  final ValueNotifier<ScrcpySessionState> _state = ValueNotifier(
    ScrcpySessionState.idle,
  );
  Future<void>? _preparing;

  ValueListenable<ScrcpySessionState> get state => _state;

  Future<void> prepare({AdbCancellationToken? cancellationToken}) {
    if (_state.value == ScrcpySessionState.disposed) {
      return Future<void>.error(
        const ScrcpyException(
          ScrcpyErrorCode.cancelled,
          'Session has been disposed',
        ),
      );
    }
    return _preparing ??= _prepare(cancellationToken).whenComplete(() {
      _preparing = null;
    });
  }

  Future<void> _prepare(AdbCancellationToken? cancellationToken) async {
    _state.value = ScrcpySessionState.preparing;
    try {
      final devices = await adbDeviceService.listDevices(
        cancellationToken: cancellationToken,
      );
      if (_state.value == ScrcpySessionState.disposed) {
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
      _state.value = ScrcpySessionState.ready;
    } catch (_) {
      if (_state.value != ScrcpySessionState.disposed) {
        _state.value = ScrcpySessionState.error;
      }
      rethrow;
    }
  }

  void dispose() {
    if (_state.value == ScrcpySessionState.disposed) return;
    _state.value = ScrcpySessionState.disposed;
    _state.dispose();
  }
}
