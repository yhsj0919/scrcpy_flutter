// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'adb_cancellation_token.dart';
import 'adb_client_base.dart';
import 'adb_exception.dart';

enum AdbBatchItemState {
  queued,
  running,
  succeeded,
  failed,
  cancelled,
  timedOut,
}

final class AdbBatchItemResult {
  const AdbBatchItemResult({
    required this.target,
    required this.state,
    required this.attempts,
    this.startedAt,
    this.finishedAt,
    this.error,
  });

  final String target;
  final AdbBatchItemState state;
  final int attempts;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final Object? error;

  AdbBatchItemResult copyWith({
    AdbBatchItemState? state,
    int? attempts,
    DateTime? startedAt,
    DateTime? finishedAt,
    Object? error,
  }) => AdbBatchItemResult(
    target: target,
    state: state ?? this.state,
    attempts: attempts ?? this.attempts,
    startedAt: startedAt ?? this.startedAt,
    finishedAt: finishedAt ?? this.finishedAt,
    error: error,
  );
}

final class AdbBatchSnapshot {
  const AdbBatchSnapshot(this.items);

  final Map<String, AdbBatchItemResult> items;

  int count(AdbBatchItemState state) =>
      items.values.where((item) => item.state == state).length;

  bool get isComplete => items.values.every(
    (item) => switch (item.state) {
      AdbBatchItemState.queued || AdbBatchItemState.running => false,
      _ => true,
    },
  );
}

typedef AdbBatchOperation = Future<void> Function(
  String target,
  AdbCancellationToken cancellationToken,
);

final class AdbBatchTask {
  // A public `operation` name is required; a private initializing formal would
  // make the named argument inaccessible to package consumers.
  AdbBatchTask({
    required List<String> targets,
    required AdbBatchOperation operation,
    this.maxConcurrency = 3,
    this.itemTimeout = const Duration(minutes: 5),
    this.maxAttempts = 1,
  }) : _targets = List<String>.unmodifiable(targets),
       _operation = operation {
    if (targets.isEmpty) throw ArgumentError.value(targets, 'targets');
    if (targets.toSet().length != targets.length) {
      throw ArgumentError.value(targets, 'targets', 'Targets must be unique');
    }
    if (maxConcurrency < 1) {
      throw RangeError.range(maxConcurrency, 1, null, 'maxConcurrency');
    }
    if (itemTimeout <= Duration.zero) {
      throw ArgumentError.value(itemTimeout, 'itemTimeout');
    }
    if (maxAttempts < 1) {
      throw RangeError.range(maxAttempts, 1, null, 'maxAttempts');
    }
    _items = <String, AdbBatchItemResult>{
      for (final target in targets)
        target: AdbBatchItemResult(
          target: target,
          state: AdbBatchItemState.queued,
          attempts: 0,
        ),
    };
  }

  final List<String> _targets;
  final AdbBatchOperation _operation;
  final int maxConcurrency;
  final Duration itemTimeout;
  final int maxAttempts;
  final _snapshots = StreamController<AdbBatchSnapshot>.broadcast();
  final _activeTokens = <AdbCancellationToken>{};
  late final Map<String, AdbBatchItemResult> _items;
  Future<AdbBatchSnapshot>? _running;
  bool _cancelled = false;
  int _nextIndex = 0;

  Stream<AdbBatchSnapshot> get snapshots => _snapshots.stream;

  AdbBatchSnapshot get current => _snapshot();

