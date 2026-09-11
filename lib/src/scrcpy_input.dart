import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'scrcpy_display_source.dart';

enum ScrcpyPointerAction { down, move, up, cancel, hover, scroll }

enum ScrcpyCopyKey { none, copy, cut }

abstract final class ScrcpyAndroidKeyCode {
  static const back = 4;
  static const home = 3;
  static const dpadUp = 19;
  static const dpadDown = 20;
  static const dpadLeft = 21;
  static const dpadRight = 22;
  static const volumeUp = 24;
  static const volumeDown = 25;
  static const power = 26;
  static const enter = 66;
  static const backspace = 67;
  static const tab = 61;
  static const space = 62;
  static const forwardDelete = 112;
  static const appSwitch = 187;
  static const wakeUp = 224;
}

/// Well-known pointer identifiers defined by the scrcpy control protocol.
abstract final class ScrcpyPointerId {
  static const mouse = 0xffffffffffffffff;
}

final class ScrcpyPointerEvent {
  const ScrcpyPointerEvent({
    required this.pointerId,
    required this.action,
    required this.normalizedX,
    required this.normalizedY,
    required this.buttons,
    this.videoWidth,
    this.videoHeight,
    this.scrollDeltaX = 0,
    this.scrollDeltaY = 0,
  });

  final int pointerId;
  final ScrcpyPointerAction action;
  final double normalizedX;
  final double normalizedY;
  final int buttons;

  /// Video dimensions used to map this event. Keeping these on the event
  /// avoids mixing an old visible frame with a newly announced stream size
  /// while a decoder texture is being recreated.
  final int? videoWidth;
  final int? videoHeight;
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
    double edgeThreshold = 0,
  }) {
    if (widgetSize.isEmpty ||
        videoSize.isEmpty ||
        !widgetSize.width.isFinite ||
        !widgetSize.height.isFinite ||
        !videoSize.width.isFinite ||
        !videoSize.height.isFinite ||
        !localPosition.dx.isFinite ||
        !localPosition.dy.isFinite ||
        !edgeThreshold.isFinite ||
        edgeThreshold < 0 ||
        edgeThreshold > 0.1) {
      return null;
    }
    final fitted = applyBoxFit(fit, videoSize, widgetSize);
    final source = alignment.inscribe(fitted.source, Offset.zero & videoSize);
    final destination = alignment.inscribe(
      fitted.destination,
      Offset.zero & widgetSize,
    );
    if (destination.isEmpty || !destination.contains(localPosition)) {
      return null;
    }
    final dx = (localPosition.dx - destination.left) / destination.width;
    final dy = (localPosition.dy - destination.top) / destination.height;
    final mapped = Offset(
      (source.left + dx * source.width) / videoSize.width,
      (source.top + dy * source.height) / videoSize.height,
    );
    if (edgeThreshold == 0) return mapped;
    double snap(double value) {
      if (value <= edgeThreshold) return 0;
      if (value >= 1 - edgeThreshold) return 1;
      return value;
    }

    return Offset(snap(mapped.dx), snap(mapped.dy));
  }
}

abstract interface class ScrcpyInputController {
  Future<void> sendPointer(ScrcpyPointerEvent event);

  Future<void> sendKey({required int keyCode, bool down = true});

  Future<void> sendText(String text);

  /// Starts an application on the display owned by this scrcpy session.
  Future<void> startApplication(ScrcpyApplicationLaunch application);

  /// Resizes a virtual display. The session must use flex display mode.
  Future<void> resizeDisplay({required int width, required int height});

  /// Device clipboard changes emitted by scrcpy clipboard autosync and
  /// explicit [requestClipboard] calls.
  Stream<String> get clipboardChanges;

  Future<void> requestClipboard({ScrcpyCopyKey copyKey = ScrcpyCopyKey.none});

  /// Updates the Android clipboard and waits for the server acknowledgement.
  Future<void> setClipboard(String text, {bool paste = false});
}

/// Optional health state for controllers backed by a transport connection.
abstract interface class ScrcpyInputTransportStatus {
  bool get isAvailable;
}

/// Optional scrcpy desktop navigation command implemented by control-channel
/// input controllers. It performs Back while the screen is on, or wakes it.
abstract interface class ScrcpyScreenPowerInputController {
  Future<void> sendBackOrScreenOn({bool down = true});
}

/// Requests a fresh video configuration and key frame from scrcpy-server.
abstract interface class ScrcpyVideoResetInputController {
  Future<void> resetVideo();
}

