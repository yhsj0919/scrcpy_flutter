import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:scrcpy_flutter/scrcpy_flutter.dart';

void main() {
  test('parses arbitrarily split scrcpy codec metadata and video packets', () {
    ScrcpyVideoCodecInfo? codec;
    final packets = <ScrcpyVideoPacket>[];
    final parser = ScrcpyVideoPacketParser(
      onCodec: (value) => codec = value,
      onPacket: packets.add,
    );
    final bytes = BytesBuilder()
      ..addByte(0)
      ..add(_u32(ScrcpyVideoCodecInfo.h264))
      ..add(_session(1080, 2400))
      ..add(_u64((1 << 62) | 1234))
      ..add(_u32(4))
      ..add(<int>[0, 0, 0, 1])
      ..add(_u64((1 << 61) | 5678))
      ..add(_u32(3))
      ..add(<int>[5, 6, 7]);
    final stream = bytes.takeBytes();
    for (var offset = 0; offset < stream.length;) {
      final end = (offset + 3).clamp(0, stream.length);
      parser.add(Uint8List.sublistView(stream, offset, end));
      offset = end;
    }

    expect(codec?.codecId, ScrcpyVideoCodecInfo.h264);
    expect(codec?.width, 1080);
    expect(codec?.height, 2400);
    expect(packets, hasLength(2));
    expect(packets.first.presentationTimeUs, 1234);
    expect(packets.first.isConfig, isTrue);
    expect(packets.first.data, <int>[0, 0, 0, 1]);
    expect(packets.last.presentationTimeUs, 5678);
    expect(packets.last.isKeyFrame, isTrue);
    expect(packets.last.data, <int>[5, 6, 7]);
  });

  test(
    'consumes recurring session packets without treating them as frames',
    () {
      final codecs = <ScrcpyVideoCodecInfo>[];
      final packets = <ScrcpyVideoPacket>[];
      final parser = ScrcpyVideoPacketParser(
        onCodec: codecs.add,
        onPacket: packets.add,
      );

      final bytes = BytesBuilder()
        ..addByte(0)
        ..add(_u32(ScrcpyVideoCodecInfo.h264))
        ..add(_session(1080, 2400))
        ..add(_session(2400, 1080, clientResized: true))
        ..add(_u64(42))
        ..add(_u32(1))
        ..addByte(7);
      parser.add(bytes.takeBytes());

      expect(codecs.map((codec) => (codec.width, codec.height)), <(int, int)>[
        (1080, 2400),
        (2400, 1080),
      ]);
      expect(packets, hasLength(1));
      expect(packets.single.presentationTimeUs, 42);
    },
  );
}

Uint8List _session(int width, int height, {bool clientResized = false}) {
  final data = ByteData(12)
    ..setUint32(0, 0x80000000 | (clientResized ? 1 : 0), Endian.big)
    ..setUint32(4, width, Endian.big)
    ..setUint32(8, height, Endian.big);
  return data.buffer.asUint8List();
}

Uint8List _u32(int value) =>
    (ByteData(4)..setUint32(0, value, Endian.big)).buffer.asUint8List();

Uint8List _u64(int value) =>
    (ByteData(8)..setUint64(0, value, Endian.big)).buffer.asUint8List();
