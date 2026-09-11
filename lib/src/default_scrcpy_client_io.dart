import 'dart:io';

import 'package:adb_client/adb_client.dart';
import 'package:adb_client_process/adb_client_process.dart';

import 'android_native_adb_client.dart';
import 'android_scrcpy_video_connector.dart';
import 'scrcpy_client.dart';

const bundledScrcpyServerVersion = '4.1';
const bundledScrcpyServerSha256 =
    'deacb991ed2509715160ffdc7907e47b4160eb30d1566217e9047fd5b8850cae';

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
      usesBundledAdb: true,
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
  return '${applicationExecutable.parent.path}${Platform.pathSeparator}'
      'scrcpy-server-v4.1';
}
