import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:scrcpy_flutter/scrcpy_flutter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('detects a real USB removal and reconnect', (tester) async {
    const serial = String.fromEnvironment('SCRCPY_DEVICE_SERIAL');
    if (serial.isEmpty) return;

    final monitor = ScrcpyDeviceMonitor(
      createDefaultScrcpyClient(),
      interval: const Duration(days: 1),
    );
    try {
      final initial = await monitor.start();
      final usb = initial.devices.where(
        (device) =>
            device.serial == serial &&
            device.connectionType == AdbConnectionType.usb,
      );
      expect(usb, isNotEmpty, reason: '$serial must start as a USB device');
      expect(usb.single.state, AdbDeviceState.device);
      debugPrint('usb-hotplug: ready serial=$serial; waiting for removal');

      final removed = await _waitFor(
        monitor,
        (snapshot) =>
            !snapshot.devices.any((device) => device.serial == serial),
      );
      expect(removed.removed.any((device) => device.serial == serial), isTrue);
      debugPrint('usb-hotplug: removal detected; waiting for reconnect');

      final reconnected = await _waitFor(
        monitor,
        (snapshot) => snapshot.devices.any(
          (device) =>
              device.serial == serial &&
              device.connectionType == AdbConnectionType.usb &&
              device.state == AdbDeviceState.device,
        ),
      );
      expect(
        reconnected.added.any(
              (device) =>
                  device.serial == serial &&
                  device.state == AdbDeviceState.device,
            ) ||
            reconnected.changed.any(
              (device) =>
                  device.serial == serial &&
                  device.state == AdbDeviceState.device,
            ),
        isTrue,
      );
      debugPrint('usb-hotplug: reconnect detected and authorized');
    } finally {
      await monitor.close();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}

Future<ScrcpyDeviceSnapshot> _waitFor(
  ScrcpyDeviceMonitor monitor,
  bool Function(ScrcpyDeviceSnapshot snapshot) predicate,
) async {
  for (var attempt = 0; attempt < 180; attempt++) {
    final snapshot = await monitor.refresh();
    if (predicate(snapshot)) return snapshot;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  throw TimeoutException('Timed out waiting for USB hotplug state');
}
