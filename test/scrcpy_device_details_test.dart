import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:scrcpy_flutter/scrcpy_flutter.dart';

final class _DetailsAdbClient implements AdbDeviceService, AdbShellService {
  _DetailsAdbClient(this.outputs);

  final Map<String, AdbCommandResult> outputs;

  @override
  Future<List<AdbDevice>> listDevices({
    AdbCancellationToken? cancellationToken,
  }) async => const <AdbDevice>[];

  @override
  Future<AdbCommandResult> shell(
    String serial,
    List<String> arguments, {
    AdbCancellationToken? cancellationToken,
  }) async => outputs[arguments.join(' ')] ?? _result('', exitCode: 1);
}

AdbCommandResult _result(String output, {int exitCode = 0}) => AdbCommandResult(
  exitCode: exitCode,
  stdout: utf8.encode(output),
  stderr: const <int>[],
  elapsed: Duration.zero,
);

void main() {
  test('device detail parsers prefer active screen overrides', () {
    expect(
      ScrcpyDeviceDetailsParser.screenSize(
        'Physical size: 1440x3200\nOverride size: 1080x2400\n',
      ),
      (1080, 2400),
    );
    expect(
      ScrcpyDeviceDetailsParser.density(
        'Physical density: 560\nOverride density: 420\n',
      ),
      420,
    );
    final battery = ScrcpyDeviceDetailsParser.battery(
      '  level: 42\n  scale: 100\n  temperature: 315\n',
    );
    expect(battery.level, 42);
    expect(battery.temperatureCelsius, 31.5);
    expect(
      ScrcpyDeviceDetailsParser.storage(
        'Filesystem 1K-blocks Used Available Use% Mounted on\n'
        '/dev/block/dm-8 100000 40000 60000 40% /data\n',
      ),
      (totalBytes: 102400000, availableBytes: 61440000),
    );
    expect(
      ScrcpyDeviceDetailsParser.uptime('90061.25 123.00\n'),
      const Duration(milliseconds: 90061250),
    );
  });

  test('collects available details when one query fails', () async {
    final adb = _DetailsAdbClient(<String, AdbCommandResult>{
      'getprop': _result(
        '[ro.product.brand]: [google]\n'
        '[ro.product.manufacturer]: [Google]\n'
        '[ro.product.model]: [Pixel Test]\n'
        '[ro.build.version.release]: [16]\n'
        '[ro.build.version.sdk]: [36]\n'
        '[ro.product.cpu.abi]: [arm64-v8a]\n',
      ),
      'wm size': _result('Physical size: 1080x2400\n'),
      'wm density': _result('', exitCode: 2),
      'dumpsys battery': _result('level: 80\nscale: 100\n'),
      'df -k /data': _result('/dev/block/dm-8 200000 50000 150000 25% /data\n'),
      'cat /proc/uptime': _result('3600.5 10.0\n'),
    });
    final details = await ScrcpyClient(adbClient: adb).getDeviceDetails(
      const AdbDevice(
        serial: 'secret-serial',
        state: AdbDeviceState.device,
        connectionType: AdbConnectionType.usb,
      ),
    );

    expect(details.model, 'Pixel Test');
    expect(details.androidVersion, '16');
    expect(details.sdkLevel, 36);
    expect(details.screenWidth, 1080);
    expect(details.batteryLevel, 80);
    expect(details.storageAvailableBytes, 153600000);
    expect(details.uptime, const Duration(milliseconds: 3600500));
    expect(details.densityDpi, isNull);
    expect(details.unavailable, contains('density'));
    expect(details.unavailable, hasLength(1));
  });
}
