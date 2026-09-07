import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrcpy_flutter/scrcpy_advanced.dart';

final class _FakeAudioStream implements ScrcpyAudioStream {
  _FakeAudioStream(this.codecValue);

  final ScrcpyAudioCodecInfo? codecValue;
  final controller = StreamController<ScrcpyAudioPacket>();
  final doneCompleter = Completer<void>();
  int received = 0;

  @override
  int get bytesReceived => received;

  @override
  Future<ScrcpyAudioCodecInfo?> get codec async => codecValue;

  @override
  Future<void> get done => doneCompleter.future;

  @override
  Stream<ScrcpyAudioPacket> get packets => controller.stream;

  Future<void> close() async {
    unawaited(controller.close());
    doneCompleter.complete();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('decodes Opus packets and controls mute and volume', () async {
    const channel = MethodChannel('scrcpy_flutter/audio');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'create' => 7,
            'decode' || 'setMuted' || 'setVolume' || 'dispose' => null,
            'audioStats' => <String, Object>{
              'decodedPackets': 1,
              'playedBuffers': 1,
              'droppedBuffers': 0,
              'bufferedBytes': 0,
              'peakSample': 12000,
            },
            _ => throw MissingPluginException(call.method),
          };
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final audio = _FakeAudioStream(
      const ScrcpyAudioCodecInfo(codecId: 0x6f707573),
    );
    final controller = createNativeScrcpyAudioController(audio);
    await controller.start();
    audio.received = 16;
    audio.controller.add(
      ScrcpyAudioPacket(
        presentationTimeUs: 42,
        isConfig: false,
        data: Uint8List.fromList(<int>[1, 2, 3]),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    await controller.setVolume(0.25);
    await controller.setMuted(true);
    expect(controller.value.status, ScrcpyAudioStatus.ready);
    expect(controller.value.volume, 0.25);
    expect(controller.value.muted, isTrue);
    final decode = calls.firstWhere((call) => call.method == 'decode');
    expect((decode.arguments as Map<Object?, Object?>)['audioId'], 7);
    await expectLater(controller.setVolume(1.1), throwsRangeError);

    await controller.stop();
    expect(calls.last.method, 'dispose');
    controller.dispose();
    await audio.close();
  });

  test('rejects codecs unsupported by the Windows audio backend', () async {
    final audio = _FakeAudioStream(
      const ScrcpyAudioCodecInfo(codecId: 0x6d703461),
    );
    final controller = createNativeScrcpyAudioController(audio);
    await expectLater(
      controller.start(),
      throwsA(
        isA<ScrcpyException>().having(
          (error) => error.code,
          'code',
          ScrcpyErrorCode.unsupportedCapability,
        ),
      ),
    );
    expect(controller.value.status, ScrcpyAudioStatus.error);
    controller.dispose();
    await audio.close();
  });
}
