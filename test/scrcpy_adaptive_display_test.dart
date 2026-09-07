import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrcpy_flutter/scrcpy_advanced.dart';

final class _FakeInput implements ScrcpyInputController {
  final sizes = <(int, int)>[];
  bool failNext = false;

  @override
  Future<void> resizeDisplay({required int width, required int height}) async {
    if (failNext) {
      failNext = false;
      throw StateError('resize failed');
    }
    sizes.add((width, height));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('uses preview size below max and caps larger previews', () {
    expect(
      ScrcpyAdaptiveDisplayController.calculateTargetSize(
        const Size(800, 600),
        maxSize: 1920,
      ),
      const Size(800, 600),
    );
    expect(
      ScrcpyAdaptiveDisplayController.calculateTargetSize(
        const Size(3840, 2160),
        maxSize: 1920,
      ),
      const Size(1920, 1080),
    );
  });

  test('preserves extreme ratios, minimum and even alignment', () {
    final size = ScrcpyAdaptiveDisplayController.calculateTargetSize(
      const Size(1000, 101),
      maxSize: 800,
      minSize: 160,
      alignment: 2,
    );
    expect(size.width, 800);
    expect(size.height.round().isEven, isTrue);
    expect(size.height, greaterThan(0));
  });

  test('debounces updates and ignores insignificant changes', () async {
    final input = _FakeInput();
    final controller = ScrcpyAdaptiveDisplayController(
      input: input,
      maxSize: 1920,
      changeThreshold: 16,
      debounce: const Duration(milliseconds: 5),
    );

    controller.updatePreview(const Size(800, 600));
    controller.updatePreview(const Size(1000, 700));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await controller.flush();
    expect(input.sizes, <(int, int)>[(1000, 700)]);

    controller.updatePreview(const Size(1008, 706));
    await controller.flush();
    expect(input.sizes, hasLength(1));
    controller.dispose();
  });

  test('cancelPending prevents a debounced resize', () async {
    final input = _FakeInput();
    final controller = ScrcpyAdaptiveDisplayController(
      input: input,
      maxSize: 1920,
      debounce: const Duration(milliseconds: 5),
    );

    controller.updatePreview(const Size(800, 600));
    controller.cancelPending();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(input.sizes, isEmpty);
    controller.dispose();
  });

  test('a failed resize does not block later requests', () async {
    final input = _FakeInput()..failNext = true;
    final errors = <Object>[];
    final controller = ScrcpyAdaptiveDisplayController(
      input: input,
      maxSize: 1920,
      debounce: Duration.zero,
      onError: (error, _) => errors.add(error),
    );

    controller.updatePreview(const Size(800, 600));
    await controller.flush();
    controller.updatePreview(const Size(1000, 700));
    await controller.flush();

    expect(errors, hasLength(1));
    expect(input.sizes, <(int, int)>[(1000, 700)]);
    controller.dispose();
  });

  test('alignment never produces a size above a non-aligned maximum', () {
    final size = ScrcpyAdaptiveDisplayController.calculateTargetSize(
      const Size(4000, 2000),
      maxSize: 1919,
      alignment: 16,
    );
    expect(size.width, 1904);
    expect(size.width.round() % 16, 0);
    expect(size.height.round() % 16, 0);
  });
}
