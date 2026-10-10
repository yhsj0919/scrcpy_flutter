import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adb_client/adb_client.dart';

import 'adb_devices_parser.dart';
import 'adb_mdns_parser.dart';

typedef AdbDiagnosticSink = void Function(
  String event,
  Map<String, Object?> fields,
);

final class ProcessAdbClient implements AdbClient {
  ProcessAdbClient({
    String? executable,
    this.executableArguments = const <String>[],
    this.environment,
    this.onDiagnostic,
    this.connectionTimeout = const Duration(seconds: 15),
  }) : executable = executable ?? resolveBundledAdbExecutable();

  final String executable;
  final List<String> executableArguments;
  final Map<String, String>? environment;
  final AdbDiagnosticSink? onDiagnostic;
  final Duration connectionTimeout;
  Future<void>? _preparingExecutable;

  @override
  Future<AdbRunningCommand> start(
    AdbCommand command, {
    AdbCancellationToken? cancellationToken,
  }) async {
    if (cancellationToken?.isCancelled ?? false) {
      throw const AdbException(AdbErrorCode.cancelled, 'ADB command cancelled');
    }
    await _prepareExecutable();
    onDiagnostic?.call('adb.start', <String, Object?>{
      'executable': executable,
      'arguments': command.redactedArguments,
      'longRunning': true,
    });
    try {
      final process = await Process.start(
        executable,
        <String>[...executableArguments, ...command.arguments],
        environment: environment,
        runInShell: false,
      );
      if (command.stdin case final input?) process.stdin.add(input);
      await process.stdin.close();
      final running = _ProcessAdbRunningCommand(process);
      unawaited(cancellationToken?.whenCancelled.then((_) => running.kill()));
      return running;
    } on ProcessException catch (error) {
      throw AdbException(
        error.errorCode == 2
            ? AdbErrorCode.executableNotFound
            : AdbErrorCode.startFailed,
        'Unable to start adb executable',
      );
    }
  }

  @override
  Future<AdbCommandResult> execute(
    AdbCommand command, {
    AdbCancellationToken? cancellationToken,
  }) async {
    if (cancellationToken?.isCancelled ?? false) {
      throw const AdbException(AdbErrorCode.cancelled, 'ADB command cancelled');
    }

    await _prepareExecutable();
    final stopwatch = Stopwatch()..start();
    onDiagnostic?.call('adb.start', <String, Object?>{
      'executable': executable,
      'arguments': command.redactedArguments,
    });

    late final Process process;
    try {
      process = await Process.start(
        executable,
        <String>[...executableArguments, ...command.arguments],
        environment: environment,
        runInShell: false,
      );
    } on ProcessException catch (error) {
      throw AdbException(
        error.errorCode == 2
            ? AdbErrorCode.executableNotFound
            : AdbErrorCode.startFailed,
        'Unable to start adb executable',
      );
    }

    final stdoutFuture = process.stdout.fold<BytesBuilder>(
      BytesBuilder(copy: false),
      (builder, bytes) => builder..add(bytes),
    );
    final stderrFuture = process.stderr.fold<BytesBuilder>(
      BytesBuilder(copy: false),
      (builder, bytes) => builder..add(bytes),
    );
    if (command.stdin case final input?) process.stdin.add(input);
    await process.stdin.close();

    Object? termination;
    final exitFuture = process.exitCode.then<Object>((value) => value);
    final timeoutFuture = Future<Object>.delayed(
      command.timeout,
      () => const _TimeoutSignal(),
    );
    final cancellationFuture = cancellationToken?.whenCancelled.then<Object>(
      (_) => const _CancellationSignal(),
    );
    final terminationCandidates = <Future<Object>>[exitFuture, timeoutFuture];
    if (cancellationFuture != null) {
      terminationCandidates.add(cancellationFuture);
    }
    termination = await Future.any<Object>(terminationCandidates);

    if (termination is _TimeoutSignal || termination is _CancellationSignal) {
      process.kill();
      await process.exitCode;
    }

    final stdout = (await stdoutFuture).takeBytes();
    final stderr = (await stderrFuture).takeBytes();
    stopwatch.stop();
    if (termination is _TimeoutSignal) {
      throw const AdbException(AdbErrorCode.timedOut, 'ADB command timed out');
    }
    if (termination is _CancellationSignal) {
      throw const AdbException(AdbErrorCode.cancelled, 'ADB command cancelled');
    }

    final result = AdbCommandResult(
      exitCode: termination as int,
      stdout: stdout,
      stderr: stderr,
      elapsed: stopwatch.elapsed,
    );
    onDiagnostic?.call('adb.exit', <String, Object?>{
      'exitCode': result.exitCode,
      'elapsedMs': result.elapsed.inMilliseconds,
      'stdoutBytes': stdout.length,
      'stderrBytes': stderr.length,
    });
    return result;
  }

