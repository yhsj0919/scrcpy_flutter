import 'dart:async';

import 'package:adb_client/adb_client.dart';

import 'scrcpy_client.dart';

final class ScrcpyDeviceSnapshot {
  const ScrcpyDeviceSnapshot({
    required this.devices,
    required this.added,
    required this.removed,
    required this.changed,
    required this.observedAt,
  });

  final List<AdbDevice> devices;
  final List<AdbDevice> added;
  final List<AdbDevice> removed;
  final List<AdbDevice> changed;
  final DateTime observedAt;
}

/// Polling device monitor built on the public ADB boundary.
///
/// Polling is used instead of owning a second long-running `adb track-devices`
/// process, which keeps the monitor portable across future ADB backends.
final class ScrcpyDeviceMonitor {
  ScrcpyDeviceMonitor(
    this.client, {
    this.interval = const Duration(seconds: 2),
  });

  final ScrcpyClient client;
  final Duration interval;
  final StreamController<ScrcpyDeviceSnapshot> _controller =
      StreamController<ScrcpyDeviceSnapshot>.broadcast();

  Timer? _timer;
  Map<String, AdbDevice> _previous = const <String, AdbDevice>{};
  Future<ScrcpyDeviceSnapshot>? _refreshing;
  bool _closed = false;

  Stream<ScrcpyDeviceSnapshot> get snapshots => _controller.stream;

  bool get isRunning => _timer != null;

  Future<ScrcpyDeviceSnapshot> start() async {
    if (_closed) throw StateError('Device monitor has been closed');
    if (interval <= Duration.zero) {
      throw ArgumentError.value(interval, 'interval', 'must be positive');
    }
    final initial = await refresh();
    _timer ??= Timer.periodic(interval, (_) => _poll());
    return initial;
  }

  Future<ScrcpyDeviceSnapshot> refresh() =>
      _refreshing ??= _refresh().whenComplete(() => _refreshing = null);

  Future<ScrcpyDeviceSnapshot> _refresh() async {
    if (_closed) throw StateError('Device monitor has been closed');
    final devices = await client.discoverDevices();
    final current = <String, AdbDevice>{
      for (final device in devices) device.serial: device,
    };
    final added = <AdbDevice>[];
    final removed = <AdbDevice>[];
    final changed = <AdbDevice>[];
    for (final entry in current.entries) {
      final previous = _previous[entry.key];
      if (previous == null) {
        added.add(entry.value);
      } else if (!_sameDevice(previous, entry.value)) {
        changed.add(entry.value);
      }
    }
    for (final entry in _previous.entries) {
      if (!current.containsKey(entry.key)) removed.add(entry.value);
    }
    _previous = current;
    final snapshot = ScrcpyDeviceSnapshot(
      devices: List.unmodifiable(devices),
      added: List.unmodifiable(added),
      removed: List.unmodifiable(removed),
      changed: List.unmodifiable(changed),
      observedAt: DateTime.now(),
    );
    if (!_closed) _controller.add(snapshot);
    return snapshot;
  }

  void _poll() => unawaited(_pollSafely());

  Future<void> _pollSafely() async {
    try {
      await refresh();
    } catch (error, stackTrace) {
      if (!_closed) _controller.addError(error, stackTrace);
    }
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _refreshing;
  }

  Future<void> close() async {
    if (_closed) return;
    await stop();
    _closed = true;
    await _controller.close();
  }

  static bool _sameDevice(AdbDevice a, AdbDevice b) =>
      a.state == b.state &&
      a.connectionType == b.connectionType &&
      a.model == b.model &&
      _sameAttributes(a.attributes, b.attributes);

  static bool _sameAttributes(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }
}
