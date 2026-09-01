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
  }) async {
    final connected = await adbClient.listDevices(
      cancellationToken: cancellationToken,
    );
    final service = adbClient;
    if (service is! AdbMdnsDiscoveryService) return connected;

    List<AdbMdnsService> mdnsServices;
    try {
      mdnsServices = await (service as AdbMdnsDiscoveryService)
          .discoverMdnsServices(cancellationToken: cancellationToken);
    } on AdbException catch (error) {
      if (error.code == AdbErrorCode.cancelled) rethrow;
      return connected;
    }

    final entries = <AdbDevice>[...connected];
    final onlineAuthorities = connected
        .where((device) => device.connectionType == AdbConnectionType.network)
        .map((device) => device.serial.toLowerCase())
        .toSet();
    final latestConnectServiceByName = <String, AdbMdnsService>{};
    for (final discovered in mdnsServices) {
      if (discovered.type == AdbMdnsServiceType.connect) {
        latestConnectServiceByName[discovered.name] = discovered;
      }
    }
    final observedAt = DateTime.now();
    for (final discovered in latestConnectServiceByName.values) {
      final authority = discovered.endpoint.authority;
      if (!onlineAuthorities.add(authority.toLowerCase())) continue;
      entries.add(
        AdbDevice(
          serial: authority,
          state: AdbDeviceState.paired,
          connectionType: AdbConnectionType.network,
          model: 'Wireless Debugging 设备',
          lastSeenAt: observedAt,
          attributes: <String, String>{'mdns_service_name': discovered.name},
        ),
      );
    }
    return List<AdbDevice>.unmodifiable(entries);
  }

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

  Future<void> pair(
    AdbEndpoint endpoint,
    String pairingCode, {
    AdbCancellationToken? cancellationToken,
  }) {
    final service = adbClient;
    if (service is! AdbConnectionService) {
      throw const ScrcpyException(
        ScrcpyErrorCode.unsupportedCapability,
        'ADB pairing is unavailable for this client',
      );
    }
    return (service as AdbConnectionService).pair(
      endpoint,
      pairingCode,
      cancellationToken: cancellationToken,
    );
  }

  Future<List<AdbMdnsService>> discoverMdnsServices({
    AdbCancellationToken? cancellationToken,
  }) {
    final service = adbClient;
    if (service is! AdbMdnsDiscoveryService) {
      throw const ScrcpyException(
        ScrcpyErrorCode.unsupportedCapability,
        'Wireless Debugging discovery is unavailable for this client',
      );
    }
    return (service as AdbMdnsDiscoveryService).discoverMdnsServices(
      cancellationToken: cancellationToken,
    );
  }

  ScrcpySession createSession(ScrcpySessionConfiguration configuration) =>
      ScrcpySession(
        adbDeviceService: adbClient,
        configuration: configuration,
        videoConnector: _videoConnectorOrNull(),
      );

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
    if (adbClient is! AdbClient || path == null || path.isEmpty) return null;
    return createScrcpyVideoConnector(
      adbClient: adbClient as AdbClient,
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
