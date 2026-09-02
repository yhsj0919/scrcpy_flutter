import 'dart:async';

import 'package:test/test.dart';
import 'package:adb_client/adb_client.dart';

void main() {
  test('limits concurrency and isolates partial failure', () async {
    var running = 0;
    var peak = 0;
    final task = AdbBatchTask(
      targets: const <String>['a', 'b', 'c', 'd'],
      maxConcurrency: 2,
      operation: (target, _) async {
        running++;
        peak = running > peak ? running : peak;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        running--;
        if (target == 'c') throw StateError('injected failure');
      },
    );

    final result = await task.start();

    expect(peak, 2);
    expect(result.count(AdbBatchItemState.succeeded), 3);
    expect(result.count(AdbBatchItemState.failed), 1);
    expect(result.items['c']!.error, isA<StateError>());
  });

  test('retries failures and reports timeout', () async {
    final attempts = <String, int>{};
    final task = AdbBatchTask(
      targets: const <String>['retry', 'timeout'],
      maxConcurrency: 1,
      maxAttempts: 2,
      itemTimeout: const Duration(milliseconds: 20),
      operation: (target, token) async {
        attempts[target] = (attempts[target] ?? 0) + 1;
        if (target == 'retry' && attempts[target] == 1) {
          throw StateError('first attempt');
        }
        if (target == 'timeout') {
          await token.whenCancelled;
          throw const AdbException(AdbErrorCode.cancelled, 'cancelled');
        }
      },
    );

    final result = await task.start();

    expect(result.items['retry']!.state, AdbBatchItemState.succeeded);
    expect(result.items['retry']!.attempts, 2);
    expect(result.items['timeout']!.state, AdbBatchItemState.timedOut);
    expect(result.items['timeout']!.attempts, 2);
  });

  test('cancel stops running work and cancels queued targets', () async {
    final started = Completer<void>();
    final task = AdbBatchTask(
      targets: const <String>['running', 'queued'],
      maxConcurrency: 1,
      operation: (_, token) async {
        if (!started.isCompleted) started.complete();
        await token.whenCancelled;
        throw const AdbException(AdbErrorCode.cancelled, 'cancelled');
      },
    );

    final completion = task.start();
    await started.future;
    task.cancel();
    final result = await completion;

    expect(result.items['running']!.state, AdbBatchItemState.cancelled);
    expect(result.items['queued']!.state, AdbBatchItemState.cancelled);
  });

  test('package tasks forward safe install and uninstall options', () async {
    final adb = _FakePackageService();
    final manager = AdbBatchPackageManager(adb);

    await manager
        .installTask(
          deviceSerials: const <String>['a', 'b'],
          apkPath: r'C:\test app.apk',
          replaceExisting: true,
        )
        .start();
    await manager
        .uninstallTask(
          deviceSerials: const <String>['a'],
          packageName: 'com.example.app',
          keepData: true,
        )
        .start();

    expect(adb.installs, <String>['a:true', 'b:true']);
    expect(adb.uninstalls, <String>['a:com.example.app:true']);
    expect(
      () => manager.uninstallTask(
        deviceSerials: const <String>['a'],
        packageName: 'bad;package',
      ),
      throwsArgumentError,
    );
  });
}

final class _FakePackageService implements AdbPackageService {
  final installs = <String>[];
  final uninstalls = <String>[];

  @override
  Future<void> install(
    String serial,
    String apkPath, {
    bool replaceExisting = false,
    AdbCancellationToken? cancellationToken,
  }) async => installs.add('$serial:$replaceExisting');

  @override
  Future<void> uninstall(
    String serial,
    String packageName, {
    bool keepData = false,
    AdbCancellationToken? cancellationToken,
  }) async => uninstalls.add('$serial:$packageName:$keepData');
}
