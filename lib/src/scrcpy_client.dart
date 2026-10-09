import 'dart:convert';

import 'package:adb_client/adb_client.dart';

import 'scrcpy_capabilities.dart';
import 'scrcpy_error.dart';
import 'scrcpy_session.dart';
import 'scrcpy_video_connection.dart';
import 'scrcpy_video_capabilities.dart';

abstract interface class ScrcpyApplicationLabelProvider {
  Future<String> loadApplicationLabels(
    String deviceSerial, {
    AdbCancellationToken? cancellationToken,
  });
}

abstract interface class ScrcpyVideoCapabilitiesProvider {
  Future<String> loadVideoEncoders(
    String deviceSerial, {
    AdbCancellationToken? cancellationToken,
  });
}

/// Root service object owned by the embedding application.
///
/// It intentionally accepts an [AdbClient], so platform transports can be
/// replaced without changing session or UI code.
final class ScrcpyClient {
  const ScrcpyClient({
    required this.adbClient,
    this.runtimeInfo,
    this._videoConnector,
  });

  final AdbClient adbClient;
  final ScrcpyRuntimeInfo? runtimeInfo;
  final ScrcpyVideoConnector? _videoConnector;

  ScrcpyCapabilities get capabilities => ScrcpyCapabilities(
    video:
        _videoConnector != null ||
        runtimeInfo?.scrcpyServerPath?.isNotEmpty == true,
    control:
        _videoConnector != null ||
        runtimeInfo?.scrcpyServerPath?.isNotEmpty == true,
  );

  ScrcpyRawSession createSession(
    ScrcpySessionConfiguration configuration, {
    String? id,
  }) => ScrcpyRawSession(
    adbDeviceService: adbClient,
    configuration: configuration,
    videoConnector: _fallbackVideoConnectorOrNull(),
    id: id,
  );

  /// Lists packages through ADB and enriches localized display names through
  /// the bundled scrcpy server. Standard package commands expose label
  /// resource IDs, but do not resolve them to text.
  Future<List<AdbApplication>> listApplications(
    String deviceSerial, {
    AdbCancellationToken? cancellationToken,
  }) async {
    final applications = await AdbApplicationManager(
      adbClient: adbClient,
      serial: deviceSerial,
    ).listApplications(cancellationToken: cancellationToken);
    if (adbClient case final ScrcpyApplicationLabelProvider provider) {
      try {
        final output = await provider.loadApplicationLabels(
          deviceSerial,
          cancellationToken: cancellationToken,
        );
        return _enrichApplicationLabels(applications, output);
      } catch (_) {
        return applications;
      }
    }
    final serverPath = runtimeInfo?.scrcpyServerPath;
    if (serverPath == null || serverPath.isEmpty) return applications;

    final probeId = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final remotePath = '/data/local/tmp/scrcpy-server-apps-$probeId.jar';
    try {
      await adbClient.push(
        deviceSerial,
        serverPath,
        remotePath,
        cancellationToken: cancellationToken,
      );
      final result = await adbClient.shell(deviceSerial, <String>[
        'CLASSPATH=$remotePath',
        'app_process',
        '/',
        'com.genymobile.scrcpy.Server',
        runtimeInfo?.scrcpyServerVersion ?? '5.0.1',
        'list_apps=true',
        'cleanup=true',
      ], cancellationToken: cancellationToken);
      if (!result.isSuccess) return applications;
      return _enrichApplicationLabels(
        applications,
        utf8.decode(<int>[
          ...result.stdout,
          ...result.stderr,
        ], allowMalformed: true),
      );
    } catch (_) {
      return applications;
    } finally {
      try {
        await adbClient.shell(deviceSerial, <String>['rm', '-f', remotePath]);
      } catch (_) {
        // Label discovery is best-effort and cleanup must not hide the list.
      }
    }
  }

  static Map<String, String> parseScrcpyApplicationLabels(String output) {
    final labels = <String, String>{};
    final linePattern = RegExp(
      r'^\s*[*-]\s+(.+?)\s+([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+|android)\s*$',
    );
    for (final line in const LineSplitter().convert(output)) {
      final match = linePattern.firstMatch(line);
      if (match == null) continue;
      final label = match.group(1)!.trim();
      final packageName = match.group(2)!;
      if (label.isNotEmpty) labels[packageName] = label;
    }
    return labels;
  }

