import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'scrcpy_input.dart';

/// Debounces preview layout changes and resizes a flex virtual display.
final class ScrcpyAdaptiveDisplayController {
  ScrcpyAdaptiveDisplayController({
    required this.input,
    this.maxSize = 1920,
    this.minSize = 160,
    this.alignment = 2,
    this.changeThreshold = 16,
    this.debounce = const Duration(milliseconds: 250),
    this.onResized,
    this.onError,
  }) {
    if (maxSize < 2 || maxSize > 16384) {
      throw RangeError.range(maxSize, 2, 16384, 'maxSize');
    }
    if (minSize < 2 || minSize > maxSize) {
      throw RangeError.range(minSize, 2, maxSize, 'minSize');
    }
    if (alignment < 1 || alignment > 16 || (alignment & (alignment - 1)) != 0) {
      throw ArgumentError.value(
        alignment,
        'alignment',
        'must be 1, 2, 4, 8 or 16',
      );
    }
    if (changeThreshold < 0) {
      throw RangeError.value(
        changeThreshold,
        'changeThreshold',
        'must be >= 0',
      );
    }
  }

  final ScrcpyInputController input;
  final int maxSize;
  final int minSize;
  final int alignment;
  final int changeThreshold;
  final Duration debounce;
  final ValueChanged<Size>? onResized;
  final void Function(Object error, StackTrace stackTrace)? onError;

  Timer? _timer;
  Size? _pending;
  Size? _lastSent;
  Future<void> _writes = Future<void>.value();
  bool _disposed = false;

  Size? get lastSentSize => _lastSent;

  /// Updates the available preview area in logical pixels.
  void updatePreview(Size previewSize) {
    if (_disposed ||
        previewSize.isEmpty ||
        !previewSize.width.isFinite ||
        !previewSize.height.isFinite) {
      return;
    }
    final target = calculateTargetSize(
      previewSize,
      maxSize: maxSize,
      minSize: minSize,
      alignment: alignment,
    );
    if (_pending == target || !_isSignificant(target)) return;
    _pending = target;
    _timer?.cancel();
    _timer = Timer(debounce, _flush);
  }

  Future<void> flush() async {
    _timer?.cancel();
    await _flush();
    await _writes;
  }

  Future<void> _flush() async {
    if (_disposed) return;
    final target = _pending;
    _pending = null;
    if (target == null || !_isSignificant(target)) return;
    _writes = _writes.then((_) async {
      try {
        await input.resizeDisplay(
          width: target.width.round(),
          height: target.height.round(),
        );
        _lastSent = target;
        onResized?.call(target);
      } catch (error, stackTrace) {
        onError?.call(error, stackTrace);
      }
    });
    await _writes;
  }

  /// Cancels a resize which is still waiting for the debounce interval.
  void cancelPending() {
    _timer?.cancel();
    _timer = null;
    _pending = null;
  }

  bool _isSignificant(Size target) {
    final previous = _lastSent;
    if (previous == null) return true;
    return (target.width - previous.width).abs() >= changeThreshold ||
        (target.height - previous.height).abs() >= changeThreshold;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    cancelPending();
  }

  static Size calculateTargetSize(
    Size previewSize, {
    required int maxSize,
    int minSize = 160,
    int alignment = 2,
  }) {
    if (previewSize.isEmpty ||
        !previewSize.width.isFinite ||
        !previewSize.height.isFinite) {
      throw ArgumentError.value(
        previewSize,
        'previewSize',
        'must be finite and non-empty',
      );
    }
    var scale = math.min(
      1.0,
      maxSize / math.max(previewSize.width, previewSize.height),
    );
    var width = previewSize.width * scale;
    var height = previewSize.height * scale;
    final shortSide = math.min(width, height);
    if (shortSide < minSize) {
      scale = minSize / shortSide;
      width *= scale;
      height *= scale;
      final longSide = math.max(width, height);
      if (longSide > maxSize) {
        final cap = maxSize / longSide;
        width *= cap;
        height *= cap;
      }
    }
    final alignedMaximum = (maxSize ~/ alignment) * alignment;
    int align(double value) {
      final aligned = (value / alignment).round() * alignment;
      return aligned.clamp(alignment, alignedMaximum);
    }

    return Size(align(width).toDouble(), align(height).toDouble());
  }
}
