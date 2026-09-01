import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

enum ScrcpyVideoStatus { idle, buffering, ready, ended, error }

final class ScrcpyVideoState {
  const ScrcpyVideoState({
    required this.status,
    this.textureId,
    this.width,
    this.height,
    this.decoder,
    this.bytesReceived = 0,
    this.packetsReceived = 0,
    this.framesRendered = 0,
    this.framesPerSecond = 0,
    this.error,
  });

  const ScrcpyVideoState.idle()
    : status = ScrcpyVideoStatus.idle,
      textureId = null,
      width = null,
      height = null,
      decoder = null,
      bytesReceived = 0,
      packetsReceived = 0,
      framesRendered = 0,
      framesPerSecond = 0,
      error = null;

  final ScrcpyVideoStatus status;
  final int? textureId;
  final int? width;
  final int? height;
  final String? decoder;
  final int bytesReceived;
  final int packetsReceived;
  final int framesRendered;
  final double framesPerSecond;
  final Object? error;

  double? get aspectRatio =>
      width != null && height != null && height! > 0 ? width! / height! : null;
}

abstract interface class ScrcpyVideoController
    implements ValueListenable<ScrcpyVideoState> {
  Future<void> start();

  Future<void> stop();

  void dispose();
}

/// A composable texture widget. The decoder implementation remains behind the
/// controller and is not exposed to embedding applications.
final class ScrcpyVideoView extends StatelessWidget {
  const ScrcpyVideoView({
    required this.controller,
    this.fit = BoxFit.contain,
    this.placeholder,
    super.key,
  });

  final ScrcpyVideoController controller;
  final BoxFit fit;
  final Widget? placeholder;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<ScrcpyVideoState>(
        valueListenable: controller,
        builder: (context, state, _) {
          final textureId = state.textureId;
          if (textureId == null || state.status != ScrcpyVideoStatus.ready) {
            return placeholder ?? const SizedBox.expand();
          }
          return FittedBox(
            fit: fit,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: state.width?.toDouble() ?? 1,
              height: state.height?.toDouble() ?? 1,
              child: Texture(textureId: textureId),
            ),
          );
        },
      );
}
