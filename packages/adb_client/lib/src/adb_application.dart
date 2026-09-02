import 'dart:convert';

import 'adb_cancellation_token.dart';
import 'adb_client_base.dart';
import 'adb_command.dart';
import 'adb_exception.dart';

enum AdbApplicationType { user, system }

enum AdbApplicationOperation { start, stop }

final class AdbApplicationOperationException implements Exception {
  const AdbApplicationOperationException({
    required this.operation,
    required this.packageName,
    required this.message,
    this.cause,
  });

  final AdbApplicationOperation operation;
  final String packageName;
  final String message;
  final Object? cause;

  @override
  String toString() =>
      'AdbApplicationOperationException($operation, $packageName, $message)';
}

final class AdbApplication {
  const AdbApplication({
    required this.packageName,
    required this.name,
    required this.type,
    required this.enabled,
    this.versionName,
    this.versionCode,
    this.apkPath,
    this.uid,
    this.launchable = false,
  });

  final String packageName;
  final String name;
  final AdbApplicationType type;
  final bool enabled;
  final String? versionName;
  final int? versionCode;
  final String? apkPath;
  final int? uid;
  final bool launchable;

  AdbApplication copyWith({String? name}) => AdbApplication(
    packageName: packageName,
    name: name ?? this.name,
    type: type,
    enabled: enabled,
    versionName: versionName,
    versionCode: versionCode,
    apkPath: apkPath,
    uid: uid,
    launchable: launchable,
  );

  bool matches(String query) {
    final normalized = query.trim().toLowerCase();
    return normalized.isEmpty ||
        name.toLowerCase().contains(normalized) ||
        packageName.toLowerCase().contains(normalized);
  }
}

final class AdbApplicationParser {
  const AdbApplicationParser._();

  static Set<String> launcherPackages(String output) {
    final packages = <String>{};
    final pattern = RegExp(r'^\s*([A-Za-z0-9_.]+)/\S+\s*$');
    for (final line in const LineSplitter().convert(output)) {
      final match = pattern.firstMatch(line);
      if (match == null) continue;
      packages.add(match.group(1)!);
    }
    return packages;
  }

  static List<AdbApplication> merge({
    required String packageListOutput,
    required String packageDumpOutput,
    String launcherActivitiesOutput = '',
  }) {
    final launchablePackages = launcherPackages(launcherActivitiesOutput);
    final dump = _parsePackageDump(packageDumpOutput);
    final result = <AdbApplication>[];
    final linePattern = RegExp(
      r'^package:(.+)=([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+|android)((?:\s+.*)?)$',
    );
    for (final rawLine in const LineSplitter().convert(packageListOutput)) {
      final match = linePattern.firstMatch(rawLine.trim());
      if (match == null) continue;
      final packageName = match.group(2)!;
      if (!_looksLikePackageName(packageName)) continue;
      final apkPath = match.group(1)!;
      final metadata = match.group(3)!;
      final details = dump[packageName];
      result.add(
        AdbApplication(
          packageName: packageName,
          name: packageName,
          type: _isSystemPath(apkPath)
              ? AdbApplicationType.system
              : AdbApplicationType.user,
          enabled: details?.enabled ?? true,
          versionName: details?.versionName,
          versionCode:
              int.tryParse(
                RegExp(r'\bversionCode:(\d+)').firstMatch(metadata)?.group(1) ??
                    '',
              ) ??
              details?.versionCode,
          apkPath: apkPath,
          uid: int.tryParse(
            RegExp(r'\buid:(\d+)').firstMatch(metadata)?.group(1) ?? '',
          ),
          launchable: launchablePackages.contains(packageName),
        ),
      );
    }
    result.sort((a, b) {
      final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return byName != 0 ? byName : a.packageName.compareTo(b.packageName);
    });
    return List<AdbApplication>.unmodifiable(result);
  }

  static Map<String, ({String? versionName, int? versionCode, bool enabled})>
  _parsePackageDump(String output) {
    final result =
        <String, ({String? versionName, int? versionCode, bool enabled})>{};
    String? packageName;
    String? versionName;
    int? versionCode;
    var enabled = true;

    void commit() {
      final name = packageName;
      if (name != null) {
        result[name] = (
          versionName: versionName,
          versionCode: versionCode,
          enabled: enabled,
        );
      }
    }

    for (final line in const LineSplitter().convert(output)) {
      final packageMatch = RegExp(r'^\s*Package \[([^\]]+)\]').firstMatch(line);
      if (packageMatch != null) {
        commit();
        packageName = packageMatch.group(1);
        versionName = null;
        versionCode = null;
        enabled = true;
        continue;
      }
      if (packageName == null) continue;
      final trimmed = line.trim();
      if (trimmed.startsWith('versionCode=')) {
        versionCode = int.tryParse(
          RegExp(r'versionCode=(\d+)').firstMatch(trimmed)?.group(1) ?? '',
        );
      } else if (trimmed.startsWith('versionName=')) {
        final value = trimmed.substring('versionName='.length).trim();
        versionName = value == 'null' || value.isEmpty ? null : value;
      } else if (trimmed.startsWith('User 0:')) {
        final state = int.tryParse(
          RegExp(r'\benabled=(\d+)').firstMatch(trimmed)?.group(1) ?? '',
        );
        if (state != null) enabled = state == 0 || state == 1;
      }
    }
    commit();
    return result;
  }

