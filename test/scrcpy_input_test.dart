import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrcpy_flutter/scrcpy_flutter.dart';

final class FakeInputController
    implements ScrcpyInputController, ScrcpyScreenPowerInputController {
  final List<ScrcpyPointerEvent> events = <ScrcpyPointerEvent>[];
  final List<(int, bool)> keys = <(int, bool)>[];
  final List<bool> backOrScreenOnActions = <bool>[];
  final StreamController<String> clipboard = StreamController<String>();

  @override
  Stream<String> get clipboardChanges => clipboard.stream;

  @override
  Future<void> requestClipboard({
    ScrcpyCopyKey copyKey = ScrcpyCopyKey.none,
  }) async {}

  @override
  Future<void> sendKey({required int keyCode, bool down = true}) async {
    keys.add((keyCode, down));
  }

  @override
  Future<void> sendBackOrScreenOn({bool down = true}) async {
    backOrScreenOnActions.add(down);
  }

  @override
  Future<void> sendPointer(ScrcpyPointerEvent event) async {
    events.add(event);
  }

  @override
  Future<void> sendText(String text) async {}

  @override
  Future<void> startApplication(ScrcpyApplicationLaunch application) async {}

  @override
  Future<void> resizeDisplay({required int width, required int height}) async {}

  @override
  Future<void> setClipboard(String text, {bool paste = false}) async {}
}

