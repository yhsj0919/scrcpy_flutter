import 'dart:typed_data';

enum ScrcpyAudioCodec {
  opus('opus', 0x6f707573, 'Opus'),
  aac('aac', 0x6d703461, 'AAC'),
  flac('flac', 0x664c6143, 'FLAC'),
  raw('raw', 0x72617720, 'Raw PCM');

  const ScrcpyAudioCodec(this.serverName, this.codecId, this.label);

  final String serverName;
  final int codecId;
  final String label;
}

final class ScrcpyAudioCodecInfo {
  const ScrcpyAudioCodecInfo({required this.codecId});

  final int codecId;

  ScrcpyAudioCodec get codec => ScrcpyAudioCodec.values.firstWhere(
    (candidate) => candidate.codecId == codecId,
  );
}

final class ScrcpyAudioPacket {
  const ScrcpyAudioPacket({
    required this.presentationTimeUs,
    required this.isConfig,
    required this.data,
  });

  final int presentationTimeUs;
  final bool isConfig;
  final Uint8List data;
}

/// Incrementally parses a scrcpy 4.x audio stream.
///
/// The stream starts with a four-byte codec id. A zero codec id means that
/// audio capture is unavailable. Encoded packets then use scrcpy's common
/// 12-byte PTS/flags/size frame header.
final class ScrcpyAudioPacketParser {
  ScrcpyAudioPacketParser({
    required this.onCodec,
    required this.onPacket,
    required this.onDisabled,
  });

  static const int _disabledCodecId = 0;
  static const int _configFlag = 1 << 62;
  static const int _ptsMask = _configFlag - 1;
  static const int _maximumPacketSize = 4 * 1024 * 1024;

  final void Function(ScrcpyAudioCodecInfo codec) onCodec;
  final void Function(ScrcpyAudioPacket packet) onPacket;
  final void Function() onDisabled;
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  var _bytes = Uint8List(0);
  var _offset = 0;
  int? _codecId;
  int? _packetSize;
  int? _packetPts;
  bool _packetIsConfig = false;
  bool _disabled = false;

  void add(List<int> chunk) {
    if (chunk.isEmpty || _disabled) return;
    if (_offset < _bytes.length) {
      _buffer.add(Uint8List.sublistView(_bytes, _offset));
    }
    _buffer.add(chunk);
    _bytes = _buffer.takeBytes();
    _offset = 0;
    _parse();
  }

  void _parse() {
    while (true) {
      if (_codecId == null) {
        if (_available < 4) return;
        final codecId = ByteData.sublistView(
          _bytes,
          _offset,
          _offset + 4,
        ).getUint32(0, Endian.big);
        _offset += 4;
        if (codecId == _disabledCodecId) {
          _disabled = true;
          onDisabled();
          return;
        }
        if (!ScrcpyAudioCodec.values.any(
          (candidate) => candidate.codecId == codecId,
        )) {
          throw FormatException(
            'Unsupported scrcpy audio codec: 0x${codecId.toRadixString(16)}',
          );
        }
        _codecId = codecId;
        onCodec(ScrcpyAudioCodecInfo(codecId: codecId));
      }
      if (_packetSize == null) {
        if (_available < 12) return;
        final data = ByteData.sublistView(_bytes, _offset, _offset + 12);
        final ptsAndFlags = data.getUint64(0, Endian.big);
        final size = data.getUint32(8, Endian.big);
        _offset += 12;
        if (size == 0 || size > _maximumPacketSize) {
          throw FormatException('Invalid scrcpy audio packet size: $size');
        }
        _packetSize = size;
        _packetPts = ptsAndFlags & _ptsMask;
        _packetIsConfig = ptsAndFlags & _configFlag != 0;
      }
      if (_available < _packetSize!) return;
      final payload = Uint8List.fromList(
        Uint8List.sublistView(_bytes, _offset, _offset + _packetSize!),
      );
      _offset += _packetSize!;
      onPacket(
        ScrcpyAudioPacket(
          presentationTimeUs: _packetPts!,
          isConfig: _packetIsConfig,
          data: payload,
        ),
      );
      _packetSize = null;
      if (_offset == _bytes.length) {
        _bytes = Uint8List(0);
        _offset = 0;
        return;
      }
    }
  }

  int get _available => _bytes.length - _offset;
}