  static bool _isSystemPath(String path) =>
      !path.startsWith('/data/app/') && !path.startsWith('/mnt/expand/');

  static bool _looksLikePackageName(String value) =>
      value == 'android' ||
      RegExp(r'^[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+$').hasMatch(value);
}

final class AdbApplicationManager {
  const AdbApplicationManager({required this.adbClient, required this.serial});

  final AdbClient adbClient;
  final String serial;

  Future<void> startApplication(
    String packageName, {
    bool forceStopFirst = false,
    AdbCancellationToken? cancellationToken,
  }) async {
    _validatePackageName(packageName);
    if (forceStopFirst) {
      await stopApplication(packageName, cancellationToken: cancellationToken);
    }
    final resolved = await adbClient.shell(serial, <String>[
      'cmd',
      'package',
      'resolve-activity',
      '--brief',
      '-a',
      'android.intent.action.MAIN',
      '-c',
      'android.intent.category.LAUNCHER',
      packageName,
    ], cancellationToken: cancellationToken);
    final resolveOutput = _decodeResult(resolved);
    final component = const LineSplitter()
        .convert(resolveOutput)
        .map((line) => line.trim())
        .where((line) => line.contains('/') && !line.contains(' '))
        .lastOrNull;
    if (!resolved.isSuccess || component == null) {
      throw AdbApplicationOperationException(
        operation: AdbApplicationOperation.start,
        packageName: packageName,
        message: 'Application has no launchable activity',
        cause: resolveOutput.trim(),
      );
    }
    final started = await adbClient.shell(serial, <String>[
      'am',
      'start',
      '-n',
      component,
    ], cancellationToken: cancellationToken);
    if (!started.isSuccess || _decodeResult(started).contains('Error:')) {
      throw AdbApplicationOperationException(
        operation: AdbApplicationOperation.start,
        packageName: packageName,
        message: 'Unable to start application',
        cause: _decodeResult(started).trim(),
      );
    }
  }

  Future<void> stopApplication(
    String packageName, {
    AdbCancellationToken? cancellationToken,
  }) async {
    _validatePackageName(packageName);
    final result = await adbClient.shell(serial, <String>[
      'am',
      'force-stop',
      packageName,
    ], cancellationToken: cancellationToken);
    if (!result.isSuccess) {
      throw AdbApplicationOperationException(
        operation: AdbApplicationOperation.stop,
        packageName: packageName,
        message: 'Unable to stop application',
        cause: _decodeResult(result).trim(),
      );
    }
  }

  Future<List<AdbApplication>> listApplications({
    AdbCancellationToken? cancellationToken,
  }) async {
    final results = await Future.wait(<Future<AdbCommandResult>>[
      adbClient.shell(serial, const <String>[
        'pm',
        'list',
        'packages',
        '-f',
        '-U',
        '--show-versioncode',
      ], cancellationToken: cancellationToken),
      adbClient.shell(serial, const <String>[
        'dumpsys',
        'package',
        'packages',
      ], cancellationToken: cancellationToken),
      adbClient.shell(serial, const <String>[
        'cmd',
        'package',
        'query-activities',
        '--brief',
        '-a',
        'android.intent.action.MAIN',
        '-c',
        'android.intent.category.LAUNCHER',
      ], cancellationToken: cancellationToken),
    ]);
    if (!results[0].isSuccess) {
      throw AdbException(
        AdbErrorCode.commandFailed,
        'Unable to list Android packages',
        exitCode: results[0].exitCode,
      );
    }
    String decode(AdbCommandResult result) =>
        utf8.decode(result.stdout, allowMalformed: true);
    return AdbApplicationParser.merge(
      packageListOutput: decode(results[0]),
      packageDumpOutput: results[1].isSuccess ? decode(results[1]) : '',
      launcherActivitiesOutput: results[2].isSuccess ? decode(results[2]) : '',
    );
  }

  static void _validatePackageName(String packageName) {
    if (!AdbApplicationParser._looksLikePackageName(packageName)) {
      throw ArgumentError.value(
        packageName,
        'packageName',
        'Invalid package name',
      );
    }
  }

  static String _decodeResult(AdbCommandResult result) => utf8.decode(<int>[
    ...result.stdout,
    ...result.stderr,
  ], allowMalformed: true);
}
