import 'dart:typed_data';
import 'dart:ui' as ui;

import 'scrcpy_capture_writer.dart';
import 'scrcpy_error.dart';

/// A PNG snapshot of the most recently decoded scrcpy video frame.
final class ScrcpyScreenshot {
  const ScrcpyScreenshot({
    required this.width,
    required this.height,
    required this.pngBytes,
  });

  final int width;
  final int height;
  final Uint8List pngBytes;

  /// Saves the PNG and creates missing parent directories when supported.
  Future<void> saveToFile(String path) async {
    try {
      await writeScrcpyCapture(path, pngBytes);
    } catch (error) {
      throw ScrcpyException(
        ScrcpyErrorCode.captureFailure,
        'Unable to save screenshot to $path',
        cause: error,
      );
    }
  }

  static Future<ScrcpyScreenshot> fromRgba({
    required int width,
    required int height,
    required Uint8List pixels,
  }) async {
    final expectedLength = width * height * 4;
    if (width <= 0 || height <= 0 || pixels.length != expectedLength) {
      throw StateError(
        'Invalid RGBA frame: ${width}x$height, '
        '${pixels.length} bytes (expected $expectedLength)',
      );
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: width,
      height: height,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('Flutter failed to encode PNG');
      return ScrcpyScreenshot(
        width: width,
        height: height,
        pngBytes: data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        ),
      );
    } finally {
      image.dispose();
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
    }
  }
}
