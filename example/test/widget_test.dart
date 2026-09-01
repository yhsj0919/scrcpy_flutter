import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrcpy_flutter/scrcpy_flutter.dart';
import 'package:scrcpy_flutter_example/main.dart';

final class _FakeDeviceService
    implements AdbDeviceService, AdbMdnsDiscoveryService {
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
    AdbDevice(
      serial: '192.0.2.10:5555',
      state: AdbDeviceState.unauthorized,
      connectionType: AdbConnectionType.network,
      model: 'Waiting Device',
    ),
  ];

  @override
  Future<List<AdbMdnsService>> discoverMdnsServices({
    AdbCancellationToken? cancellationToken,
  }) async => const <AdbMdnsService>[
    AdbMdnsService(
      name: 'adb-test',
      type: AdbMdnsServiceType.pairing,
      endpoint: AdbEndpoint(host: '192.0.2.20', port: 37123),
    ),
    AdbMdnsService(
      name: 'adb-test',
      type: AdbMdnsServiceType.connect,
      endpoint: AdbEndpoint(host: '192.0.2.20', port: 42002),
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
    expect(find.text('Waiting Device'), findsOneWidget);
    expect(find.textContaining('网络 · 等待授权'), findsOneWidget);
    expect(find.text('设备 3 台 · 可用 1 台'), findsOneWidget);
    expect(find.text('Wireless Debugging 设备'), findsOneWidget);
    expect(find.textContaining('网络 · 已配对，未连接'), findsOneWidget);
    expect(find.byTooltip('连接已配对设备'), findsOneWidget);
    expect(find.text('网络连接'), findsOneWidget);
    expect(find.text('验证码配对'), findsOneWidget);
    expect(find.textContaining('test-secret'), findsNothing);

    await tester.tap(find.text('验证码配对'));
    await tester.pumpAndSettle();
    expect(find.text('发现的无线调试服务'), findsOneWidget);
    await tester.tap(find.text('配对 192.0.2.20:37123'));
    await tester.pump();
    final addressFields = tester.widgetList<TextFormField>(
      find.byType(TextFormField),
    );
    expect(addressFields.first.controller!.text, '192.0.2.20:37123');
    expect(addressFields.last.controller!.text, '192.0.2.20:42002');
  });
}
