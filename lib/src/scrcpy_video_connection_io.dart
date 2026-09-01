import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:adb_client/adb_client.dart';
import 'package:flutter/foundation.dart';

import 'scrcpy_error.dart';
import 'scrcpy_control_message.dart';
import 'scrcpy_input.dart';
import 'scrcpy_session.dart';
import 'scrcpy_video_connection.dart';
import 'scrcpy_video_packet.dart';

ScrcpyVideoConnector createScrcpyVideoConnector({
  required AdbClient adbClient,
  required String serverPath,
}) => _IoScrcpyVideoConnector(adbClient, serverPath);

final class _IoScrcpyVideoConnector implements ScrcpyVideoConnector {
  _IoScrcpyVideoConnector(this._adb, this._serverPath);

  static const _version = '4.1';
  final AdbClient _adb;
  final String _serverPath;

  @override
  Future<ScrcpyVideoConnection> connect(
    ScrcpySessionConfiguration configuration, {
    AdbCancellationToken? cancellationToken,
  }) async {
    if (!await File(_serverPath).exists()) {
      throw const ScrcpyException(
        ScrcpyErrorCode.resourceMissing,
        'Bundled scrcpy server was not found',
      );
    }
    final scid = Random.secure()
        .nextInt(0x7fffffff)
        .toRadixString(16)
        .padLeft(8, '0');
    final remotePath = '/data/local/tmp/scrcpy-server-$scid.jar';
    final socketName = 'scrcpy_$scid';
    String? local;
    AdbRunningCommand? serverProcess;
    try {
      await _adb.push(
        configuration.deviceSerial,
        _serverPath,
        remotePath,
        cancellationToken: cancellationToken,
      );
      final forwardResult = await _adb.execute(
        AdbCommand(
          <String>[
            '-s',
            configuration.deviceSerial,
            'forward',
            'tcp:0',
            'localabstract:$socketName',
          ],
          sensitiveArgumentIndexes: const <int>{1},
        ),
        cancellationToken: cancellationToken,
      );
      if (!forwardResult.isSuccess) {
        throw ScrcpyException(
          ScrcpyErrorCode.connectionFailure,
          'Unable to create scrcpy ADB forward',
          cause: forwardResult.exitCode,
        );
      }
      local = utf8.decode(forwardResult.stdout).trim();
      final port = int.tryParse(local);
      if (port == null || port <= 0 || port > 65535) {
        throw const ScrcpyException(
          ScrcpyErrorCode.protocolFailure,
          'ADB returned an invalid dynamic forward port',
        );
      }
      final video = configuration.video;
      final serverArguments = <String>[
        'CLASSPATH=$remotePath',
        'app_process',
        '/',
        'com.genymobile.scrcpy.Server',
        _version,
        'scid=$scid',
        'log_level=info',
        'tunnel_forward=true',
        'video=true',
        'audio=false',
        'control=${configuration.controlEnabled}',
        'cleanup=true',
        'send_device_meta=false',
        'video_codec=${video.codec}',
        'max_size=${video.maxSize}',
        'max_fps=${video.maxFps}',
        'video_bit_rate=${video.bitRate}',
      ];
      serverProcess = await _adb.start(
        AdbCommand(
          <String>[
            '-s',
            configuration.deviceSerial,
            'shell',
            ...serverArguments,
          ],
          timeout: const Duration(days: 1),
          sensitiveArgumentIndexes: const <int>{1},
        ),
        cancellationToken: cancellationToken,
      );
      final serverOutput = BytesBuilder(copy: false);
      void collectServerOutput(List<int> data) {
        serverOutput.add(data);
        if (kDebugMode) {
          final line = utf8.decode(data, allowMalformed: true).trim();
          if (line.isNotEmpty) debugPrint('scrcpy server: $line');
        }
      }

      serverProcess.stdout.listen(collectServerOutput);
      serverProcess.stderr.listen(collectServerOutput);
      final sockets = await _connectWithRetry(
        port,
        controlEnabled: configuration.controlEnabled,
        cancellationToken: cancellationToken,
      );
      return _IoScrcpyVideoConnection(
        _adb,
        configuration.deviceSerial,
        sockets.video,
        sockets.control,
        serverProcess,
        serverOutput,
        info: ScrcpyVideoConnectionInfo(
          scid: scid,
          localPort: port,
          remoteServerPath: remotePath,
        ),
      );
    } catch (_) {
      serverProcess?.kill();
      if (local != null) {
        await _ignoreFailure(
          _adb.removeForward(configuration.deviceSerial, 'tcp:$local'),
        );
      }
      await _ignoreFailure(
        _adb.shell(configuration.deviceSerial, <String>[
          'rm',
          '-f',
          remotePath,
        ]),
      );
      rethrow;
    }
  }

