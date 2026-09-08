import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrcpy_flutter/scrcpy_advanced.dart';

final class _FakeVideoConnection implements ScrcpyVideoConnection {
  _FakeVideoConnection({this.codecId = ScrcpyVideoCodecInfo.h264});

  final int codecId;

  @override
  ScrcpyAudioStream? get audio => null;
  final sessionsController = StreamController<ScrcpyVideoCodecInfo>();
  final packetsController = StreamController<ScrcpyVideoPacket>();
  bool closed = false;
  final doneCompleter = Completer<void>();

  @override
  int get bytesReceived => 0;

  @override
  Future<void> get done => doneCompleter.future;

  @override
  Future<ScrcpyVideoCodecInfo> get codec async =>
      ScrcpyVideoCodecInfo(codecId: codecId, width: 1080, height: 1920);

  @override
  ScrcpyVideoConnectionInfo get info => const ScrcpyVideoConnectionInfo(
    scid: 'test',
    localPort: 1234,
    remoteServerPath: '/data/local/tmp/test.jar',
  );

  @override
  ScrcpyInputController? get input => null;

  @override
  Stream<ScrcpyVideoPacket> get packets => packetsController.stream;

  @override
  Stream<ScrcpyVideoCodecInfo> get sessions => sessionsController.stream;

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    if (!doneCompleter.isCompleted) doneCompleter.complete();
    await sessionsController.close();
    await packetsController.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('rejects codecs unsupported by the Windows native backend', () async {
    final connection = _FakeVideoConnection(codecId: ScrcpyVideoCodecInfo.h265);
    final controller = createNativeScrcpyVideoController(connection);

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

    expect(connection.closed, isTrue);
    expect(controller.value.status, ScrcpyVideoStatus.error);
    controller.dispose();
  });

  test(
    'recreates the native texture when scrcpy session size changes',
    () async {
      const channel = MethodChannel('scrcpy_flutter/video');
      final calls = <MethodCall>[];
      var nextTextureId = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return switch (call.method) {
              'create' => ++nextTextureId,
              'dispose' || 'decode' => null,
              'videoStats' => <String, Object>{'frames': 0},
              _ => throw MissingPluginException(call.method),
            };
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final connection = _FakeVideoConnection();
      final controller = createNativeScrcpyVideoController(connection);
      await controller.start();
      expect(controller.value.textureId, 1);

      connection.sessionsController.add(
        const ScrcpyVideoCodecInfo(
          codecId: ScrcpyVideoCodecInfo.h264,
          width: 1920,
          height: 1080,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(controller.value.textureId, 2);
      expect(controller.value.width, 1920);
      expect(controller.value.height, 1080);
      final firstDispose = calls.firstWhere((call) => call.method == 'dispose');
      expect((firstDispose.arguments as Map<Object?, Object?>)['textureId'], 1);

      await controller.stop();
      expect(connection.closed, isTrue);
      controller.dispose();
    },
  );

  test('captures the latest native RGBA frame as PNG', () async {
    const channel = MethodChannel('scrcpy_flutter/video');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          return switch (call.method) {
            'create' => 7,
            'captureFrame' => <String, Object>{
              'width': 1,
              'height': 1,
              'pixels': Uint8List.fromList(<int>[255, 0, 0, 255]),
            },
            'dispose' || 'decode' => null,
            'videoStats' => <String, Object>{'frames': 1},
            _ => throw MissingPluginException(call.method),
          };
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final connection = _FakeVideoConnection();
    final controller = createNativeScrcpyVideoController(connection);
    await controller.start();

    final screenshot = await controller.captureFrame();

    expect(screenshot.width, 1);
    expect(screenshot.height, 1);
    expect(screenshot.pngBytes.take(8), <int>[137, 80, 78, 71, 13, 10, 26, 10]);
    await controller.stop();
    controller.dispose();
  });

  test('closes the connection when native texture disposal fails', () async {
    const channel = MethodChannel('scrcpy_flutter/video');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          return switch (call.method) {
            'create' => 1,
            'dispose' => throw PlatformException(code: 'dispose_failed'),
            'decode' => null,
            'videoStats' => <String, Object>{'frames': 0},
            _ => throw MissingPluginException(call.method),
          };
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final connection = _FakeVideoConnection();
    final controller = createNativeScrcpyVideoController(connection);
    await controller.start();

    await expectLater(controller.stop(), throwsA(isA<PlatformException>()));

    expect(connection.closed, isTrue);
    expect(controller.value.status, ScrcpyVideoStatus.error);
    controller.dispose();
  });
}
