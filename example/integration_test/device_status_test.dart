import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:scrcpy_flutter/scrcpy_flutter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('samples current device runtime status', (_) async {
    final client = createDefaultScrcpyClient();
    final device = (await client.discoverDevices())
        .where((candidate) => candidate.isReady)
        .first;
    final monitor = client.createDeviceStatusMonitor(device.serial);
    try {
      await monitor.start();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final status = await monitor.refresh();

      expect(status.cpuUsagePercent, inInclusiveRange(0, 100));
      expect(status.memoryTotalBytes, greaterThan(0));
      expect(status.memoryAvailableBytes, greaterThan(0));
      expect(status.storageTotalBytes, greaterThan(0));
      expect(status.storageAvailableBytes, greaterThanOrEqualTo(0));
      expect(status.networkReceivedBytes, greaterThanOrEqualTo(0));
      expect(status.networkTransmittedBytes, greaterThanOrEqualTo(0));
      expect(status.batteryLevel, inInclusiveRange(0, 100));
      expect(status.deviceGpuPercent, inInclusiveRange(0, 100));
      expect(status.deviceGpuFrequencyHz, greaterThan(0));
      expect(status.deviceGpuSource, isNotEmpty);
      expect(status.foregroundApplication, isNotEmpty);
      expect(status.foregroundApplicationPid, greaterThan(0));
      expect(status.foregroundApplicationCpuPercent, inInclusiveRange(0, 100));
      expect(status.foregroundApplicationPssBytes, greaterThan(0));
      expect(status.foregroundApplicationRssBytes, greaterThan(0));
      expect(status.foregroundApplicationGpuPercent, inInclusiveRange(0, 100));
      expect(status.foregroundApplicationGpuMemoryBytes, greaterThan(0));

      // ignore: avoid_print
      print(
        'device status: ${device.redactedSerial}, '
        'cpu=${status.cpuUsagePercent?.toStringAsFixed(1)}%, '
        'memory=${status.memoryAvailableBytes}/${status.memoryTotalBytes}, '
        'network=${status.networkReceivedBytes}/${status.networkTransmittedBytes}, '
        'foreground=${status.foregroundApplication}, '
        'pid=${status.foregroundApplicationPid}, '
        'appCpu=${status.foregroundApplicationCpuPercent?.toStringAsFixed(1)}%, '
        'pss=${status.foregroundApplicationPssBytes}, '
        'rss=${status.foregroundApplicationRssBytes}, '
        'gpu=${status.foregroundApplicationGpuPercent?.toStringAsFixed(1)}%, '
        'gpuMemory=${status.foregroundApplicationGpuMemoryBytes}, '
        'deviceGpu=${status.deviceGpuPercent?.toStringAsFixed(1)}%, '
        'deviceGpuFrequency=${status.deviceGpuFrequencyHz}, '
        'deviceGpuSource=${status.deviceGpuSource}, '
        'unavailable=${status.unavailable.keys.toList()}',
      );
    } finally {
      await monitor.close();
    }
  });
}