  Future<_SocketPair> _connectWithRetry(
    int port, {
    required bool controlEnabled,
    AdbCancellationToken? cancellationToken,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt < 40; attempt++) {
      if (cancellationToken?.isCancelled ?? false) {
        throw const ScrcpyException(
          ScrcpyErrorCode.cancelled,
          'scrcpy connection cancelled',
        );
      }
      try {
        final video = _ReadySocket(
          await Socket.connect(
            InternetAddress.loopbackIPv4,
            port,
            timeout: const Duration(milliseconds: 500),
          ),
        );
        _ReadySocket? control;
        if (controlEnabled) {
          control = _ReadySocket(
            await Socket.connect(
              InternetAddress.loopbackIPv4,
              port,
              timeout: const Duration(milliseconds: 500),
            ),
          );
        }
        final ready = await video.ready.timeout(
          const Duration(milliseconds: 500),
          onTimeout: () => false,
        );
        if (ready) return _SocketPair(video, control);
        await video.close();
        await control?.close();
      } on SocketException catch (error) {
        lastError = error;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw ScrcpyException(
      ScrcpyErrorCode.connectionFailure,
      'Timed out connecting to scrcpy video socket',
      cause: lastError,
    );
  }
}

final class _SocketPair {
  const _SocketPair(this.video, this.control);

  final _ReadySocket video;
  final _ReadySocket? control;
}

final class _ReadySocket {
  _ReadySocket(this._socket) {
    _socket.listen(
      (data) {
        if (!_ready.isCompleted) _ready.complete(true);
        _chunks.add(Uint8List.fromList(data));
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!_ready.isCompleted) _ready.completeError(error, stackTrace);
        _chunks.addError(error, stackTrace);
      },
      onDone: () {
        if (!_ready.isCompleted) _ready.complete(false);
        unawaited(_chunks.close());
      },
    );
  }

  final Socket _socket;
  final Completer<bool> _ready = Completer<bool>();
  final StreamController<Uint8List> _chunks = StreamController<Uint8List>();

  Future<bool> get ready => _ready.future;
  Stream<Uint8List> get chunks => _chunks.stream;

  Future<void> close() => _socket.close();

  void add(List<int> data) => _socket.add(data);

  Future<void> flush() => _socket.flush();
}

final class _IoScrcpyVideoConnection implements ScrcpyVideoConnection {
  _IoScrcpyVideoConnection(
    this._adb,
    this._serial,
    this._socket,
    _ReadySocket? controlSocket,
    this._serverProcess,
    this._serverOutput, {
    required this.info,
  }) {
    _input = controlSocket == null
        ? null
        : _IoScrcpyInputController(controlSocket);
    _parser = ScrcpyVideoPacketParser(
      onCodec: (codec) {
        if (!_codec.isCompleted) _codec.complete(codec);
        _input?.updateVideoSize(codec.width, codec.height);
        _sessionController.add(codec);
      },
      onPacket: _packetController.add,
    );
    _socket.chunks.listen(
      (data) {
        _bytesReceived += data.length;
        if (kDebugMode && !_loggedFirstChunk) {
          _loggedFirstChunk = true;
          debugPrint(
            'scrcpy video first bytes (${data.length}): '
            '${data.take(32).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(' ')}',
          );
        }
        try {
          _parser.add(data);
        } catch (error, stackTrace) {
          if (!_codec.isCompleted) _codec.completeError(error, stackTrace);
          _packetController.addError(error, stackTrace);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!_codec.isCompleted) _codec.completeError(error, stackTrace);
        _packetController.addError(error, stackTrace);
      },
      onDone: () async {
        if (_bytesReceived == 0) {
          await Future.any<void>(<Future<void>>[
            _serverProcess.exitCode.then((_) {}),
            Future<void>.delayed(const Duration(milliseconds: 250)),
          ]);
          final error = ScrcpyException(
            ScrcpyErrorCode.connectionFailure,
            'scrcpy video socket closed before receiving data',
            cause: utf8.decode(_serverOutput.toBytes(), allowMalformed: true),
          );
          if (!_codec.isCompleted) _codec.completeError(error);
          _packetController.addError(error);
        }
        if (!_codec.isCompleted) {
          await Future.any<void>(<Future<void>>[
            _serverProcess.exitCode.then((_) {}),
            Future<void>.delayed(const Duration(milliseconds: 250)),
          ]);
          _codec.completeError(
            ScrcpyException(
              ScrcpyErrorCode.protocolFailure,
              'scrcpy video socket closed before codec metadata',
              cause: utf8.decode(_serverOutput.toBytes(), allowMalformed: true),
            ),
          );
        }
        unawaited(_packetController.close());
        unawaited(_sessionController.close());
      },
    );
  }

