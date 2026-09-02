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

  testWidgets('starts and stops a launcher application on the main display', (
    _,
  ) async {
    final client = createDefaultScrcpyClient();
    final readyDevices = (await client.adbToolkit.discoverDevices())
        .where((candidate) => candidate.isReady)
        .toList();
    final usbDevices = readyDevices
        .where((candidate) => candidate.connectionType == AdbConnectionType.usb)
        .toList();
    final device = usbDevices.isNotEmpty
        ? usbDevices.first
        : readyDevices.first;
    final manager = client.adbToolkit.applications(device.serial);
    final applications = await manager.listApplications();
    final candidates = applications.where(
      (application) =>
          application.enabled &&
          application.launchable &&
          application.packageName != 'com.android.settings',
    );
    final application =
        candidates
            .where(
              (candidate) => candidate.packageName == 'com.android.calculator2',
            )
            .firstOrNull ??
        candidates.first;

    await manager.startApplication(
      application.packageName,
      forceStopFirst: true,
    );
    final shell = client.adbClient as AdbShellService;
    final resumed = await shell.shell(device.serial, const <String>[
      'dumpsys',
      'activity',
      'activities',
    ]);
    expect(resumed.isSuccess, isTrue);
    expect(
      utf8.decode(resumed.stdout, allowMalformed: true),
      contains(application.packageName),
    );

    await manager.stopApplication(application.packageName);

    final noLauncher = applications
        .where(
          (candidate) =>
              !candidate.launchable && candidate.packageName != 'android',
        )
        .first;
    await expectLater(
      manager.startApplication(noLauncher.packageName),
      throwsA(isA<AdbApplicationOperationException>()),
    );

    // ignore: avoid_print
    print(
      'application control: ${device.redactedSerial}, '
      'started/stopped ${application.packageName}, '
      'rejected ${noLauncher.packageName}',
    );
  });
}
