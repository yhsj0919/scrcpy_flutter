import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:scrcpy_flutter/scrcpy_advanced.dart';

final class _FakeHostClipboard implements ScrcpyHostClipboard {
  String? text;
  int writes = 0;

  @override
  Future<String?> readText() async => text;

  @override
  Future<void> writeText(String text) async {
    this.text = text;
    writes++;
  }
}

final class _FakeClipboardInput implements ScrcpyInputController {
  final StreamController<String> device = StreamController<String>.broadcast();
  final List<(String, bool)> sets = <(String, bool)>[];
  final List<ScrcpyCopyKey> requests = <ScrcpyCopyKey>[];

  @override
  Stream<String> get clipboardChanges => device.stream;

  @override
  Future<void> requestClipboard({
    ScrcpyCopyKey copyKey = ScrcpyCopyKey.none,
  }) async {
    requests.add(copyKey);
  }

  @override
  Future<void> setClipboard(String text, {bool paste = false}) async {
    sets.add((text, paste));
  }

  @override
  Future<void> sendKey({required int keyCode, bool down = true}) async {}

  @override
  Future<void> sendPointer(ScrcpyPointerEvent event) async {}

  @override
  Future<void> sendText(String text) async {}

  @override
  Future<void> startApplication(ScrcpyApplicationLaunch application) async {}

  @override
  Future<void> resizeDisplay({required int width, required int height}) async {}
}

void main() {
  test('bidirectional sync suppresses its own clipboard loop', () async {
    final input = _FakeClipboardInput();
    final host = _FakeHostClipboard()..text = 'initial-host';
    final synchronizer = ScrcpyClipboardSynchronizer(
      input,
      hostClipboard: host,
      pollInterval: const Duration(milliseconds: 10),
    );

    await synchronizer.start();
    expect(input.requests, <ScrcpyCopyKey>[ScrcpyCopyKey.none]);

    input.device.add('from-device');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(host.text, 'from-device');
    expect(host.writes, 1);
    expect(input.sets, isEmpty, reason: 'device write must not echo to device');

    host.text = 'from-host';
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(input.sets, <(String, bool)>[('from-host', false)]);

    input.device.add('from-host');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(host.writes, 1, reason: 'host write echo must not rewrite host');

    await synchronizer.stop();
    expect(synchronizer.isRunning, isFalse);
    await input.device.close();
  });

  test('manual push supports paste and pull supports copy/cut', () async {
    final input = _FakeClipboardInput();
    final host = _FakeHostClipboard()..text = 'paste me';
    final synchronizer = ScrcpyClipboardSynchronizer(
      input,
      hostClipboard: host,
    );

    await synchronizer.pushHostToDevice(paste: true);
    expect(input.sets, <(String, bool)>[('paste me', true)]);

    final pull = synchronizer.pullDeviceToHost(copyKey: ScrcpyCopyKey.cut);
    await Future<void>.delayed(Duration.zero);
    expect(input.requests, <ScrcpyCopyKey>[ScrcpyCopyKey.cut]);
    input.device.add('cut text');
    expect(await pull, 'cut text');
    expect(host.text, 'cut text');
    await input.device.close();
  });
}
