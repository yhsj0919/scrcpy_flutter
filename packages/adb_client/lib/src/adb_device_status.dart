import 'dart:async';
import 'dart:convert';

import 'adb_client_base.dart';
import 'adb_device_details.dart';

final class AdbDeviceStatus {
  const AdbDeviceStatus({
    required this.observedAt,
    this.cpuUsagePercent,
    this.memoryTotalBytes,
    this.memoryAvailableBytes,
    this.storageTotalBytes,
    this.storageAvailableBytes,
    this.networkReceivedBytes,
    this.networkTransmittedBytes,
    this.batteryLevel,
    this.batteryTemperatureCelsius,
    this.foregroundApplication,
    this.foregroundApplicationPid,
    this.foregroundApplicationCpuPercent,
    this.foregroundApplicationPssBytes,
    this.foregroundApplicationRssBytes,
    this.foregroundApplicationGpuPercent,
    this.foregroundApplicationGpuMemoryBytes,
    this.deviceGpuPercent,
    this.deviceGpuFrequencyHz,
    this.deviceGpuSource,
    this.unavailable = const <String, String>{},
  });

  final DateTime observedAt;
  final double? cpuUsagePercent;
  final int? memoryTotalBytes;
  final int? memoryAvailableBytes;
  final int? storageTotalBytes;
  final int? storageAvailableBytes;
  final int? networkReceivedBytes;
  final int? networkTransmittedBytes;
  final int? batteryLevel;
  final double? batteryTemperatureCelsius;
  final String? foregroundApplication;
  final int? foregroundApplicationPid;
  final double? foregroundApplicationCpuPercent;
  final int? foregroundApplicationPssBytes;
  final int? foregroundApplicationRssBytes;
  final double? foregroundApplicationGpuPercent;
  final int? foregroundApplicationGpuMemoryBytes;
  final double? deviceGpuPercent;
  final int? deviceGpuFrequencyHz;
  final String? deviceGpuSource;
  final Map<String, String> unavailable;
}

final class AdbCpuTimes {
  const AdbCpuTimes({required this.total, required this.idle});

  final int total;
  final int idle;
}

final class AdbDeviceStatusParser {
  const AdbDeviceStatusParser._();

  static AdbCpuTimes? cpuTimes(String output) {
    final line = const LineSplitter()
        .convert(output)
        .where((value) => value.startsWith('cpu '))
        .firstOrNull;
    if (line == null) return null;
    final values = line
        .trim()
        .split(RegExp(r'\s+'))
        .skip(1)
        .map(int.tryParse)
        .toList();
    if (values.length < 4 || values.any((value) => value == null)) return null;
    final total = values.whereType<int>().fold<int>(
      0,
      (sum, value) => sum + value,
    );
    final idle = values[3]! + (values.length > 4 ? values[4]! : 0);
    return AdbCpuTimes(total: total, idle: idle);
  }

  static double? cpuUsage(AdbCpuTimes? previous, AdbCpuTimes? current) {
    if (previous == null || current == null) return null;
    final totalDelta = current.total - previous.total;
    final idleDelta = current.idle - previous.idle;
    if (totalDelta <= 0) return null;
    return ((totalDelta - idleDelta) * 100 / totalDelta).clamp(0, 100);
  }

  static ({int? totalBytes, int? availableBytes}) memory(String output) {
    final values = <String, int>{};
    for (final line in const LineSplitter().convert(output)) {
      final match = RegExp(r'^(MemTotal|MemAvailable):\s*(\d+)\s*kB$')
          .firstMatch(line);
      if (match != null) {
        values[match.group(1)!] = int.parse(match.group(2)!) * 1024;
      }
    }
    return (
      totalBytes: values['MemTotal'],
      availableBytes: values['MemAvailable'],
    );
  }

  static ({int receivedBytes, int transmittedBytes})? network(String output) {
    var received = 0;
    var transmitted = 0;
    var found = false;
    for (final line in const LineSplitter().convert(output)) {
      if (!line.contains(':')) continue;
      final parts = line.split(':');
      final interface = parts.first.trim();
      if (interface == 'lo') continue;
      final fields = parts.sublist(1).join(':').trim().split(RegExp(r'\s+'));
      if (fields.length < 9) continue;
      final rx = int.tryParse(fields[0]);
      final tx = int.tryParse(fields[8]);
      if (rx == null || tx == null) continue;
      received += rx;
      transmitted += tx;
      found = true;
    }
    return found
        ? (receivedBytes: received, transmittedBytes: transmitted)
        : null;
  }

