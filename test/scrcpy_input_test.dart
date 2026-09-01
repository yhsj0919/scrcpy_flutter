import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrcpy_flutter/scrcpy_flutter.dart';

final class FakeInputController implements ScrcpyInputController {
  final List<ScrcpyPointerEvent> events = <ScrcpyPointerEvent>[];
  final List<(int, bool)> keys = <(int, bool)>[];

  @override
  Future<void> sendKey({required int keyCode, bool down = true}) async {
    keys.add((keyCode, down));
  }

  @override
  Future<void> sendPointer(ScrcpyPointerEvent event) async {
    events.add(event);
  }

  @override
  Future<void> sendText(String text) async {}
}

void main() {
  test('contain mapping excludes letterbox and maps video corners', () {
    const widget = Size(400, 400);
    const video = Size(400, 200);

    expect(
      ScrcpyCoordinateMapper.map(
        localPosition: const Offset(200, 50),
        widgetSize: widget,
        videoSize: video,
      ),
      isNull,
    );
    expect(
      ScrcpyCoordinateMapper.map(
        localPosition: const Offset(0, 100),
        widgetSize: widget,
        videoSize: video,
      ),
      Offset.zero,
    );
    expect(
      ScrcpyCoordinateMapper.map(
        localPosition: const Offset(399.999, 299.999),
        widgetSize: widget,
        videoSize: video,
      ),
      isNotNull,
    );
  });

  test('cover mapping includes the cropped source offset', () {
    final mapped = ScrcpyCoordinateMapper.map(
      localPosition: const Offset(0, 200),
      widgetSize: const Size(400, 400),
      videoSize: const Size(400, 200),
      fit: BoxFit.cover,
    );
    expect(mapped?.dx, closeTo(0.25, 0.0001));
    expect(mapped?.dy, closeTo(0.5, 0.0001));
  });

  testWidgets('input layer emits normalized pointer coordinates', (
    tester,
  ) async {
    final controller = FakeInputController();
    await tester.pumpWidget(
      Center(
        child: SizedBox(
          width: 200,
          height: 100,
          child: ScrcpyInputLayer(
            controller: controller,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );

    final box = tester.getRect(find.byType(ScrcpyInputLayer));
    final gesture = await tester.startGesture(
      box.topLeft + const Offset(50, 25),
    );
    await gesture.up();

    expect(controller.events.first.action, ScrcpyPointerAction.down);
    expect(controller.events.first.normalizedX, closeTo(0.25, 0.001));
    expect(controller.events.first.normalizedY, closeTo(0.25, 0.001));
    expect(controller.events.last.action, ScrcpyPointerAction.up);
  });

  testWidgets('disabled input layer does not emit events', (tester) async {
    final controller = FakeInputController();
    await tester.pumpWidget(
      Center(
        child: SizedBox(
          width: 100,
          height: 100,
          child: ScrcpyInputLayer(
            controller: controller,
            enabled: false,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(ScrcpyInputLayer));
    expect(controller.events, isEmpty);
  });

  testWidgets('input layer maps focused keyboard events to Android keycodes', (
    tester,
  ) async {
    final controller = FakeInputController();
    await tester.pumpWidget(
      ScrcpyInputLayer(
        controller: controller,
        child: const SizedBox(width: 100, height: 100),
      ),
    );
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);

    expect(controller.keys, <(int, bool)>[(66, true), (66, false)]);
  });

  testWidgets('focused input layer prevents mapped keys from bubbling', (
    tester,
  ) async {
    final controller = FakeInputController();
    var parentEvents = 0;
    await tester.pumpWidget(
      Focus(
        onKeyEvent: (_, _) {
          parentEvents++;
          return KeyEventResult.ignored;
        },
        child: ScrcpyInputLayer(
          controller: controller,
          child: const SizedBox(width: 100, height: 100),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);

    expect(controller.keys, <(int, bool)>[(66, true), (66, false)]);
    expect(parentEvents, 0);
  });

  testWidgets('unmapped keys continue to host shortcuts', (tester) async {
    final controller = FakeInputController();
    var parentEvents = 0;
    await tester.pumpWidget(
      Focus(
        onKeyEvent: (_, _) {
          parentEvents++;
          return KeyEventResult.handled;
        },
        child: ScrcpyInputLayer(
          controller: controller,
          child: const SizedBox(width: 100, height: 100),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.f1);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.f1);

    expect(controller.keys, isEmpty);
    expect(parentEvents, 2);
  });
}
