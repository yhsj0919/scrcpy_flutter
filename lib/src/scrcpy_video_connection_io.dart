import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:adb_client/adb_client.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'scrcpy_error.dart';
import 'scrcpy_audio_packet.dart';
import 'scrcpy_control_message.dart';
import 'scrcpy_display_source.dart';
import 'scrcpy_input.dart';
import 'scrcpy_session.dart';
import 'scrcpy_video_connection.dart';
import 'scrcpy_video_packet.dart';

ScrcpyVideoConnector createScrcpyVideoConnector({
  required AdbClient adbClient,
  required String serverPath,
  String? expectedServerSha256,
}) => _IoScrcpyVideoConnector(adbClient, serverPath, expectedServerSha256);

Future<void> validateScrcpyServerResource(
  String serverPath, {
  String? expectedSha256,
}) async {
  final file = File(serverPath);
  if (!await file.exists()) {
    throw const ScrcpyException(
      ScrcpyErrorCode.resourceMissing,
      'Bundled scrcpy server was not found',
    );
  }
  if (expectedSha256 == null) return;
  final digest = await sha256.bind(file.openRead()).first;
  if (digest.toString().toLowerCase() != expectedSha256.toLowerCase()) {
    throw const ScrcpyException(
      ScrcpyErrorCode.resourceInvalid,
      'Bundled scrcpy server checksum does not match version 4.1',
    );
  }
}

final class _IoScrcpyVideoConnector implements ScrcpyVideoConnector {
  _IoScrcpyVideoConnector(
    this._adb,
    this._serverPath,
    this._expectedServerSha256,
  );

  static const _version = '4.1';
  final AdbClient _adb;
  final String _serverPath;
  final String? _expectedServerSha256;
  Future<void>? _resourceValidation;
  final Map<String, Future<int?>> _androidSdkBySerial =
      <String, Future<int?>>{};

  @override
  Future<ScrcpyVideoConnection> connect(
    ScrcpySessionConfiguration configuration, {
    AdbCancellationToken? cancellationToken,
  }) async {
    configuration.validate();
    await (_resourceValidation ??= validateScrcpyServerResource(
      _serverPath,
      expectedSha256: _expectedServerSha256,
    ));
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
      final audioPreparation = await _prepareAndroid11AudioCapture(
        configuration,
        cancellationToken: cancellationToken,
      );
      final audioSource = configuration.audio.resolveSourceForAndroidSdk(
        audioPreparation.sdk,
      );
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
        'audio=${configuration.audioEnabled}',
        'control=${configuration.controlEnabled}',
        'clipboard_autosync=false',
        'cleanup=true',
        'send_device_meta=false',
        'video_codec=${video.codec.serverName}',
        'max_size=${video.maxSize}',
        'max_fps=${video.maxFps}',
        'video_bit_rate=${video.bitRate}',
        if (configuration.audioEnabled) ...<String>[
          'audio_codec=${configuration.audio.codec.serverName}',
          'audio_bit_rate=${configuration.audio.bitRate}',
          'audio_source=${audioSource.serverName!}',
          'audio_dup=${configuration.audio.duplicateOnDevice}',
        ],
        if (video.encoder case final encoder?) 'video_encoder=$encoder',
        ...configuration.displaySource.toServerArguments(),
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
        audioEnabled: configuration.audioEnabled,
        controlEnabled: configuration.controlEnabled,
        cancellationToken: cancellationToken,
      );
      final connection = _IoScrcpyVideoConnection(
        _adb,
        configuration.deviceSerial,
        sockets.video,
        sockets.audio,
        sockets.control,
        serverProcess,
        serverOutput,
        info: ScrcpyVideoConnectionInfo(
          scid: scid,
          localPort: port,
          remoteServerPath: remotePath,
        ),
      );
      if (audioPreparation.popupStarted) {
        final audio = connection.audio;
        if (audio == null) {
          unawaited(_dismissAndroid11AudioPopup(configuration.deviceSerial));
        } else {
          unawaited(
            audio.codec
                .timeout(const Duration(seconds: 5), onTimeout: () => null)
                .whenComplete(
                  () => _dismissAndroid11AudioPopup(configuration.deviceSerial),
                ),
          );
        }
      }
      if (configuration.audioRequired) {
        ScrcpyAudioCodecInfo? audioCodec;
        try {
          audioCodec = await connection.audio!.codec.timeout(
            const Duration(seconds: 5),
          );
        } catch (error) {
          await connection.close();
          throw ScrcpyException(
            ScrcpyErrorCode.connectionFailure,
            'scrcpy audio capture is required but did not become ready',
            cause: error,
          );
        }
        if (audioCodec == null) {
          await connection.close();
          throw const ScrcpyException(
            ScrcpyErrorCode.connectionFailure,
            'scrcpy audio capture is required but unavailable',
          );
        }
      }
      final source = configuration.displaySource;
      if (source is ScrcpyVirtualDisplaySource) {
        final application = source.launchApplication;
        if (application != null) {
          await connection.input!.startApplication(application);
        }
      }
      return connection;
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

