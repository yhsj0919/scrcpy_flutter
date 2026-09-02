// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:adb_client/adb_client.dart';

enum ScrcpyBatchItemState {
  queued,
  running,
  succeeded,
  failed,
  cancelled,
  timedOut,
}

final class ScrcpyBatchItemResult {
  const ScrcpyBatchItemResult({
    required this.target,
    required this.state,
    required this.attempts,
    this.startedAt,
    this.finishedAt,
    this.error,
  });

  final String target;
  final ScrcpyBatchItemState state;
  final int attempts;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final Object? error;

  ScrcpyBatchItemResult copyWith({
    ScrcpyBatchItemState? state,
    int? attempts,
    DateTime? startedAt,
    DateTime? finishedAt,
    Object? error,
  }) => ScrcpyBatchItemResult(
    target: target,
    state: state ?? this.state,
    attempts: attempts ?? this.attempts,
    startedAt: startedAt ?? this.startedAt,
    finishedAt: finishedAt ?? this.finishedAt,
    error: error,
  );
}

final class ScrcpyBatchSnapshot {
  const ScrcpyBatchSnapshot(this.items);

  final Map<String, ScrcpyBatchItemResult> items;

  int count(ScrcpyBatchItemState state) =>
      items.values.where((item) => item.state == state).length;

  bool get isComplete => items.values.every(
    (item) => switch (item.state) {
      ScrcpyBatchItemState.queued || ScrcpyBatchItemState.running => false,
      _ => true,
    },
  );
}

typedef ScrcpyBatchOperation = Future<void> Function(
  String target,
  AdbCancellationToken cancellationToken,
);

final class ScrcpyBatchTask {
  // A public `operation` name is required; a private initializing formal would
  // make the named argument inaccessible to package consumers.
  ScrcpyBatchTask({
    required List<String> targets,
    required ScrcpyBatchOperation operation,
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
    _items = <String, ScrcpyBatchItemResult>{
      for (final target in targets)
        target: ScrcpyBatchItemResult(
          target: target,
          state: ScrcpyBatchItemState.queued,
          attempts: 0,
        ),
    };
  }

  final List<String> _targets;
  final ScrcpyBatchOperation _operation;
  final int maxConcurrency;
  final Duration itemTimeout;
  final int maxAttempts;
  final _snapshots = StreamController<ScrcpyBatchSnapshot>.broadcast();
  final _activeTokens = <AdbCancellationToken>{};
  late final Map<String, ScrcpyBatchItemResult> _items;
  Future<ScrcpyBatchSnapshot>? _running;
  bool _cancelled = false;
  int _nextIndex = 0;

  Stream<ScrcpyBatchSnapshot> get snapshots => _snapshots.stream;

  ScrcpyBatchSnapshot get current => _snapshot();

  Future<ScrcpyBatchSnapshot> start() => _running ??= _run();

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final token in _activeTokens.toList()) {
      token.cancel();
    }
    for (final target in _targets.skip(_nextIndex)) {
      final item = _items[target]!;
      if (item.state == ScrcpyBatchItemState.queued) {
        _items[target] = item.copyWith(
          state: ScrcpyBatchItemState.cancelled,
          finishedAt: DateTime.now(),
        );
      }
    }
    _emit();
  }

  Future<ScrcpyBatchSnapshot> _run() async {
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
        _finish(target, ScrcpyBatchItemState.cancelled, attempt - 1, startedAt);
        return;
      }
      final token = AdbCancellationToken();
      _activeTokens.add(token);
      _items[target] = _items[target]!.copyWith(
        state: ScrcpyBatchItemState.running,
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
        _finish(target, ScrcpyBatchItemState.succeeded, attempt, startedAt);
        return;
      } on _BatchTimeout catch (error) {
        _activeTokens.remove(token);
        if (attempt == maxAttempts) {
          _finish(
            target,
            ScrcpyBatchItemState.timedOut,
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
            ScrcpyBatchItemState.cancelled,
            attempt,
            startedAt,
            error,
          );
          return;
        }
        if (attempt == maxAttempts) {
          _finish(
            target,
            ScrcpyBatchItemState.failed,
            attempt,
            startedAt,
            error,
          );
          return;
        }
      }
    }
  }

  void _finish(
    String target,
    ScrcpyBatchItemState state,
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

  ScrcpyBatchSnapshot _snapshot() => ScrcpyBatchSnapshot(
    Map<String, ScrcpyBatchItemResult>.unmodifiable(_items),
  );

  void _emit() {
    if (!_snapshots.isClosed) _snapshots.add(_snapshot());
  }
}

final class ScrcpyBatchPackageManager {
  const ScrcpyBatchPackageManager(this._adb);

  final AdbPackageService _adb;

  ScrcpyBatchTask installTask({
    required List<String> deviceSerials,
    required String apkPath,
    bool replaceExisting = false,
    int maxConcurrency = 3,
    Duration itemTimeout = const Duration(minutes: 5),
    int maxAttempts = 1,
  }) => ScrcpyBatchTask(
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

  ScrcpyBatchTask uninstallTask({
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
    return ScrcpyBatchTask(
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
