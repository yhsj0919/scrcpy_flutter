import 'package:flutter/foundation.dart';

enum ScrcpyAudioStatus { idle, buffering, ready, ended, error }

final class ScrcpyAudioState {
  const ScrcpyAudioState({
    required this.status,
    this.codec,
    this.muted = false,
    this.volume = 1,
    this.packetsReceived = 0,
    this.bytesReceived = 0,
    this.decodedPackets = 0,
    this.playedBuffers = 0,
    this.droppedBuffers = 0,
    this.bufferedBytes = 0,
    this.peakSample = 0,
    this.error,
  });

  const ScrcpyAudioState.idle()
    : status = ScrcpyAudioStatus.idle,
      codec = null,
      muted = false,
      volume = 1,
      packetsReceived = 0,
      bytesReceived = 0,
      decodedPackets = 0,
      playedBuffers = 0,
      droppedBuffers = 0,
      bufferedBytes = 0,
      peakSample = 0,
      error = null;

  final ScrcpyAudioStatus status;
  final String? codec;
  final bool muted;
  final double volume;
  final int packetsReceived;
  final int bytesReceived;
  final int decodedPackets;
  final int playedBuffers;
  final int droppedBuffers;
  final int bufferedBytes;
  final int peakSample;
  double get peakLevel => peakSample / 32768;
  final Object? error;
}

abstract interface class ScrcpyAudioController
    implements ValueListenable<ScrcpyAudioState> {
  Future<void> start();

  Future<void> setMuted(bool muted);

  Future<void> setVolume(double volume);

  Future<void> stop();

  void dispose();
}
