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
  static const int backOrScreenOnType = 4;
  static const int getClipboardType = 8;
  static const int setClipboardType = 9;
  static const int startApplicationType = 16;
  static const int resizeDisplayType = 21;
  static const int maxClipboardTextLength = (1 << 18) - 14;

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

  static Uint8List backOrScreenOn({required bool down}) =>
      Uint8List.fromList(<int>[backOrScreenOnType, down ? 0 : 1]);

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

  static Uint8List getClipboard({ScrcpyCopyKey copyKey = ScrcpyCopyKey.none}) =>
      Uint8List.fromList(<int>[getClipboardType, copyKey.index]);

  static Uint8List setClipboard({
    required String text,
    required int sequence,
    bool paste = false,
  }) {
    final payload = utf8.encode(text);
    if (payload.length > maxClipboardTextLength) {
      throw ArgumentError.value(
        text,
        'text',
        'UTF-8 clipboard text exceeds $maxClipboardTextLength bytes',
      );
    }
    final result = Uint8List(14 + payload.length);
    ByteData.sublistView(result)
      ..setUint8(0, setClipboardType)
      ..setUint64(1, sequence, Endian.big)
      ..setUint8(9, paste ? 1 : 0)
      ..setUint32(10, payload.length, Endian.big);
    result.setRange(14, result.length, payload);
    return result;
  }

  static Uint8List startApplication(String name) {
    final payload = utf8.encode(name);
    if (payload.isEmpty || payload.length > 255) {
      throw ArgumentError.value(
        name,
        'name',
        'UTF-8 application name must contain 1 to 255 bytes',
      );
    }
    final result = Uint8List(2 + payload.length)
      ..[0] = startApplicationType
      ..[1] = payload.length;
    result.setRange(2, result.length, payload);
    return result;
  }

  static Uint8List resizeDisplay({required int width, required int height}) {
    if (width <= 0 || width > 0xffff) {
      throw RangeError.range(width, 1, 0xffff, 'width');
    }
    if (height <= 0 || height > 0xffff) {
      throw RangeError.range(height, 1, 0xffff, 'height');
    }
    final data = ByteData(5)
      ..setUint8(0, resizeDisplayType)
      ..setUint16(1, width, Endian.big)
      ..setUint16(3, height, Endian.big);
    return data.buffer.asUint8List();
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

sealed class ScrcpyDeviceMessage {
  const ScrcpyDeviceMessage();
}

final class ScrcpyClipboardMessage extends ScrcpyDeviceMessage {
  const ScrcpyClipboardMessage(this.text);

  final String text;
}

final class ScrcpyClipboardAckMessage extends ScrcpyDeviceMessage {
  const ScrcpyClipboardAckMessage(this.sequence);

  final int sequence;
}

final class ScrcpyUhidOutputMessage extends ScrcpyDeviceMessage {
  const ScrcpyUhidOutputMessage(this.id, this.data);

  final int id;
  final Uint8List data;
}

/// Incremental scrcpy 4.1 device-to-client message parser.
final class ScrcpyDeviceMessageParser {
  static const int _clipboard = 0;
  static const int _ackClipboard = 1;
  static const int _uhidOutput = 2;

  Uint8List _buffer = Uint8List(0);

  List<ScrcpyDeviceMessage> add(List<int> chunk) {
    if (chunk.isNotEmpty) {
      final merged = Uint8List(_buffer.length + chunk.length)
        ..setRange(0, _buffer.length, _buffer)
        ..setRange(_buffer.length, _buffer.length + chunk.length, chunk);
      _buffer = merged;
    }
    final messages = <ScrcpyDeviceMessage>[];
    var offset = 0;
    while (offset < _buffer.length) {
      final available = _buffer.length - offset;
      final type = _buffer[offset];
      int? messageLength;
      ScrcpyDeviceMessage? message;
      if (type == _clipboard) {
        if (available < 5) break;
        final length = ByteData.sublistView(_buffer)
            .getUint32(offset + 1, Endian.big);
        if (length > ScrcpyControlMessageSerializer.maxClipboardTextLength) {
          throw FormatException('scrcpy clipboard message is too large');
        }
        messageLength = 5 + length;
        if (available < messageLength) break;
        message = ScrcpyClipboardMessage(
          utf8.decode(_buffer.sublist(offset + 5, offset + messageLength)),
        );
      } else if (type == _ackClipboard) {
        messageLength = 9;
        if (available < messageLength) break;
        message = ScrcpyClipboardAckMessage(
          ByteData.sublistView(_buffer).getUint64(offset + 1, Endian.big),
        );
      } else if (type == _uhidOutput) {
        if (available < 5) break;
        final id = ByteData.sublistView(_buffer)
            .getUint16(offset + 1, Endian.big);
        final length = ByteData.sublistView(_buffer)
            .getUint16(offset + 3, Endian.big);
        messageLength = 5 + length;
        if (available < messageLength) break;
        message = ScrcpyUhidOutputMessage(
          id,
          Uint8List.fromList(
            _buffer.sublist(offset + 5, offset + messageLength),
          ),
        );
      } else {
        throw FormatException('Unknown scrcpy device message type $type');
      }
      messages.add(message);
      offset += messageLength;
    }
    if (offset != 0) _buffer = Uint8List.fromList(_buffer.sublist(offset));
    return messages;
  }
}
