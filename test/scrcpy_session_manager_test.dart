import 'package:adb_client/adb_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrcpy_flutter/scrcpy_flutter.dart';

final class _FakeAdbClient implements AdbClient {
  _FakeAdbClient(this.devices);

  final List<AdbDevice> devices;

  @override
  Future<List<AdbDevice>> listDevices({
    AdbCancellationToken? cancellationToken,
  }) async => devices;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AdbDevice _device(String serial) => AdbDevice(
  serial: serial,
  state: AdbDeviceState.device,
  connectionType: AdbConnectionType.usb,
);

void main() {
  test('creates, groups and focuses sessions across devices', () async {
    final client = ScrcpyClient(
      adbClient: _FakeAdbClient(<AdbDevice>[_device('a'), _device('b')]),
    );
    final manager = ScrcpySessionManager(client: client);
    final first = manager.create(
      const ScrcpySessionConfiguration(deviceSerial: 'a'),
    );
    final second = manager.create(
      const ScrcpySessionConfiguration(deviceSerial: 'a'),
      id: 'secondary',
    );
    final third = manager.create(
      const ScrcpySessionConfiguration(deviceSerial: 'b'),
    );

    expect(first.id, 'session-1');
    expect(manager.sessions, hasLength(3));
    expect(manager.sessionsForDevice('a'), <ScrcpyManagedSession>[
      first,
      second,
    ]);
    expect(manager.sessionsForDevice('b'), <ScrcpyManagedSession>[third]);
    expect(manager.sessionsByDevice.keys, <String>['a', 'b']);

    manager.focus(second.id);
    expect(manager.focusedSession, same(second));
    manager.focus(null);
    expect(manager.focusedSession, isNull);

    await manager.close();
    manager.dispose();
  });

  test('prepares sessions independently and removes idempotently', () async {
    final client = ScrcpyClient(
      adbClient: _FakeAdbClient(<AdbDevice>[_device('a'), _device('b')]),
    );
    final manager = ScrcpySessionManager(client: client);
    final first = manager.create(
      const ScrcpySessionConfiguration(deviceSerial: 'a'),
      id: 'first',
    );
    final second = manager.create(
      const ScrcpySessionConfiguration(deviceSerial: 'b'),
      id: 'second',
    );

    await Future.wait(<Future<void>>[
      manager.prepare(first.id),
      manager.prepare(second.id),
    ]);
    expect(first.state.value, ScrcpySessionState.ready);
    expect(second.state.value, ScrcpySessionState.ready);

    expect(await manager.remove('first'), isTrue);
    expect(await manager.remove('first'), isFalse);
    expect(manager.session('first'), isNull);
    expect(manager.sessions, <ScrcpyManagedSession>[second]);

    await manager.close();
    manager.dispose();
  });

  test('rejects duplicate ids and operations after close', () async {
    final manager = ScrcpySessionManager(
      client: ScrcpyClient(adbClient: _FakeAdbClient(<AdbDevice>[])),
    );
    manager.create(
      const ScrcpySessionConfiguration(deviceSerial: 'a'),
      id: 'same',
    );
    expect(
      () => manager.create(
        const ScrcpySessionConfiguration(deviceSerial: 'b'),
        id: 'same',
      ),
      throwsStateError,
    );

    await manager.close();
    expect(
      () => manager.create(const ScrcpySessionConfiguration(deviceSerial: 'a')),
      throwsStateError,
    );
    manager.dispose();
  });

  test('enforces the configured resource limit', () async {
    final manager = ScrcpySessionManager(
      client: ScrcpyClient(adbClient: _FakeAdbClient(<AdbDevice>[])),
      maxSessions: 1,
    );
    manager.create(const ScrcpySessionConfiguration(deviceSerial: 'a'));

    expect(
      () => manager.create(const ScrcpySessionConfiguration(deviceSerial: 'b')),
      throwsStateError,
    );

    final firstClose = manager.close();
    expect(manager.close(), same(firstClose));
    await firstClose;
    manager.dispose();
  });
}