/// Sends synthetic multi-pointer gestures through a scrcpy control channel.
///
/// Coordinates and spans are normalized to the current video size, so the
/// gesture remains valid after rotation or host window resizing.
final class ScrcpyGestureSimulator {
  const ScrcpyGestureSimulator(this.controller);

  final ScrcpyInputController controller;

  Future<void> pinch({
    Offset center = const Offset(0.5, 0.5),
    double startSpan = 0.2,
    double endSpan = 0.5,
    Offset axis = const Offset(1, 0),
    int steps = 8,
    Duration duration = const Duration(milliseconds: 240),
    int firstPointerId = 0x7ffffffffffffff0,
    int secondPointerId = 0x7ffffffffffffff1,
  }) async {
    if (steps < 1) throw ArgumentError.value(steps, 'steps', 'must be >= 1');
    if (duration.isNegative) {
      throw ArgumentError.value(duration, 'duration', 'must not be negative');
    }
    if (firstPointerId == secondPointerId) {
      throw ArgumentError('Multi-touch pointer IDs must be different');
    }
    final axisLength = axis.distance;
    if (!axisLength.isFinite || axisLength == 0) {
      throw ArgumentError.value(axis, 'axis', 'must be finite and non-zero');
    }
    final unitAxis = axis / axisLength;
    final start = _pinchPoints(center, unitAxis, startSpan);
    final end = _pinchPoints(center, unitAxis, endSpan);
    if (!_isNormalized(start.$1) ||
        !_isNormalized(start.$2) ||
        !_isNormalized(end.$1) ||
        !_isNormalized(end.$2)) {
      throw ArgumentError('The pinch path must remain inside the video');
    }

    var firstDown = false;
    var secondDown = false;
    try {
      await _send(firstPointerId, ScrcpyPointerAction.down, start.$1);
      firstDown = true;
      await _send(secondPointerId, ScrcpyPointerAction.down, start.$2);
      secondDown = true;
      final stepDelay = duration ~/ steps;
      for (var step = 1; step <= steps; step++) {
        final progress = step / steps;
        await _send(
          firstPointerId,
          ScrcpyPointerAction.move,
          Offset.lerp(start.$1, end.$1, progress)!,
        );
        await _send(
          secondPointerId,
          ScrcpyPointerAction.move,
          Offset.lerp(start.$2, end.$2, progress)!,
        );
        if (stepDelay > Duration.zero) await Future<void>.delayed(stepDelay);
      }
    } finally {
      if (secondDown) {
        await _send(secondPointerId, ScrcpyPointerAction.up, end.$2);
      }
      if (firstDown) {
        await _send(firstPointerId, ScrcpyPointerAction.up, end.$1);
      }
    }
  }

  Future<void> _send(int pointerId, ScrcpyPointerAction action, Offset point) =>
      controller.sendPointer(
        ScrcpyPointerEvent(
          pointerId: pointerId,
          action: action,
          normalizedX: point.dx,
          normalizedY: point.dy,
          buttons: action == ScrcpyPointerAction.up ? 0 : 1,
        ),
      );

  static (Offset, Offset) _pinchPoints(
    Offset center,
    Offset axis,
    double span,
  ) {
    if (!span.isFinite || span < 0) {
      throw ArgumentError.value(span, 'span', 'must be finite and >= 0');
    }
    final radius = axis * (span / 2);
    return (center - radius, center + radius);
  }

  static bool _isNormalized(Offset point) =>
      point.dx.isFinite &&
      point.dy.isFinite &&
      point.dx >= 0 &&
      point.dx <= 1 &&
      point.dy >= 0 &&
      point.dy <= 1;
}

/// Captures Flutter pointer events above a video surface. Coordinates are
/// normalized here; exact video/letterbox mapping is implemented in P3.
final class ScrcpyInputLayer extends StatefulWidget {
  const ScrcpyInputLayer({
    required this.controller,
    required this.child,
    this.enabled = true,
    this.videoSize,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.autofocus = true,
    this.captureAllKeys = false,
    this.blockHostGestures = true,
    this.gestureEdgeThreshold = 0.02,
    super.key,
  }) : assert(gestureEdgeThreshold >= 0 && gestureEdgeThreshold <= 0.1);

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

  /// Claims pointer gestures inside the video so ancestor scrollables and
  /// gesture detectors do not react to the same remote-device operation.
  ///
  /// Disable this when the embedding application intentionally uses gestures
  /// over the video for its own navigation.
  final bool blockHostGestures;

  /// Snaps mouse presses near a video edge to its first or last physical
  /// pixel so Android gesture navigation can reliably detect edge swipes.
  final double gestureEdgeThreshold;

