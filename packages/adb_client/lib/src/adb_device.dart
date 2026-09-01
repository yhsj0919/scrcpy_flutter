enum AdbDeviceState {
  device,
  unauthorized,
  offline,
  recovery,
  bootloader,
  sideload,
  noPermissions,
  paired,
  unknown,
}

enum AdbConnectionType { usb, network, unknown }

final class AdbDevice {
  const AdbDevice({
    required this.serial,
    required this.state,
    required this.connectionType,
    this.product,
    this.model,
    this.device,
    this.transportId,
    this.lastSeenAt,
    this.attributes = const <String, String>{},
  });

  final String serial;
  final AdbDeviceState state;
  final AdbConnectionType connectionType;
  final String? product;
  final String? model;
  final String? device;
  final String? transportId;
  final DateTime? lastSeenAt;
  final Map<String, String> attributes;

  bool get isReady => state == AdbDeviceState.device;

  /// Stable enough for logs while avoiding disclosure of the actual serial.
  String get redactedSerial {
    var hash = 0x811c9dc5;
    for (final codeUnit in serial.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return 'device-${hash.toRadixString(16).padLeft(8, '0')}';
  }
}
