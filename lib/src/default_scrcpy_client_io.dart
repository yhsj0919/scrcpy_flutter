import 'dart:io';

import 'package:adb_client_process/adb_client_process.dart';

import 'scrcpy_client.dart';

const bundledScrcpyServerVersion = '4.1';
const bundledScrcpyServerSha256 =
    'deacb991ed2509715160ffdc7907e47b4160eb30d1566217e9047fd5b8850cae';

ScrcpyClient createDefaultScrcpyClient({
  String? adbExecutablePath,
  String? scrcpyServerPath,
}) {
  final usesBundledServer = scrcpyServerPath == null;
  final adbClient = ProcessAdbClient(executable: adbExecutablePath);
  return ScrcpyClient(
    adbClient: adbClient,
    runtimeInfo: ScrcpyRuntimeInfo(
      usesBundledAdb: true,
      adbExecutablePath: adbClient.executable,
      scrcpyServerPath:
          scrcpyServerPath ?? resolveBundledScrcpyServerExecutable(),
      scrcpyServerVersion: bundledScrcpyServerVersion,
      scrcpyServerSha256: usesBundledServer ? bundledScrcpyServerSha256 : null,
    ),
  );
}

String resolveBundledScrcpyServerExecutable() {
  final applicationExecutable = File(Platform.resolvedExecutable);
  return '${applicationExecutable.parent.path}${Platform.pathSeparator}'
      'scrcpy-server-v4.1';
}