  @override
  State<ScrcpyInputLayer> createState() => _ScrcpyInputLayerState();
}

class _ScrcpyInputLayerState extends State<ScrcpyInputLayer> {
  final Set<int> _activePrimaryMousePointers = <int>{};
  final Map<int, Offset> _activePointerPositions = <int, Offset>{};

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final listener = Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: widget.enabled
            ? (event) => _handlePointerDown(event, constraints)
            : null,
        onPointerMove: widget.enabled
            ? (event) => _handlePointerMove(event, constraints)
            : null,
        onPointerUp: widget.enabled
            ? (event) =>
                  _handlePointerEnd(event, ScrcpyPointerAction.up, constraints)
            : null,
        onPointerCancel: widget.enabled
            ? (event) => _handlePointerEnd(
                event,
                ScrcpyPointerAction.cancel,
                constraints,
              )
            : null,
        onPointerHover: widget.enabled
            ? (event) => _send(event, ScrcpyPointerAction.hover, constraints)
            : null,
        onPointerSignal: widget.enabled
            ? (event) => _handlePointerSignal(event, constraints)
            : null,
        child: widget.child,
      );
      final pointerSurface = widget.enabled && widget.blockHostGestures
          ? RawGestureDetector(
              behavior: HitTestBehavior.opaque,
              gestures: <Type, GestureRecognizerFactory>{
                _HostGestureBlockerRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                      _HostGestureBlockerRecognizer
                    >(_HostGestureBlockerRecognizer.new, (_) {}),
              },
              child: listener,
            )
          : listener;
      return Focus(
        autofocus: widget.autofocus,
        onKeyEvent: widget.enabled
            ? (_, event) => (_sendKey(event) || widget.captureAllKeys)
                  ? KeyEventResult.handled
                  : KeyEventResult.ignored
            : null,
        child: pointerSurface,
      );
    },
  );

  void _handlePointerSignal(
    PointerSignalEvent event,
    BoxConstraints constraints,
  ) {
    if (event is! PointerScrollEvent) return;
    void send(PointerSignalEvent resolvedEvent) {
      _send(
        resolvedEvent,
        ScrcpyPointerAction.scroll,
        constraints,
        scrollDelta: event.scrollDelta,
      );
    }

    if (widget.blockHostGestures) {
      GestureBinding.instance.pointerSignalResolver.register(event, send);
    } else {
      send(event);
    }
  }

  void _handlePointerDown(PointerDownEvent event, BoxConstraints constraints) {
    if (event.kind == PointerDeviceKind.mouse) {
      if (event.buttons == kMiddleMouseButton) {
        _sendKeyClick(ScrcpyAndroidKeyCode.home);
        return;
      }
      if (event.buttons == kSecondaryMouseButton) {
        _sendBackOrScreenOnClick();
        return;
      }
      if (event.buttons != kPrimaryMouseButton) return;
      if (_activePrimaryMousePointers.isNotEmpty) {
        if (kDebugMode) {
          debugPrint('scrcpy input: cancelling a stale mouse touch');
        }
        _send(event, ScrcpyPointerAction.cancel, constraints);
        _activePrimaryMousePointers.clear();
      }
      _activePrimaryMousePointers.add(event.pointer);
    }
    _send(event, ScrcpyPointerAction.down, constraints);
  }

  void _handlePointerMove(PointerMoveEvent event, BoxConstraints constraints) {
    if (event.kind == PointerDeviceKind.mouse &&
        !_activePrimaryMousePointers.contains(event.pointer)) {
      return;
    }
    _send(event, ScrcpyPointerAction.move, constraints);
  }

  void _handlePointerEnd(
    PointerEvent event,
    ScrcpyPointerAction action,
    BoxConstraints constraints,
  ) {
    if (event.kind == PointerDeviceKind.mouse) {
      if (_activePrimaryMousePointers.isEmpty) return;
      _activePrimaryMousePointers.clear();
    }
    _send(event, action, constraints);
  }

  void _sendKeyClick(int keyCode) {
    _dispatch(widget.controller.sendKey(keyCode: keyCode));
    _dispatch(widget.controller.sendKey(keyCode: keyCode, down: false));
  }

  void _sendBackOrScreenOnClick() {
    final controller = widget.controller;
    if (controller is ScrcpyScreenPowerInputController) {
      final screenPowerController =
          controller as ScrcpyScreenPowerInputController;
      _dispatch(screenPowerController.sendBackOrScreenOn());
      _dispatch(screenPowerController.sendBackOrScreenOn(down: false));
    } else {
      _sendKeyClick(ScrcpyAndroidKeyCode.back);
    }
  }

  bool _sendKey(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return false;
    }
    final keyCode = _androidKeyCode(event.logicalKey);
    if (keyCode == null || event is KeyRepeatEvent) return false;
    _dispatch(
      widget.controller.sendKey(keyCode: keyCode, down: event is KeyDownEvent),
    );
    return true;
  }

  void _send(
    PointerEvent event,
    ScrcpyPointerAction action,
    BoxConstraints constraints, {
    Offset scrollDelta = Offset.zero,
  }) {
    final pointerId = event.kind == PointerDeviceKind.mouse
        ? ScrcpyPointerId.mouse
        : event.pointer;
    final width = constraints.maxWidth;
    final height = constraints.maxHeight;
    if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) {
      return;
    }
    var normalized = Offset(
      event.localPosition.dx / width,
      event.localPosition.dy / height,
    );
    final currentVideoSize = widget.videoSize;
    if (currentVideoSize != null) {
      final mapped = ScrcpyCoordinateMapper.map(
        localPosition: event.localPosition,
        widgetSize: Size(width, height),
        videoSize: currentVideoSize,
        fit: widget.fit,
        alignment: widget.alignment,
        edgeThreshold:
            event.kind == PointerDeviceKind.mouse &&
                action == ScrcpyPointerAction.down
            ? widget.gestureEdgeThreshold
            : 0,
      );
      if (mapped == null) {
        final lastPosition = _activePointerPositions[pointerId];
        if (lastPosition == null ||
            (action != ScrcpyPointerAction.up &&
                action != ScrcpyPointerAction.cancel)) {
          return;
        }
        normalized = lastPosition;
      } else {
        normalized = mapped;
      }
    }
    normalized = Offset(normalized.dx.clamp(0, 1), normalized.dy.clamp(0, 1));
    if (action == ScrcpyPointerAction.down ||
        action == ScrcpyPointerAction.move) {
      _activePointerPositions[pointerId] = normalized;
    } else if (action == ScrcpyPointerAction.up ||
        action == ScrcpyPointerAction.cancel) {
      _activePointerPositions.remove(pointerId);
    }
    _dispatch(
      widget.controller.sendPointer(
        ScrcpyPointerEvent(
          pointerId: pointerId,
          action: action,
          normalizedX: normalized.dx,
          normalizedY: normalized.dy,
          buttons: event.buttons,
          videoWidth: currentVideoSize?.width.round(),
          videoHeight: currentVideoSize?.height.round(),
          scrollDeltaX: scrollDelta.dx,
          scrollDeltaY: scrollDelta.dy,
        ),
      ),
    );
  }

  void _dispatch(Future<void> operation) {
    unawaited(
      operation.catchError((Object error) {
        if (kDebugMode) debugPrint('scrcpy input send failed: $error');
      }),
    );
  }
}

