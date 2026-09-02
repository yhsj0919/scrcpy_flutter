import 'dart:convert';

import 'package:adb_client/adb_client.dart';

import 'scrcpy_capabilities.dart';
import 'scrcpy_error.dart';
import 'scrcpy_session.dart';
import 'scrcpy_video_connection.dart';
import 'scrcpy_video_capabilities.dart';

/// Root service object owned by the embedding application.
///
/// It intentionally accepts an [AdbClient], so platform transports can be
/// replaced without changing session or UI code.
final class ScrcpyClient {
  const ScrcpyClient({required this.adbClient, this.runtimeInfo});

  final AdbClient adbClient;
  final ScrcpyRuntimeInfo? runtimeInfo;

  ScrcpyCapabilities get capabilities => ScrcpyCapabilities(
    video: runtimeInfo?.scrcpyServerPath?.isNotEmpty == true,
    control: runtimeInfo?.scrcpyServerPath?.isNotEmpty == true,
  );

  ScrcpySession createSession(ScrcpySessionConfiguration configuration) =>
      ScrcpySession(
        adbDeviceService: adbClient,
        configuration: configuration,
        videoConnector: _videoConnectorOrNull(),
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
        runtimeInfo?.scrcpyServerVersion ?? '4.1',
        'list_apps=true',
        'cleanup=true',
      ], cancellationToken: cancellationToken);
      if (!result.isSuccess) return applications;
      final labels = parseScrcpyApplicationLabels(
        utf8.decode(<int>[
          ...result.stdout,
          ...result.stderr,
        ], allowMalformed: true),
      );
      if (labels.isEmpty) return applications;
      final enriched = <AdbApplication>[
        for (final application in applications)
          application.copyWith(name: labels[application.packageName]),
      ]..sort((a, b) {
        final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        return byName != 0 ? byName : a.packageName.compareTo(b.packageName);
      });
      return List<AdbApplication>.unmodifiable(enriched);
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

  Future<ScrcpyVideoCapabilities> probeVideoCapabilities(
    String deviceSerial, {
    AdbCancellationToken? cancellationToken,
  }) async {
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
        runtimeInfo?.scrcpyServerVersion ?? '4.1',
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
    final connector = _videoConnectorOrNull();
    if (connector == null) {
      throw const ScrcpyException(
        ScrcpyErrorCode.unsupportedCapability,
        'Video connection is unavailable for this client',
      );
    }
    return connector;
  }

  ScrcpyVideoConnector? _videoConnectorOrNull() {
    final path = runtimeInfo?.scrcpyServerPath;
    if (path == null || path.isEmpty) return null;
    return createScrcpyVideoConnector(
      adbClient: adbClient,
      serverPath: path,
      expectedServerSha256: runtimeInfo?.scrcpyServerSha256,
    );
  }
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
