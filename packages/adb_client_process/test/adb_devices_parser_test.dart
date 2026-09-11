import 'dart:io';

import 'package:adb_client/adb_client.dart';
import 'package:adb_client_process/adb_client_process.dart';
import 'package:test/test.dart';

void main() {
  test('parses USB, network and device metadata', () {
    final devices = parseAdbDevices('''
List of devices attached
R58M1234 device product:a model:Pixel_8 device:husky transport_id:1
192.168.1.8:5555 unauthorized transport_id:2

''');

    expect(devices, hasLength(2));
    expect(devices.first.state, AdbDeviceState.device);
    expect(devices.first.connectionType, AdbConnectionType.usb);
    expect(devices.first.model, 'Pixel 8');
    expect(devices.last.state, AdbDeviceState.unauthorized);
    expect(devices.last.connectionType, AdbConnectionType.network);
  });

  test('removes an mDNS alias for the same network endpoint', () {
    final devices = parseAdbDevices('''
List of devices attached
192.168.5.44:38715 device product:houji model:M2505W1 device:houji
adb-demo._adb-tls-connect._tcp device product:houji model:M2505W1 device:houji
USB123 device product:houji model:M2505W1 device:houji
''');
    const services = <AdbMdnsService>[
      AdbMdnsService(
        name: 'adb-demo',
        type: AdbMdnsServiceType.connect,
        endpoint: AdbEndpoint(host: '192.168.5.44', port: 38715),
      ),
    ];

    expect(devices[1].connectionType, AdbConnectionType.network);
    expect(
      removeMdnsDeviceAliases(devices, services).map((device) => device.serial),
      <String>['192.168.5.44:38715', 'USB123'],
    );
  });

  test('ignores daemon diagnostics and empty lines', () {
    final devices = parseAdbDevices('''
List of devices attached
* daemon started successfully
emulator-5554 offline
''');

    expect(devices, hasLength(1));
    expect(devices.single.state, AdbDeviceState.offline);
  });

  test('parses the multi-word no permissions state', () {
    final devices = parseAdbDevices('''
List of devices attached
???????????? no permissions (missing udev rules?)
''');

    expect(devices.single.state, AdbDeviceState.noPermissions);
  });

  test('resolves bundled adb beside the Windows application', () {
    if (!Platform.isWindows) return;

    expect(
      resolveBundledAdbExecutable(
        applicationExecutablePath: r'C:\Apps\DeviceWall\device_wall.exe',
      ),
      r'C:\Apps\DeviceWall\adb.exe',
    );
  });
}
