import 'dart:convert';

import 'adb_application.dart';
import 'adb_batch.dart';
import 'adb_cancellation_token.dart';
import 'adb_client_base.dart';
import 'adb_device.dart';
import 'adb_device_details.dart';
import 'adb_device_status.dart';
import 'adb_endpoint.dart';
import 'adb_exception.dart';
import 'adb_file_manager.dart';
import 'adb_mdns_service.dart';

/// High-level ADB toolbox. It has no dependency on scrcpy resources or APIs.
final class AdbToolkit {
  const AdbToolkit(this.client);

  final AdbClient client;

  Future<List<AdbDevice>> discoverDevices({
    AdbCancellationToken? cancellationToken,
  }) async {
    final connected = await client.listDevices(
      cancellationToken: cancellationToken,
    );
    List<AdbMdnsService> services;
    try {
      services = await client.discoverMdnsServices(
        cancellationToken: cancellationToken,
      );
    } on AdbException catch (error) {
      if (error.code == AdbErrorCode.cancelled) rethrow;
      return connected;
    }
    final connectServices = <AdbMdnsService>[
      for (final service in services)
        if (service.type == AdbMdnsServiceType.connect) service,
    ];
    final serviceByAuthority = <String, AdbMdnsService>{
      for (final service in connectServices)
        service.endpoint.authority.toLowerCase(): service,
    };
    final entries = <AdbDevice>[
      for (final device in connected)
        if (serviceByAuthority[device.serial.toLowerCase()] case final service?)
          _withMdnsIdentity(device, service.name)
        else
          device,
    ];
    final authorities = connected
        .where((device) => device.connectionType == AdbConnectionType.network)
        .map((device) => device.serial.toLowerCase())
        .toSet();
    final latestByName = <String, AdbMdnsService>{};
    for (final service in connectServices) {
      latestByName[service.name] = service;
    }
    for (final service in latestByName.values) {
      final authority = service.endpoint.authority;
      if (!authorities.add(authority.toLowerCase())) continue;
      entries.add(
        AdbDevice(
          serial: authority,
          state: AdbDeviceState.paired,
          connectionType: AdbConnectionType.network,
          model: 'Wireless Debugging 设备',
          lastSeenAt: DateTime.now(),
          attributes: <String, String>{'mdns_service_name': service.name},
        ),
      );
    }
    return List<AdbDevice>.unmodifiable(entries);
  }

  static AdbDevice _withMdnsIdentity(AdbDevice device, String serviceName) =>
      AdbDevice(
        serial: device.serial,
        state: device.state,
        connectionType: device.connectionType,
        product: device.product,
        model: device.model,
        device: device.device,
        transportId: device.transportId,
        lastSeenAt: device.lastSeenAt,
        attributes: <String, String>{
          ...device.attributes,
          'mdns_service_name': serviceName,
        },
      );

  Future<void> connect(
    AdbEndpoint endpoint, {
    AdbCancellationToken? cancellationToken,
  }) => client.connect(endpoint, cancellationToken: cancellationToken);

  Future<void> disconnect(
    AdbEndpoint endpoint, {
    AdbCancellationToken? cancellationToken,
  }) => client.disconnect(endpoint, cancellationToken: cancellationToken);

  Future<void> pair(
    AdbEndpoint endpoint,
    String pairingCode, {
    AdbCancellationToken? cancellationToken,
  }) =>
      client.pair(endpoint, pairingCode, cancellationToken: cancellationToken);