  Future<({int? sdk, bool popupStarted})> _prepareAndroid11AudioCapture(
    ScrcpySessionConfiguration configuration, {
    AdbCancellationToken? cancellationToken,
  }) async {
    if (!configuration.audioEnabled) return (sdk: null, popupStarted: false);
    final serial = configuration.deviceSerial;
    final sdkLookup = _androidSdkBySerial.putIfAbsent(
      serial,
      () => _readAndroidSdk(serial, cancellationToken: cancellationToken),
    );
    final sdk = await sdkLookup;
    if (sdk == null && identical(_androidSdkBySerial[serial], sdkLookup)) {
      _androidSdkBySerial.remove(serial);
    }
    if (sdk != 30) return (sdk: sdk, popupStarted: false);
    try {
      // Android 11 only permits shell audio capture while the shell package is
      // considered foreground. scrcpy also performs this workaround, but a
      // few vendor ROMs require the activity to be started explicitly before
      // the server process (Genymobile/scrcpy#4147).
      final result = await _adb.shell(serial, const <String>[
        'am',
        'start',
        '-W',
        '-n',
        'com.android.shell/.HeapDumpActivity',
      ], cancellationToken: cancellationToken);
      if (!result.isSuccess && kDebugMode) {
        debugPrint('scrcpy audio: Android 11 foreground preparation failed');
      }
      return (sdk: sdk, popupStarted: result.isSuccess);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('scrcpy audio: Android 11 foreground preparation: $error');
      }
      return (sdk: sdk, popupStarted: false);
    }
  }

  Future<void> _dismissAndroid11AudioPopup(String serial) async {
    try {
      final activities = await _adb.shell(serial, const <String>[
        'dumpsys',
        'activity',
        'activities',
      ]);
      final output = utf8.decode(<int>[
        ...activities.stdout,
        ...activities.stderr,
      ], allowMalformed: true);
      final popupIsForeground = const LineSplitter()
          .convert(output)
          .any(
            (line) =>
                line.contains('ResumedActivity') &&
                line.contains('com.android.shell/.HeapDumpActivity'),
          );
      if (!popupIsForeground) return;
      await _adb.shell(serial, const <String>['input', 'keyevent', '4']);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('scrcpy audio: unable to dismiss Android 11 popup: $error');
      }
    }
  }

  Future<int?> _readAndroidSdk(
    String serial, {
    AdbCancellationToken? cancellationToken,
  }) async {
    try {
      final result = await _adb.shell(serial, const <String>[
        'getprop',
        'ro.build.version.sdk',
      ], cancellationToken: cancellationToken);
      if (!result.isSuccess) return null;
      return int.tryParse(utf8.decode(result.stdout).trim());
    } catch (_) {
      return null;
    }
  }

  Future<_SocketPair> _connectWithRetry(
    int port, {
    required bool audioEnabled,
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
      _ReadySocket? video;
      _ReadySocket? audio;
      _ReadySocket? control;
      try {
        video = _ReadySocket(
          await Socket.connect(
            InternetAddress.loopbackIPv4,
            port,
            timeout: const Duration(milliseconds: 500),
          ),
        );
        if (audioEnabled) {
          audio = _ReadySocket(
            await Socket.connect(
              InternetAddress.loopbackIPv4,
              port,
              timeout: const Duration(milliseconds: 500),
            ),
          );
        }
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
        if (ready) return _SocketPair(video, audio, control);
        lastError = StateError('scrcpy socket closed before becoming ready');
        await _ignoreFailure(video.close());
        if (audio != null) await _ignoreFailure(audio.close());
        if (control != null) await _ignoreFailure(control.close());
      } catch (error) {
        lastError = error;
        if (video != null) await _ignoreFailure(video.close());
        if (audio != null) await _ignoreFailure(audio.close());
        if (control != null) await _ignoreFailure(control.close());
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
  const _SocketPair(this.video, this.audio, this.control);

  final _ReadySocket video;
  final _ReadySocket? audio;
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
    _ReadySocket? audioSocket,
    _ReadySocket? controlSocket,
    this._serverProcess,
    this._serverOutput, {
    required this.info,
  }) {
    _audio = audioSocket == null ? null : _IoScrcpyAudioStream(audioSocket);
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
        if (!_done.isCompleted) _done.completeError(error, stackTrace);
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
        if (!_done.isCompleted) _done.complete();
      },
    );
  }

  final AdbClient _adb;
  final String _serial;
  final _ReadySocket _socket;
  late final _IoScrcpyInputController? _input;
  late final _IoScrcpyAudioStream? _audio;
  final AdbRunningCommand _serverProcess;
  final BytesBuilder _serverOutput;
  final Completer<ScrcpyVideoCodecInfo> _codec =
      Completer<ScrcpyVideoCodecInfo>();
  final Completer<void> _done = Completer<void>();
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
  ScrcpyAudioStream? get audio => _audio;

  @override
  int get bytesReceived => _bytesReceived;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (_input != null) {
      await _ignoreFailure(_input.close().timeout(const Duration(seconds: 2)));
    }
    if (_audio != null) {
      await _ignoreFailure(_audio.close().timeout(const Duration(seconds: 2)));
    }
    await _ignoreFailure(_socket.close().timeout(const Duration(seconds: 2)));
    _serverProcess.kill();
    await _ignoreFailure(
      _serverProcess.exitCode.timeout(
        const Duration(seconds: 2),
        onTimeout: () => -1,
      ),
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
    if (!_done.isCompleted) _done.complete();
  }
}

