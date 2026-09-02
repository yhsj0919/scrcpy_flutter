import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:adb_client/adb_client.dart';
import 'package:scrcpy_flutter/scrcpy_flutter.dart';

extension on ScrcpyClient {
  AdbToolkit get adbToolkit => AdbToolkit(adbClient);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('isolates an unavailable device from a real device operation', (
    _,
  ) async {
    final client = createDefaultScrcpyClient();
    final device = (await client.adbToolkit.discoverDevices())
        .where((candidate) => candidate.isReady)
        .first;
    final shell = client.adbClient as AdbShellService;
    const unavailable = 'scrcpy-flutter-missing-device';
    final task = AdbBatchTask(
      targets: <String>[device.serial, unavailable],
      maxConcurrency: 2,
      itemTimeout: const Duration(seconds: 10),
      operation: (serial, token) async {
        final result = await shell.shell(serial, const <String>[
          'echo',
          'scrcpy-batch-probe',
        ], cancellationToken: token);
        if (!result.isSuccess ||
            !utf8.decode(result.stdout).contains('scrcpy-batch-probe')) {
          throw AdbException(
            AdbErrorCode.commandFailed,
            'Read-only batch probe failed',
            exitCode: result.exitCode,
          );
        }
      },
    );

    final result = await task.start();

    expect(result.items[device.serial]!.state, AdbBatchItemState.succeeded);
    expect(result.items[unavailable]!.state, AdbBatchItemState.failed);
    expect(result.isComplete, isTrue);
    // ignore: avoid_print
    print(
      'batch isolation: ${device.redactedSerial}=succeeded, '
      'missing-device=failed',
    );
  });
}
