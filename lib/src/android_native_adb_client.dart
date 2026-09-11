import 'dart:convert';

import 'package:adb_client/adb_client.dart';
import 'package:flutter/services.dart';

import 'scrcpy_client.dart';

/// Android uses a platform-owned ADB implementation.
///
/// The native backend is installed by the Android plugin. Device discovery is
/// intentionally disabled until that backend is wired to the public API.
final class AndroidNativeAdbClient
    implements
        AdbClient,
        AdbUsbHostProvider,
        ScrcpyApplicationLabelProvider,
        ScrcpyVideoCapabilitiesProvider {
  static const _channel = MethodChannel('scrcpy_flutter/android_adb');
  bool _mdnsStarted = false;

  @override
  Future<List<AdbDevice>> listDevices({
    AdbCancellationToken? cancellationToken,
  }) async {
    _throwIfCancelled(cancellationToken);
    final devices = await _invokeList(
      'listDevices',
      AdbErrorCode.connectionFailed,
    );
    return <AdbDevice>[
      for (final value in devices ?? const <Object?>[])
        if (value case final Map<Object?, Object?> device)
          AdbDevice(
            serial: device['serial']! as String,
            state: _parseDeviceState(device['state'] as String?),
            connectionType: _parseConnectionType(
              device['connectionType'] as String?,
            ),
            model: device['model'] as String?,
            lastSeenAt: DateTime.now(),
          ),
    ];
  }

  @override
  Future<AdbUsbHostStatus> getUsbHostStatus({
    bool requestPermission = false,
    AdbCancellationToken? cancellationToken,
  }) async {
    _throwIfCancelled(cancellationToken);
    final response = await _invokeMap(
      'usbHostStatus',
      AdbErrorCode.commandFailed,
      <String, Object>{'requestPermission': requestPermission},
    );
    if (response == null) {
      throw const AdbException(
        AdbErrorCode.invalidResponse,
        'Android USB Host status returned no result',
      );
    }
    return AdbUsbHostStatus(
      attachedDeviceCount: response['attachedDeviceCount'] as int? ?? 0,
      adbDeviceCount: response['adbDeviceCount'] as int? ?? 0,
      authorizedDeviceCount: response['authorizedDeviceCount'] as int? ?? 0,
      permissionRequestPending:
          response['permissionRequestPending'] as bool? ?? false,
      permissionDenied: response['permissionDenied'] as bool? ?? false,
    );
  }

  @override
  Future<void> connect(
    AdbEndpoint endpoint, {
    AdbCancellationToken? cancellationToken,
  }) async {
    _throwIfCancelled(cancellationToken);
    await _invoke<void>(
      'connect',
      AdbErrorCode.connectionFailed,
      <String, Object>{'host': endpoint.host, 'port': endpoint.port},
    );
  }

  @override
  Future<void> disconnect(
    AdbEndpoint endpoint, {
    AdbCancellationToken? cancellationToken,
  }) async {
    _throwIfCancelled(cancellationToken);
    await _invoke<void>('disconnect', AdbErrorCode.connectionFailed);
  }

  @override
  Future<void> pair(
    AdbEndpoint endpoint,
    String pairingCode, {
    AdbCancellationToken? cancellationToken,
  }) async {
    _throwIfCancelled(cancellationToken);
    await _invoke<void>('pair', AdbErrorCode.pairingFailed, <String, Object>{
      'host': endpoint.host,
      'port': endpoint.port,
      'pairingCode': pairingCode,
    });
  }

  @override
  Future<AdbCommandResult> shell(
    String serial,
    List<String> arguments, {
    AdbCancellationToken? cancellationToken,
  }) async {
    _throwIfCancelled(cancellationToken);
    final startedAt = DateTime.now();
    final response = await _invokeMap(
      'shell',
      AdbErrorCode.commandFailed,
      <String, Object>{
        'serial': serial,
        'command': _serializeShellArguments(arguments),
      },
    );
    if (response == null) {
      throw const AdbException(
        AdbErrorCode.invalidResponse,
        'Android ADB shell returned no result',
      );
    }
    return AdbCommandResult(
      exitCode: response['exitCode'] as int? ?? -1,
      stdout: utf8.encode(response['stdout'] as String? ?? ''),
      stderr: const <int>[],
      elapsed: DateTime.now().difference(startedAt),
    );
  }

  @override
  Future<void> push(
    String serial,
    String localPath,
    String remotePath, {
    AdbCancellationToken? cancellationToken,
  }) async {
    _throwIfCancelled(cancellationToken);
    await _invoke<void>('push', AdbErrorCode.commandFailed, <String, Object>{
      'serial': serial,
      'localPath': localPath,
      'remotePath': remotePath,
    });
  }

  @override
  Future<void> pull(
    String serial,
    String remotePath,
    String localPath, {
    AdbCancellationToken? cancellationToken,
  }) async {
    _throwIfCancelled(cancellationToken);
    await _invoke<void>('pull', AdbErrorCode.commandFailed, <String, Object>{
      'serial': serial,
      'remotePath': remotePath,
      'localPath': localPath,
    });
  }

  @override
  Future<void> install(
    String serial,
    String apkPath, {
    bool replaceExisting = false,
    AdbCancellationToken? cancellationToken,
  }) async {
    _throwIfCancelled(cancellationToken);
    await _invoke<void>('install', AdbErrorCode.commandFailed, <String, Object>{
      'serial': serial,
      'apkPath': apkPath,
      'replaceExisting': replaceExisting,
    });
  }

  @override
  Future<void> uninstall(
    String serial,
    String packageName, {
    bool keepData = false,
    AdbCancellationToken? cancellationToken,
  }) async {
    _throwIfCancelled(cancellationToken);
    await _invoke<void>(
      'uninstall',
      AdbErrorCode.commandFailed,
      <String, Object>{
        'serial': serial,
        'packageName': packageName,
        'keepData': keepData,
      },
    );
  }

  @override
  Future<List<AdbMdnsService>> discoverMdnsServices({
    AdbCancellationToken? cancellationToken,
  }) async {
    _throwIfCancelled(cancellationToken);
    final waitMillis = _mdnsStarted ? 0 : 1200;
    _mdnsStarted = true;
    final values = await _invokeList(
      'discoverMdnsServices',
      AdbErrorCode.commandFailed,
      <String, Object>{'waitMillis': waitMillis},
    );
    _throwIfCancelled(cancellationToken);
    return <AdbMdnsService>[
      for (final value in values ?? const <Object?>[])
        if (value case final Map<Object?, Object?> service)
          if (_parseMdnsType(service['type'] as String?) case final type?)
            if (service['host'] case final String host)
              if (service['port'] case final int port)
                AdbMdnsService(
                  name: service['name'] as String? ?? '',
                  type: type,
                  endpoint: AdbEndpoint(host: host, port: port),
                ),
    ];
  }

  @override
  Future<String> loadApplicationLabels(
    String deviceSerial, {
    AdbCancellationToken? cancellationToken,
  }) async {
    _throwIfCancelled(cancellationToken);
    return await _invoke<String>(
          'listApplicationLabels',
          AdbErrorCode.commandFailed,
          <String, Object>{'serial': deviceSerial},
        ) ??
        '';
  }

  @override
  Future<String> loadVideoEncoders(
    String deviceSerial, {
    AdbCancellationToken? cancellationToken,
  }) async {
    _throwIfCancelled(cancellationToken);
    return await _invoke<String>(
          'listVideoEncoders',
          AdbErrorCode.commandFailed,
          <String, Object>{'serial': deviceSerial},
        ) ??
        '';
  }

  @override
  Future<AdbCommandResult> execute(
    AdbCommand command, {
    AdbCancellationToken? cancellationToken,
  }) => Future<AdbCommandResult>.error(
    const AdbException(
      AdbErrorCode.unsupportedCapability,
      'Raw adb executable commands are unavailable on the Android direct backend',
    ),
  );

  @override
  Future<AdbRunningCommand> start(
    AdbCommand command, {
    AdbCancellationToken? cancellationToken,
  }) => Future<AdbRunningCommand>.error(
    const AdbException(
      AdbErrorCode.unsupportedCapability,
      'Long-running adb executable commands are unavailable on the Android direct backend',
    ),
  );

  @override
  Future<void> forward(
    String serial,
    AdbForwardRule rule, {
    AdbCancellationToken? cancellationToken,
  }) => Future<void>.error(
    const AdbException(
      AdbErrorCode.unsupportedCapability,
      'ADB host forwarding is not used by the Android direct backend',
    ),
  );

  @override
  Future<void> removeForward(
    String serial,
    String local, {
    AdbCancellationToken? cancellationToken,
  }) => Future<void>.error(
    const AdbException(
      AdbErrorCode.unsupportedCapability,
      'ADB host forwarding is not used by the Android direct backend',
    ),
  );

  static String _quoteShellArgument(String value) =>
      "'${value.replaceAll("'", "'\\''")}'";

  static String _serializeShellArguments(List<String> arguments) {
    if (arguments.length == 3 && arguments[0] == 'sh' && arguments[1] == '-c') {
      // The native transport already opens an Android shell service. Running
      // another quoted `sh -c` command changes its argument boundaries on
      // some vendor shells, so execute the supplied script directly.
      return arguments[2];
    }
    return arguments.map(_quoteShellArgument).join(' ');
  }

  static AdbDeviceState _parseDeviceState(String? value) => switch (value) {
    'device' => AdbDeviceState.device,
    'noPermissions' => AdbDeviceState.noPermissions,
    'unauthorized' => AdbDeviceState.unauthorized,
    'offline' => AdbDeviceState.offline,
    _ => AdbDeviceState.unknown,
  };

  static AdbConnectionType _parseConnectionType(String? value) =>
      switch (value) {
        'usb' => AdbConnectionType.usb,
        'network' => AdbConnectionType.network,
        _ => AdbConnectionType.unknown,
      };

  static AdbMdnsServiceType? _parseMdnsType(String? value) => switch (value) {
    '_adb-tls-pairing._tcp' => AdbMdnsServiceType.pairing,
    '_adb-tls-connect._tcp' => AdbMdnsServiceType.connect,
    _ => null,
  };

  static Future<T?> _invoke<T>(
    String method,
    AdbErrorCode errorCode, [
    Map<String, Object>? arguments,
  ]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (error) {
      throw AdbException(
        errorCode,
        error.message ?? 'Android ADB $method failed',
      );
    }
  }

  static Future<List<Object?>?> _invokeList(
    String method,
    AdbErrorCode errorCode, [
    Map<String, Object>? arguments,
  ]) async {
    try {
      return await _channel.invokeListMethod<Object?>(method, arguments);
    } on PlatformException catch (error) {
      throw AdbException(
        errorCode,
        error.message ?? 'Android ADB $method failed',
      );
    }
  }

  static Future<Map<String, Object?>?> _invokeMap(
    String method,
    AdbErrorCode errorCode,
    Map<String, Object> arguments,
  ) async {
    try {
      return await _channel.invokeMapMethod<String, Object?>(method, arguments);
    } on PlatformException catch (error) {
      throw AdbException(
        errorCode,
        error.message ?? 'Android ADB $method failed',
      );
    }
  }

  static void _throwIfCancelled(AdbCancellationToken? token) {
    if (token?.isCancelled ?? false) {
      throw const AdbException(
        AdbErrorCode.cancelled,
        'ADB operation cancelled',
      );
    }
  }
}
