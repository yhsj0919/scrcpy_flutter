import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:scrcpy_flutter/scrcpy_advanced.dart';

void main() {
  test('accepts all scrcpy 4.1 audio codec identifiers', () {
    for (final selected in ScrcpyAudioCodec.values) {
      ScrcpyAudioCodecInfo? codec;
      final parser = ScrcpyAudioPacketParser(
        onCodec: (value) => codec = value,
        onPacket: (_) {},
        onDisabled: () => fail('audio must not be disabled'),
      );
      parser.add(_u32(selected.codecId));
      expect(codec?.codec, selected);
    }
  });

  test('reports a zero codec id as unavailable audio', () {
    var disabled = false;
    final parser = ScrcpyAudioPacketParser(
      onCodec: (_) => fail('disabled audio has no codec'),
      onPacket: (_) => fail('disabled audio has no packets'),
      onDisabled: () => disabled = true,
    );
    parser.add(_u32(0));
    expect(disabled, isTrue);
  });

  test('parses arbitrarily split config and Opus packets', () {
    ScrcpyAudioCodecInfo? codec;
    final packets = <ScrcpyAudioPacket>[];
    final parser = ScrcpyAudioPacketParser(
      onCodec: (value) => codec = value,
      onPacket: packets.add,
      onDisabled: () => fail('audio must not be disabled'),
    );
    final bytes = BytesBuilder()
      ..add(_u32(ScrcpyAudioCodec.opus.codecId))
      ..add(_u64((1 << 62) | 1234))
      ..add(_u32(3))
      ..add(<int>[1, 2, 3])
      ..add(_u64(5678))
      ..add(_u32(2))
      ..add(<int>[4, 5]);
    final stream = bytes.takeBytes();
    for (var offset = 0; offset < stream.length; offset += 2) {
      parser.add(
        Uint8List.sublistView(
          stream,
          offset,
          (offset + 2).clamp(0, stream.length),
        ),
      );
    }

    expect(codec?.codec, ScrcpyAudioCodec.opus);
    expect(packets, hasLength(2));
    expect(packets.first.presentationTimeUs, 1234);
    expect(packets.first.isConfig, isTrue);
    expect(packets.first.data, <int>[1, 2, 3]);
    expect(packets.last.presentationTimeUs, 5678);
    expect(packets.last.isConfig, isFalse);
    expect(packets.last.data, <int>[4, 5]);
  });

  test('rejects unknown codecs and invalid packet sizes', () {
    ScrcpyAudioPacketParser parser() => ScrcpyAudioPacketParser(
      onCodec: (_) {},
      onPacket: (_) {},
      onDisabled: () {},
    );

    expect(() => parser().add(_u32(0x12345678)), throwsFormatException);
    expect(
      () => parser().add(
        (BytesBuilder()
              ..add(_u32(ScrcpyAudioCodec.opus.codecId))
              ..add(_u64(1))
              ..add(_u32(0)))
            .takeBytes(),
      ),
      throwsFormatException,
    );
  });

  test('validates require-audio and audio bitrate options', () {
    expect(
      () => const ScrcpySessionConfiguration(
        deviceSerial: 'device',
        audioRequired: true,
      ).validate(),
      throwsArgumentError,
    );
    expect(
      () => const ScrcpySessionConfiguration(
        deviceSerial: 'device',
        audioEnabled: true,
        audio: ScrcpyAudioOptions(bitRate: 7999),
      ).validate(),
      throwsRangeError,
    );
    expect(
      () => const ScrcpySessionConfiguration(
        deviceSerial: 'device',
        audioEnabled: true,
        audioRequired: true,
      ).validate(),
      returnsNormally,
    );
    expect(
      () => const ScrcpySessionConfiguration(
        deviceSerial: 'device',
        audioEnabled: true,
        audio: ScrcpyAudioOptions(initialVolume: 1.1),
      ).validate(),
      throwsRangeError,
    );
  });

  test('resolves automatic audio source by Android SDK', () {
    const automatic = ScrcpyAudioOptions();
    expect(automatic.resolveSourceForAndroidSdk(30), ScrcpyAudioSource.output);
    expect(
      automatic.resolveSourceForAndroidSdk(31),
      ScrcpyAudioSource.playback,
    );
    expect(
      automatic.resolveSourceForAndroidSdk(36),
      ScrcpyAudioSource.playback,
    );
    expect(
      automatic.resolveSourceForAndroidSdk(null),
      ScrcpyAudioSource.output,
    );
    expect(
      const ScrcpyAudioOptions(source: ScrcpyAudioSource.output)
          .resolveSourceForAndroidSdk(36),
      ScrcpyAudioSource.output,
    );
  });
}

Uint8List _u32(int value) =>
    (ByteData(4)..setUint32(0, value, Endian.big)).buffer.asUint8List();

Uint8List _u64(int value) =>
    (ByteData(8)..setUint64(0, value, Endian.big)).buffer.asUint8List();
