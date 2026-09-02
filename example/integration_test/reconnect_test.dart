import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:scrcpy_flutter/scrcpy_flutter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('recovers video after its scrcpy server is terminated', (
    tester,
  ) async {
    const serial = String.fromEnvironment('SCRCPY_DEVICE_SERIAL');
    if (serial.isEmpty) return;
    final client = createDefaultScrcpyClient();
    final adb = client.adbClient;
    if (adb is! AdbShellService) {
      throw StateError('ADB shell is unavailable');
    }
    final shell = adb as AdbShellService;
    final session = client.createSession(
      const ScrcpySessionConfiguration(
        deviceSerial: serial,
        video: ScrcpyVideoOptions(maxSize: 720, maxFps: 15, bitRate: 2000000),
        reconnectPolicy: ScrcpyReconnectPolicy(
          maxAttempts: 5,
          initialDelay: Duration(milliseconds: 200),
          maxDelay: Duration(seconds: 1),
        ),
      ),
    );
    ScrcpyVideoController? video;
    try {
      final first = await session.start().timeout(const Duration(seconds: 15));
      video = createNativeScrcpyVideoController(first);
      await video.start().timeout(const Duration(seconds: 15));
      await tester.pumpWidget(
        MaterialApp(home: ScrcpyVideoView(controller: video)),
      );
      await _waitForFrame(tester, video);

      final replacementFuture = session.reconnectedConnections.first.timeout(
        const Duration(seconds: 20),
      );
      final processes = await shell.shell(serial, <String>[
        'ps',
        '-A',
        '-o',
        'PID,ARGS',
      ]);
      final processLines = utf8
          .decode(processes.stdout, allowMalformed: true)
          .split(RegExp(r'\r?\n'));
      final matching = processLines
          .where((line) => line.contains('scid=${first.info.scid}'))
          .toList();
      if (matching.isEmpty) {
        throw StateError('No scrcpy process found for ${first.info.scid}');
      }
      final direct = matching.where((line) => !line.contains('sh -c')).toList();
      final process = direct.isNotEmpty ? direct.last : matching.last;
      final pid = process.trim().split(RegExp(r'\s+')).first;
      final kill = await shell.shell(serial, <String>['kill', pid]);
      if (!kill.isSuccess) {
        throw StateError('Unable to terminate the test scrcpy server');
      }
      final replacement = await replacementFuture;
      expect(replacement.info.scid, isNot(first.info.scid));
      expect(session.state.value, ScrcpySessionState.streaming);

      try {
        await video.stop();
      } catch (_) {}
      video.dispose();
      video = createNativeScrcpyVideoController(replacement);
      await video.start().timeout(const Duration(seconds: 15));
      await tester.pumpWidget(
        MaterialApp(home: ScrcpyVideoView(controller: video)),
      );
      final frames = await _waitForFrame(tester, video);
      expect(frames, greaterThan(0));
      debugPrint(
        'reconnect: ${first.info.scid} -> ${replacement.info.scid}, '
        'frames=$frames',
      );
    } finally {
      await video?.stop();
      await session.stop();
      video?.dispose();
      session.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 1)));
}

Future<int> _waitForFrame(
  WidgetTester tester,
  ScrcpyVideoController video,
) async {
  const channel = MethodChannel('scrcpy_flutter/video');
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.pump(const Duration(milliseconds: 100));
    final textureId = video.value.textureId;
    if (textureId == null) continue;
    final frames = await channel.invokeMethod<int>(
      'frameCount',
      <String, Object>{'textureId': textureId},
    );
    if ((frames ?? 0) > 0) return frames!;
  }
  throw TimeoutException('No decoded frame after reconnect');
}
