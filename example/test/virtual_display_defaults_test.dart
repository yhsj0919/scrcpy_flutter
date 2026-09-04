import 'package:adb_client/adb_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrcpy_flutter_example/virtual_display_defaults.dart';

AdbDeviceDetails _details({
  required int? width,
  required int? height,
  required int? dpi,
}) => AdbDeviceDetails(
  serial: 'device',
  connectionType: AdbConnectionType.usb,
  observedAt: DateTime(2026),
  screenWidth: width,
  screenHeight: height,
  densityDpi: dpi,
);

void main() {
  test('normalizes device geometry to portrait without upscaling', () {
    final defaults = VirtualDisplayDefaults.fromDeviceDetails(
      _details(width: 1280, height: 720, dpi: 240),
    );

    expect(defaults.width, 720);
    expect(defaults.height, 1280);
    expect(defaults.dpi, 240);
  });

  test('reduces resolution and density proportionally', () {
    final defaults = VirtualDisplayDefaults.fromDeviceDetails(
      _details(width: 1080, height: 2400, dpi: 420),
    );

    expect(defaults.width, 576);
    expect(defaults.height, 1280);
    expect(defaults.dpi, 224);
  });

  test('uses portrait fallback when device metrics are unavailable', () {
    final defaults = VirtualDisplayDefaults.fromDeviceDetails(
      _details(width: null, height: null, dpi: null),
    );

    expect(defaults.width, 720);
    expect(defaults.height, 1280);
    expect(defaults.dpi, 240);
  });
}
