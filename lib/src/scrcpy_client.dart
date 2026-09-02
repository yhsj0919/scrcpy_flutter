import 'dart:convert';

import 'package:adb_client/adb_client.dart';

import 'scrcpy_capabilities.dart';
import 'scrcpy_batch.dart';
import 'scrcpy_device_details.dart';
import 'scrcpy_device_status.dart';
import 'scrcpy_error.dart';
import 'scrcpy_file_manager.dart';
import 'scrcpy_session.dart';
import 'scrcpy_video_connection.dart';
import 'scrcpy_video_capabilities.dart';

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

  Future<ScrcpyDeviceDetails> getDeviceDetails(
    AdbDevice device, {
    AdbCancellationToken? cancellationToken,
  }) async {
    final service = adbClient;
    if (service is! AdbShellService) {
      throw const ScrcpyException(
        ScrcpyErrorCode.unsupportedCapability,
        'Device details are unavailable for this client',
      );
    }
    final outputs = <String, String>{};
    final unavailable = <String, String>{};

    Future<void> query(String name, List<String> arguments) async {
      try {
        final result = await (service as AdbShellService).shell(
          device.serial,
          arguments,
          cancellationToken: cancellationToken,
        );
        if (!result.isSuccess) {
          unavailable[name] = 'ADB exit code ${result.exitCode}';
          return;
        }
        outputs[name] = utf8.decode(result.stdout, allowMalformed: true);
      } catch (error) {
        unavailable[name] = '$error';
      }
    }

    await Future.wait(<Future<void>>[
      query('properties', const <String>['getprop']),
      query('screen', const <String>['wm', 'size']),
      query('density', const <String>['wm', 'density']),
      query('battery', const <String>['dumpsys', 'battery']),
      query('storage', const <String>['df', '-k', '/data']),
      query('uptime', const <String>['cat', '/proc/uptime']),
    ]);

    final properties = ScrcpyDeviceDetailsParser.properties(
      outputs['properties'] ?? '',
    );
    final screen = ScrcpyDeviceDetailsParser.screenSize(
      outputs['screen'] ?? '',
    );
    final density = ScrcpyDeviceDetailsParser.density(outputs['density'] ?? '');
    final battery = ScrcpyDeviceDetailsParser.battery(outputs['battery'] ?? '');
    final storage = ScrcpyDeviceDetailsParser.storage(outputs['storage'] ?? '');
    final uptime = ScrcpyDeviceDetailsParser.uptime(outputs['uptime'] ?? '');

    return ScrcpyDeviceDetails(
      serial: device.serial,
      connectionType: device.connectionType,
      observedAt: DateTime.now(),
      brand: properties['ro.product.brand'],
      manufacturer: properties['ro.product.manufacturer'],
      model: properties['ro.product.model'] ?? device.model,
      androidVersion: properties['ro.build.version.release'],
      sdkLevel: int.tryParse(properties['ro.build.version.sdk'] ?? ''),
      abi: properties['ro.product.cpu.abi'],
      screenWidth: screen?.$1,
      screenHeight: screen?.$2,
      densityDpi: density,
      batteryLevel: battery.level,
      batteryTemperatureCelsius: battery.temperatureCelsius,
      storageTotalBytes: storage?.totalBytes,
      storageAvailableBytes: storage?.availableBytes,
      uptime: uptime,
      unavailable: Map<String, String>.unmodifiable(unavailable),
    );
  }

  ScrcpySession createSession(ScrcpySessionConfiguration configuration) =>
      ScrcpySession(
        adbDeviceService: adbClient,
        configuration: configuration,
        videoConnector: _videoConnectorOrNull(),
      );

  ScrcpyFileManager createFileManager(String deviceSerial) {
    final service = adbClient;
    if (service is! AdbClient) {
      throw const ScrcpyException(
        ScrcpyErrorCode.unsupportedCapability,
        'File management is unavailable for this client',
      );
    }
    return ScrcpyFileManager(adbClient: service, serial: deviceSerial);
  }

  ScrcpyDeviceStatusMonitor createDeviceStatusMonitor(
    String deviceSerial, {
    Duration interval = const Duration(seconds: 5),
  }) {
    final service = adbClient;
    if (service is! AdbShellService) {
      throw const ScrcpyException(
        ScrcpyErrorCode.unsupportedCapability,
        'Device status is unavailable for this client',
      );
    }
    return ScrcpyDeviceStatusMonitor(
      adbShell: service as AdbShellService,
      serial: deviceSerial,
      interval: interval,
    );
  }

  ScrcpyBatchPackageManager createBatchPackageManager() {
    final service = adbClient;
    if (service is! AdbPackageService) {
      throw const ScrcpyException(
        ScrcpyErrorCode.unsupportedCapability,
        'Package management is unavailable for this client',
      );
    }
    return ScrcpyBatchPackageManager(service as AdbPackageService);
  }

  Future<ScrcpyVideoCapabilities> probeVideoCapabilities(
    String deviceSerial, {
    AdbCancellationToken? cancellationToken,
  }) async {
    final service = adbClient;
    final serverPath = runtimeInfo?.scrcpyServerPath;
    if (service is! AdbClient || serverPath == null || serverPath.isEmpty) {
      throw const ScrcpyException(
        ScrcpyErrorCode.unsupportedCapability,
        'Video encoder discovery is unavailable for this client',
      );
    }
    final probeId = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final remotePath = '/data/local/tmp/scrcpy-server-probe-$probeId.jar';
    try {
      await service.push(
        deviceSerial,
        serverPath,
        remotePath,
        cancellationToken: cancellationToken,
      );
      final result = await service.shell(deviceSerial, <String>[
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
        await service.shell(deviceSerial, <String>['rm', '-f', remotePath]);
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
