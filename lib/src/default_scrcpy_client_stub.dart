import 'package:adb_client/adb_client.dart';

import 'scrcpy_client.dart';

ScrcpyClient createDefaultScrcpyClient({
  String? adbExecutablePath,
  String? scrcpyServerPath,
}) => const ScrcpyClient(
  adbClient: _UnsupportedAdbDeviceService(),
  runtimeInfo: ScrcpyRuntimeInfo(usesBundledAdb: false),
);

final class _UnsupportedAdbDeviceService implements AdbDeviceService {
  const _UnsupportedAdbDeviceService();

  @override
  Future<List<AdbDevice>> listDevices({
    AdbCancellationToken? cancellationToken,
  }) => Future<List<AdbDevice>>.error(
    UnsupportedError('ADB device discovery is not supported on this platform'),
  );
}
