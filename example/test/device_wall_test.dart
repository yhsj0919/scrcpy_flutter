import 'package:adb_client/adb_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrcpy_flutter/scrcpy_flutter.dart';
import 'package:scrcpy_flutter_example/device_wall.dart';

final class _FakeAdbClient implements AdbClient {
  @override
  Future<List<AdbDevice>> listDevices({
    AdbCancellationToken? cancellationToken,
  }) async => const <AdbDevice>[];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<AdbDevice> _devices(int count) => List<AdbDevice>.generate(
  count,
  (index) => AdbDevice(
    serial: 'device-$index',
    state: AdbDeviceState.device,
    connectionType: AdbConnectionType.usb,
  ),
);

void main() {
  for (final count in <int>[1, 2, 4, 8]) {
    testWidgets('renders $count independent device wall cells', (tester) async {
      tester.view.physicalSize = const Size(1300, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final devices = _devices(count);
      await tester.pumpWidget(
        MaterialApp(
          home: DeviceWallPage(
            client: ScrcpyClient(adbClient: _FakeAdbClient()),
            devices: devices,
          ),
        ),
      );
      await tester.pump();

      for (var index = 0; index < count; index++) {
        expect(
          find.byKey(
            ValueKey('device-wall-cell-wall-${devices[index].redactedSerial}'),
          ),
          findsOneWidget,
        );
      }
    });
  }

  testWidgets('changes column width with the available window width', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    final client = ScrcpyClient(adbClient: _FakeAdbClient());
    final device = _devices(1).single;

    Future<double> cellWidth(double width) async {
      tester.view.physicalSize = Size(width, 900);
      await tester.pumpWidget(
        MaterialApp(
          home: DeviceWallPage(client: client, devices: <AdbDevice>[device]),
        ),
      );
      await tester.pump();
      return tester
          .getSize(
            find.byKey(
              ValueKey('device-wall-cell-wall-${device.redactedSerial}'),
            ),
          )
          .width;
    }

    expect(await cellWidth(600), closeTo(568, 0.1));
    expect(await cellWidth(800), closeTo(378, 0.1));
    expect(await cellWidth(1300), closeTo(414.7, 0.1));
    expect(await cellWidth(1900), closeTo(458, 0.1));
  });
}