  Future<void> _prepareExecutable() =>
      _preparingExecutable ??= _setExecutablePermission();

  Future<void> _setExecutablePermission() async {
    if (!Platform.isLinux || !executable.startsWith('/')) return;
    final file = File(executable);
    if (!await file.exists()) return;
    final result = await Process.run('/bin/chmod', <String>['755', executable]);
    if (result.exitCode != 0) {
      throw const AdbException(
        AdbErrorCode.startFailed,
        'Unable to make the bundled adb executable',
      );
    }
  }

  @override
  Future<List<AdbDevice>> listDevices({
    AdbCancellationToken? cancellationToken,
  }) async {
    const command = AdbCommand(<String>['devices', '-l']);
    final result = await execute(command, cancellationToken: cancellationToken);
    if (!result.isSuccess) {
      throw AdbException(
        AdbErrorCode.commandFailed,
        'adb devices failed',
        exitCode: result.exitCode,
      );
    }
    try {
      final devices = parseAdbDevices(
        utf8.decode(result.stdout),
        observedAt: DateTime.now(),
      );
      if (!_containsMdnsAlias(devices) ||
          !devices.any(
            (device) =>
                device.connectionType == AdbConnectionType.network &&
                device.serial.contains(':'),
          )) {
        return devices;
      }
      try {
        final services = await discoverMdnsServices(
          cancellationToken: cancellationToken,
        );
        return removeMdnsDeviceAliases(devices, services);
      } on AdbException {
        return devices;
      }
    } on FormatException {
      throw const AdbException(
        AdbErrorCode.invalidResponse,
        'adb devices returned invalid UTF-8',
      );
    }
  }

  static bool _containsMdnsAlias(List<AdbDevice> devices) => devices.any(
    (device) =>
        device.serial.endsWith('._adb-tls-connect._tcp') ||
        device.serial.endsWith('._adb-tls-connect._tcp.'),
  );

  @override
  Future<List<AdbMdnsService>> discoverMdnsServices({
    AdbCancellationToken? cancellationToken,
  }) async {
    const command = AdbCommand(<String>['mdns', 'services']);
    final result = await execute(command, cancellationToken: cancellationToken);
    if (!result.isSuccess) {
      throw AdbException(
        AdbErrorCode.commandFailed,
        'Unable to discover Wireless Debugging services',
        exitCode: result.exitCode,
      );
    }
    return parseAdbMdnsServices(
      utf8.decode(result.stdout, allowMalformed: true),
    );
  }

  @override
  Future<void> connect(
    AdbEndpoint endpoint, {
    AdbCancellationToken? cancellationToken,
  }) => _executeAdbOperation(
    command: AdbCommand(<String>[
      'connect',
      endpoint.authority,
    ], timeout: connectionTimeout),
    isSuccessful: (output) =>
        output.contains('connected to ') ||
        output.contains('already connected to '),
    errorCode: AdbErrorCode.connectionFailed,
    errorMessage: 'Unable to connect to the ADB device',
    cancellationToken: cancellationToken,
  );