  static String? foregroundApplication(String output) {
    final patterns = <RegExp>[
      RegExp(r'topResumedActivity=.*\su\d+\s+([\w.]+)/(?:[\w.$]+)'),
      RegExp(r'ResumedActivity:.*\su\d+\s+([\w.]+)/(?:[\w.$]+)'),
      RegExp(r'mCurrentFocus=Window\{[^}]*\s([\w.]+)/(?:[\w.$]+)'),
      RegExp(r'mFocusedApp=.*\s([\w.]+)/(?:[\w.$]+)'),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(output);
      if (match != null) return match.group(1);
    }
    return null;
  }

  static int? processCpuTicks(String output) {
    final closingParen = output.lastIndexOf(')');
    if (closingParen < 0) return null;
    final fields = output
        .substring(closingParen + 1)
        .trim()
        .split(RegExp(r'\s+'));
    if (fields.length < 13) return null;
    final userTicks = int.tryParse(fields[11]);
    final systemTicks = int.tryParse(fields[12]);
    return userTicks == null || systemTicks == null
        ? null
        : userTicks + systemTicks;
  }

  static int? processRssBytes(String output) {
    final match = RegExp(
      r'^VmRSS:\s*(\d+)\s*kB$',
      multiLine: true,
    ).firstMatch(output);
    return match == null ? null : int.parse(match.group(1)!) * 1024;
  }

  static int? processUid(String output) {
    final match = RegExp(r'^Uid:\s*(\d+)', multiLine: true).firstMatch(output);
    return match == null ? null : int.parse(match.group(1)!);
  }

  static int? processPssBytes(String output) {
    final summary = RegExp(
      r'TOTAL PSS:\s*(\d+)',
      caseSensitive: false,
    ).firstMatch(output);
    if (summary != null) return int.parse(summary.group(1)!) * 1024;
    final total = RegExp(
      r'^\s*TOTAL\s+(\d+)\s+',
      multiLine: true,
    ).firstMatch(output);
    return total == null ? null : int.parse(total.group(1)!) * 1024;
  }

  static ({int active, int inactive})? gpuWorkForUid(String output, int uid) {
    final pattern = RegExp(
      '^\\s*\\d+\\s+$uid\\s+(\\d+)\\s+(\\d+)\\s*\$',
      multiLine: true,
    );
    final match = pattern.firstMatch(output);
    if (match == null) return null;
    return (
      active: int.parse(match.group(1)!),
      inactive: int.parse(match.group(2)!),
    );
  }

  static int? gpuMemoryForPid(String output, int pid) {
    final match = RegExp(
      '^Proc $pid total:\\s*(\\d+)\\s*\$',
      multiLine: true,
    ).firstMatch(output);
    return match == null ? null : int.parse(match.group(1)!);
  }

  static double? devfreqGpuLoad(String output) {
    final match = RegExp(r'(\d+(?:\.\d+)?)\s*@').firstMatch(output);
    final value = match == null ? null : double.tryParse(match.group(1)!);
    return value?.clamp(0, 100);
  }

  static int? gpuFrequencyHz(String output) {
    final match = RegExp(r'\b(\d{5,})\b').firstMatch(output);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  static ({int busy, int total})? gpuBusyTimes(String output) {
    final values = RegExp(r'\d+')
        .allMatches(output)
        .map((match) => int.parse(match.group(0)!))
        .toList();
    return values.length < 2 ? null : (busy: values[0], total: values[1]);
  }

  static double? maliGpuUtilization(String output) {
    final match = RegExp(r'\d+(?:\.\d+)?').firstMatch(output);
    final value = match == null ? null : double.tryParse(match.group(0)!);
    return value?.clamp(0, 100);
  }
}

final class _ApplicationCpuSample {
  const _ApplicationCpuSample({
    required this.pid,
    required this.processTicks,
    required this.systemTicks,
  });

  final int pid;
  final int processTicks;
  final int systemTicks;
}

final class _ApplicationGpuSample {
  const _ApplicationGpuSample({
    required this.uid,
    required this.active,
    required this.inactive,
    required this.observedAtMicroseconds,
  });

  final int uid;
  final int active;
  final int inactive;
  final int observedAtMicroseconds;
}

final class AdbDeviceStatusMonitor {
  AdbDeviceStatusMonitor({
    required AdbShellService adbShell,
    required this.serial,
    this.interval = const Duration(seconds: 5),
  }) : _adb = adbShell {
    if (interval < const Duration(seconds: 2)) {
      throw ArgumentError.value(
        interval,
        'interval',
        'Minimum interval is 2 seconds',
      );
    }
  }

