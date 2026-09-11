import 'package:adb_client/adb_client.dart';

import 'scrcpy_session.dart';
import 'scrcpy_audio.dart';
import 'scrcpy_audio_packet.dart';
import 'scrcpy_input.dart';
import 'scrcpy_video_packet.dart';
import 'scrcpy_video.dart';
import 'scrcpy_video_connection_stub.dart'
    if (dart.library.io) 'scrcpy_video_connection_io.dart'
    as implementation;

final class ScrcpyVideoConnectionInfo {
  const ScrcpyVideoConnectionInfo({
    required this.scid,
    required this.localPort,
    required this.remoteServerPath,
  });

  final String scid;
  final int localPort;
  final String remoteServerPath;
}

abstract interface class ScrcpyAudioStream {
  /// Resolves to null when scrcpy reports that capture is unavailable.
  Future<ScrcpyAudioCodecInfo?> get codec;

  Stream<ScrcpyAudioPacket> get packets;

  int get bytesReceived;

  Future<void> get done;
}

abstract interface class ScrcpyVideoConnection {
  ScrcpyVideoConnectionInfo get info;

  Future<ScrcpyVideoCodecInfo> get codec;

  /// Emits the initial dimensions and later scrcpy session size changes.
  Stream<ScrcpyVideoCodecInfo> get sessions;

  Stream<ScrcpyVideoPacket> get packets;

  ScrcpyInputController? get input;

  ScrcpyAudioStream? get audio;

  int get bytesReceived;

  /// Completes when the underlying video transport closes.
  Future<void> get done;

  Future<void> close();
}

/// A platform connection which already owns its decoder and Flutter texture.
abstract interface class ScrcpyVideoControllerProvider {
  ScrcpyVideoController createVideoController();
}

/// A platform connection which owns audio capture, decoding and playback.
abstract interface class ScrcpyAudioControllerProvider {
  ScrcpyAudioController createAudioController();
}


abstract interface class ScrcpyVideoConnector {
  Future<ScrcpyVideoConnection> connect(
    ScrcpySessionConfiguration configuration, {
    AdbCancellationToken? cancellationToken,
  });
}

ScrcpyVideoConnector createScrcpyVideoConnector({
  required AdbClient adbClient,
  required String serverPath,
  String? expectedServerSha256,
}) => implementation.createScrcpyVideoConnector(
  adbClient: adbClient,
  serverPath: serverPath,
  expectedServerSha256: expectedServerSha256,
);