  @override
  Future<void> disconnect(
    AdbEndpoint endpoint, {
    AdbCancellationToken? cancellationToken,
  }) => _executeAdbOperation(
    command: AdbCommand(<String>[
      'disconnect',
      endpoint.authority,
    ], timeout: connectionTimeout),
    isSuccessful: (output) =>
        output.contains('disconnected ') || output.contains('no such device'),
    errorCode: AdbErrorCode.connectionFailed,
    errorMessage: 'Unable to disconnect the ADB device',
    allowSemanticSuccessOnNonZero: true,
    cancellationToken: cancellationToken,
  );

  @override
  Future<void> pair(
    AdbEndpoint endpoint,
    String pairingCode, {
    AdbCancellationToken? cancellationToken,
  }) => _executeAdbOperation(
    command: AdbCommand(
      <String>['pair', endpoint.authority, pairingCode],
      timeout: connectionTimeout,
      sensitiveArgumentIndexes: const <int>{2},
    ),
    isSuccessful: (output) => output.contains('successfully paired to '),
    errorCode: AdbErrorCode.pairingFailed,
    errorMessage: 'Unable to pair with the ADB device',
    cancellationToken: cancellationToken,
  );

  @override
  Future<AdbCommandResult> shell(
    String serial,
    List<String> arguments, {
    AdbCancellationToken? cancellationToken,
  }) => execute(
    AdbCommand(
      <String>['-s', serial, 'shell', ...arguments],
      sensitiveArgumentIndexes: const <int>{1},
    ),
    cancellationToken: cancellationToken,
  );

  @override
  Future<void> push(
    String serial,
    String localPath,
    String remotePath, {
    AdbCancellationToken? cancellationToken,
  }) => _executeChecked(
    AdbCommand(
      <String>['-s', serial, 'push', localPath, remotePath],
      sensitiveArgumentIndexes: const <int>{1},
    ),
    cancellationToken: cancellationToken,
  );

  @override
  Future<void> pull(
    String serial,
    String remotePath,
    String localPath, {
    AdbCancellationToken? cancellationToken,
  }) => _executeChecked(
    AdbCommand(
      <String>['-s', serial, 'pull', remotePath, localPath],
      sensitiveArgumentIndexes: const <int>{1},
    ),
    cancellationToken: cancellationToken,
  );

  @override
  Future<void> install(
    String serial,
    String apkPath, {
    bool replaceExisting = false,
    AdbCancellationToken? cancellationToken,
  }) => _executeChecked(
    AdbCommand(
      <String>['-s', serial, 'install', if (replaceExisting) '-r', apkPath],
      timeout: const Duration(minutes: 5),
      sensitiveArgumentIndexes: const <int>{1},
    ),
    cancellationToken: cancellationToken,
  );

  @override
  Future<void> uninstall(
    String serial,
    String packageName, {
    bool keepData = false,
    AdbCancellationToken? cancellationToken,
  }) => _executeChecked(
    AdbCommand(
      <String>['-s', serial, 'uninstall', if (keepData) '-k', packageName],
      sensitiveArgumentIndexes: const <int>{1},
    ),
    cancellationToken: cancellationToken,
  );

  @override
  Future<void> forward(
    String serial,
    AdbForwardRule rule, {
    AdbCancellationToken? cancellationToken,
  }) => _executeChecked(
    AdbCommand(
      <String>['-s', serial, 'forward', rule.local, rule.remote],
      sensitiveArgumentIndexes: const <int>{1},
    ),
    cancellationToken: cancellationToken,
  );

  @override
  Future<void> removeForward(
    String serial,
    String local, {
    AdbCancellationToken? cancellationToken,
  }) => _executeChecked(
    AdbCommand(
      <String>['-s', serial, 'forward', '--remove', local],
      sensitiveArgumentIndexes: const <int>{1},
    ),
    cancellationToken: cancellationToken,
  );

