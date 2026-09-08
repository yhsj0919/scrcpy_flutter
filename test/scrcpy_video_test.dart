import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrcpy_flutter/scrcpy_advanced.dart';

final class FakeVideoController extends ValueNotifier<ScrcpyVideoState>
    implements ScrcpyVideoController {
  FakeVideoController() : super(const ScrcpyVideoState.idle());

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<ScrcpyScreenshot> captureFrame() =>
      throw UnimplementedError('Not used by this test');

  @override
  bool get isRecording => false;

  @override
  Future<void> startRecording(String path) async {}

  @override
  Future<int> stopRecording() async => 0;
}

void main() {
  testWidgets('video view shows placeholder until texture is ready', (
    tester,
  ) async {
    final controller = FakeVideoController();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ScrcpyVideoView(
          controller: controller,
          placeholder: const Text('等待视频'),
        ),
      ),
    );

    expect(find.text('等待视频'), findsOneWidget);
    expect(find.byType(Texture), findsNothing);

    controller.value = const ScrcpyVideoState(
      status: ScrcpyVideoStatus.ready,
      textureId: 42,
      width: 1920,
      height: 1080,
    );
    await tester.pump();

    expect(find.text('等待视频'), findsNothing);
    expect(find.byType(Texture), findsOneWidget);
    expect(tester.widget<Texture>(find.byType(Texture)).textureId, 42);
    controller.dispose();
  });
}
