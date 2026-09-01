import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

enum ScrcpyPointerAction { down, move, up, cancel, hover, scroll }

final class ScrcpyPointerEvent {
  const ScrcpyPointerEvent({
    required this.pointerId,
    required this.action,
    required this.normalizedX,
    required this.normalizedY,
    required this.buttons,
    this.scrollDeltaX = 0,
    this.scrollDeltaY = 0,
  });

  final int pointerId;
  final ScrcpyPointerAction action;
  final double normalizedX;
  final double normalizedY;
  final int buttons;
  final double scrollDeltaX;
  final double scrollDeltaY;
}

final class ScrcpyCoordinateMapper {
  const ScrcpyCoordinateMapper._();

  static Offset? map({
    required Offset localPosition,
    required Size widgetSize,
    required Size videoSize,
    BoxFit fit = BoxFit.contain,
    Alignment alignment = Alignment.center,
  }) {
    if (widgetSize.isEmpty || videoSize.isEmpty) return null;
    final fitted = applyBoxFit(fit, videoSize, widgetSize);
    final source = alignment.inscribe(fitted.source, Offset.zero & videoSize);
    final destination = alignment.inscribe(
      fitted.destination,
      Offset.zero & widgetSize,
    );
    if (!destination.contains(localPosition)) return null;
    final dx = (localPosition.dx - destination.left) / destination.width;
    final dy = (localPosition.dy - destination.top) / destination.height;
    return Offset(
      (source.left + dx * source.width) / videoSize.width,
      (source.top + dy * source.height) / videoSize.height,
    );
  }
}

abstract interface class ScrcpyInputController {
  Future<void> sendPointer(ScrcpyPointerEvent event);

  Future<void> sendKey({required int keyCode, bool down = true});

  Future<void> sendText(String text);
}

/// Captures Flutter pointer events above a video surface. Coordinates are
/// normalized here; exact video/letterbox mapping is implemented in P3.
final class ScrcpyInputLayer extends StatelessWidget {
  const ScrcpyInputLayer({
    required this.controller,
    required this.child,
    this.enabled = true,
    this.videoSize,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.autofocus = true,
    this.captureAllKeys = false,
    super.key,
  });

  final ScrcpyInputController controller;
  final Widget child;
  final bool enabled;
  final Size? videoSize;
  final BoxFit fit;
  final Alignment alignment;
  final bool autofocus;

  /// Prevents unmapped keys from bubbling to host Flutter shortcuts while
  /// this input layer owns keyboard focus.
  final bool captureAllKeys;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Focus(
      autofocus: autofocus,
      onKeyEvent: enabled
          ? (_, event) => (_sendKey(event) || captureAllKeys)
                ? KeyEventResult.handled
                : KeyEventResult.ignored
          : null,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: enabled
            ? (event) => _send(event, ScrcpyPointerAction.down, constraints)
            : null,
        onPointerMove: enabled
            ? (event) => _send(event, ScrcpyPointerAction.move, constraints)
            : null,
        onPointerUp: enabled
            ? (event) => _send(event, ScrcpyPointerAction.up, constraints)
            : null,
        onPointerCancel: enabled
            ? (event) => _send(event, ScrcpyPointerAction.cancel, constraints)
            : null,
        onPointerHover: enabled
            ? (event) => _send(event, ScrcpyPointerAction.hover, constraints)
            : null,
        onPointerSignal: enabled
            ? (event) {
                if (event is PointerScrollEvent) {
                  _send(
                    event,
                    ScrcpyPointerAction.scroll,
                    constraints,
                    scrollDelta: event.scrollDelta,
                  );
                }
              }
            : null,
        child: child,
      ),
    ),
  );

  bool _sendKey(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return false;
    }
    final keyCode = _androidKeyCode(event.logicalKey);
    if (keyCode == null || event is KeyRepeatEvent) return false;
    controller.sendKey(keyCode: keyCode, down: event is KeyDownEvent);
    return true;
  }

  void _send(
    PointerEvent event,
    ScrcpyPointerAction action,
    BoxConstraints constraints, {
    Offset scrollDelta = Offset.zero,
  }) {
    final width = constraints.maxWidth;
    final height = constraints.maxHeight;
    if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) {
      return;
    }
    var normalized = Offset(
      event.localPosition.dx / width,
      event.localPosition.dy / height,
    );
    final currentVideoSize = videoSize;
    if (currentVideoSize != null) {
      final mapped = ScrcpyCoordinateMapper.map(
        localPosition: event.localPosition,
        widgetSize: Size(width, height),
        videoSize: currentVideoSize,
        fit: fit,
        alignment: alignment,
      );
      if (mapped == null) return;
      normalized = mapped;
    }
    controller.sendPointer(
      ScrcpyPointerEvent(
        pointerId: event.pointer,
        action: action,
        normalizedX: normalized.dx.clamp(0, 1),
        normalizedY: normalized.dy.clamp(0, 1),
        buttons: event.buttons,
        scrollDeltaX: scrollDelta.dx,
        scrollDeltaY: scrollDelta.dy,
      ),
    );
  }
}

int? _androidKeyCode(LogicalKeyboardKey key) {
  final fixed = <LogicalKeyboardKey, int>{
    LogicalKeyboardKey.escape: 4,
    LogicalKeyboardKey.home: 3,
    LogicalKeyboardKey.enter: 66,
    LogicalKeyboardKey.numpadEnter: 66,
    LogicalKeyboardKey.backspace: 67,
    LogicalKeyboardKey.delete: 112,
    LogicalKeyboardKey.tab: 61,
    LogicalKeyboardKey.space: 62,
    LogicalKeyboardKey.arrowUp: 19,
    LogicalKeyboardKey.arrowDown: 20,
    LogicalKeyboardKey.arrowLeft: 21,
    LogicalKeyboardKey.arrowRight: 22,
    LogicalKeyboardKey.audioVolumeUp: 24,
    LogicalKeyboardKey.audioVolumeDown: 25,
  };
  final known = fixed[key];
  if (known != null) return known;
  final label = key.keyLabel;
  if (label.length == 1) {
    final code = label.toUpperCase().codeUnitAt(0);
    if (code >= 65 && code <= 90) return 29 + code - 65;
    if (code >= 48 && code <= 57) return 7 + code - 48;
  }
  return null;
}