  final AdbClient _adb;
  final String _serial;
  final _ReadySocket _socket;
  late final _IoScrcpyInputController? _input;
  final AdbRunningCommand _serverProcess;
  final BytesBuilder _serverOutput;
  final Completer<ScrcpyVideoCodecInfo> _codec =
      Completer<ScrcpyVideoCodecInfo>();
  final StreamController<ScrcpyVideoPacket> _packetController =
      StreamController<ScrcpyVideoPacket>();
  final StreamController<ScrcpyVideoCodecInfo> _sessionController =
      StreamController<ScrcpyVideoCodecInfo>();
  late final ScrcpyVideoPacketParser _parser;
  int _bytesReceived = 0;
  bool _loggedFirstChunk = false;
  bool _closed = false;

  @override
  final ScrcpyVideoConnectionInfo info;

  @override
  Future<ScrcpyVideoCodecInfo> get codec => _codec.future;

  @override
  Stream<ScrcpyVideoCodecInfo> get sessions => _sessionController.stream;

  @override
  Stream<ScrcpyVideoPacket> get packets => _packetController.stream;

  @override
  ScrcpyInputController? get input => _input;

  @override
  int get bytesReceived => _bytesReceived;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _socket.close().timeout(const Duration(seconds: 2));
    await _input?.close();
    _serverProcess.kill();
    await _serverProcess.exitCode.timeout(
      const Duration(seconds: 2),
      onTimeout: () => -1,
    );
    await _ignoreFailure(
      _adb
          .removeForward(_serial, 'tcp:${info.localPort}')
          .timeout(const Duration(seconds: 2)),
    );
    await _ignoreFailure(
      _adb
          .shell(_serial, <String>['rm', '-f', info.remoteServerPath])
          .timeout(const Duration(seconds: 2)),
    );
  }
}

final class _IoScrcpyInputController implements ScrcpyInputController {
  _IoScrcpyInputController(this._socket);

  final _ReadySocket _socket;
  Future<void> _writes = Future<void>.value();
  int _width = 0;
  int _height = 0;

  void updateVideoSize(int width, int height) {
    _width = width;
    _height = height;
  }

  Future<void> _send(List<int> bytes) {
    _writes = _writes.then((_) async {
      _socket.add(bytes);
      await _socket.flush();
    });
    return _writes;
  }

  @override
  Future<void> sendKey({required int keyCode, bool down = true}) =>
      _send(ScrcpyControlMessageSerializer.key(keyCode: keyCode, down: down));

  @override
  Future<void> sendPointer(ScrcpyPointerEvent event) {
    if (_width <= 0 || _height <= 0) {
      return Future<void>.error(StateError('Video size is not available'));
    }
    if (event.action == ScrcpyPointerAction.scroll) {
      return _send(
        ScrcpyControlMessageSerializer.scroll(
          normalizedX: event.normalizedX,
          normalizedY: event.normalizedY,
          videoWidth: _width,
          videoHeight: _height,
          horizontal: -event.scrollDeltaX / 20,
          vertical: -event.scrollDeltaY / 20,
          buttons: event.buttons,
        ),
      );
    }
    return _send(
      ScrcpyControlMessageSerializer.pointer(
        event,
        videoWidth: _width,
        videoHeight: _height,
      ),
    );
  }

  @override
  Future<void> sendText(String text) =>
      _send(ScrcpyControlMessageSerializer.text(text));

  Future<void> close() async {
    await _writes;
    await _socket.close();
  }
}

Future<void> _ignoreFailure(Future<Object?> operation) async {
  try {
    await operation;
  } catch (_) {
    // Cleanup is best-effort and must not mask the original failure.
  }
}
