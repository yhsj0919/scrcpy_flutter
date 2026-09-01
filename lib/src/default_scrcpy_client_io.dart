import 'dart:io';

import 'package:adb_client_process/adb_client_process.dart';

import 'scrcpy_client.dart';

ScrcpyClient createDefaultScrcpyClient({
  String? adbExecutablePath,
  String? scrcpyServerPath,
}) {
  final adbClient = ProcessAdbClient(executable: adbExecutablePath);
  return ScrcpyClient(
    adbClient: adbClient,
    runtimeInfo: ScrcpyRuntimeInfo(
      usesBundledAdb: true,
      adbExecutablePath: adbClient.executable,
      scrcpyServerPath:
          scrcpyServerPath ?? resolveBundledScrcpyServerExecutable(),
    ),
  );
}

String resolveBundledScrcpyServerExecutable() {
  final applicationExecutable = File(Platform.resolvedExecutable);
  return '${applicationExecutable.parent.path}${Platform.pathSeparator}'
      'scrcpy-server-v4.1';
}
