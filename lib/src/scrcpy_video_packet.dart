import 'dart:typed_data';

final class ScrcpyVideoCodecInfo {
  const ScrcpyVideoCodecInfo({
    required this.codecId,
    required this.width,
    required this.height,
  });

  static const int h264 = 0x68323634;
  static const int h265 = 0x68323635;
  static const int av1 = 0x61763031;

  final int codecId;
  final int width;
  final int height;

  bool get isH264 => codecId == h264;
  bool get isH265 => codecId == h265;
  bool get isAv1 => codecId == av1;
}

final class ScrcpyVideoPacket {
  const ScrcpyVideoPacket({
    required this.presentationTimeUs,
    required this.isConfig,
    required this.isKeyFrame,
    required this.data,
  });

  final int presentationTimeUs;
  final bool isConfig;
  final bool isKeyFrame;
  final Uint8List data;
}

/// Incrementally parses scrcpy 4.x's dummy byte, codec id, session metadata
/// and video packets.
final class ScrcpyVideoPacketParser {
  ScrcpyVideoPacketParser({required this.onCodec, required this.onPacket});

  static const int _sessionFlag = 1 << 63;
  static const int _configFlag = 1 << 62;
  static const int _keyFrameFlag = 1 << 61;
  static const int _ptsMask = _keyFrameFlag - 1;
  static const int _maximumPacketSize = 16 * 1024 * 1024;

  final void Function(ScrcpyVideoCodecInfo codec) onCodec;
  final void Function(ScrcpyVideoPacket packet) onPacket;
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  var _bytes = Uint8List(0);
  var _offset = 0;
  var _dummyRead = false;
  int? _codecId;
  int? _packetSize;
  int? _packetPts;
  bool _packetIsConfig = false;
  bool _packetIsKeyFrame = false;

  void add(List<int> chunk) {
    if (chunk.isEmpty) return;
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
      if (!_dummyRead) {
        if (_available < 1) return;
        _offset++;
        _dummyRead = true;
      }
      if (_codecId == null) {
        if (_available < 4) return;
        final data = ByteData.sublistView(_bytes, _offset, _offset + 4);
        final codecId = data.getUint32(0, Endian.big);
        _offset += 4;
        if (codecId != ScrcpyVideoCodecInfo.h264 &&
            codecId != ScrcpyVideoCodecInfo.h265 &&
            codecId != ScrcpyVideoCodecInfo.av1) {
          throw FormatException(
            'Unsupported scrcpy codec: 0x${codecId.toRadixString(16)}',
          );
        }
        _codecId = codecId;
      }
      if (_packetSize == null) {
        if (_available < 12) return;
        final data = ByteData.sublistView(_bytes, _offset, _offset + 12);
        final ptsAndFlags = data.getUint64(0, Endian.big);
        if (ptsAndFlags & _sessionFlag != 0) {
          final codec = ScrcpyVideoCodecInfo(
            codecId: _codecId!,
            width: data.getUint32(4, Endian.big),
            height: data.getUint32(8, Endian.big),
          );
          _offset += 12;
          if (codec.width <= 0 || codec.height <= 0) {
            throw FormatException(
              'Invalid scrcpy session size: ${codec.width}x${codec.height}',
            );
          }
          onCodec(codec);
          continue;
        }
        final size = data.getUint32(8, Endian.big);
        _offset += 12;
        if (size == 0 || size > _maximumPacketSize) {
          throw FormatException('Invalid scrcpy video packet size: $size');
        }
        _packetSize = size;
        _packetPts = ptsAndFlags & _ptsMask;
        _packetIsConfig = ptsAndFlags & _configFlag != 0;
        _packetIsKeyFrame = ptsAndFlags & _keyFrameFlag != 0;
      }
      if (_available < _packetSize!) return;
      final payload = Uint8List.fromList(
        Uint8List.sublistView(_bytes, _offset, _offset + _packetSize!),
      );
      _offset += _packetSize!;
      onPacket(
        ScrcpyVideoPacket(
          presentationTimeUs: _packetPts!,
          isConfig: _packetIsConfig,
          isKeyFrame: _packetIsKeyFrame,
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