  final AdbShellService _adb;
  final String serial;
  final Duration interval;
  final _controller = StreamController<AdbDeviceStatus>.broadcast();
  Timer? _timer;
  AdbCpuTimes? _previousCpu;
  _ApplicationCpuSample? _previousApplicationCpu;
  _ApplicationGpuSample? _previousApplicationGpu;
  ({int busy, int total})? _previousDeviceGpuBusy;
  Future<AdbDeviceStatus>? _pendingRefresh;
  bool _closed = false;

  Stream<AdbDeviceStatus> get statuses => _controller.stream;

  Future<AdbDeviceStatus> start() async {
    if (_closed) throw StateError('Monitor is closed');
    _timer ??= Timer.periodic(interval, (_) => unawaited(refresh()));
    return refresh();
  }

  Future<AdbDeviceStatus> refresh() {
    if (_closed) throw StateError('Monitor is closed');
    return _pendingRefresh ??= _performRefresh().whenComplete(
      () => _pendingRefresh = null,
    );
  }

  Future<AdbDeviceStatus> _performRefresh() async {
    final output = <String, String>{};
    final unavailable = <String, String>{};
    Future<void> query(String name, List<String> arguments) async {
      try {
        final result = await _adb.shell(serial, arguments);
        if (!result.isSuccess) {
          unavailable[name] = 'ADB exit code ${result.exitCode}';
        } else {
          output[name] = utf8.decode(result.stdout, allowMalformed: true);
        }
      } catch (error) {
        unavailable[name] = '$error';
      }
    }

    Future<void> optionalQuery(String name, List<String> arguments) async {
      try {
        final result = await _adb.shell(serial, arguments);
        if (result.isSuccess) {
          output[name] = utf8.decode(result.stdout, allowMalformed: true);
        }
      } catch (_) {
        // GPU driver metrics are optional and vendor-dependent.
      }
    }

    await Future.wait(<Future<void>>[
      query('cpu', const <String>['cat', '/proc/stat']),
      query('memory', const <String>['cat', '/proc/meminfo']),
      query('storage', const <String>['df', '-k', '/data']),
      query('network', const <String>['cat', '/proc/net/dev']),
      query('battery', const <String>['dumpsys', 'battery']),
      query('foreground', const <String>['dumpsys', 'activity', 'activities']),
      query('gpu', const <String>['dumpsys', 'gpu']),
      optionalQuery('deviceGpuDevfreqLoad', const <String>[
        'cat',
        '/sys/class/devfreq/*gpu*/load',
      ]),
      optionalQuery('deviceGpuFrequency', const <String>[
        'cat',
        '/sys/class/devfreq/*gpu*/cur_freq',
      ]),
      optionalQuery('deviceGpuKgsl', const <String>[
        'cat',
        '/sys/class/kgsl/kgsl-3d0/gpubusy',
      ]),
      optionalQuery('deviceGpuMali', const <String>[
        'cat',
        '/sys/class/misc/mali0/device/utilization',
      ]),
    ]);
    final cpu = AdbDeviceStatusParser.cpuTimes(output['cpu'] ?? '');
    final cpuUsage = AdbDeviceStatusParser.cpuUsage(_previousCpu, cpu);
    _previousCpu = cpu ?? _previousCpu;
    final memory = AdbDeviceStatusParser.memory(output['memory'] ?? '');
    final storage = AdbDeviceDetailsParser.storage(output['storage'] ?? '');
    final network = AdbDeviceStatusParser.network(output['network'] ?? '');
    final battery = AdbDeviceDetailsParser.battery(output['battery'] ?? '');
    var deviceGpuPercent = AdbDeviceStatusParser.devfreqGpuLoad(
      output['deviceGpuDevfreqLoad'] ?? '',
    );
    String? deviceGpuSource = deviceGpuPercent == null ? null : 'devfreq load';
    deviceGpuPercent ??= AdbDeviceStatusParser.maliGpuUtilization(
      output['deviceGpuMali'] ?? '',
    );
    if (deviceGpuSource == null && deviceGpuPercent != null) {
      deviceGpuSource = 'Mali utilization';
    }
    final kgsl = AdbDeviceStatusParser.gpuBusyTimes(
      output['deviceGpuKgsl'] ?? '',
    );
    final previousKgsl = _previousDeviceGpuBusy;
    if (deviceGpuPercent == null && kgsl != null && previousKgsl != null) {
      final busyDelta = kgsl.busy - previousKgsl.busy;
      final totalDelta = kgsl.total - previousKgsl.total;
      if (busyDelta >= 0 && totalDelta > 0) {
        deviceGpuPercent = (busyDelta * 100 / totalDelta).clamp(0, 100);
        deviceGpuSource = 'Qualcomm KGSL';
      }
    }
    if (kgsl != null) _previousDeviceGpuBusy = kgsl;
    final foreground = AdbDeviceStatusParser.foregroundApplication(
      output['foreground'] ?? '',
    );
    int? foregroundPid;
    int? foregroundPssBytes;
    int? foregroundRssBytes;
    double? foregroundCpuPercent;
    double? foregroundGpuPercent;
    int? foregroundGpuMemoryBytes;
    if (foreground != null) {
      await query('applicationPid', <String>['pidof', '-s', foreground]);
      foregroundPid = int.tryParse(output['applicationPid']?.trim() ?? '');
      if (foregroundPid != null) {
        await Future.wait(<Future<void>>[
          query('applicationCpu', <String>['cat', '/proc/$foregroundPid/stat']),
          query('applicationRss', <String>[
            'cat',
            '/proc/$foregroundPid/status',
          ]),
          query('applicationPss', <String>['dumpsys', 'meminfo', foreground]),
        ]);
        final processTicks = AdbDeviceStatusParser.processCpuTicks(
          output['applicationCpu'] ?? '',
        );
        final previous = _previousApplicationCpu;
        if (processTicks != null && cpu != null) {
          if (previous != null && previous.pid == foregroundPid) {
            final systemDelta = cpu.total - previous.systemTicks;
            final processDelta = processTicks - previous.processTicks;
            if (systemDelta > 0 && processDelta >= 0) {
              foregroundCpuPercent = (processDelta * 100 / systemDelta).clamp(
                0,
                100,
              );
            }
          }
          _previousApplicationCpu = _ApplicationCpuSample(
            pid: foregroundPid,
            processTicks: processTicks,
            systemTicks: cpu.total,
          );
        }
        foregroundRssBytes = AdbDeviceStatusParser.processRssBytes(
          output['applicationRss'] ?? '',
        );
        foregroundPssBytes = AdbDeviceStatusParser.processPssBytes(
          output['applicationPss'] ?? '',
        );
        final uid = AdbDeviceStatusParser.processUid(
          output['applicationRss'] ?? '',
        );
        final gpuWork = uid == null
            ? null
            : AdbDeviceStatusParser.gpuWorkForUid(output['gpu'] ?? '', uid);
        final previousGpu = _previousApplicationGpu;
        final gpuObservedAt = DateTime.now().microsecondsSinceEpoch;
        if (uid != null && gpuWork != null) {
          if (previousGpu != null && previousGpu.uid == uid) {
            final activeDelta = gpuWork.active - previousGpu.active;
            final elapsedNanoseconds =
                (gpuObservedAt - previousGpu.observedAtMicroseconds) * 1000;
            if (activeDelta >= 0 && elapsedNanoseconds > 0) {
              foregroundGpuPercent = (activeDelta * 100 / elapsedNanoseconds)
                  .clamp(0, 100);
            }
          }
          _previousApplicationGpu = _ApplicationGpuSample(
            uid: uid,
            active: gpuWork.active,
            inactive: gpuWork.inactive,
            observedAtMicroseconds: gpuObservedAt,
          );
        }
        foregroundGpuMemoryBytes = AdbDeviceStatusParser.gpuMemoryForPid(
          output['gpu'] ?? '',
          foregroundPid,
        );
      }
    } else {
      _previousApplicationCpu = null;
      _previousApplicationGpu = null;
    }
    final status = AdbDeviceStatus(
      observedAt: DateTime.now(),
      cpuUsagePercent: cpuUsage,
      memoryTotalBytes: memory.totalBytes,
      memoryAvailableBytes: memory.availableBytes,
      storageTotalBytes: storage?.totalBytes,
      storageAvailableBytes: storage?.availableBytes,
      networkReceivedBytes: network?.receivedBytes,
      networkTransmittedBytes: network?.transmittedBytes,
      batteryLevel: battery.level,
      batteryTemperatureCelsius: battery.temperatureCelsius,
      foregroundApplication: foreground,
      foregroundApplicationPid: foregroundPid,
      foregroundApplicationCpuPercent: foregroundCpuPercent,
      foregroundApplicationPssBytes: foregroundPssBytes,
      foregroundApplicationRssBytes: foregroundRssBytes,
      foregroundApplicationGpuPercent: foregroundGpuPercent,
      foregroundApplicationGpuMemoryBytes: foregroundGpuMemoryBytes,
      deviceGpuPercent: deviceGpuPercent,
      deviceGpuFrequencyHz: AdbDeviceStatusParser.gpuFrequencyHz(
        output['deviceGpuFrequency'] ?? '',
      ),
      deviceGpuSource: deviceGpuSource,
      unavailable: Map<String, String>.unmodifiable(unavailable),
    );
    if (!_controller.isClosed) _controller.add(status);
    return status;
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    stop();
    await _controller.close();
  }
}