final class _IoScrcpyAudioStream implements ScrcpyAudioStream {
  _IoScrcpyAudioStream(this._socket) {
    _parser = ScrcpyAudioPacketParser(
      onCodec: (value) {
        if (!_codec.isCompleted) _codec.complete(value);
      },
      onDisabled: () {
        if (!_codec.isCompleted) _codec.complete(null);
      },
      onPacket: _packets.add,
    );
    _subscription = _socket.chunks.listen(
      (data) {
        _bytesReceived += data.length;
        try {
          _parser.add(data);
        } catch (error, stackTrace) {
          if (!_codec.isCompleted) _codec.completeError(error, stackTrace);
          _packets.addError(error, stackTrace);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!_codec.isCompleted) _codec.completeError(error, stackTrace);
        _packets.addError(error, stackTrace);
        if (!_done.isCompleted) _done.completeError(error, stackTrace);
      },
      onDone: () {
        if (!_codec.isCompleted) _codec.complete(null);
        unawaited(_packets.close());
        if (!_done.isCompleted) _done.complete();
      },
    );
  }

  final _ReadySocket _socket;
  final Completer<ScrcpyAudioCodecInfo?> _codec =
      Completer<ScrcpyAudioCodecInfo?>();
  final StreamController<ScrcpyAudioPacket> _packets =
      StreamController<ScrcpyAudioPacket>();
  final Completer<void> _done = Completer<void>();
  late final ScrcpyAudioPacketParser _parser;
  late final StreamSubscription<Uint8List> _subscription;
  int _bytesReceived = 0;
  bool _closed = false;

  @override
  Future<ScrcpyAudioCodecInfo?> get codec => _codec.future;

  @override
  Stream<ScrcpyAudioPacket> get packets => _packets.stream;

  @override
  int get bytesReceived => _bytesReceived;

  @override
  Future<void> get done => _done.future;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription.cancel();
    await _socket.close();
    if (!_codec.isCompleted) _codec.complete(null);
    await _packets.close();
    if (!_done.isCompleted) _done.complete();
  }
}

final class _IoScrcpyInputController implements ScrcpyInputController {
  _IoScrcpyInputController(this._socket) {
    _subscription = _socket.chunks.listen(
      _onDeviceData,
      onError: _clipboardController.addError,
      onDone: _onDeviceDone,
    );
  }

  final _ReadySocket _socket;
  final ScrcpyDeviceMessageParser _deviceParser = ScrcpyDeviceMessageParser();
  final StreamController<String> _clipboardController =
      StreamController<String>.broadcast();
  final Map<int, Completer<void>> _clipboardAcks = <int, Completer<void>>{};
  late final StreamSubscription<Uint8List> _subscription;
  Future<void> _writes = Future<void>.value();
  int _nextClipboardSequence = 1;
  int _width = 0;
  int _height = 0;
  bool _closed = false;
  bool _disposed = false;
  final Map<int, (int, int)> _activePointerSizes = <int, (int, int)>{};

  void updateVideoSize(int width, int height) {
    _width = width;
    _height = height;
  }