  /// Pairs a wireless-debugging device and connects to its advertised endpoint.
  ///
  /// Android assigns pairing and connection ports independently. When
  /// [connectionEndpoint] is omitted, the connection endpoint is discovered
  /// through mDNS on the same host until [discoveryTimeout] expires. A `null`
  /// result means pairing succeeded but no connection service was discovered.
  Future<AdbEndpoint?> pairAndConnect(
    AdbEndpoint pairingEndpoint,
    String pairingCode, {
    AdbEndpoint? connectionEndpoint,
    Duration discoveryTimeout = const Duration(seconds: 10),
    Duration discoveryInterval = const Duration(milliseconds: 500),
    AdbCancellationToken? cancellationToken,
  }) async {
    _throwIfCancelled(cancellationToken);
    await pair(
      pairingEndpoint,
      pairingCode,
      cancellationToken: cancellationToken,
    );

    var endpoint = connectionEndpoint;
    if (endpoint == null) {
      final deadline = DateTime.now().add(discoveryTimeout);
      do {
        _throwIfCancelled(cancellationToken);
        try {
          final services = await discoverMdnsServices(
            cancellationToken: cancellationToken,
          );
          endpoint = _connectionEndpointForHost(services, pairingEndpoint.host);
        } on AdbException catch (error) {
          if (error.code == AdbErrorCode.cancelled) rethrow;
          // Pairing remains successful when mDNS is unavailable.
          return null;
        }
        if (endpoint != null || !DateTime.now().isBefore(deadline)) break;
        await _delay(discoveryInterval, cancellationToken);
      } while (true);
    }

    if (endpoint == null) return null;
    await connect(endpoint, cancellationToken: cancellationToken);
    return endpoint;
  }

  Future<List<AdbMdnsService>> discoverMdnsServices({
    AdbCancellationToken? cancellationToken,
  }) => client.discoverMdnsServices(cancellationToken: cancellationToken);

  static AdbEndpoint? _connectionEndpointForHost(
    List<AdbMdnsService> services,
    String host,
  ) {
    final normalizedHost = host.toLowerCase();
    for (final service in services.reversed) {
      if (service.type == AdbMdnsServiceType.connect &&
          service.endpoint.host.toLowerCase() == normalizedHost) {
        return service.endpoint;
      }
    }
    return null;
  }

  static Future<void> _delay(
    Duration duration,
    AdbCancellationToken? cancellationToken,
  ) async {
    if (duration <= Duration.zero) return;
    if (cancellationToken == null) {
      await Future<void>.delayed(duration);
      return;
    }
    await Future.any<void>(<Future<void>>[
      Future<void>.delayed(duration),
      cancellationToken.whenCancelled,
    ]);
    _throwIfCancelled(cancellationToken);
  }

  static void _throwIfCancelled(AdbCancellationToken? cancellationToken) {
    if (cancellationToken?.isCancelled ?? false) {
      throw const AdbException(
        AdbErrorCode.cancelled,
        'ADB operation cancelled',
      );
    }
  }

  AdbApplicationManager applications(String serial) =>
      AdbApplicationManager(adbClient: client, serial: serial);

  AdbFileManager files(String serial) =>
      AdbFileManager(adbClient: client, serial: serial);

  AdbDeviceStatusMonitor status(
    String serial, {
    Duration interval = const Duration(seconds: 5),
  }) => AdbDeviceStatusMonitor(
    adbShell: client,
    serial: serial,
    interval: interval,
  );

  AdbBatchPackageManager get batchPackages => AdbBatchPackageManager(client);

  Future<AdbDeviceDetails> getDeviceDetails(
    AdbDevice device, {
    AdbCancellationToken? cancellationToken,
  }) async {
    final outputs = <String, String>{};
    final unavailable = <String, String>{};
    Future<void> query(String name, List<String> arguments) async {
      try {
        final result = await client.shell(
          device.serial,
          arguments,
          cancellationToken: cancellationToken,
        );
        if (!result.isSuccess) {
          unavailable[name] = 'ADB exit code ${result.exitCode}';
        } else {
          outputs[name] = utf8.decode(result.stdout, allowMalformed: true);
        }
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
    final properties = AdbDeviceDetailsParser.properties(
      outputs['properties'] ?? '',
    );
    final screen = AdbDeviceDetailsParser.screenSize(outputs['screen'] ?? '');
    final battery = AdbDeviceDetailsParser.battery(outputs['battery'] ?? '');
    final storage = AdbDeviceDetailsParser.storage(outputs['storage'] ?? '');
    return AdbDeviceDetails(
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
      densityDpi: AdbDeviceDetailsParser.density(outputs['density'] ?? ''),
      batteryLevel: battery.level,
      batteryTemperatureCelsius: battery.temperatureCelsius,
      storageTotalBytes: storage?.totalBytes,
      storageAvailableBytes: storage?.availableBytes,
      uptime: AdbDeviceDetailsParser.uptime(outputs['uptime'] ?? ''),
      unavailable: Map<String, String>.unmodifiable(unavailable),
    );
  }
}
