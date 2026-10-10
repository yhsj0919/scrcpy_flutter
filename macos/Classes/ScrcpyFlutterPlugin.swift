import Cocoa
import AVFoundation
import CoreMedia
import CoreVideo
import FlutterMacOS
import VideoToolbox

public final class ScrcpyFlutterPlugin: NSObject, FlutterPlugin {
  private var videos: [Int64: MacOSVideoTexture] = [:]
  private weak var textures: FlutterTextureRegistry?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = ScrcpyFlutterPlugin(textures: registrar.textures)
    let channel = FlutterMethodChannel(
      name: "scrcpy_flutter/video",
      binaryMessenger: registrar.messenger)
    registrar.addMethodCallDelegate(plugin, channel: channel)
    let audio = MacOSAudioPlugin()
    let audioChannel = FlutterMethodChannel(
      name: "scrcpy_flutter/audio",
      binaryMessenger: registrar.messenger)
    registrar.addMethodCallDelegate(audio, channel: audioChannel)
  }

  private init(textures: FlutterTextureRegistry) {
    self.textures = textures
    super.init()
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any] else {
      result(FlutterError(code: "invalid_arguments", message: "Expected map arguments", details: nil))
      return
    }
    do {
      switch call.method {
      case "create":
        guard try integer(arguments, "codecId") == 0x68323634 else {
          throw VideoError.unsupportedCodec
        }
        guard let textures else { throw VideoError.textureRegistryUnavailable }
        let video = MacOSVideoTexture(
          registry: textures,
          width: try integer(arguments, "width"),
          height: try integer(arguments, "height"))
        let identifier = textures.register(video)
        video.textureId = identifier
        videos[identifier] = video
        result(identifier)
      case "decode":
        let video = try findVideo(arguments)
        guard let data = arguments["data"] as? FlutterStandardTypedData else {
          throw VideoError.invalidData
        }
        try video.decode(
          data.data,
          presentationTimeUs: try int64(arguments, "pts"),
          configurationOnly: arguments["config"] as? Bool ?? false,
          keyFrame: arguments["keyFrame"] as? Bool ?? false)
        result(nil)
      case "videoStats":
        let video = try findVideo(arguments)
        result(video.stats())
      case "dispose":
        let identifier = try int64(arguments, "textureId")
        if let video = videos.removeValue(forKey: identifier) {
          video.close()
          textures?.unregisterTexture(identifier)
        }
        result(nil)
      case "captureFrame":
        result(try findVideo(arguments).captureFrame())
      case "startRecording":
        guard let path = arguments["path"] as? String, !path.isEmpty else {
          throw VideoError.invalidArguments
        }
        try findVideo(arguments).startRecording(path: path)
        result(nil)
      case "stopRecording":
        let video = try findVideo(arguments)
        video.stopRecording { outcome in
          switch outcome {
          case .success(let frames): result(frames)
          case .failure(let error):
            NSLog("[scrcpy] Recording failed: %@", String(describing: error))
            result(FlutterError(
              code: "recording_failure",
              message: String(describing: error),
              details: nil))
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    } catch {
      NSLog("[scrcpy] Video request %@ failed: %@", call.method, String(describing: error))
      result(FlutterError(code: "video_error", message: String(describing: error), details: nil))
    }
  }

  deinit {
    for (identifier, video) in videos {
      video.close()
      textures?.unregisterTexture(identifier)
    }
  }

  private func findVideo(_ arguments: [String: Any]) throws -> MacOSVideoTexture {
    let identifier = try int64(arguments, "textureId")
    guard let video = videos[identifier] else { throw VideoError.unknownTexture }
    return video
  }

  private func integer(_ arguments: [String: Any], _ key: String) throws -> Int {
    guard let number = arguments[key] as? NSNumber else { throw VideoError.invalidArguments }
    return number.intValue
  }

  private func int64(_ arguments: [String: Any], _ key: String) throws -> Int64 {
    guard let number = arguments[key] as? NSNumber else { throw VideoError.invalidArguments }
    return number.int64Value
  }
}

private final class MacOSVideoTexture: NSObject, FlutterTexture {
  private let registry: FlutterTextureRegistry
  private let width: Int
  private let height: Int
  private let lock = NSLock()
  private var latestPixelBuffer: CVPixelBuffer?
  private var formatDescription: CMVideoFormatDescription?
  private var decompressionSession: VTDecompressionSession?
  private var frameCount: Int64 = 0
  private var needMoreCount: Int64 = 0
  fileprivate var textureId: Int64 = 0
  private var assetWriter: AVAssetWriter?
  private var assetWriterInput: AVAssetWriterInput?
  private var recordingFrames: Int64 = 0
  private var recordingWaitingForKeyFrame = true

  init(registry: FlutterTextureRegistry, width: Int, height: Int) {
    self.registry = registry
    self.width = width
    self.height = height
    super.init()
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    defer { lock.unlock() }
    guard let latestPixelBuffer else { return nil }
    return Unmanaged.passRetained(latestPixelBuffer)
  }

  func decode(
    _ data: Data,
    presentationTimeUs: Int64,
    configurationOnly: Bool,
    keyFrame: Bool
  ) throws {
    let units = AnnexB.units(in: data)
    guard !units.isEmpty else {
      needMoreCount += 1
      return
    }
    let sps = units.last { ($0.first ?? 0) & 0x1f == 7 }
    let pps = units.last { ($0.first ?? 0) & 0x1f == 8 }
    if let sps, let pps { try configure(sps: sps, pps: pps) }
    if configurationOnly { return }
    let frameUnits = units.filter {
      let type = ($0.first ?? 0) & 0x1f
      return type != 7 && type != 8 && type != 9
    }
    guard !frameUnits.isEmpty,
          let formatDescription,
          let decompressionSession else {
      needMoreCount += 1
      return
    }
    var sampleData = Data()
    for unit in frameUnits {
      var length = UInt32(unit.count).bigEndian
      withUnsafeBytes(of: &length) { sampleData.append(contentsOf: $0) }
      sampleData.append(unit)
    }
    var blockBuffer: CMBlockBuffer?
    let blockStatus = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil,
      blockLength: sampleData.count,
      blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: sampleData.count,
      flags: 0,
      blockBufferOut: &blockBuffer)
    guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
      throw VideoError.coreMedia(blockStatus)
    }
    let replaceStatus = sampleData.withUnsafeBytes { bytes in
      CMBlockBufferReplaceDataBytes(
        with: bytes.baseAddress!,
        blockBuffer: blockBuffer,
        offsetIntoDestination: 0,
        dataLength: sampleData.count)
    }
    guard replaceStatus == kCMBlockBufferNoErr else {
      throw VideoError.coreMedia(replaceStatus)
    }
    var timing = CMSampleTimingInfo(
      duration: .invalid,
      presentationTimeStamp: CMTime(value: presentationTimeUs, timescale: 1_000_000),
      decodeTimeStamp: .invalid)
    var sampleSize = sampleData.count
    var sampleBuffer: CMSampleBuffer?
    let sampleStatus = CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault,
      dataBuffer: blockBuffer,
      formatDescription: formatDescription,
      sampleCount: 1,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleSizeEntryCount: 1,
      sampleSizeArray: &sampleSize,
      sampleBufferOut: &sampleBuffer)
    guard sampleStatus == noErr, let sampleBuffer else {
      throw VideoError.coreMedia(sampleStatus)
    }
    if let writer = assetWriter, let input = assetWriterInput {
      if recordingWaitingForKeyFrame && keyFrame {
        writer.startSession(atSourceTime: timing.presentationTimeStamp)
        recordingWaitingForKeyFrame = false
      }
      if !recordingWaitingForKeyFrame && input.isReadyForMoreMediaData {
        guard input.append(sampleBuffer) else {
          throw writer.error ?? VideoError.recordingAppendFailed
        }
        recordingFrames += 1
      }
    }
    var infoFlags = VTDecodeInfoFlags()
    let status = VTDecompressionSessionDecodeFrame(
      decompressionSession,
      sampleBuffer: sampleBuffer,
      flags: [._EnableAsynchronousDecompression],
      frameRefcon: nil,
      infoFlagsOut: &infoFlags)
    guard status == noErr else { throw VideoError.videoToolbox(status) }
  }

  func close() {
    assetWriter?.cancelWriting()
    assetWriter = nil
    assetWriterInput = nil
    resetDecoder()
  }

  private func resetDecoder() {
    if let decompressionSession {
      VTDecompressionSessionWaitForAsynchronousFrames(decompressionSession)
      VTDecompressionSessionInvalidate(decompressionSession)
    }
    decompressionSession = nil
    formatDescription = nil
    lock.lock()
    latestPixelBuffer = nil
    lock.unlock()
  }

  func startRecording(path: String) throws {
    guard assetWriter == nil else { throw VideoError.recordingAlreadyActive }
    guard let formatDescription else { throw VideoError.frameUnavailable }
    let writer = try AVAssetWriter(
      outputURL: URL(fileURLWithPath: path),
      fileType: .mp4)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: nil,
      sourceFormatHint: formatDescription)
    input.expectsMediaDataInRealTime = true
    guard writer.canAdd(input) else { throw VideoError.recordingInputRejected }
    writer.add(input)
    guard writer.startWriting() else {
      throw writer.error ?? VideoError.recordingStartFailed
    }
    assetWriter = writer
    assetWriterInput = input
    recordingFrames = 0
    recordingWaitingForKeyFrame = true
  }

  func stopRecording(
    completion: @escaping (Result<Int64, Error>) -> Void
  ) {
    guard let writer = assetWriter, let input = assetWriterInput else {
      completion(.success(0))
      return
    }
    let frames = recordingFrames
    assetWriter = nil
    assetWriterInput = nil
    recordingFrames = 0
    recordingWaitingForKeyFrame = true
    guard frames > 0 else {
      writer.cancelWriting()
      completion(.success(0))
      return
    }
    input.markAsFinished()
    writer.finishWriting {
      DispatchQueue.main.async {
        if writer.status == .completed {
          completion(.success(frames))
        } else {
          completion(.failure(
            writer.error ?? VideoError.recordingFinalizeFailed))
        }
      }
    }
  }

  private func configure(sps: Data, pps: Data) throws {
    var description: CMFormatDescription?
    let status = sps.withUnsafeBytes { spsBytes in
      pps.withUnsafeBytes { ppsBytes in
        let spsPointer = spsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
        let ppsPointer = ppsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
        let pointers = [spsPointer, ppsPointer]
        let sizes = [sps.count, pps.count]
        return pointers.withUnsafeBufferPointer { pointerBuffer in
          sizes.withUnsafeBufferPointer { sizeBuffer in
            CMVideoFormatDescriptionCreateFromH264ParameterSets(
              allocator: kCFAllocatorDefault,
              parameterSetCount: 2,
              parameterSetPointers: pointerBuffer.baseAddress!,
              parameterSetSizes: sizeBuffer.baseAddress!,
              nalUnitHeaderLength: 4,
              formatDescriptionOut: &description)
          }
        }
      }
    }
    guard status == noErr, let description else {
      throw VideoError.coreMedia(status)
    }
    if let decompressionSession,
       VTDecompressionSessionCanAcceptFormatDescription(
         decompressionSession,
         formatDescription: description) {
      formatDescription = description
      return
    }
    resetDecoder()
    formatDescription = description
    let attributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey: width,
      kCVPixelBufferHeightKey: height,
      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    ]
    var callback = VTDecompressionOutputCallbackRecord(
      decompressionOutputCallback: { reference, _, status, _, imageBuffer, _, _ in
        if status != noErr {
          NSLog("[scrcpy] VideoToolbox output failed: %d", status)
          return
        }
        guard status == noErr, let reference, let imageBuffer else { return }
        let video = Unmanaged<MacOSVideoTexture>.fromOpaque(reference).takeUnretainedValue()
        video.didDecode(imageBuffer)
      },
      decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
    var session: VTDecompressionSession?
    let sessionStatus = VTDecompressionSessionCreate(
      allocator: kCFAllocatorDefault,
      formatDescription: description,
      decoderSpecification: nil,
      imageBufferAttributes: attributes as CFDictionary,
      outputCallback: &callback,
      decompressionSessionOut: &session)
    guard sessionStatus == noErr, let session else {
      throw VideoError.videoToolbox(sessionStatus)
    }
    VTSessionSetProperty(
      session,
      key: kVTDecompressionPropertyKey_RealTime,
      value: kCFBooleanTrue)
    decompressionSession = session
  }

  private func didDecode(_ imageBuffer: CVImageBuffer) {
    lock.lock()
    latestPixelBuffer = imageBuffer
    frameCount += 1
    lock.unlock()
    registry.textureFrameAvailable(textureId)
  }

  func stats() -> [String: Int64] {
    lock.lock()
    defer { lock.unlock() }
    return ["frames": frameCount, "needMore": needMoreCount]
  }

  func captureFrame() throws -> [String: Any] {
    lock.lock()
    guard let pixelBuffer = latestPixelBuffer else {
      lock.unlock()
      throw VideoError.frameUnavailable
    }
    lock.unlock()

    let status = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    guard status == kCVReturnSuccess else {
      throw VideoError.pixelBuffer(status)
    }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
      throw VideoError.frameUnavailable
    }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let source = baseAddress.assumingMemoryBound(to: UInt8.self)
    var rgba = Data(count: width * height * 4)
    rgba.withUnsafeMutableBytes { destinationBytes in
      guard let destination = destinationBytes.baseAddress?
        .assumingMemoryBound(to: UInt8.self) else { return }
      for row in 0..<height {
        let sourceRow = source.advanced(by: row * stride)
        let destinationRow = destination.advanced(by: row * width * 4)
        for column in 0..<width {
          let sourcePixel = sourceRow.advanced(by: column * 4)
          let destinationPixel = destinationRow.advanced(by: column * 4)
          destinationPixel[0] = sourcePixel[2]
          destinationPixel[1] = sourcePixel[1]
          destinationPixel[2] = sourcePixel[0]
          destinationPixel[3] = sourcePixel[3]
        }
      }
    }
    return [
      "width": width,
      "height": height,
      "pixels": FlutterStandardTypedData(bytes: rgba),
    ]
  }
}

