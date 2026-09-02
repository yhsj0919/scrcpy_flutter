import 'package:adb_client/adb_client.dart';

import 'scrcpy_client.dart';

ScrcpyClient createDefaultScrcpyClient({
  String? adbExecutablePath,
  String? scrcpyServerPath,
}) => const ScrcpyClient(
  adbClient: _UnsupportedAdbClient(),
  runtimeInfo: ScrcpyRuntimeInfo(usesBundledAdb: false),
);

final class _UnsupportedAdbClient implements AdbClient {
  const _UnsupportedAdbClient();

  @override
  Future<List<AdbDevice>> listDevices({
    AdbCancellationToken? cancellationToken,
  }) => Future<List<AdbDevice>>.error(
    UnsupportedError('ADB device discovery is not supported on this platform'),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
