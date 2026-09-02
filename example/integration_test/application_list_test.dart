import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:adb_client/adb_client.dart';
import 'package:scrcpy_flutter/scrcpy_flutter.dart';

extension on ScrcpyClient {
  AdbToolkit get adbToolkit => AdbToolkit(adbClient);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('lists installed applications from a connected device', (
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
    final stopwatch = Stopwatch()..start();

    final applications = await client.listApplications(device.serial);
    stopwatch.stop();

    expect(applications, isNotEmpty);
    expect(
      applications.map((application) => application.packageName),
      contains('android'),
    );
    expect(
      applications.every(
        (application) =>
            application.name.isNotEmpty && application.packageName.isNotEmpty,
      ),
      isTrue,
    );
    expect(
      applications.any(
        (application) => application.type == AdbApplicationType.system,
      ),
      isTrue,
    );
    expect(
      applications.any(
        (application) => application.type == AdbApplicationType.user,
      ),
      isTrue,
    );
    expect(
      applications.any(
        (application) =>
            application.launchable && application.name != application.packageName,
      ),
      isTrue,
      reason: 'scrcpy should resolve at least one localized app label',
    );

    // ignore: avoid_print
    print(
      'application list: ${device.redactedSerial}, '
      '${applications.length} packages, '
      '${applications.where((app) => app.type == AdbApplicationType.user).length} user, '
      '${applications.where((app) => app.launchable).length} launchable, '
      '${stopwatch.elapsedMilliseconds} ms',
    );
  });
}
