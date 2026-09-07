import 'dart:async';

import 'package:test/test.dart';
import 'package:adb_client/adb_client.dart';

final class _SequenceAdbDevices implements AdbClient {
  _SequenceAdbDevices(this.snapshots);

  final List<List<AdbDevice>> snapshots;
  var calls = 0;

  @override
  Future<List<AdbDevice>> listDevices({
    AdbCancellationToken? cancellationToken,
  }) async => snapshots[(calls++).clamp(0, snapshots.length - 1)];

  @override
  Future<List<AdbMdnsService>> discoverMdnsServices({
    AdbCancellationToken? cancellationToken,
  }) async => const <AdbMdnsService>[];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('monitor reports add, remove and device state changes', () async {
    const usbUnauthorized = AdbDevice(
      serial: 'usb-1',
      state: AdbDeviceState.unauthorized,
      connectionType: AdbConnectionType.usb,
    );
    const usbReady = AdbDevice(
      serial: 'usb-1',
      state: AdbDeviceState.device,
      connectionType: AdbConnectionType.usb,
      model: 'Phone',
    );
    const networkOffline = AdbDevice(
      serial: '192.168.1.2:5555',
      state: AdbDeviceState.offline,
      connectionType: AdbConnectionType.network,
    );
    final adb = _SequenceAdbDevices(<List<AdbDevice>>[
      <AdbDevice>[usbUnauthorized],
      <AdbDevice>[usbReady, networkOffline],
      <AdbDevice>[networkOffline],
    ]);
    final monitor = AdbDeviceMonitor(
      AdbToolkit(adb),
      interval: const Duration(days: 1),
    );
    final emitted = <AdbDeviceSnapshot>[];
    final subscription = monitor.snapshots.listen(emitted.add);

    final initial = await monitor.start();
    expect(initial.added, <AdbDevice>[usbUnauthorized]);
    expect(initial.removed, isEmpty);

    final changed = await monitor.refresh();
    expect(changed.added, <AdbDevice>[networkOffline]);
    expect(changed.changed, <AdbDevice>[usbReady]);
    expect(changed.removed, isEmpty);

    final removed = await monitor.refresh();
    expect(removed.removed, <AdbDevice>[usbReady]);
    expect(removed.devices, <AdbDevice>[networkOffline]);
    await Future<void>.delayed(Duration.zero);
    expect(emitted, hasLength(3));

    await monitor.stop();
    expect(monitor.isRunning, isFalse);
    await subscription.cancel();
    await monitor.close();
  });

  test('monitor rejects invalid interval and refresh after close', () async {
    final monitor = AdbDeviceMonitor(
      AdbToolkit(_SequenceAdbDevices(<List<AdbDevice>>[const <AdbDevice>[]])),
      interval: Duration.zero,
    );
    await expectLater(monitor.start(), throwsArgumentError);
    await monitor.close();
    await expectLater(monitor.refresh(), throwsStateError);
  });

  test('watchDevices starts immediately and stops when cancelled', () async {
    const device = AdbDevice(
      serial: 'usb-1',
      state: AdbDeviceState.device,
      connectionType: AdbConnectionType.usb,
    );
    final client = _SequenceAdbDevices(<List<AdbDevice>>[
      <AdbDevice>[device],
    ]);
    final firstSnapshot = Completer<void>();
    final subscription = AdbToolkit(client)
        .watchDevices(interval: const Duration(milliseconds: 10))
        .listen((_) {
          if (!firstSnapshot.isCompleted) firstSnapshot.complete();
        });

    await firstSnapshot.future;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(client.calls, greaterThanOrEqualTo(1));

    await subscription.cancel();
    final callsAfterCancel = client.calls;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(client.calls, callsAfterCancel);
  });

  test('watchDevices can suppress unchanged polling snapshots', () async {
    const device = AdbDevice(
      serial: 'usb-1',
      state: AdbDeviceState.device,
      connectionType: AdbConnectionType.usb,
    );
    final snapshots = <AdbDeviceSnapshot>[];
    final firstSnapshot = Completer<void>();
    final subscription =
        AdbToolkit(
              _SequenceAdbDevices(<List<AdbDevice>>[
                <AdbDevice>[device],
              ]),
            )
            .watchDevices(interval: const Duration(milliseconds: 10))
            .listen((snapshot) {
              snapshots.add(snapshot);
              if (!firstSnapshot.isCompleted) firstSnapshot.complete();
            });

    await firstSnapshot.future;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await subscription.cancel();
    expect(snapshots, hasLength(1));
    expect(snapshots.single.devices, <AdbDevice>[device]);
  });
}
