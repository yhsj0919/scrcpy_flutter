import 'dart:async';

import 'adb_mdns_service.dart';
import 'adb_toolkit.dart';

final class AdbMdnsSnapshot {
  const AdbMdnsSnapshot({
    required this.services,
    required this.added,
    required this.removed,
    required this.observedAt,
  });

  final List<AdbMdnsService> services;
  final List<AdbMdnsService> added;
  final List<AdbMdnsService> removed;
  final DateTime observedAt;
}

extension AdbMdnsWatching on AdbToolkit {
  /// Continuously discovers Wireless Debugging pairing and connect services.
  ///
  /// Unsupported platforms may return an empty discovery result. The stream
  /// starts on listen and releases its polling timer when cancelled.
  Stream<AdbMdnsSnapshot> watchMdnsServices({
    Duration interval = const Duration(seconds: 3),
    bool emitOnlyChanges = true,
  }) {
    if (interval <= Duration.zero) {
      throw ArgumentError.value(interval, 'interval', 'must be positive');
    }
    late final StreamController<AdbMdnsSnapshot> controller;
    Timer? timer;
    var previous = <String, AdbMdnsService>{};
    var refreshing = false;
    var emittedInitial = false;

    Future<void> refresh() async {
      if (refreshing || controller.isClosed) return;
      refreshing = true;
      try {
        final discovered = await discoverMdnsServices();
        if (controller.isClosed) return;
        final current = <String, AdbMdnsService>{
          for (final service in discovered) _serviceKey(service): service,
        };
        final added = <AdbMdnsService>[
          for (final entry in current.entries)
            if (!previous.containsKey(entry.key)) entry.value,
        ];
        final removed = <AdbMdnsService>[
          for (final entry in previous.entries)
            if (!current.containsKey(entry.key)) entry.value,
        ];
        previous = current;
        if (!emittedInitial ||
            !emitOnlyChanges ||
            added.isNotEmpty ||
            removed.isNotEmpty) {
          emittedInitial = true;
          controller.add(
            AdbMdnsSnapshot(
              services: List.unmodifiable(current.values),
              added: List.unmodifiable(added),
              removed: List.unmodifiable(removed),
              observedAt: DateTime.now(),
            ),
          );
        }
      } catch (error, stackTrace) {
        if (!controller.isClosed) controller.addError(error, stackTrace);
      } finally {
        refreshing = false;
      }
    }

    controller = StreamController<AdbMdnsSnapshot>(
      onListen: () {
        unawaited(refresh());
        timer = Timer.periodic(interval, (_) => unawaited(refresh()));
      },
      onCancel: () {
        timer?.cancel();
        timer = null;
      },
    );
    return controller.stream;
  }
}

String _serviceKey(AdbMdnsService service) =>
    '${service.type.name}:${service.name}:${service.endpoint.authority}';