  static List<AdbApplication> _enrichApplicationLabels(
    List<AdbApplication> applications,
    String output,
  ) {
    final labels = parseScrcpyApplicationLabels(output);
    if (labels.isEmpty) return applications;
    final enriched =
        <AdbApplication>[
          for (final application in applications)
            application.copyWith(name: labels[application.packageName]),
        ]..sort((a, b) {
          final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
          return byName != 0 ? byName : a.packageName.compareTo(b.packageName);
        });
    return List<AdbApplication>.unmodifiable(enriched);
  }

  Future<ScrcpyVideoCapabilities> probeVideoCapabilities(
    String deviceSerial, {
    AdbCancellationToken? cancellationToken,
  }) async {
    if (adbClient case final ScrcpyVideoCapabilitiesProvider provider) {
      final output = await provider.loadVideoEncoders(
        deviceSerial,
        cancellationToken: cancellationToken,
      );
      final capabilities = ScrcpyVideoCapabilities.parseServerOutput(output);
      if (capabilities.encoders.isEmpty) {
        throw const ScrcpyException(
          ScrcpyErrorCode.protocolFailure,
          'scrcpy returned no supported video encoders',
        );
      }
      return capabilities;
    }
    final serverPath = runtimeInfo?.scrcpyServerPath;
    if (serverPath == null || serverPath.isEmpty) {
      throw const ScrcpyException(
        ScrcpyErrorCode.unsupportedCapability,
        'Video encoder discovery is unavailable for this client',
      );
    }
    final probeId = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final remotePath = '/data/local/tmp/scrcpy-server-probe-$probeId.jar';
    try {
      await adbClient.push(
        deviceSerial,
        serverPath,
        remotePath,
        cancellationToken: cancellationToken,
      );
      final result = await adbClient.shell(deviceSerial, <String>[
        'CLASSPATH=$remotePath',
        'app_process',
        '/',
        'com.genymobile.scrcpy.Server',
        runtimeInfo?.scrcpyServerVersion ?? '5.0.1',
        'list_encoders=true',
        'cleanup=true',
      ], cancellationToken: cancellationToken);
      final output = utf8.decode(<int>[
        ...result.stdout,
        ...result.stderr,
      ], allowMalformed: true);
      if (!result.isSuccess) {
        throw ScrcpyException(
          ScrcpyErrorCode.connectionFailure,
          'Unable to list device video encoders',
          cause: result.exitCode,
        );
      }
      final capabilities = ScrcpyVideoCapabilities.parseServerOutput(output);
      if (capabilities.encoders.isEmpty) {
        throw const ScrcpyException(
          ScrcpyErrorCode.protocolFailure,
          'scrcpy returned no supported video encoders',
        );
      }
      return capabilities;
    } finally {
      try {
        await adbClient.shell(deviceSerial, <String>['rm', '-f', remotePath]);
      } catch (_) {
        // Probe cleanup is best-effort.
      }
    }
  }

  ScrcpyVideoConnector createVideoConnector() {
    final connector = _fallbackVideoConnectorOrNull();
    if (connector == null) {
      throw const ScrcpyException(
        ScrcpyErrorCode.unsupportedCapability,
        'Video connection is unavailable for this client',
      );
    }
    return connector;
  }

  ScrcpyVideoConnector? _fallbackVideoConnectorOrNull() {
    final connector = _videoConnectorOrNull();
    if (connector == null) return null;
    return _ScrcpyVideoFallbackConnector(
      connector,
      (serial, cancellationToken) =>
          probeVideoCapabilities(serial, cancellationToken: cancellationToken),
    );
  }

  ScrcpyVideoConnector? _videoConnectorOrNull() {
    if (_videoConnector case final connector?) return connector;
    final path = runtimeInfo?.scrcpyServerPath;
    if (path == null || path.isEmpty) return null;
    return createScrcpyVideoConnector(
      adbClient: adbClient,
      serverPath: path,
      expectedServerSha256: runtimeInfo?.scrcpyServerSha256,
    );
  }
}

final class _ScrcpyVideoFallbackConnector implements ScrcpyVideoConnector {
  const _ScrcpyVideoFallbackConnector(this._delegate, this._probe);

  final ScrcpyVideoConnector _delegate;
  final Future<ScrcpyVideoCapabilities> Function(
    String deviceSerial,
    AdbCancellationToken? cancellationToken,
  )
  _probe;

