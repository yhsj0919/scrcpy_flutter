import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:scrcpy_flutter/scrcpy_flutter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('reads basic details from a connected USB device', (_) async {
    final client = createDefaultScrcpyClient();
    final devices = await client.discoverDevices();
    final device = devices.where((candidate) {
      return candidate.isReady &&
          candidate.connectionType == AdbConnectionType.usb;
    }).first;

    final details = await client.getDeviceDetails(device);

    expect(details.model, isNotEmpty);
    expect(details.androidVersion, isNotEmpty);
    expect(details.sdkLevel, greaterThan(0));
    expect(details.abi, isNotEmpty);
    expect(details.screenWidth, greaterThan(0));
    expect(details.screenHeight, greaterThan(0));
    expect(details.densityDpi, greaterThan(0));
    expect(details.batteryLevel, inInclusiveRange(0, 100));
    expect(details.storageTotalBytes, greaterThan(0));
    expect(details.storageAvailableBytes, greaterThanOrEqualTo(0));
    expect(details.uptime, greaterThan(Duration.zero));

    // Useful evidence in the integration-test output without exposing serial.
    // ignore: avoid_print
    print(
      'device details: ${device.redactedSerial} '
      '${details.manufacturer} ${details.model}, '
      'Android ${details.androidVersion} SDK ${details.sdkLevel}, '
      '${details.abi}, ${details.screenWidth}x${details.screenHeight} '
      '${details.densityDpi}dpi, battery ${details.batteryLevel}%, '
      'unavailable=${details.unavailable.keys.toList()}',
    );
  });
}
