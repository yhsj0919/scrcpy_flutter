import 'dart:async';

import 'package:flutter/services.dart';

import 'scrcpy_input.dart';

abstract interface class ScrcpyHostClipboard {
  Future<String?> readText();

  Future<void> writeText(String text);
}

final class FlutterScrcpyHostClipboard implements ScrcpyHostClipboard {
  const FlutterScrcpyHostClipboard();

  @override
  Future<String?> readText() async =>
      (await Clipboard.getData(Clipboard.kTextPlain))?.text;

  @override
  Future<void> writeText(String text) =>
      Clipboard.setData(ClipboardData(text: text));
}

/// Optional bidirectional clipboard synchronization for a scrcpy session.
///
/// The embedded server runs with its own clipboard autosync disabled so that
/// explicit reads are deterministic. Flutter does not expose a portable host
/// clipboard change stream, therefore both sides are checked at [pollInterval].
final class ScrcpyClipboardSynchronizer {
  ScrcpyClipboardSynchronizer(
    this.controller, {
    this.hostClipboard = const FlutterScrcpyHostClipboard(),
    this.pollInterval = const Duration(milliseconds: 500),
    this.onError,
  });

  final ScrcpyInputController controller;
  final Duration pollInterval;
  final void Function(Object error, StackTrace stackTrace)? onError;
  final ScrcpyHostClipboard hostClipboard;

  StreamSubscription<String>? _deviceSubscription;
  Timer? _timer;
  Future<void> _operations = Future<void>.value();
  String? _lastHostText;
  String? _lastSentToDevice;
  String? _lastWrittenFromDevice;

  bool get isRunning => _deviceSubscription != null;

  Future<void> start() async {
    if (isRunning) return;
    if (pollInterval <= Duration.zero) {
      throw ArgumentError.value(
        pollInterval,
        'pollInterval',
        'must be greater than zero',
      );
    }
    _lastHostText = await hostClipboard.readText();
    _deviceSubscription = controller.clipboardChanges.listen(
      (text) => _queue(() => _applyDeviceText(text)),
      onError: (Object error, StackTrace stackTrace) =>
          onError?.call(error, stackTrace),
    );
    _timer = Timer.periodic(pollInterval, (_) => _queue(_pollHost));
    await controller.requestClipboard();
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    final subscription = _deviceSubscription;
    _deviceSubscription = null;
    await subscription?.cancel();
    await _operations;
  }

  Future<void> pushHostToDevice({bool paste = false}) async {
    final text = await hostClipboard.readText();
    if (text == null) return;
    _lastHostText = text;
    _lastSentToDevice = text;
    await controller.setClipboard(text, paste: paste);
  }

  Future<String> pullDeviceToHost({
    ScrcpyCopyKey copyKey = ScrcpyCopyKey.none,
  }) async {
    final next = controller.clipboardChanges.first.timeout(
      const Duration(seconds: 3),
    );
    await controller.requestClipboard(copyKey: copyKey);
    final text = await next;
    await _applyDeviceText(text);
    return text;
  }

  void _queue(Future<void> Function() operation) {
    _operations = _operations.then((_) => operation()).catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      onError?.call(error, stackTrace);
    });
  }

  Future<void> _pollHost() async {
    final text = await hostClipboard.readText();
    if (text != null && text != _lastHostText) {
      _lastHostText = text;
      if (text != _lastWrittenFromDevice) {
        _lastSentToDevice = text;
        await controller.setClipboard(text);
      }
    }
    await controller.requestClipboard();
  }

  Future<void> _applyDeviceText(String text) async {
    if (text == _lastSentToDevice || text == _lastWrittenFromDevice) return;
    _lastWrittenFromDevice = text;
    _lastHostText = text;
    await hostClipboard.writeText(text);
  }
}
