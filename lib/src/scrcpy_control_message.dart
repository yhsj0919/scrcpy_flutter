import 'dart:convert';
import 'dart:typed_data';

import 'scrcpy_input.dart';

/// scrcpy 4.1 client-to-device control message serializer.
final class ScrcpyControlMessageSerializer {
  const ScrcpyControlMessageSerializer._();

  static const int injectKeycode = 0;
  static const int injectText = 1;
  static const int injectTouch = 2;
  static const int injectScroll = 3;

  static Uint8List key({
    required int keyCode,
    required bool down,
    int repeat = 0,
    int metaState = 0,
  }) {
    final data = ByteData(14)
      ..setUint8(0, injectKeycode)
      ..setUint8(1, down ? 0 : 1)
      ..setUint32(2, keyCode, Endian.big)
      ..setUint32(6, repeat, Endian.big)
      ..setUint32(10, metaState, Endian.big);
    return data.buffer.asUint8List();
  }

  static Uint8List text(String value) {
    final payload = utf8.encode(value);
    if (payload.length > 300) {
      throw ArgumentError.value(value, 'value', 'UTF-8 text exceeds 300 bytes');
    }
    final result = Uint8List(5 + payload.length);
    ByteData.sublistView(result)
      ..setUint8(0, injectText)
      ..setUint32(1, payload.length, Endian.big);
    result.setRange(5, result.length, payload);
    return result;
  }

  static Uint8List pointer(
    ScrcpyPointerEvent event, {
    required int videoWidth,
    required int videoHeight,
  }) {
    if (videoWidth <= 0 || videoWidth > 0xffff) {
      throw RangeError.range(videoWidth, 1, 0xffff, 'videoWidth');
    }
    if (videoHeight <= 0 || videoHeight > 0xffff) {
      throw RangeError.range(videoHeight, 1, 0xffff, 'videoHeight');
    }
    final action = switch (event.action) {
      ScrcpyPointerAction.down => 0,
      ScrcpyPointerAction.up => 1,
      ScrcpyPointerAction.move => 2,
      ScrcpyPointerAction.cancel => 3,
      ScrcpyPointerAction.hover => 7,
      ScrcpyPointerAction.scroll => throw ArgumentError(
        'Scroll uses a different scrcpy control message',
      ),
    };
    final x = (event.normalizedX.clamp(0.0, 1.0) * (videoWidth - 1)).round();
    final y = (event.normalizedY.clamp(0.0, 1.0) * (videoHeight - 1)).round();
    final pressed =
        event.action != ScrcpyPointerAction.up &&
        event.action != ScrcpyPointerAction.cancel;
    final data = ByteData(32)
      ..setUint8(0, injectTouch)
      ..setUint8(1, action)
      ..setUint64(2, event.pointerId, Endian.big)
      ..setUint32(10, x, Endian.big)
      ..setUint32(14, y, Endian.big)
      ..setUint16(18, videoWidth, Endian.big)
      ..setUint16(20, videoHeight, Endian.big)
      ..setUint16(22, pressed ? 0xffff : 0, Endian.big)
      ..setUint32(24, event.buttons, Endian.big)
      ..setUint32(28, pressed ? event.buttons : 0, Endian.big);
    return data.buffer.asUint8List();
  }

  static Uint8List scroll({
    required double normalizedX,
    required double normalizedY,
    required int videoWidth,
    required int videoHeight,
    required double horizontal,
    required double vertical,
    int buttons = 0,
  }) {
    if (videoWidth <= 0 || videoWidth > 0xffff) {
      throw RangeError.range(videoWidth, 1, 0xffff, 'videoWidth');
    }
    if (videoHeight <= 0 || videoHeight > 0xffff) {
      throw RangeError.range(videoHeight, 1, 0xffff, 'videoHeight');
    }
    final x = (normalizedX.clamp(0.0, 1.0) * (videoWidth - 1)).round();
    final y = (normalizedY.clamp(0.0, 1.0) * (videoHeight - 1)).round();
    int fixed(double value) => ((value / 16).clamp(-1.0, 1.0) * 0x7fff).round();
    final data = ByteData(21)
      ..setUint8(0, injectScroll)
      ..setUint32(1, x, Endian.big)
      ..setUint32(5, y, Endian.big)
      ..setUint16(9, videoWidth, Endian.big)
      ..setUint16(11, videoHeight, Endian.big)
      ..setInt16(13, fixed(horizontal), Endian.big)
      ..setInt16(15, fixed(vertical), Endian.big)
      ..setUint32(17, buttons, Endian.big);
    return data.buffer.asUint8List();
  }
}
