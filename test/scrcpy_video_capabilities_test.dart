import 'package:flutter_test/flutter_test.dart';
import 'package:scrcpy_flutter/scrcpy_flutter.dart';

void main() {
  test('parses scrcpy 4.1 video encoder listing', () {
    const output = '''
[server] INFO: List of video encoders:
    --video-codec=h264 --video-encoder=c2.rk.avc.encoder (hw) [vendor]
    --video-codec=h264 --video-encoder=OMX.rk.avc (hw) [vendor] (alias for c2.rk.avc.encoder)
    --video-codec=h265 --video-encoder=c2.android.hevc.encoder (sw)
    --video-codec=av1 --video-encoder=c2.android.av1.encoder (sw)
    --video-codec=vp9 --video-encoder=c2.android.vp9.encoder (sw)
''';

    final capabilities = ScrcpyVideoCapabilities.parseServerOutput(output);

    expect(capabilities.encoders, hasLength(4));
    expect(capabilities.deviceEncoderCodecs, <ScrcpyVideoCodec>{
      ScrcpyVideoCodec.h264,
      ScrcpyVideoCodec.h265,
      ScrcpyVideoCodec.av1,
    });
    final h264 = capabilities.forCodec(ScrcpyVideoCodec.h264);
    expect(h264, hasLength(1));
    expect(h264.single.name, 'c2.rk.avc.encoder');
    expect(h264.single.hardware, isTrue);
    expect(h264.single.vendor, isTrue);
    expect(
      capabilities.forCodec(ScrcpyVideoCodec.h264, includeAliases: true),
      hasLength(2),
    );
  });

  test('declares only codecs implemented by the native backend', () {
    expect(ScrcpyVideoCapabilities.nativeDecoderCodecs, <ScrcpyVideoCodec>{
      ScrcpyVideoCodec.h264,
    });
  });
}
