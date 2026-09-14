import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:adb_client/adb_client.dart';
import 'package:scrcpy_flutter/scrcpy_advanced.dart';

class FakeAdbClient implements AdbClient {
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

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class EmptyAdbClient implements AdbClient {
  @override
  Future<List<AdbDevice>> listDevices({
    AdbCancellationToken? cancellationToken,
  }) async => const <AdbDevice>[];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class DelayedAdbClient implements AdbClient {
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

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeConnectionAdbClient implements AdbClient, AdbConnectionService {
  AdbEndpoint? connected;
  AdbEndpoint? disconnected;
  AdbEndpoint? paired;
  String? receivedPairingCode;

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
  }) async {
    paired = endpoint;
    receivedPairingCode = pairingCode;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeApplicationLabelClient
    implements AdbClient, ScrcpyApplicationLabelProvider {
  @override
  Future<AdbCommandResult> shell(
    String serial,
    List<String> arguments, {
    AdbCancellationToken? cancellationToken,
  }) async {
    final output = switch (arguments) {
      ['pm', 'list', 'packages', ...] => 'package:/data/app/example/base.apk=com.example.app uid:10001 versionCode:1\n',
      ['cmd', 'package', 'query-activities', ...] =>
        'com.example.app/.MainActivity\n',
      _ => '',
    };
    return AdbCommandResult(
      exitCode: 0,
      stdout: output.codeUnits,
      stderr: const <int>[],
      elapsed: Duration.zero,
    );
  }

  @override
  Future<String> loadApplicationLabels(
    String deviceSerial, {
    AdbCancellationToken? cancellationToken,
  }) async => '* 示例应用 com.example.app\n';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeUnifiedDiscoveryAdbClient
    implements AdbClient, AdbMdnsDiscoveryService {
  @override
  Future<List<AdbDevice>> listDevices({
    AdbCancellationToken? cancellationToken,
  }) async => <AdbDevice>[
    AdbDevice(
      serial: '192.0.2.10:41001',
      state: AdbDeviceState.device,
      connectionType: AdbConnectionType.network,
      lastSeenAt: DateTime(2026, 9, 1, 12),
    ),
  ];

  @override
  Future<List<AdbMdnsService>> discoverMdnsServices({
    AdbCancellationToken? cancellationToken,
  }) async => const <AdbMdnsService>[
    AdbMdnsService(
      name: 'online',
      type: AdbMdnsServiceType.connect,
      endpoint: AdbEndpoint(host: '192.0.2.10', port: 41001),
    ),
    AdbMdnsService(
      name: 'paired',
      type: AdbMdnsServiceType.connect,
      endpoint: AdbEndpoint(host: '192.0.2.20', port: 41001),
    ),
    AdbMdnsService(
      name: 'paired',
      type: AdbMdnsServiceType.connect,
      endpoint: AdbEndpoint(host: '192.0.2.20', port: 42002),
    ),
    AdbMdnsService(
      name: 'waiting',
      type: AdbMdnsServiceType.pairing,
      endpoint: AdbEndpoint(host: '192.0.2.30', port: 37123),
    ),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeVideoConnector implements ScrcpyVideoConnector {
  final connectionCompleter = Completer<ScrcpyVideoConnection>();
  var calls = 0;
  ScrcpySessionConfiguration? lastConfiguration;

  @override
  Future<ScrcpyVideoConnection> connect(
    ScrcpySessionConfiguration configuration, {
    AdbCancellationToken? cancellationToken,
  }) {
    calls++;
    lastConfiguration = configuration;
    return connectionCompleter.future;
  }
}

class RepeatingVideoConnector implements ScrcpyVideoConnector {
  final connections = <FakeSessionVideoConnection>[];
  final configurations = <ScrcpySessionConfiguration>[];

  @override
  Future<ScrcpyVideoConnection> connect(
    ScrcpySessionConfiguration configuration, {
    AdbCancellationToken? cancellationToken,
  }) async {
    configurations.add(configuration);
    final connection = FakeSessionVideoConnection();
    connections.add(connection);
    return connection;
  }
}

class MovingEndpointAdbClient implements AdbClient {
  String serial = '192.0.2.10:41001';
  final connected = <AdbEndpoint>[];

  @override
  Future<List<AdbDevice>> listDevices({
    AdbCancellationToken? cancellationToken,
  }) async => <AdbDevice>[
    AdbDevice(
      serial: serial,
      state: AdbDeviceState.device,
      connectionType: AdbConnectionType.network,
    ),
  ];

  @override
  Future<List<AdbMdnsService>> discoverMdnsServices({
    AdbCancellationToken? cancellationToken,
  }) async => const <AdbMdnsService>[
    AdbMdnsService(
      name: 'adb-moving',
      type: AdbMdnsServiceType.connect,
      endpoint: AdbEndpoint(host: '192.0.2.10', port: 42002),
    ),
  ];

  @override
  Future<void> connect(
    AdbEndpoint endpoint, {
    AdbCancellationToken? cancellationToken,
  }) async {
    connected.add(endpoint);
    serial = endpoint.authority;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FirstThenFailVideoConnector implements ScrcpyVideoConnector {
  var calls = 0;
  final first = FakeSessionVideoConnection();

  @override
  Future<ScrcpyVideoConnection> connect(
    ScrcpySessionConfiguration configuration, {
    AdbCancellationToken? cancellationToken,
  }) async {
    calls++;
    if (calls == 1) return first;
    throw StateError('injected reconnect failure');
  }
}

class AlwaysFailVideoConnector implements ScrcpyVideoConnector {
  var calls = 0;

  @override
  Future<ScrcpyVideoConnection> connect(
    ScrcpySessionConfiguration configuration, {
    AdbCancellationToken? cancellationToken,
  }) async {
    calls++;
    throw StateError('injected session failure');
  }
}

class FakeSessionVideoConnection implements ScrcpyVideoConnection {
  @override
  ScrcpyAudioStream? get audio => null;

  final doneCompleter = Completer<void>();
  var closeCalls = 0;

  @override
  int get bytesReceived => 0;

  @override
  Future<ScrcpyVideoCodecInfo> get codec => Future.value(
    const ScrcpyVideoCodecInfo(
      codecId: ScrcpyVideoCodecInfo.h264,
      width: 1080,
      height: 1920,
    ),
  );

  @override
  Future<void> get done => doneCompleter.future;

  @override
  ScrcpyVideoConnectionInfo get info => const ScrcpyVideoConnectionInfo(
    scid: 'session-test',
    localPort: 12345,
    remoteServerPath: '/data/local/tmp/test.jar',
  );

  @override
  ScrcpyInputController? get input => null;

  @override
  Stream<ScrcpyVideoPacket> get packets => const Stream.empty();

  @override
  Stream<ScrcpyVideoCodecInfo> get sessions => const Stream.empty();

  @override
  Future<void> close() async {
    closeCalls++;
    if (!doneCompleter.isCompleted) doneCompleter.complete();
  }

  void disconnect() {
    if (!doneCompleter.isCompleted) doneCompleter.complete();
  }
}

void main() {
  test('parses localized application labels from scrcpy output', () {
    final labels = ScrcpyClient.parseScrcpyApplicationLabels('''
[server] INFO: List of apps:
 * 设置                             com.android.settings
 * App with spaces                 com.example.spaces
 - 媒花易数                           com.palsmon.app
malformed line
''');

    expect(labels['com.android.settings'], '设置');
    expect(labels['com.example.spaces'], 'App with spaces');
    expect(labels['com.palsmon.app'], '媒花易数');
    expect(labels, hasLength(3));
  });

  test('application list uses a platform label provider', () async {
    final applications = await ScrcpyClient(
      adbClient: FakeApplicationLabelClient(),
    ).listApplications('test-device');

    expect(applications, hasLength(1));
    expect(applications.single.packageName, 'com.example.app');
    expect(applications.single.name, '示例应用');
    expect(applications.single.launchable, isTrue);
  });

  test('device discovery attaches a stable mDNS identity', () async {
    final devices = await AdbToolkit(FakeUnifiedDiscoveryAdbClient())
        .discoverDevices();

    expect(devices, hasLength(2));
    expect(devices.first.attributes['mdns_service_name'], 'online');
    expect(devices.last.serial, '192.0.2.20:42002');
    expect(devices.last.attributes['mdns_service_name'], 'paired');
  });

  test('video options validate quality and encoder selections', () {
    const valid = ScrcpyVideoOptions(
      maxSize: 1280,
      maxFps: 30,
      bitRate: 4000000,
      codec: ScrcpyVideoCodec.h265,
      encoder: 'c2.android.hevc.encoder',
    );
    expect(valid.validate, returnsNormally);
    expect(valid.codec.serverName, 'h265');

    expect(
      () => const ScrcpyVideoOptions(maxFps: 0).validate(),
      throwsRangeError,
    );
    expect(
      () => const ScrcpyVideoOptions(bitRate: 99999).validate(),
      throwsRangeError,
    );
    expect(
      () => const ScrcpyVideoOptions(encoder: 'bad encoder').validate(),
      throwsArgumentError,
    );
  });

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
    expect(client.runtimeInfo?.usesBundledAdb, isFalse);
    expect(
      client.runtimeInfo?.scrcpyServerPath,
      r'C:\tools\scrcpy-server-v4.1',
    );
  });

  test('ScrcpySession reports an unexpected transport disconnect', () async {
    final connector = FakeVideoConnector();
    final connection = FakeSessionVideoConnection();
    final session = ScrcpyRawSession(
      adbDeviceService: FakeAdbClient(),
      configuration: const ScrcpySessionConfiguration(
        deviceSerial: 'test-device',
      ),
      videoConnector: connector,
    );

    final starting = session.start();
    await Future<void>.delayed(Duration.zero);
    connector.connectionCompleter.complete(connection);
    await starting;
    connection.disconnect();
    await Future<void>.delayed(Duration.zero);

    expect(session.state.value, ScrcpySessionState.disconnected);
    expect(connection.closeCalls, 1);
    session.dispose();
  });

  test('ScrcpySession forwards its display source to the connector', () async {
    final connector = FakeVideoConnector();
    final connection = FakeSessionVideoConnection();
    const source = ScrcpyDisplaySource.existing(
      3,
      imePolicy: ScrcpyDisplayImePolicy.fallbackDisplay,
    );
    final session = ScrcpyRawSession(
      adbDeviceService: FakeAdbClient(),
      configuration: const ScrcpySessionConfiguration(
        deviceSerial: 'test-device',
        displaySource: source,
      ),
      videoConnector: connector,
    );

    final starting = session.start();
    await Future<void>.delayed(Duration.zero);
    connector.connectionCompleter.complete(connection);
    await starting;

    expect(connector.lastConfiguration?.displaySource, same(source));
    await session.stop();
    session.dispose();
  });

  test(
    'ScrcpySession reconnects once after an unexpected disconnect',
    () async {
      final connector = RepeatingVideoConnector();
      final session = ScrcpyRawSession(
        adbDeviceService: FakeAdbClient(),
        configuration: const ScrcpySessionConfiguration(
          deviceSerial: 'test-device',
          reconnectPolicy: ScrcpyReconnectPolicy(
            maxAttempts: 3,
            initialDelay: Duration.zero,
            maxDelay: Duration.zero,
          ),
        ),
        videoConnector: connector,
      );

      final first = await session.start();
      final replacementFuture = session.reconnectedConnections.first;
      (first as FakeSessionVideoConnection).disconnect();
      final replacement = await replacementFuture.timeout(
        const Duration(seconds: 1),
      );

      expect(replacement, same(connector.connections[1]));
      expect(connector.connections, hasLength(2));
      expect(session.state.value, ScrcpySessionState.streaming);
      await session.stop();
      session.dispose();
    },
  );

  test('ScrcpySession follows a changed Wireless Debugging port', () async {
    final adb = MovingEndpointAdbClient();
    final connector = RepeatingVideoConnector();
    final session = ScrcpyRawSession(
      adbDeviceService: adb,
      configuration: const ScrcpySessionConfiguration(
        deviceSerial: '192.0.2.10:41001',
        reconnectPolicy: ScrcpyReconnectPolicy(
          maxAttempts: 1,
          initialDelay: Duration.zero,
          maxDelay: Duration.zero,
        ),
      ),
      videoConnector: connector,
    );

    final first = await session.start() as FakeSessionVideoConnection;
    final replacementFuture = session.reconnectedConnections.first;
    first.disconnect();
    await replacementFuture.timeout(const Duration(seconds: 1));

    expect(adb.connected.single.authority, '192.0.2.10:42002');
    expect(
      connector.configurations.map((value) => value.deviceSerial),
      <String>['192.0.2.10:41001', '192.0.2.10:42002'],
    );
    expect(session.deviceSerial, '192.0.2.10:42002');
    await session.stop();
    session.dispose();
  });

  test(
    'user stop cancels pending reconnect without a duplicate session',
    () async {
      final connector = RepeatingVideoConnector();
      final session = ScrcpyRawSession(
        adbDeviceService: FakeAdbClient(),
        configuration: const ScrcpySessionConfiguration(
          deviceSerial: 'test-device',
          reconnectPolicy: ScrcpyReconnectPolicy(
            maxAttempts: 3,
            initialDelay: Duration(milliseconds: 100),
            maxDelay: Duration(milliseconds: 100),
          ),
        ),
        videoConnector: connector,
      );

      final first = await session.start() as FakeSessionVideoConnection;
      first.disconnect();
      await Future<void>.delayed(Duration.zero);
      expect(session.state.value, ScrcpySessionState.reconnecting);
      await session.stop();
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(connector.connections, hasLength(1));
      expect(session.state.value, ScrcpySessionState.ready);
      session.dispose();
    },
  );

  test('reconnect exhaustion reports one terminal error', () async {
    final connector = FirstThenFailVideoConnector();
    final session = ScrcpyRawSession(
      adbDeviceService: FakeAdbClient(),
      configuration: const ScrcpySessionConfiguration(
        deviceSerial: 'test-device',
        reconnectPolicy: ScrcpyReconnectPolicy(
          maxAttempts: 2,
          initialDelay: Duration.zero,
          maxDelay: Duration.zero,
        ),
      ),
      videoConnector: connector,
    );

    await session.start();
    final terminalError = session.reconnectedConnections.first;
    connector.first.disconnect();

    await expectLater(terminalError, throwsStateError);
    expect(connector.calls, 3, reason: 'initial start plus two retries');
    expect(session.state.value, ScrcpySessionState.error);
    await session.stop();
    session.dispose();
  });

  test('one startup failure does not affect another session', () async {
    final failedConnector = AlwaysFailVideoConnector();
    final healthyConnector = RepeatingVideoConnector();
    final failed = ScrcpyRawSession(
      adbDeviceService: FakeAdbClient(),
      configuration: const ScrcpySessionConfiguration(
        deviceSerial: 'test-device',
      ),
      videoConnector: failedConnector,
    );
    final healthy = ScrcpyRawSession(
      adbDeviceService: FakeAdbClient(),
      configuration: const ScrcpySessionConfiguration(
        deviceSerial: 'test-device',
      ),
      videoConnector: healthyConnector,
    );

    await expectLater(failed.start(), throwsStateError);
    final healthyConnection = await healthy.start();

    expect(failed.state.value, ScrcpySessionState.error);
    expect(healthy.state.value, ScrcpySessionState.streaming);
    expect(failedConnector.calls, 1);
    expect(healthyConnector.connections, hasLength(1));
    expect(healthyConnector.connections.single, same(healthyConnection));

    await failed.stop();
    await healthy.stop();
    failed.dispose();
    healthy.dispose();
  });

  test('reconnect policy validates its retry bounds and backoff', () {
    const policy = ScrcpyReconnectPolicy(
      maxAttempts: 4,
      initialDelay: Duration(milliseconds: 100),
      maxDelay: Duration(milliseconds: 350),
      multiplier: 2,
    );
    expect(policy.validate, returnsNormally);
    expect(policy.delayForAttempt(1), const Duration(milliseconds: 100));
    expect(policy.delayForAttempt(2), const Duration(milliseconds: 200));
    expect(policy.delayForAttempt(3), const Duration(milliseconds: 350));
    expect(
      () => const ScrcpyReconnectPolicy(maxAttempts: -1).validate(),
      throwsRangeError,
    );
  });

  test(
    'ScrcpySession closes a connection that arrives after dispose',
    () async {
      final connector = FakeVideoConnector();
      final connection = FakeSessionVideoConnection();
      final session = ScrcpyRawSession(
        adbDeviceService: FakeAdbClient(),
        configuration: const ScrcpySessionConfiguration(
          deviceSerial: 'test-device',
        ),
        videoConnector: connector,
      );

      final starting = session.start();
      await Future<void>.delayed(Duration.zero);
      expect(session.state.value, ScrcpySessionState.starting);
      session.dispose();
      connector.connectionCompleter.complete(connection);

      await expectLater(
        starting,
        throwsA(
          isA<ScrcpyException>().having(
            (error) => error.code,
            'code',
            ScrcpyErrorCode.cancelled,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(connection.closeCalls, 1);
    },
  );

  test('ScrcpySession starts and stops cleanly for 50 cycles', () async {
    final connector = RepeatingVideoConnector();
    final session = ScrcpyRawSession(
      adbDeviceService: FakeAdbClient(),
      configuration: const ScrcpySessionConfiguration(
        deviceSerial: 'test-device',
      ),
      videoConnector: connector,
    );

    for (var iteration = 0; iteration < 50; iteration++) {
      final connection = await session.start();
      expect(session.state.value, ScrcpySessionState.streaming);
      expect(connection, same(connector.connections.last));

      await session.stop();
      expect(session.state.value, ScrcpySessionState.ready);
      expect(connector.connections.last.closeCalls, 1);
    }

    expect(connector.connections, hasLength(50));
    expect(
      connector.connections.every((connection) => connection.closeCalls == 1),
      isTrue,
    );
    session.dispose();
  });
}