  Future<void> _send(List<int> bytes) {
    if (_closed) return Future<void>.value();
    _writes = _writes.then((_) async {
      if (_closed) return;
      try {
        _socket.add(bytes);
        await _socket.flush();
      } on StateError catch (error) {
        // dart:io reports a closed socket as a StateError. The connection
        // lifecycle reports the disconnect; late UI input is safe to drop.
        if (error.message.toString().contains('closed')) {
          _closed = true;
          _activePointerSizes.clear();
          return;
        }
        rethrow;
      } on SocketException {
        _closed = true;
        _activePointerSizes.clear();
      }
    });
    return _writes;
  }

  @override
  Future<void> sendKey({required int keyCode, bool down = true}) =>
      _send(ScrcpyControlMessageSerializer.key(keyCode: keyCode, down: down));

  @override
  Future<void> sendPointer(ScrcpyPointerEvent event) {
    final eventWidth = event.videoWidth;
    final eventHeight = event.videoHeight;
    var width = eventWidth != null && eventWidth > 0 ? eventWidth : _width;
    var height = eventHeight != null && eventHeight > 0 ? eventHeight : _height;
    final activeSize = _activePointerSizes[event.pointerId];
    if (activeSize != null &&
        (event.action == ScrcpyPointerAction.move ||
            event.action == ScrcpyPointerAction.up ||
            event.action == ScrcpyPointerAction.cancel)) {
      width = activeSize.$1;
      height = activeSize.$2;
    }
    if (width <= 0 || height <= 0) {
      return Future<void>.error(StateError('Video size is not available'));
    }
    if (event.action == ScrcpyPointerAction.down) {
      _activePointerSizes[event.pointerId] = (width, height);
    } else if (event.action == ScrcpyPointerAction.up ||
        event.action == ScrcpyPointerAction.cancel) {
      _activePointerSizes.remove(event.pointerId);
    }
    if (event.action == ScrcpyPointerAction.scroll) {
      return _send(
        ScrcpyControlMessageSerializer.scroll(
          normalizedX: event.normalizedX,
          normalizedY: event.normalizedY,
          videoWidth: width,
          videoHeight: height,
          horizontal: -event.scrollDeltaX / 20,
          vertical: -event.scrollDeltaY / 20,
          buttons: event.buttons,
        ),
      );
    }
    return _send(
      ScrcpyControlMessageSerializer.pointer(
        event,
        videoWidth: width,
        videoHeight: height,
      ),
    );
  }

  @override
  Future<void> sendText(String text) =>
      _send(ScrcpyControlMessageSerializer.text(text));

  @override
  Future<void> startApplication(ScrcpyApplicationLaunch application) {
    application.validate();
    return _send(
      ScrcpyControlMessageSerializer.startApplication(application.controlName),
    );
  }

  @override
  Future<void> resizeDisplay({required int width, required int height}) =>
      _send(
        ScrcpyControlMessageSerializer.resizeDisplay(
          width: width,
          height: height,
        ),
      );

  @override
  Stream<String> get clipboardChanges => _clipboardController.stream;

  @override
  Future<void> requestClipboard({ScrcpyCopyKey copyKey = ScrcpyCopyKey.none}) =>
      _send(ScrcpyControlMessageSerializer.getClipboard(copyKey: copyKey));

  @override
  Future<void> setClipboard(String text, {bool paste = false}) async {
    final sequence = _nextClipboardSequence++;
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
      await acknowledgement.future.timeout(const Duration(seconds: 3));
    } finally {
      _clipboardAcks.remove(sequence);
    }
  }

  void _onDeviceData(Uint8List data) {
    try {
      for (final message in _deviceParser.add(data)) {
        switch (message) {
          case ScrcpyClipboardMessage(:final text):
            _clipboardController.add(text);
          case ScrcpyClipboardAckMessage(:final sequence):
            _clipboardAcks.remove(sequence)?.complete();
          case ScrcpyUhidOutputMessage():
            break;
        }
      }
    } catch (error, stackTrace) {
      _clipboardController.addError(error, stackTrace);
    }
  }

  void _onDeviceDone() {
    _closed = true;
    _activePointerSizes.clear();
    for (final acknowledgement in _clipboardAcks.values) {
      if (!acknowledgement.isCompleted) {
        acknowledgement.completeError(
          StateError('scrcpy control socket closed before clipboard ACK'),
        );
      }
    }
  }

  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    _closed = true;
    _activePointerSizes.clear();
    try {
      await _writes;
    } finally {
      await _subscription.cancel();
      await _clipboardController.close();
      await _socket.close();
    }
  }
}

Future<void> _ignoreFailure(Future<Object?> operation) async {
  try {
    await operation;
  } catch (_) {
    // Cleanup is best-effort and must not mask the original failure.
  }
}
