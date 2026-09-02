import 'scrcpy_session.dart';

final class ScrcpyVideoEncoder {
  const ScrcpyVideoEncoder({
    required this.codec,
    required this.name,
    required this.hardware,
    required this.vendor,
    this.aliasFor,
  });

  final ScrcpyVideoCodec codec;
  final String name;
  final bool hardware;
  final bool vendor;
  final String? aliasFor;

  bool get isAlias => aliasFor != null;
}

final class ScrcpyVideoCapabilities {
  const ScrcpyVideoCapabilities({required this.encoders});

  final List<ScrcpyVideoEncoder> encoders;

  /// Codecs currently implemented by this plugin's Windows Texture backend.
  static const Set<ScrcpyVideoCodec> nativeDecoderCodecs = <ScrcpyVideoCodec>{
    ScrcpyVideoCodec.h264,
  };

  Set<ScrcpyVideoCodec> get deviceEncoderCodecs =>
      encoders.map((encoder) => encoder.codec).toSet();

  List<ScrcpyVideoEncoder> forCodec(
    ScrcpyVideoCodec codec, {
    bool includeAliases = false,
  }) => <ScrcpyVideoEncoder>[
    for (final encoder in encoders)
      if (encoder.codec == codec && (includeAliases || !encoder.isAlias))
        encoder,
  ];

  static ScrcpyVideoCapabilities parseServerOutput(String output) {
    final encoders = <ScrcpyVideoEncoder>[];
    final pattern = RegExp(
      r'--video-codec=(h264|h265|av1)\s+'
      r'--video-encoder=([^\s]+)\s+'
      r'\((hw|sw)\)'
      r'(\s+\[vendor\])?'
      r'(?:\s+\(alias for ([^)]+)\))?',
    );
    for (final match in pattern.allMatches(output)) {
      final codecName = match.group(1)!;
      final codec = ScrcpyVideoCodec.values.firstWhere(
        (candidate) => candidate.serverName == codecName,
      );
      encoders.add(
        ScrcpyVideoEncoder(
          codec: codec,
          name: match.group(2)!,
          hardware: match.group(3) == 'hw',
          vendor: match.group(4) != null,
          aliasFor: match.group(5),
        ),
      );
    }
    return ScrcpyVideoCapabilities(encoders: List.unmodifiable(encoders));
  }
}
