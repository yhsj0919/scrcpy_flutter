import 'dart:io';

import 'package:adb_client/adb_client.dart';
import 'package:adb_client_process/adb_client_process.dart';

import 'android_native_adb_client.dart';
import 'android_scrcpy_video_connector.dart';
import 'scrcpy_client.dart';

const bundledScrcpyServerVersion = '5.0.1';
const bundledScrcpyServerSha256 =
    '764eb6f79811d5211fe9df341120882ba9994c7a61b897d7bf3fb662e53bc536';

ScrcpyClient createDefaultScrcpyClient({
  String? adbExecutablePath,
  String? scrcpyServerPath,
}) {
  if (Platform.isAndroid) {
    return ScrcpyClient(
      adbClient: AndroidNativeAdbClient(),
      videoConnector: AndroidScrcpyVideoConnector(),
      runtimeInfo: ScrcpyRuntimeInfo(
        usesBundledAdb: false,
        scrcpyServerPath: null,
        scrcpyServerVersion: bundledScrcpyServerVersion,
        scrcpyServerSha256: bundledScrcpyServerSha256,
      ),
    );
  }
  final usesBundledServer = scrcpyServerPath == null;
  final AdbClient adbClient = ProcessAdbClient(executable: adbExecutablePath);
  return ScrcpyClient(
    adbClient: adbClient,
    runtimeInfo: ScrcpyRuntimeInfo(
      usesBundledAdb: adbExecutablePath == null,
      adbExecutablePath: (adbClient as ProcessAdbClient).executable,
      scrcpyServerPath:
          scrcpyServerPath ?? resolveBundledScrcpyServerExecutable(),
      scrcpyServerVersion: bundledScrcpyServerVersion,
      scrcpyServerSha256: usesBundledServer ? bundledScrcpyServerSha256 : null,
    ),
  );
}

String resolveBundledScrcpyServerExecutable() {
  final applicationExecutable = File(Platform.resolvedExecutable);
  final executableDirectory = applicationExecutable.parent;
  final candidates = switch (Platform.operatingSystem) {
    'linux' => <String>[
      '${executableDirectory.path}${Platform.pathSeparator}lib'
          '${Platform.pathSeparator}scrcpy-server-v5.0.1',
    ],
    'macos' => <String>[
      '${executableDirectory.parent.path}${Platform.pathSeparator}Frameworks'
          '${Platform.pathSeparator}scrcpy_flutter.framework'
          '${Platform.pathSeparator}Resources'
          '${Platform.pathSeparator}scrcpy_flutter_resources.bundle'
          '${Platform.pathSeparator}Contents${Platform.pathSeparator}Resources'
          '${Platform.pathSeparator}scrcpy-server-v5.0.1',
      '${executableDirectory.parent.path}${Platform.pathSeparator}Resources'
          '${Platform.pathSeparator}scrcpy_flutter_resources.bundle'
          '${Platform.pathSeparator}scrcpy-server-v5.0.1',
      '${executableDirectory.parent.path}${Platform.pathSeparator}Resources'
          '${Platform.pathSeparator}scrcpy-server-v5.0.1',
    ],
    _ => <String>[
      '${executableDirectory.path}${Platform.pathSeparator}'
          'scrcpy-server-v5.0.1',
    ],
  };
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return candidate;
  }
  return candidates.first;
}
