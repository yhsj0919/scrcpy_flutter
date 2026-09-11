import 'package:adb_client/adb_client.dart';

List<AdbDevice> parseAdbDevices(String output, {DateTime? observedAt}) {
  final devices = <AdbDevice>[];
  for (final rawLine in output.split(RegExp(r'\r?\n')).skip(1)) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('*')) continue;

    final fields = line.split(RegExp(r'\s+'));
    if (fields.length < 2) continue;
    final serial = fields.first;
    final hasNoPermissionsState =
        fields.length > 2 && fields[1] == 'no' && fields[2] == 'permissions';
    final rawState = hasNoPermissionsState ? 'no permissions' : fields[1];
    final attributes = <String, String>{};
    for (final field in fields.skip(hasNoPermissionsState ? 3 : 2)) {
      final separator = field.indexOf(':');
      if (separator > 0) {
        attributes[field.substring(0, separator)] = field.substring(
          separator + 1,
        );
      }
    }

    devices.add(
      AdbDevice(
        serial: serial,
        state: _parseState(rawState),
        connectionType: _connectionType(serial),
        product: attributes['product'],
        model: attributes['model']?.replaceAll('_', ' '),
        device: attributes['device'],
        transportId: attributes['transport_id'],
        lastSeenAt: observedAt,
        attributes: Map.unmodifiable(attributes),
      ),
    );
  }
  return List.unmodifiable(devices);
}

AdbDeviceState _parseState(String value) => switch (value) {
  'device' => AdbDeviceState.device,
  'unauthorized' => AdbDeviceState.unauthorized,
  'offline' => AdbDeviceState.offline,
  'recovery' => AdbDeviceState.recovery,
  'bootloader' => AdbDeviceState.bootloader,
  'sideload' => AdbDeviceState.sideload,
  'no permissions' => AdbDeviceState.noPermissions,
  _ => AdbDeviceState.unknown,
};

AdbConnectionType _connectionType(String serial) {
  if (RegExp(r'^\[[0-9a-fA-F:]+\]:\d+$').hasMatch(serial) ||
      RegExp(r'^[^:]+:\d+$').hasMatch(serial) ||
      serial.endsWith('._adb-tls-connect._tcp') ||
      serial.endsWith('._adb-tls-connect._tcp.')) {
    return AdbConnectionType.network;
  }
  return AdbConnectionType.usb;
}

List<AdbDevice> removeMdnsDeviceAliases(
  List<AdbDevice> devices,
  List<AdbMdnsService> services,
) {
  final serials = devices.map((device) => device.serial).toSet();
  final redundantAliases = <String>{};
  for (final service in services) {
    if (service.type != AdbMdnsServiceType.connect ||
        !serials.contains(service.endpoint.authority)) {
      continue;
    }
    redundantAliases
      ..add('${service.name}._adb-tls-connect._tcp')
      ..add('${service.name}._adb-tls-connect._tcp.');
  }
  return List.unmodifiable(
    devices.where((device) => !redundantAliases.contains(device.serial)),
  );
}
