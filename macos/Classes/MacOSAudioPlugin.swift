import AVFoundation
import FlutterMacOS

final class MacOSAudioPlugin: NSObject, FlutterPlugin {
  private var players: [Int64: MacOSOpusPlayer] = [:]
  private var nextIdentifier: Int64 = 1

  static func register(with registrar: FlutterPluginRegistrar) {}

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any] else {
      result(error("invalid_arguments", "Expected map arguments"))
      return
    }
    do {
      switch call.method {
      case "create":
        let identifier = nextIdentifier
        nextIdentifier += 1
        players[identifier] = try MacOSOpusPlayer()
        result(identifier)
      case "decode":
        let player = try find(arguments)
        guard let packet = arguments["data"] as? FlutterStandardTypedData else {
          throw AudioFailure.invalidPacket
        }
        if arguments["config"] as? Bool != true {
          try player.decode(packet.data)
        }
        result(nil)
      case "setMuted":
        guard let muted = arguments["muted"] as? Bool else {
          throw AudioFailure.invalidArguments
        }
        try find(arguments).setMuted(muted)
        result(nil)
      case "setVolume":
        guard let number = arguments["volume"] as? NSNumber else {
          throw AudioFailure.invalidArguments
        }
        let volume = number.floatValue
        guard volume.isFinite, volume >= 0, volume <= 1 else {
          throw AudioFailure.invalidVolume
        }
        try find(arguments).setVolume(volume)
        result(nil)
      case "audioStats":
        result(try find(arguments).stats())
      case "dispose":
        let identifier = try audioIdentifier(arguments)
        players.removeValue(forKey: identifier)?.close()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    } catch {
      NSLog("[scrcpy] Audio request %@ failed: %@", call.method, String(describing: error))
      result(self.error("native_audio_error", String(describing: error)))
    }
  }

  deinit {
    for player in players.values { player.close() }
  }

  private func find(_ arguments: [String: Any]) throws -> MacOSOpusPlayer {
    let identifier = try audioIdentifier(arguments)
    guard let player = players[identifier] else {
      throw AudioFailure.unknownPlayer
    }
    return player
  }

  private func audioIdentifier(_ arguments: [String: Any]) throws -> Int64 {
    guard let number = arguments["audioId"] as? NSNumber else {
      throw AudioFailure.invalidArguments
    }
    return number.int64Value
  }

  private func error(_ code: String, _ message: String) -> FlutterError {
    FlutterError(code: code, message: message, details: nil)
  }
}

private final class MacOSOpusPlayer {
  private let engine = AVAudioEngine()
  private let node = AVAudioPlayerNode()
  private let converter: AVAudioConverter
  private let inputFormat: AVAudioFormat
  private let outputFormat: AVAudioFormat
  private let lock = NSLock()
  private var closed = false
  private var muted = false
  private var volume: Float = 1
  private var queuedBuffers = 0
  private var decodedPackets: Int64 = 0
  private var playedBuffers: Int64 = 0
  private var droppedBuffers: Int64 = 0
  private var bufferedBytes: Int64 = 0
  private var peakSample: Int64 = 0

  init() throws {
    var inputDescription = AudioStreamBasicDescription(
      mSampleRate: 48_000,
      mFormatID: kAudioFormatOpus,
      mFormatFlags: 0,
      mBytesPerPacket: 0,
      mFramesPerPacket: 960,
      mBytesPerFrame: 0,
      mChannelsPerFrame: 2,
      mBitsPerChannel: 0,
      mReserved: 0)
    guard let inputFormat = AVAudioFormat(streamDescription: &inputDescription),
          let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true),
          let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
      throw AudioFailure.opusUnavailable
    }
    self.inputFormat = inputFormat
    self.outputFormat = outputFormat
    self.converter = converter

    engine.attach(node)
    engine.connect(node, to: engine.mainMixerNode, format: outputFormat)
    try engine.start()
    node.play()
  }

  func decode(_ data: Data) throws {
    guard !data.isEmpty else { return }
    lock.lock()
    if closed {
      lock.unlock()
      throw AudioFailure.closed
    }
    if queuedBuffers >= 12 {
      droppedBuffers += 1
      lock.unlock()
      return
    }
    lock.unlock()

    let compressed = AVAudioCompressedBuffer(
      format: inputFormat,
      packetCapacity: 1,
      maximumPacketSize: data.count)
    guard let pcm = AVAudioPCMBuffer(
        pcmFormat: outputFormat,
        frameCapacity: 5_760) else {
      throw AudioFailure.allocationFailed
    }
    data.copyBytes(to: compressed.data.assumingMemoryBound(to: UInt8.self),
                   count: data.count)
    compressed.byteLength = UInt32(data.count)
    compressed.packetCount = 1
    compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(
      mStartOffset: 0,
      mVariableFramesInPacket: 0,
      mDataByteSize: UInt32(data.count))

    var supplied = false
    var conversionError: NSError?
    let status = converter.convert(to: pcm, error: &conversionError) {
      _, inputStatus in
      if supplied {
        inputStatus.pointee = .noDataNow
        return nil
      }
      supplied = true
      inputStatus.pointee = .haveData
      return compressed
    }
    guard status == .haveData, pcm.frameLength > 0 else {
      if let conversionError { throw conversionError }
      throw AudioFailure.decodeFailed(status.rawValue)
    }

    var peak: Int64 = 0
    if let samples = pcm.int16ChannelData?.pointee {
      let count = Int(pcm.frameLength) * Int(outputFormat.channelCount)
      for index in 0..<count {
        peak = max(peak, Int64(abs(Int32(samples[index]))))
      }
    }
    let byteCount = Int64(pcm.frameLength) * 4
    lock.lock()
    if closed {
      lock.unlock()
      return
    }
    decodedPackets += 1
    queuedBuffers += 1
    bufferedBytes += byteCount
    peakSample = max(peakSample, peak)
    lock.unlock()

    node.scheduleBuffer(pcm, completionCallbackType: .dataPlayedBack) {
      [weak self] _ in
      guard let self else { return }
      self.lock.lock()
      self.queuedBuffers = max(0, self.queuedBuffers - 1)
      self.bufferedBytes = max(0, self.bufferedBytes - byteCount)
      self.playedBuffers += 1
      self.lock.unlock()
    }
  }

  func setMuted(_ value: Bool) {
    lock.lock()
    muted = value
    let effectiveVolume: Float = muted ? 0 : volume
    lock.unlock()
    node.volume = effectiveVolume
  }

  func setVolume(_ value: Float) {
    lock.lock()
    volume = value
    let effectiveVolume: Float = muted ? 0 : volume
    lock.unlock()
    node.volume = effectiveVolume
  }

  func stats() -> [String: Int64] {
    lock.lock()
    defer { lock.unlock() }
    return [
      "decodedPackets": decodedPackets,
      "playedBuffers": playedBuffers,
      "droppedBuffers": droppedBuffers,
      "bufferedBytes": bufferedBytes,
      "peakSample": peakSample,
    ]
  }

  func close() {
    lock.lock()
    guard !closed else {
      lock.unlock()
      return
    }
    closed = true
    queuedBuffers = 0
    bufferedBytes = 0
    lock.unlock()
    node.stop()
    engine.stop()
    converter.reset()
  }
}

private enum AudioFailure: Error {
  case invalidArguments
  case invalidPacket
  case invalidVolume
  case unknownPlayer
  case opusUnavailable
  case allocationFailed
  case decodeFailed(Int)
  case closed
}
