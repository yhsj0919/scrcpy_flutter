import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adb_client/adb_client.dart';
import 'package:adb_client_process/adb_client_process.dart';
import 'package:test/test.dart';

void main() {
  late ProcessAdbClient client;

  setUp(() {
    client = ProcessAdbClient(
      executable: Platform.resolvedExecutable,
      executableArguments: <String>[
        '${Directory.current.path}${Platform.pathSeparator}test'
            '${Platform.pathSeparator}fixtures${Platform.pathSeparator}'
            'fake_adb.dart',
      ],
    );
  });

  test('captures successful output and structured arguments', () async {
    final result = await client.execute(
      const AdbCommand(<String>['success', 'one value', r'a&b']),
    );

    expect(result.exitCode, 0);
    expect(utf8.decode(result.stdout), r'ok:one value,a&b');
  });

  test('passes stdin bytes without text conversion', () async {
    final input = Uint8List.fromList(<int>[0, 1, 2, 255]);
    final result = await client.execute(
      AdbCommand(<String>['stdin'], stdin: input),
    );

    expect(result.stdout, input);
  });

  test('returns non-zero exit code and stderr', () async {
    final result = await client.execute(const AdbCommand(<String>['failure']));

    expect(result.exitCode, 7);
    expect(utf8.decode(result.stderr), 'expected failure');
  });

  test('kills only the created process on timeout', () async {
    await expectLater(
      client.execute(
        const AdbCommand(<String>[
          'sleep',
        ], timeout: Duration(milliseconds: 200)),
      ),
      throwsA(
        isA<AdbException>().having(
          (error) => error.code,
          'code',
          AdbErrorCode.timedOut,
        ),
      ),
    );
  });

  test('kills only the created process on cancellation', () async {
    final token = AdbCancellationToken();
    final future = client.execute(
      const AdbCommand(<String>['sleep']),
      cancellationToken: token,
    );
    Future<void>.delayed(const Duration(milliseconds: 200), token.cancel);

    await expectLater(
      future,
      throwsA(
        isA<AdbException>().having(
          (error) => error.code,
          'code',
          AdbErrorCode.cancelled,
        ),
      ),
    );
  });

  test('drains large stdout without deadlock', () async {
    final result = await client.execute(
      const AdbCommand(<String>['large'], timeout: Duration(seconds: 10)),
    );

    expect(result.stdout, hasLength(2 * 1024 * 1024));
  });

  test('owns and terminates only its long-running command', () async {
    final running = await client.start(
      const AdbCommand(<String>['long-running']),
    );

    expect(utf8.decode(await running.stdout.first), 'ready');
    expect(running.kill(), isTrue);
    expect(await running.exitCode, isNot(0));
  });

  test('typed pair call redacts the pairing code diagnostics', () async {
      final diagnostics = <Map<String, Object?>>[];
      client = ProcessAdbClient(
        executable: Platform.resolvedExecutable,
        executableArguments: <String>[
          '${Directory.current.path}${Platform.pathSeparator}test'
              '${Platform.pathSeparator}fixtures${Platform.pathSeparator}'
              'fake_adb.dart',
        ],
        onDiagnostic: (_, fields) => diagnostics.add(fields),
      );

      await client.pair(
        const AdbEndpoint(host: '192.0.2.1', port: 37123),
        '123456',
      );

      final start = diagnostics.first;
      expect(start['arguments'], <String>[
        'pair',
        '192.0.2.1:37123',
        '<redacted>',
      ]);
      expect(start.toString(), isNot(contains('123456')));
    },
  );

  test('discovers Wireless Debugging mDNS services', () async {
    final services = await client.discoverMdnsServices();

    expect(services, hasLength(3));
    expect(services.first.type, AdbMdnsServiceType.pairing);
    expect(services[1].type, AdbMdnsServiceType.connect);
    expect(services.last.endpoint.host, '2001:db8::10');
  });

  test('accepts successful and repeated network operations', () async {
    await client.connect(const AdbEndpoint(host: 'device.example', port: 5555));
    await client.connect(
      const AdbEndpoint(host: 'already.example', port: 5555),
    );
    await client.disconnect(
      const AdbEndpoint(host: 'missing.example', port: 5555),
    );
  });

  test('detects connect failures reported with exit code zero', () async {
    await expectLater(
      client.connect(const AdbEndpoint(host: 'fail.example', port: 5555)),
      throwsA(
        isA<AdbException>().having(
          (error) => error.code,
          'code',
          AdbErrorCode.connectionFailed,
        ),
      ),
    );
  });

  test('times out a network connection with a typed error', () async {
    client = ProcessAdbClient(
      executable: Platform.resolvedExecutable,
      executableArguments: <String>[
        '${Directory.current.path}${Platform.pathSeparator}test'
            '${Platform.pathSeparator}fixtures${Platform.pathSeparator}'
            'fake_adb.dart',
      ],
      connectionTimeout: const Duration(milliseconds: 200),
    );

    await expectLater(
      client.connect(const AdbEndpoint(host: 'sleep.example', port: 5555)),
      throwsA(
        isA<AdbException>().having(
          (error) => error.code,
          'code',
          AdbErrorCode.timedOut,
        ),
      ),
    );
  });

  test('cancels an in-flight network connection', () async {
    final token = AdbCancellationToken();
    final connection = client.connect(
      const AdbEndpoint(host: 'sleep.example', port: 5555),
      cancellationToken: token,
    );
    Future<void>.delayed(const Duration(milliseconds: 200), token.cancel);

    await expectLater(
      connection,
      throwsA(
        isA<AdbException>().having(
          (error) => error.code,
          'code',
          AdbErrorCode.cancelled,
        ),
      ),
    );
  });

  test('detects disconnect failures reported with exit code zero', () async {
    await expectLater(
      client.disconnect(const AdbEndpoint(host: 'fail.example', port: 5555)),
      throwsA(
        isA<AdbException>().having(
          (error) => error.code,
          'code',
          AdbErrorCode.connectionFailed,
        ),
      ),
    );
  });

  test('detects pairing failures reported with exit code zero', () async {
    await expectLater(
      client.pair(
        const AdbEndpoint(host: 'device.example', port: 37123),
        '000000',
      ),
      throwsA(
        isA<AdbException>().having(
          (error) => error.code,
          'code',
          AdbErrorCode.pairingFailed,
        ),
      ),
    );
  });

  test('detects an expired pairing code', () async {
    await expectLater(
      client.pair(
        const AdbEndpoint(host: 'device.example', port: 37123),
        '111111',
      ),
      throwsA(
        isA<AdbException>()
            .having(
              (error) => error.code,
              'code',
              AdbErrorCode.pairingFailed,
            )
            .having(
              (error) => error.message,
              'message',
              contains('pairing code expired'),
            )
            .having(
              (error) => error.message,
              'message',
              isNot(contains('111111')),
            ),
      ),
    );
  });

  test('cancels an in-flight pairing operation', () async {
    final token = AdbCancellationToken();
    final pairing = client.pair(
      const AdbEndpoint(host: 'device.example', port: 37123),
      '999999',
      cancellationToken: token,
    );
    Future<void>.delayed(const Duration(milliseconds: 200), token.cancel);

    await expectLater(
      pairing,
      throwsA(
        isA<AdbException>().having(
          (error) => error.code,
          'code',
          AdbErrorCode.cancelled,
        ),
      ),
    );
  });
}
