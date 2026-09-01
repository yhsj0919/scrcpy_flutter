import 'package:adb_client/adb_client.dart';

List<AdbDevice> parseAdbDevices(String output) {
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
      RegExp(r'^[^:]+:\d+$').hasMatch(serial)) {
    return AdbConnectionType.network;
  }
  return AdbConnectionType.usb;
}
