import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:adb_client/adb_client.dart';
import 'package:scrcpy_flutter/scrcpy_flutter.dart';

extension on ScrcpyClient {
  AdbToolkit get adbToolkit => AdbToolkit(adbClient);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('detects a real network ADB disconnect and reconnect', (
    tester,
  ) async {
    const serial = String.fromEnvironment('SCRCPY_DEVICE_SERIAL');
    final endpoint = AdbEndpoint.tryParse(serial);
    if (serial.isEmpty || endpoint == null) return;

    final client = createDefaultScrcpyClient();
    final monitor = AdbDeviceMonitor(
      client.adbToolkit,
      interval: const Duration(days: 1),
    );
    try {
      final initial = await monitor.start();
      expect(
        initial.devices.any(
          (device) =>
              device.serial == serial && device.state == AdbDeviceState.device,
        ),
        isTrue,
      );

      await client.adbToolkit.disconnect(endpoint);
      final disconnected = await _waitFor(
        tester,
        monitor,
        (snapshot) => !snapshot.devices.any(
          (device) =>
              device.serial == serial && device.state == AdbDeviceState.device,
        ),
      );
      expect(
        disconnected.removed.isNotEmpty ||
            disconnected.changed.isNotEmpty ||
            disconnected.devices.any(
              (device) => device.state != AdbDeviceState.device,
            ),
        isTrue,
      );

      await client.adbToolkit.connect(endpoint);
      final reconnected = await _waitFor(
        tester,
        monitor,
        (snapshot) => snapshot.devices.any(
          (device) =>
              device.serial == serial && device.state == AdbDeviceState.device,
        ),
      );
      expect(reconnected.devices, isNotEmpty);
    } finally {
      try {
        await client.adbToolkit.connect(endpoint);
      } catch (_) {
        // Preserve the original test failure; a following refresh reports it.
      }
      await monitor.close();
    }
  }, timeout: const Timeout(Duration(minutes: 1)));
}

Future<AdbDeviceSnapshot> _waitFor(
  WidgetTester tester,
  AdbDeviceMonitor monitor,
  bool Function(AdbDeviceSnapshot snapshot) predicate,
) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    final snapshot = await monitor.refresh();
    if (predicate(snapshot)) return snapshot;
    await tester.pump(const Duration(milliseconds: 250));
  }
  throw StateError('Timed out waiting for the expected device state');
}