final class _HostGestureBlockerRecognizer extends OneSequenceGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    startTrackingPointer(event.pointer, event.transform);
    resolve(GestureDisposition.accepted);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'scrcpy host gesture blocker';
}

int? _androidKeyCode(LogicalKeyboardKey key) {
  final fixed = <LogicalKeyboardKey, int>{
    LogicalKeyboardKey.escape: ScrcpyAndroidKeyCode.back,
    LogicalKeyboardKey.home: ScrcpyAndroidKeyCode.home,
    LogicalKeyboardKey.enter: ScrcpyAndroidKeyCode.enter,
    LogicalKeyboardKey.numpadEnter: ScrcpyAndroidKeyCode.enter,
    LogicalKeyboardKey.backspace: ScrcpyAndroidKeyCode.backspace,
    LogicalKeyboardKey.delete: ScrcpyAndroidKeyCode.forwardDelete,
    LogicalKeyboardKey.tab: ScrcpyAndroidKeyCode.tab,
    LogicalKeyboardKey.space: ScrcpyAndroidKeyCode.space,
    LogicalKeyboardKey.arrowUp: ScrcpyAndroidKeyCode.dpadUp,
    LogicalKeyboardKey.arrowDown: ScrcpyAndroidKeyCode.dpadDown,
    LogicalKeyboardKey.arrowLeft: ScrcpyAndroidKeyCode.dpadLeft,
    LogicalKeyboardKey.arrowRight: ScrcpyAndroidKeyCode.dpadRight,
    LogicalKeyboardKey.audioVolumeUp: ScrcpyAndroidKeyCode.volumeUp,
    LogicalKeyboardKey.audioVolumeDown: ScrcpyAndroidKeyCode.volumeDown,
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
