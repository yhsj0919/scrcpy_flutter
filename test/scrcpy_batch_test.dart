import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:scrcpy_flutter/scrcpy_flutter.dart';

void main() {
  test('limits concurrency and isolates partial failure', () async {
    var running = 0;
    var peak = 0;
    final task = ScrcpyBatchTask(
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
    expect(result.count(ScrcpyBatchItemState.succeeded), 3);
    expect(result.count(ScrcpyBatchItemState.failed), 1);
    expect(result.items['c']!.error, isA<StateError>());
  });

  test('retries failures and reports timeout', () async {
    final attempts = <String, int>{};
    final task = ScrcpyBatchTask(
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

    expect(result.items['retry']!.state, ScrcpyBatchItemState.succeeded);
    expect(result.items['retry']!.attempts, 2);
    expect(result.items['timeout']!.state, ScrcpyBatchItemState.timedOut);
    expect(result.items['timeout']!.attempts, 2);
  });

  test('cancel stops running work and cancels queued targets', () async {
    final started = Completer<void>();
    final task = ScrcpyBatchTask(
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

    expect(result.items['running']!.state, ScrcpyBatchItemState.cancelled);
    expect(result.items['queued']!.state, ScrcpyBatchItemState.cancelled);
  });

  test('package tasks forward safe install and uninstall options', () async {
    final adb = _FakePackageService();
    final manager = ScrcpyBatchPackageManager(adb);

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
