import 'package:adb_client/adb_client.dart';
import 'package:test/test.dart';

final class _PairingAdbClient implements AdbClient {
  _PairingAdbClient(this.discoveries);

  final List<List<AdbMdnsService>> discoveries;
  final List<AdbEndpoint> paired = <AdbEndpoint>[];
  final List<AdbEndpoint> connected = <AdbEndpoint>[];
  var discoveryCalls = 0;

  @override
  Future<void> pair(
    AdbEndpoint endpoint,
    String pairingCode, {
    AdbCancellationToken? cancellationToken,
  }) async {
    paired.add(endpoint);
  }

  @override
  Future<void> connect(
    AdbEndpoint endpoint, {
    AdbCancellationToken? cancellationToken,
  }) async {
    connected.add(endpoint);
  }

  @override
  Future<List<AdbMdnsService>> discoverMdnsServices({
    AdbCancellationToken? cancellationToken,
  }) async => discoveries[(discoveryCalls++).clamp(0, discoveries.length - 1)];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('redacts sensitive command arguments without changing the command', () {
    const command = AdbCommand(
      <String>['pair', '192.0.2.10:37123', '123456'],
      sensitiveArgumentIndexes: <int>{2},
    );

    expect(command.redactedArguments, <String>[
      'pair',
      '192.0.2.10:37123',
      '<redacted>',
    ]);
    expect(command.arguments.last, '123456');
  });

  test('device serial is stable and not exposed by redactedSerial', () {
    const device = AdbDevice(
      serial: 'secret-serial',
      state: AdbDeviceState.device,
      connectionType: AdbConnectionType.usb,
    );

    expect(device.redactedSerial, startsWith('device-'));
    expect(device.redactedSerial, isNot(contains(device.serial)));
    expect(device.redactedSerial, device.redactedSerial);
  });

  test('cancellation is idempotent', () async {
    final token = AdbCancellationToken();
    token.cancel();
    token.cancel();

    await token.whenCancelled;
    expect(token.isCancelled, isTrue);
  });

  test('parses network endpoints with a default port', () {
    expect(AdbEndpoint.tryParse('192.0.2.10')?.authority, '192.0.2.10:5555');
    expect(
      AdbEndpoint.tryParse('device.local:4321')?.authority,
      'device.local:4321',
    );
    expect(
      AdbEndpoint.tryParse('[2001:db8::1]:5556')?.authority,
      '[2001:db8::1]:5556',
    );
    expect(AdbEndpoint.tryParse('device.local:70000'), isNull);
  });

  test('pairAndConnect discovers the connect port after pairing', () async {
    const pairingEndpoint = AdbEndpoint(host: '192.0.2.10', port: 37123);
    const connectEndpoint = AdbEndpoint(host: '192.0.2.10', port: 42891);
    final client = _PairingAdbClient(<List<AdbMdnsService>>[
      const <AdbMdnsService>[],
      const <AdbMdnsService>[
        AdbMdnsService(
          name: 'adb-device',
          type: AdbMdnsServiceType.connect,
          endpoint: connectEndpoint,
        ),
      ],
    ]);

    final result = await AdbToolkit(client).pairAndConnect(
      pairingEndpoint,
      '123456',
      discoveryInterval: Duration.zero,
    );

    expect(result, same(connectEndpoint));
    expect(client.paired, <AdbEndpoint>[pairingEndpoint]);
    expect(client.connected, <AdbEndpoint>[connectEndpoint]);
    expect(client.discoveryCalls, 2);
  });

  test(
    'pairAndConnect keeps successful pairing when discovery expires',
    () async {
      const pairingEndpoint = AdbEndpoint(host: '192.0.2.10', port: 37123);
      final client = _PairingAdbClient(const <List<AdbMdnsService>>[
        <AdbMdnsService>[],
      ]);

      final result = await AdbToolkit(client).pairAndConnect(
        pairingEndpoint,
        '123456',
        discoveryTimeout: Duration.zero,
        discoveryInterval: Duration.zero,
      );

      expect(result, isNull);
      expect(client.paired, <AdbEndpoint>[pairingEndpoint]);
      expect(client.connected, isEmpty);
    },
  );
}