  Future<void> _executeChecked(
    AdbCommand command, {
    AdbCancellationToken? cancellationToken,
  }) async {
    final result = await execute(command, cancellationToken: cancellationToken);
    if (!result.isSuccess) {
      throw AdbException(
        AdbErrorCode.commandFailed,
        'ADB command failed',
        exitCode: result.exitCode,
      );
    }
  }

  Future<void> _executeAdbOperation({
    required AdbCommand command,
    required bool Function(String output) isSuccessful,
    required AdbErrorCode errorCode,
    required String errorMessage,
    bool allowSemanticSuccessOnNonZero = false,
    AdbCancellationToken? cancellationToken,
  }) async {
    final result = await execute(command, cancellationToken: cancellationToken);
    final rawOutput =
        '${utf8.decode(result.stdout, allowMalformed: true)}\n'
        '${utf8.decode(result.stderr, allowMalformed: true)}';
    final semanticSuccess = isSuccessful(rawOutput.toLowerCase());
    if (!semanticSuccess ||
        (!result.isSuccess && !allowSemanticSuccessOnNonZero)) {
      final message = _operationErrorMessage(errorMessage, rawOutput, command);
      stderr.writeln('[adb] $message (exit ${result.exitCode})');
      throw AdbException(errorCode, message, exitCode: result.exitCode);
    }
  }

  static String _operationErrorMessage(
    String fallback,
    String output,
    AdbCommand command,
  ) {
    var detail = output.trim();
    if (detail.isEmpty) return fallback;

    for (final index in command.sensitiveArgumentIndexes) {
      if (index >= command.arguments.length) continue;
      final value = command.arguments[index];
      if (value.isNotEmpty) detail = detail.replaceAll(value, '<redacted>');
    }
    return '$fallback: $detail';
  }
}

final class _ProcessAdbRunningCommand implements AdbRunningCommand {
  _ProcessAdbRunningCommand(this._process);

  final Process _process;

  @override
  Stream<List<int>> get stdout => _process.stdout;

  @override
  Stream<List<int>> get stderr => _process.stderr;

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  bool kill() => _process.kill();
}

/// Resolves the ADB executable bundled with the desktop application.
String resolveBundledAdbExecutable({String? applicationExecutablePath}) {
  final applicationExecutable = File(
    applicationExecutablePath ?? Platform.resolvedExecutable,
  );
  final executableDirectory = applicationExecutable.parent;
  final candidates = switch (Platform.operatingSystem) {
    'windows' => <String>[
      '${executableDirectory.path}${Platform.pathSeparator}adb.exe',
    ],
    'linux' => <String>[
      '${executableDirectory.path}${Platform.pathSeparator}lib'
          '${Platform.pathSeparator}adb',
      '${executableDirectory.path}${Platform.pathSeparator}adb',
    ],
    'macos' => <String>[
      '${executableDirectory.parent.path}${Platform.pathSeparator}Frameworks'
          '${Platform.pathSeparator}scrcpy_flutter.framework'
          '${Platform.pathSeparator}Resources'
          '${Platform.pathSeparator}scrcpy_flutter_resources.bundle'
          '${Platform.pathSeparator}Contents${Platform.pathSeparator}Resources'
          '${Platform.pathSeparator}adb',
      '${executableDirectory.parent.path}${Platform.pathSeparator}Resources'
          '${Platform.pathSeparator}scrcpy_flutter_resources.bundle'
          '${Platform.pathSeparator}adb',
      '${executableDirectory.parent.path}${Platform.pathSeparator}Resources'
          '${Platform.pathSeparator}adb',
    ],
    _ => const <String>[],
  };
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return candidate;
  }
  return Platform.isWindows ? candidates.first : 'adb';
}

final class _TimeoutSignal {
  const _TimeoutSignal();
}

final class _CancellationSignal {
  const _CancellationSignal();
}