  @override
  Future<ScrcpyVideoConnection> connect(
    ScrcpySessionConfiguration configuration, {
    AdbCancellationToken? cancellationToken,
  }) async {
    final video = configuration.video;
    if (video.codec != ScrcpyVideoCodec.h264) {
      return _delegate.connect(
        configuration,
        cancellationToken: cancellationToken,
      );
    }

    final attempts = <({String? encoder, bool lowLatency})>[];
    if (video.encoder case final encoder?) {
      attempts.add((encoder: encoder, lowLatency: video.lowLatency));
      if (video.lowLatency) {
        attempts.add((encoder: encoder, lowLatency: false));
      }
    } else {
      try {
        final capabilities = await _probe(
          configuration.deviceSerial,
          cancellationToken,
        );
        ScrcpyVideoEncoder? hardware;
        ScrcpyVideoEncoder? software;
        ScrcpyVideoEncoder? softwareAlias;
        for (final encoder in capabilities.forCodec(
          ScrcpyVideoCodec.h264,
          includeAliases: true,
        )) {
          if (encoder.isAlias) {
            if (!encoder.hardware) softwareAlias ??= encoder;
          } else if (encoder.hardware) {
            hardware ??= encoder;
          } else {
            software ??= encoder;
          }
        }
        for (final encoder in <ScrcpyVideoEncoder?>[
          hardware,
          software,
          softwareAlias,
        ].nonNulls) {
          attempts.add((encoder: encoder.name, lowLatency: video.lowLatency));
          if (video.lowLatency) {
            attempts.add((encoder: encoder.name, lowLatency: false));
          }
        }
      } catch (_) {
        if (cancellationToken?.isCancelled ?? false) {
          throw const ScrcpyException(
            ScrcpyErrorCode.cancelled,
            'scrcpy connection cancelled',
          );
        }
      }
      if (attempts.isEmpty) {
        attempts.add((encoder: null, lowLatency: video.lowLatency));
        if (video.lowLatency) {
          attempts.add((encoder: null, lowLatency: false));
        }
      }
    }
    Object? lastError;
    for (var index = 0; index < attempts.length; index++) {
      if (cancellationToken?.isCancelled ?? false) {
        throw const ScrcpyException(
          ScrcpyErrorCode.cancelled,
          'scrcpy connection cancelled',
        );
      }
      final attempt = attempts[index];
      ScrcpyVideoConnection? connection;
      try {
        connection = await _delegate.connect(
          _withVideo(
            configuration,
            encoder: attempt.encoder,
            lowLatency: attempt.lowLatency,
          ),
          cancellationToken: cancellationToken,
        );
        await connection.codec.timeout(const Duration(seconds: 5));
        return connection;
      } catch (error) {
        await connection?.close();
        if (!_isEncoderStartupFailure(error)) rethrow;
        lastError = error;
        if (index + 1 < attempts.length) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      }
    }
    throw ScrcpyException(
      ScrcpyErrorCode.videoFailure,
      'Unable to start an H.264 encoder after trying ${attempts.map(_attemptName).join(', ')}',
      cause: lastError,
    );
  }

  static String _attemptName(({String? encoder, bool lowLatency}) attempt) =>
      '${attempt.encoder ?? 'automatic'}${attempt.lowLatency ? '' : ' without low latency'}';

  static bool _isEncoderStartupFailure(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('capture/encoding error') ||
        text.contains('mediacodec') ||
        text.contains('before codec metadata');
  }

  static ScrcpySessionConfiguration _withVideo(
    ScrcpySessionConfiguration configuration, {
    required String? encoder,
    required bool lowLatency,
  }) => ScrcpySessionConfiguration(
    deviceSerial: configuration.deviceSerial,
    video: ScrcpyVideoOptions(
      maxSize: configuration.video.maxSize,
      maxFps: configuration.video.maxFps,
      bitRate: configuration.video.bitRate,
      codec: configuration.video.codec,
      encoder: encoder,
      lowLatency: lowLatency,
    ),
    controlEnabled: configuration.controlEnabled,
    audioEnabled: configuration.audioEnabled,
    audioRequired: configuration.audioRequired,
    audio: configuration.audio,
    displaySource: configuration.displaySource,
    reconnectPolicy: configuration.reconnectPolicy,
  );
}

final class ScrcpyRuntimeInfo {
  const ScrcpyRuntimeInfo({
    required this.usesBundledAdb,
    this.adbExecutablePath,
    this.scrcpyServerPath,
    this.scrcpyServerVersion,
    this.scrcpyServerSha256,
  });

  final bool usesBundledAdb;
  final String? adbExecutablePath;
  final String? scrcpyServerPath;
  final String? scrcpyServerVersion;
  final String? scrcpyServerSha256;
}