void main() {
  test('gesture simulator emits a balanced two-pointer pinch', () async {
    final controller = FakeInputController();

    await ScrcpyGestureSimulator(controller).pinch(
      startSpan: 0.2,
      endSpan: 0.6,
      steps: 2,
      duration: Duration.zero,
      firstPointerId: 11,
      secondPointerId: 22,
    );

    expect(controller.events, hasLength(8));
    expect(controller.events.map((event) => event.pointerId), <int>[
      11,
      22,
      11,
      22,
      11,
      22,
      22,
      11,
    ]);
    for (final pointerId in <int>[11, 22]) {
      final actions = controller.events
          .where((event) => event.pointerId == pointerId)
          .map((event) => event.action);
      expect(actions.first, ScrcpyPointerAction.down);
      expect(
        actions.where((action) => action == ScrcpyPointerAction.move),
        hasLength(2),
      );
      expect(actions.last, ScrcpyPointerAction.up);
    }
    expect(controller.events[0].normalizedX, closeTo(0.4, 0.0001));
    expect(controller.events[1].normalizedX, closeTo(0.6, 0.0001));
    expect(controller.events[6].normalizedX, closeTo(0.8, 0.0001));
    expect(controller.events[7].normalizedX, closeTo(0.2, 0.0001));
  });

  test('gesture simulator rejects invalid pinch paths', () async {
    final controller = FakeInputController();
    final simulator = ScrcpyGestureSimulator(controller);

    await expectLater(
      simulator.pinch(center: Offset.zero, endSpan: 0.5),
      throwsArgumentError,
    );
    await expectLater(
      simulator.pinch(firstPointerId: 1, secondPointerId: 1),
      throwsArgumentError,
    );
    expect(controller.events, isEmpty);
  });

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

  test('contain maps all four visible corners', () {
    const widget = Size(400, 400);
    const video = Size(400, 200);
    const epsilon = 0.001;
    final cases = <(Offset, Offset)>[
      (const Offset(0, 100), Offset.zero),
      (const Offset(400 - epsilon, 100), const Offset(1, 0)),
      (const Offset(0, 300 - epsilon), const Offset(0, 1)),
      (const Offset(400 - epsilon, 300 - epsilon), const Offset(1, 1)),
    ];

    for (final (position, expected) in cases) {
      final mapped = ScrcpyCoordinateMapper.map(
        localPosition: position,
        widgetSize: widget,
        videoSize: video,
      );
      expect(mapped, isNotNull);
      expect(mapped!.dx, closeTo(expected.dx, 0.00001));
      expect(mapped.dy, closeTo(expected.dy, 0.00001));
    }
  });

  test('non-centered contain alignment moves the visible destination', () {
    const widget = Size(400, 400);
    const video = Size(400, 200);

    expect(
      ScrcpyCoordinateMapper.map(
        localPosition: const Offset(0, 0),
        widgetSize: widget,
        videoSize: video,
        alignment: Alignment.topLeft,
      ),
      Offset.zero,
    );
    expect(
      ScrcpyCoordinateMapper.map(
        localPosition: const Offset(0, 199),
        widgetSize: widget,
        videoSize: video,
        alignment: Alignment.bottomRight,
      ),
      isNull,
    );
    expect(
      ScrcpyCoordinateMapper.map(
        localPosition: const Offset(0, 200),
        widgetSize: widget,
        videoSize: video,
        alignment: Alignment.bottomRight,
      ),
      Offset.zero,
    );
  });

  test('cover alignment selects the correct cropped source edge', () {
    final topLeft = ScrcpyCoordinateMapper.map(
      localPosition: const Offset(0, 200),
      widgetSize: const Size(400, 400),
      videoSize: const Size(400, 200),
      fit: BoxFit.cover,
      alignment: Alignment.topLeft,
    );
    final bottomRight = ScrcpyCoordinateMapper.map(
      localPosition: const Offset(0, 200),
      widgetSize: const Size(400, 400),
      videoSize: const Size(400, 200),
      fit: BoxFit.cover,
      alignment: Alignment.bottomRight,
    );

    expect(topLeft?.dx, closeTo(0, 0.0001));
    expect(bottomRight?.dx, closeTo(0.5, 0.0001));
  });

  test('mapping is invariant across window size and logical DPI scaling', () {
    final base = ScrcpyCoordinateMapper.map(
      localPosition: const Offset(150, 125),
      widgetSize: const Size(300, 200),
      videoSize: const Size(1920, 1080),
    );
    final resized = ScrcpyCoordinateMapper.map(
      localPosition: const Offset(300, 250),
      widgetSize: const Size(600, 400),
      videoSize: const Size(1920, 1080),
    );
    final highDpi = ScrcpyCoordinateMapper.map(
      localPosition: const Offset(225, 187.5),
      widgetSize: const Size(450, 300),
      videoSize: const Size(2880, 1620),
    );

    expect(resized?.dx, closeTo(base!.dx, 0.000001));
    expect(resized?.dy, closeTo(base.dy, 0.000001));
    expect(highDpi?.dx, closeTo(base.dx, 0.000001));
    expect(highDpi?.dy, closeTo(base.dy, 0.000001));
  });

  test('dynamic portrait and landscape sizes map their own letterbox', () {
    final portrait = ScrcpyCoordinateMapper.map(
      localPosition: const Offset(200, 50),
      widgetSize: const Size(400, 400),
      videoSize: const Size(1080, 1920),
    );
    final landscape = ScrcpyCoordinateMapper.map(
      localPosition: const Offset(200, 50),
      widgetSize: const Size(400, 400),
      videoSize: const Size(1920, 1080),
    );

    expect(portrait?.dx, closeTo(0.5, 0.0001));
    expect(portrait?.dy, closeTo(0.125, 0.0001));
    expect(landscape, isNull);
  });

  test('mapping rejects invalid dimensions and coordinates', () {
    expect(
      ScrcpyCoordinateMapper.map(
        localPosition: Offset.zero,
        widgetSize: Size.zero,
        videoSize: const Size(100, 100),
      ),
      isNull,
    );
    expect(
      ScrcpyCoordinateMapper.map(
        localPosition: const Offset(double.nan, 0),
        widgetSize: const Size(100, 100),
        videoSize: const Size(100, 100),
      ),
      isNull,
    );
    expect(
      ScrcpyCoordinateMapper.map(
        localPosition: Offset.zero,
        widgetSize: const Size(double.infinity, 100),
        videoSize: const Size(100, 100),
      ),
      isNull,
    );
  });

  testWidgets('input layer uses a dynamically updated video size', (
    tester,
  ) async {
    final controller = FakeInputController();

    Future<void> pump(Size videoSize) => tester.pumpWidget(
      Center(
        child: SizedBox.square(
          dimension: 400,
          child: ScrcpyInputLayer(
            controller: controller,
            videoSize: videoSize,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );

    await pump(const Size(1920, 1080));
    var rect = tester.getRect(find.byType(ScrcpyInputLayer));
    await tester.tapAt(rect.topCenter + const Offset(0, 50));
    expect(controller.events, isEmpty);

    await pump(const Size(1080, 1920));
    rect = tester.getRect(find.byType(ScrcpyInputLayer));
    await tester.tapAt(rect.topCenter + const Offset(0, 50));
    expect(controller.events, hasLength(2));
    expect(controller.events.first.normalizedX, closeTo(0.5, 0.001));
    expect(controller.events.first.normalizedY, closeTo(0.125, 0.001));
    expect(controller.events.first.videoWidth, 1080);
    expect(controller.events.first.videoHeight, 1920);
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
            videoSize: const Size(400, 200),
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
    expect(controller.events.first.videoWidth, 400);
    expect(controller.events.first.videoHeight, 200);
    expect(controller.events.first.normalizedX, closeTo(0.25, 0.001));
    expect(controller.events.first.normalizedY, closeTo(0.25, 0.001));
    expect(controller.events.last.action, ScrcpyPointerAction.up);
  });

  testWidgets('mouse buttons follow scrcpy desktop navigation mapping', (
    tester,
  ) async {
    final controller = FakeInputController();
    await tester.pumpWidget(
      Center(
        child: ScrcpyInputLayer(
          controller: controller,
          child: const SizedBox(width: 200, height: 100),
        ),
      ),
    );
    final center = tester.getCenter(find.byType(ScrcpyInputLayer));

    Future<void> click(int pointer, int buttons) async {
      await tester.sendEventToBinding(
        PointerDownEvent(
          pointer: pointer,
          kind: PointerDeviceKind.mouse,
          position: center,
          buttons: buttons,
        ),
      );
      await tester.sendEventToBinding(
        PointerUpEvent(
          pointer: pointer,
          kind: PointerDeviceKind.mouse,
          position: center,
        ),
      );
    }

    await click(41, kMiddleMouseButton);
    await click(42, kSecondaryMouseButton);

    expect(controller.keys, <(int, bool)>[
      (ScrcpyAndroidKeyCode.home, true),
      (ScrcpyAndroidKeyCode.home, false),
    ]);
    expect(controller.backOrScreenOnActions, <bool>[true, false]);
    expect(controller.events, isEmpty);

    await click(43, kPrimaryMouseButton);
    expect(
      controller.events.map((event) => event.action),
      <ScrcpyPointerAction>[ScrcpyPointerAction.down, ScrcpyPointerAction.up],
    );
    expect(controller.events.map((event) => event.pointerId).toSet(), <int>{
      ScrcpyPointerId.mouse,
    });
  });

  testWidgets('a new mouse down cancels a stale injected touch', (
    tester,
  ) async {
    final controller = FakeInputController();
    await tester.pumpWidget(
      Center(
        child: ScrcpyInputLayer(
          controller: controller,
          child: const SizedBox(width: 200, height: 100),
        ),
      ),
    );
    final center = tester.getCenter(find.byType(ScrcpyInputLayer));

    for (final pointer in <int>[51, 52]) {
      await tester.sendEventToBinding(
        PointerDownEvent(
          pointer: pointer,
          kind: PointerDeviceKind.mouse,
          position: center,
          buttons: kPrimaryMouseButton,
        ),
      );
    }

    expect(
      controller.events.map((event) => event.action),
      <ScrcpyPointerAction>[
        ScrcpyPointerAction.down,
        ScrcpyPointerAction.cancel,
        ScrcpyPointerAction.down,
      ],
    );
    expect(controller.events.map((event) => event.pointerId).toSet(), <int>{
      ScrcpyPointerId.mouse,
    });
  });

  test('coordinate mapper snaps gesture starts to physical edges', () {
    final bottom = ScrcpyCoordinateMapper.map(
      localPosition: const Offset(100, 99),
      widgetSize: const Size(200, 100),
      videoSize: const Size(1000, 500),
      edgeThreshold: 0.02,
    );
    final left = ScrcpyCoordinateMapper.map(
      localPosition: const Offset(3, 50),
      widgetSize: const Size(200, 100),
      videoSize: const Size(1000, 500),
      edgeThreshold: 0.02,
    );

    expect(bottom, const Offset(0.5, 1));
    expect(left, const Offset(0, 0.5));
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

  testWidgets('input layer preserves long press down and up sequence', (
    tester,
  ) async {
    final controller = FakeInputController();
    await tester.pumpWidget(
      ScrcpyInputLayer(
        controller: controller,
        child: const SizedBox(width: 200, height: 200),
      ),
    );

    final gesture = await tester.startGesture(const Offset(100, 100));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.up();

    expect(
      controller.events.map((event) => event.action),
      <ScrcpyPointerAction>[ScrcpyPointerAction.down, ScrcpyPointerAction.up],
    );
  });

  testWidgets('input layer emits normalized drag movement', (tester) async {
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

    final bounds = tester.getRect(find.byType(ScrcpyInputLayer));
    final gesture = await tester.startGesture(
      bounds.topLeft + const Offset(20, 50),
    );
    await gesture.moveTo(bounds.topLeft + const Offset(180, 50));
    await gesture.up();

    expect(controller.events.first.action, ScrcpyPointerAction.down);
    expect(
      controller.events.any(
        (event) =>
            event.action == ScrcpyPointerAction.move && event.normalizedX > 0.8,
      ),
      isTrue,
    );
    expect(controller.events.last.action, ScrcpyPointerAction.up);
  });

  testWidgets('pointer released in letterbox uses its last video position', (
    tester,
  ) async {
    final controller = FakeInputController();
    await tester.pumpWidget(
      Center(
        child: SizedBox.square(
          dimension: 400,
          child: ScrcpyInputLayer(
            controller: controller,
            videoSize: const Size(200, 400),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    final bounds = tester.getRect(find.byType(ScrcpyInputLayer));
    final gesture = await tester.startGesture(bounds.center, pointer: 71);
    await gesture.moveTo(bounds.centerLeft + const Offset(20, 0));
    await gesture.up();

    expect(
      controller.events.map((event) => event.action),
      <ScrcpyPointerAction>[ScrcpyPointerAction.down, ScrcpyPointerAction.up],
    );
    expect(controller.events.first.normalizedX, closeTo(0.5, 0.001));
    expect(controller.events.last.normalizedX, closeTo(0.5, 0.001));
    expect(controller.events.last.normalizedY, closeTo(0.5, 0.001));
  });

  testWidgets('input layer emits pointer scroll deltas', (tester) async {
    final controller = FakeInputController();
    await tester.pumpWidget(
      ScrcpyInputLayer(
        controller: controller,
        child: const SizedBox(width: 200, height: 100),
      ),
    );

    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(100, 50),
        scrollDelta: Offset(0, 40),
      ),
    );

    expect(controller.events, hasLength(1));
    expect(controller.events.single.action, ScrcpyPointerAction.scroll);
    expect(controller.events.single.scrollDeltaY, 40);
  });

  testWidgets('input layer keeps simultaneous pointer ids independent', (
    tester,
  ) async {
    final controller = FakeInputController();
    await tester.pumpWidget(
      ScrcpyInputLayer(
        controller: controller,
        child: const SizedBox(width: 200, height: 200),
      ),
    );

    final first = await tester.startGesture(
      const Offset(60, 100),
      pointer: 101,
    );
    final second = await tester.startGesture(
      const Offset(140, 100),
      pointer: 202,
    );
    await first.moveTo(const Offset(40, 100));
    await second.moveTo(const Offset(160, 100));
    await second.up();
    await first.up();

    expect(controller.events.map((event) => event.pointerId).toSet(), <int>{
      101,
      202,
    });
    for (final pointerId in <int>[101, 202]) {
      final actions = controller.events
          .where((event) => event.pointerId == pointerId)
          .map((event) => event.action);
      expect(actions.first, ScrcpyPointerAction.down);
      expect(actions, contains(ScrcpyPointerAction.move));
      expect(actions.last, ScrcpyPointerAction.up);
    }
  });

  testWidgets('input layer forwards pointer cancellation', (tester) async {
    final controller = FakeInputController();
    await tester.pumpWidget(
      ScrcpyInputLayer(
        controller: controller,
        child: const SizedBox(width: 200, height: 200),
      ),
    );

    final gesture = await tester.startGesture(
      const Offset(100, 100),
      pointer: 303,
    );
    await gesture.cancel();

    expect(
      controller.events.map((event) => event.action),
      <ScrcpyPointerAction>[
        ScrcpyPointerAction.down,
        ScrcpyPointerAction.cancel,
      ],
    );
    expect(controller.events.map((event) => event.pointerId).toSet(), <int>{
      303,
    });
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
