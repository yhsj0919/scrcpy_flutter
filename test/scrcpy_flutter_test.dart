import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:scrcpy_flutter/scrcpy_flutter.dart';

class FakeAdbClient implements AdbDeviceService {
  var calls = 0;

  @override
  Future<List<AdbDevice>> listDevices({
    AdbCancellationToken? cancellationToken,
  }) async {
    calls++;
    return const <AdbDevice>[
      AdbDevice(
        serial: 'test-device',
        state: AdbDeviceState.device,
        connectionType: AdbConnectionType.usb,
      ),
    ];
  }
}

class EmptyAdbClient implements AdbDeviceService {
  @override
  Future<List<AdbDevice>> listDevices({
    AdbCancellationToken? cancellationToken,
  }) async => const <AdbDevice>[];
}

class DelayedAdbClient implements AdbDeviceService {
  var calls = 0;

  @override
  Future<List<AdbDevice>> listDevices({
    AdbCancellationToken? cancellationToken,
  }) async {
    calls++;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return const <AdbDevice>[
      AdbDevice(
        serial: 'test-device',
        state: AdbDeviceState.device,
        connectionType: AdbConnectionType.usb,
      ),
    ];
  }
}

class FakeConnectionAdbClient
    implements AdbDeviceService, AdbConnectionService {
  AdbEndpoint? connected;
  AdbEndpoint? disconnected;

  @override
  Future<List<AdbDevice>> listDevices({
    AdbCancellationToken? cancellationToken,
  }) async => const <AdbDevice>[];

  @override
  Future<void> connect(
    AdbEndpoint endpoint, {
    AdbCancellationToken? cancellationToken,
  }) async => connected = endpoint;

  @override
  Future<void> disconnect(
    AdbEndpoint endpoint, {
    AdbCancellationToken? cancellationToken,
  }) async => disconnected = endpoint;

  @override
  Future<void> pair(
    AdbEndpoint endpoint,
    String pairingCode, {
    AdbCancellationToken? cancellationToken,
  }) async {}
}

void main() {
  test(
    'ScrcpyClient discovers devices through the injected ADB boundary',
    () async {
      final adb = FakeAdbClient();
      final client = ScrcpyClient(adbClient: adb);

      final devices = await client.discoverDevices();

      expect(adb.calls, 1);
      expect(devices.single.serial, 'test-device');
    },
  );

  test('ScrcpySession prepares through a fake ADB device service', () async {
    final adb = FakeAdbClient();
    final client = ScrcpyClient(adbClient: adb);
    final session = client.createSession(
      const ScrcpySessionConfiguration(deviceSerial: 'test-device'),
    );

    await session.prepare();

    expect(session.state.value, ScrcpySessionState.ready);
    expect(adb.calls, 1);
    session.dispose();
  });

  test('ScrcpySession rejects a missing device', () async {
    final client = ScrcpyClient(adbClient: EmptyAdbClient());
    final session = client.createSession(
      const ScrcpySessionConfiguration(deviceSerial: 'missing'),
    );

    await expectLater(session.prepare(), throwsA(isA<ScrcpyException>()));
    expect(session.state.value, ScrcpySessionState.error);
    session.dispose();
  });

  test(
    'ScrcpySession coalesces concurrent prepare and disposes twice',
    () async {
      final adb = DelayedAdbClient();
      final session = ScrcpyClient(adbClient: adb).createSession(
        const ScrcpySessionConfiguration(deviceSerial: 'test-device'),
      );

      await Future.wait(<Future<void>>[session.prepare(), session.prepare()]);

      expect(adb.calls, 1);
      expect(session.state.value, ScrcpySessionState.ready);
      session.dispose();
      session.dispose();
    },
  );

  test('default desktop client accepts explicit resource overrides', () {
    if (!Platform.isWindows) return;

    final client = createDefaultScrcpyClient(
      adbExecutablePath: r'C:\tools\adb.exe',
      scrcpyServerPath: r'C:\tools\scrcpy-server-v4.1',
    );

    expect(client.runtimeInfo?.adbExecutablePath, r'C:\tools\adb.exe');
    expect(
      client.runtimeInfo?.scrcpyServerPath,
      r'C:\tools\scrcpy-server-v4.1',
    );
  });

  test('ScrcpyClient forwards network connect and disconnect', () async {
    final adb = FakeConnectionAdbClient();
    final client = ScrcpyClient(adbClient: adb);
    const endpoint = AdbEndpoint(host: '192.0.2.10', port: 5555);

    await client.connect(endpoint);
    await client.disconnect(endpoint);

    expect(adb.connected, same(endpoint));
    expect(adb.disconnected, same(endpoint));
  });
}
