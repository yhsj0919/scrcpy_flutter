import 'package:adb_client/adb_client.dart';

import 'scrcpy_capabilities.dart';
import 'scrcpy_error.dart';
import 'scrcpy_session.dart';
import 'scrcpy_video_connection.dart';

/// Root service object owned by the embedding application.
///
/// It intentionally accepts an [AdbClient], so platform transports can be
/// replaced without changing session or UI code.
final class ScrcpyClient {
  const ScrcpyClient({required this.adbClient, this.runtimeInfo});

  final AdbDeviceService adbClient;
  final ScrcpyRuntimeInfo? runtimeInfo;

  ScrcpyCapabilities get capabilities => ScrcpyCapabilities(
    deviceDiscovery: true,
    usbAdb: runtimeInfo?.usesBundledAdb ?? false,
    networkAdb: runtimeInfo?.usesBundledAdb ?? false,
    wirelessPairing: runtimeInfo?.usesBundledAdb ?? false,
    video:
        adbClient is AdbClient &&
        runtimeInfo?.scrcpyServerPath?.isNotEmpty == true,
    control: false,
  );

  Future<List<AdbDevice>> discoverDevices({
    AdbCancellationToken? cancellationToken,
  }) => adbClient.listDevices(cancellationToken: cancellationToken);

  Future<void> connect(
    AdbEndpoint endpoint, {
    AdbCancellationToken? cancellationToken,
  }) {
    final service = adbClient;
    if (service is! AdbConnectionService) {
      throw const ScrcpyException(
        ScrcpyErrorCode.unsupportedCapability,
        'ADB connection is unavailable for this client',
      );
    }
    return (service as AdbConnectionService).connect(
      endpoint,
      cancellationToken: cancellationToken,
    );
  }

  Future<void> disconnect(
    AdbEndpoint endpoint, {
    AdbCancellationToken? cancellationToken,
  }) {
    final service = adbClient;
    if (service is! AdbConnectionService) {
      throw const ScrcpyException(
        ScrcpyErrorCode.unsupportedCapability,
        'ADB disconnection is unavailable for this client',
      );
    }
    return (service as AdbConnectionService).disconnect(
      endpoint,
      cancellationToken: cancellationToken,
    );
  }

  ScrcpySession createSession(ScrcpySessionConfiguration configuration) =>
      ScrcpySession(adbDeviceService: adbClient, configuration: configuration);

  ScrcpyVideoConnector createVideoConnector() {
    final path = runtimeInfo?.scrcpyServerPath;
    if (adbClient is! AdbClient || path == null || path.isEmpty) {
      throw const ScrcpyException(
        ScrcpyErrorCode.unsupportedCapability,
        'Video connection is unavailable for this client',
      );
    }
    return createScrcpyVideoConnector(
      adbClient: adbClient as AdbClient,
      serverPath: path,
    );
  }
}

final class ScrcpyRuntimeInfo {
  const ScrcpyRuntimeInfo({
    required this.usesBundledAdb,
    this.adbExecutablePath,
    this.scrcpyServerPath,
  });

  final bool usesBundledAdb;
  final String? adbExecutablePath;
  final String? scrcpyServerPath;
}
