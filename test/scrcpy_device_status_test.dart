import 'package:flutter_test/flutter_test.dart';
import 'package:scrcpy_flutter/scrcpy_flutter.dart';

void main() {
  test('parses CPU deltas memory network and foreground application', () {
    final previous = ScrcpyDeviceStatusParser.cpuTimes(
      'cpu  100 10 20 870 0 0 0 0\n',
    );
    final current = ScrcpyDeviceStatusParser.cpuTimes(
      'cpu  130 10 30 930 0 0 0 0\n',
    );
    expect(ScrcpyDeviceStatusParser.cpuUsage(previous, current), 40);

    final memory = ScrcpyDeviceStatusParser.memory(
      'MemTotal:        8000000 kB\nMemAvailable:    3000000 kB\n',
    );
    expect(memory.totalBytes, 8192000000);
    expect(memory.availableBytes, 3072000000);

    final network = ScrcpyDeviceStatusParser.network(
      'Inter-| Receive | Transmit\n'
      ' lo: 100 0 0 0 0 0 0 0 100 0 0 0 0 0 0 0\n'
      ' wlan0: 2000 1 0 0 0 0 0 0 3000 1 0 0 0 0 0 0\n'
      ' rmnet0: 4000 1 0 0 0 0 0 0 5000 1 0 0 0 0 0 0\n',
    );
    expect(network?.receivedBytes, 6000);
    expect(network?.transmittedBytes, 8000);

    expect(
      ScrcpyDeviceStatusParser.foregroundApplication(
        'mCurrentFocus=Window{abc u0 com.example.app/.MainActivity}',
      ),
      'com.example.app',
    );
    expect(
      ScrcpyDeviceStatusParser.foregroundApplication(
        'topResumedActivity=ActivityRecord{abc u0 com.android.settings/.Settings t1}',
      ),
      'com.android.settings',
    );
    expect(
      ScrcpyDeviceStatusParser.processCpuTicks(
        '123 (test app) S 1 2 3 4 5 6 7 8 9 10 120 30 0 0 0',
      ),
      150,
    );
    expect(
      ScrcpyDeviceStatusParser.processRssBytes(
        'Name:\ttest\nVmRSS:\t  12345 kB\n',
      ),
      12641280,
    );
    expect(
      ScrcpyDeviceStatusParser.processPssBytes(
        'App Summary\nTOTAL PSS: 54321\n',
      ),
      55624704,
    );
    const processStatus = 'Name:\ttest\nUid:\t10123 10123 10123 10123\n';
    expect(ScrcpyDeviceStatusParser.processUid(processStatus), 10123);
    const gpu =
        'Memory snapshot for GPU 0:\n'
        'Proc 123 total: 456789\n'
        'GPU work information.\n'
        'gpu_id uid total_active_duration_ns total_inactive_duration_ns\n'
        '0 10123 800 200\n';
    expect(ScrcpyDeviceStatusParser.gpuWorkForUid(gpu, 10123), (
      active: 800,
      inactive: 200,
    ));
    expect(ScrcpyDeviceStatusParser.gpuMemoryForPid(gpu, 123), 456789);
    expect(ScrcpyDeviceStatusParser.devfreqGpuLoad('37@600000000Hz\n'), 37);
    expect(ScrcpyDeviceStatusParser.gpuFrequencyHz('600000000\n'), 600000000);
    expect(ScrcpyDeviceStatusParser.gpuBusyTimes('1200 4000\n'), (
      busy: 1200,
      total: 4000,
    ));
    expect(
      ScrcpyDeviceStatusParser.maliGpuUtilization('utilization: 42\n'),
      42,
    );
  });

  test('rejects polling intervals below two seconds', () {
    expect(
      () => ScrcpyDeviceStatusMonitor(
        adbShell: _UnusedShell(),
        serial: 'device',
        interval: const Duration(seconds: 1),
      ),
      throwsArgumentError,
    );
  });
}

final class _UnusedShell implements AdbShellService {
  @override
  Future<AdbCommandResult> shell(
    String serial,
    List<String> arguments, {
    AdbCancellationToken? cancellationToken,
  }) => throw UnimplementedError();
}
