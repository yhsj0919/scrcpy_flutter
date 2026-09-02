import 'dart:async';
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
}

class FakeUnifiedDiscoveryAdbClient
    implements AdbDeviceService, AdbMdnsDiscoveryService {
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
}

class FakeVideoConnector implements ScrcpyVideoConnector {
  final connectionCompleter = Completer<ScrcpyVideoConnection>();
  var calls = 0;

  @override
  Future<ScrcpyVideoConnection> connect(
    ScrcpySessionConfiguration configuration, {
    AdbCancellationToken? cancellationToken,
  }) {
    calls++;
    return connectionCompleter.future;
  }
}

class RepeatingVideoConnector implements ScrcpyVideoConnector {
  final connections = <FakeSessionVideoConnection>[];

  @override
  Future<ScrcpyVideoConnection> connect(
    ScrcpySessionConfiguration configuration, {
    AdbCancellationToken? cancellationToken,
  }) async {
    final connection = FakeSessionVideoConnection();
    connections.add(connection);
    return connection;
  }
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

class FakeSessionVideoConnection implements ScrcpyVideoConnection {
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

  test('ScrcpyClient forwards network connect, disconnect and pair', () async {
    final adb = FakeConnectionAdbClient();
    final client = ScrcpyClient(adbClient: adb);
    const endpoint = AdbEndpoint(host: '192.0.2.10', port: 5555);

    await client.connect(endpoint);
    await client.disconnect(endpoint);
    await client.pair(endpoint, '123456');

    expect(adb.connected, same(endpoint));
    expect(adb.disconnected, same(endpoint));
    expect(adb.paired, same(endpoint));
    expect(adb.receivedPairingCode, '123456');
  });

  test('ScrcpyClient merges connected and paired mDNS devices', () async {
    final devices = await ScrcpyClient(
      adbClient: FakeUnifiedDiscoveryAdbClient(),
    ).discoverDevices();

    expect(devices, hasLength(2));
    expect(devices.first.state, AdbDeviceState.device);
    expect(devices.last.state, AdbDeviceState.paired);
    expect(devices.last.serial, '192.0.2.20:42002');
    expect(devices.last.isReady, isFalse);
    expect(devices.last.lastSeenAt, isNotNull);
    expect(
      devices.where((device) => device.serial == '192.0.2.20:41001'),
      isEmpty,
    );
  });

  test(
    'ScrcpySession coalesces concurrent start and stop operations',
    () async {
      final connector = FakeVideoConnector();
      final connection = FakeSessionVideoConnection();
      final session = ScrcpySession(
        adbDeviceService: FakeAdbClient(),
        configuration: const ScrcpySessionConfiguration(
          deviceSerial: 'test-device',
        ),
        videoConnector: connector,
      );

      final firstStart = session.start();
      final secondStart = session.start();
      await Future<void>.delayed(Duration.zero);
      expect(session.state.value, ScrcpySessionState.starting);
      connector.connectionCompleter.complete(connection);

      expect(await firstStart, same(connection));
      expect(await secondStart, same(connection));
      expect(connector.calls, 1);
      expect(session.state.value, ScrcpySessionState.streaming);

      await Future.wait(<Future<void>>[session.stop(), session.stop()]);
      expect(connection.closeCalls, 1);
      expect(session.state.value, ScrcpySessionState.ready);
      session.dispose();
    },
  );

  test('ScrcpySession reports an unexpected transport disconnect', () async {
    final connector = FakeVideoConnector();
    final connection = FakeSessionVideoConnection();
    final session = ScrcpySession(
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

  test(
    'ScrcpySession reconnects once after an unexpected disconnect',
    () async {
      final connector = RepeatingVideoConnector();
      final session = ScrcpySession(
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

  test(
    'user stop cancels pending reconnect without a duplicate session',
    () async {
      final connector = RepeatingVideoConnector();
      final session = ScrcpySession(
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
    final session = ScrcpySession(
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
      final session = ScrcpySession(
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
    final session = ScrcpySession(
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