private enum AnnexB {
  static func units(in data: Data) -> [Data] {
    let bytes = [UInt8](data)
    var starts: [(offset: Int, length: Int)] = []
    var index = 0
    while index + 3 <= bytes.count {
      if bytes[index] == 0 && bytes[index + 1] == 0 {
        if bytes[index + 2] == 1 {
          starts.append((index, 3))
          index += 3
          continue
        }
        if index + 3 < bytes.count && bytes[index + 2] == 0 && bytes[index + 3] == 1 {
          starts.append((index, 4))
          index += 4
          continue
        }
      }
      index += 1
    }
    if starts.isEmpty { return data.isEmpty ? [] : [data] }
    return starts.enumerated().compactMap { position, start in
      let from = start.offset + start.length
      let to = position + 1 < starts.count ? starts[position + 1].offset : bytes.count
      return from < to ? Data(bytes[from..<to]) : nil
    }
  }
}

private enum VideoError: Error {
  case invalidArguments
  case invalidData
  case unknownTexture
  case unsupportedCodec
  case textureRegistryUnavailable
  case coreMedia(OSStatus)
  case videoToolbox(OSStatus)
  case frameUnavailable
  case pixelBuffer(CVReturn)
  case recordingAlreadyActive
  case recordingInputRejected
  case recordingStartFailed
  case recordingAppendFailed
  case recordingFinalizeFailed
}
