import 'package:flutter_test/flutter_test.dart';
import 'package:scrcpy_flutter/scrcpy_flutter.dart';
import 'package:scrcpy_flutter_example/main.dart';

final class _FakeDeviceService implements AdbDeviceService {
  @override
  Future<List<AdbDevice>> listDevices({
    AdbCancellationToken? cancellationToken,
  }) async => const <AdbDevice>[
    AdbDevice(
      serial: 'test-secret',
      state: AdbDeviceState.device,
      connectionType: AdbConnectionType.usb,
      model: 'Pixel Test',
    ),
  ];
}

void main() {
  testWidgets('shows devices returned by the plugin public API', (
    tester,
  ) async {
    final client = ScrcpyClient(
      adbClient: _FakeDeviceService(),
      runtimeInfo: const ScrcpyRuntimeInfo(
        usesBundledAdb: true,
        adbExecutablePath: r'C:\demo\adb.exe',
      ),
    );

    await tester.pumpWidget(DeviceWallDemo(client: client));
    await tester.pumpAndSettle();

    expect(find.text('内置 ADB'), findsOneWidget);
    expect(find.text('Pixel Test'), findsOneWidget);
    expect(find.text('网络连接'), findsOneWidget);
    expect(find.textContaining('test-secret'), findsNothing);
  });
}