  Future<AdbBatchSnapshot> start() => _running ??= _run();

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final token in _activeTokens.toList()) {
      token.cancel();
    }
    for (final target in _targets.skip(_nextIndex)) {
      final item = _items[target]!;
      if (item.state == AdbBatchItemState.queued) {
        _items[target] = item.copyWith(
          state: AdbBatchItemState.cancelled,
          finishedAt: DateTime.now(),
        );
      }
    }
    _emit();
  }

  Future<AdbBatchSnapshot> _run() async {
    _emit();
    final workerCount = maxConcurrency.clamp(1, _targets.length);
    await Future.wait(
      List<Future<void>>.generate(workerCount, (_) => _worker()),
    );
    _emit();
    await _snapshots.close();
    return _snapshot();
  }

  Future<void> _worker() async {
    while (!_cancelled && _nextIndex < _targets.length) {
      final target = _targets[_nextIndex++];
      await _runTarget(target);
    }
  }

  Future<void> _runTarget(String target) async {
    final startedAt = DateTime.now();
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (_cancelled) {
        _finish(target, AdbBatchItemState.cancelled, attempt - 1, startedAt);
        return;
      }
      final token = AdbCancellationToken();
      _activeTokens.add(token);
      _items[target] = _items[target]!.copyWith(
        state: AdbBatchItemState.running,
        attempts: attempt,
        startedAt: startedAt,
      );
      _emit();
      try {
        await _operation(target, token).timeout(
          itemTimeout,
          onTimeout: () {
            token.cancel();
            throw const _BatchTimeout();
          },
        );
        _activeTokens.remove(token);
        _finish(target, AdbBatchItemState.succeeded, attempt, startedAt);
        return;
      } on _BatchTimeout catch (error) {
        _activeTokens.remove(token);
        if (attempt == maxAttempts) {
          _finish(
            target,
            AdbBatchItemState.timedOut,
            attempt,
            startedAt,
            error,
          );
          return;
        }
      } catch (error) {
        _activeTokens.remove(token);
        if (_cancelled ||
            (error is AdbException && error.code == AdbErrorCode.cancelled)) {
          _finish(
            target,
            AdbBatchItemState.cancelled,
            attempt,
            startedAt,
            error,
          );
          return;
        }
        if (attempt == maxAttempts) {
          _finish(target, AdbBatchItemState.failed, attempt, startedAt, error);
          return;
        }
      }
    }
  }

  void _finish(
    String target,
    AdbBatchItemState state,
    int attempts,
    DateTime startedAt, [
    Object? error,
  ]) {
    _items[target] = _items[target]!.copyWith(
      state: state,
      attempts: attempts,
      startedAt: startedAt,
      finishedAt: DateTime.now(),
      error: error,
    );
    _emit();
  }

  AdbBatchSnapshot _snapshot() =>
      AdbBatchSnapshot(Map<String, AdbBatchItemResult>.unmodifiable(_items));

  void _emit() {
    if (!_snapshots.isClosed) _snapshots.add(_snapshot());
  }
}

final class AdbBatchPackageManager {
  const AdbBatchPackageManager(this._adb);

  final AdbPackageService _adb;

  AdbBatchTask installTask({
    required List<String> deviceSerials,
    required String apkPath,
    bool replaceExisting = false,
    int maxConcurrency = 3,
    Duration itemTimeout = const Duration(minutes: 5),
    int maxAttempts = 1,
  }) => AdbBatchTask(
    targets: deviceSerials,
    maxConcurrency: maxConcurrency,
    itemTimeout: itemTimeout,
    maxAttempts: maxAttempts,
    operation: (serial, token) => _adb.install(
      serial,
      apkPath,
      replaceExisting: replaceExisting,
      cancellationToken: token,
    ),
  );

  AdbBatchTask uninstallTask({
    required List<String> deviceSerials,
    required String packageName,
    bool keepData = false,
    int maxConcurrency = 3,
    Duration itemTimeout = const Duration(minutes: 1),
    int maxAttempts = 1,
  }) {
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+$')
        .hasMatch(packageName)) {
      throw ArgumentError.value(packageName, 'packageName');
    }
    return AdbBatchTask(
      targets: deviceSerials,
      maxConcurrency: maxConcurrency,
      itemTimeout: itemTimeout,
      maxAttempts: maxAttempts,
      operation: (serial, token) => _adb.uninstall(
        serial,
        packageName,
        keepData: keepData,
        cancellationToken: token,
      ),
    );
  }
}

final class _BatchTimeout implements Exception {
  const _BatchTimeout();

  @override
  String toString() => 'Batch item timed out';
}
