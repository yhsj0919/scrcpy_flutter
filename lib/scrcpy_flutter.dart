/// Ready-to-use API for embedding Android displays in Flutter applications.
///
/// Import `scrcpy_advanced.dart` only for custom transports, decoders,
/// protocol tooling, or diagnostics.
library;

export 'src/default_scrcpy_client.dart' show createDefaultScrcpyManager;
export 'src/scrcpy_audio_packet.dart' show ScrcpyAudioCodec;
export 'src/scrcpy_audio.dart' show ScrcpyAudioController, ScrcpyAudioState;
export 'src/scrcpy_capture.dart' show ScrcpyScreenshot;
export 'src/scrcpy_display_source.dart'
    show ScrcpyDisplayImePolicy, ScrcpyVirtualDisplayClosePolicy;
export 'src/scrcpy_error.dart';
export 'src/scrcpy_facade.dart';
export 'src/scrcpy_input.dart' show ScrcpyAndroidKeyCode, ScrcpyInputController;
export 'src/scrcpy_session.dart'
    show
        ScrcpyAudioOptions,
        ScrcpyAudioSource,
        ScrcpyReconnectPolicy,
        ScrcpySessionState,
        ScrcpyVideoCodec,
        ScrcpyVideoOptions;
export 'src/scrcpy_video.dart'
    show ScrcpyVideoController, ScrcpyVideoState, ScrcpyVideoStatus;
