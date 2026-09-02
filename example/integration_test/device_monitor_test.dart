import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:scrcpy_flutter/scrcpy_flutter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('detects a real network ADB disconnect and reconnect', (
    tester,
  ) async {
    const serial = String.fromEnvironment('SCRCPY_DEVICE_SERIAL');
    final endpoint = AdbEndpoint.tryParse(serial);
    if (serial.isEmpty || endpoint == null) return;

    final client = createDefaultScrcpyClient();
    final monitor = ScrcpyDeviceMonitor(
      client,
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

      await client.disconnect(endpoint);
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

      await client.connect(endpoint);
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
        await client.connect(endpoint);
      } catch (_) {
        // Preserve the original test failure; a following refresh reports it.
      }
      await monitor.close();
    }
  }, timeout: const Timeout(Duration(minutes: 1)));
}

Future<ScrcpyDeviceSnapshot> _waitFor(
  WidgetTester tester,
  ScrcpyDeviceMonitor monitor,
  bool Function(ScrcpyDeviceSnapshot snapshot) predicate,
) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    final snapshot = await monitor.refresh();
    if (predicate(snapshot)) return snapshot;
    await tester.pump(const Duration(milliseconds: 250));
  }
  throw StateError('Timed out waiting for the expected device state');
}
