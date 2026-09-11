package dev.scrcpy.flutter

import android.util.Log
import dev.scrcpy.flutter.transport.AdbSocketStream
import dev.scrcpy.flutter.transport.AdbDeviceTransport
import java.io.BufferedInputStream
import java.io.DataInputStream
import java.io.EOFException
import java.io.File
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlin.concurrent.thread

internal class AndroidScrcpySession(
    val id: String,
    private val adb: AdbDeviceTransport,
    private val remotePath: String,
    private val decoder: AndroidVideoDecoder,
    private val serverStream: AdbSocketStream,
    private val videoStream: AdbSocketStream,
    private val videoInput: DataInputStream,
    private val audioStream: AdbSocketStream?,
    private val audioInput: DataInputStream?,
    private val audioPlayer: AndroidAudioPlayer?,
    private val controlStream: AdbSocketStream?,
    val codecId: Int,
    initialWidth: Int,
    initialHeight: Int,
    private val onSizeChanged: (Int, Int) -> Unit,
    private val onClipboard: (String) -> Unit,
    private val onClipboardAck: (Long) -> Unit,
    private val onRecordingStopped: (Long, String?) -> Unit,
    private val onAudioStopped: (String?) -> Unit,
    private val onDisconnected: (String?) -> Unit,
) : AutoCloseable {
    private val closed = AtomicBoolean()
    private val controlExecutor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "scrcpy-control-$id").apply { isDaemon = true }
    }
    private val controlOutput: OutputStream? = controlStream?.outputStream
    private val recordingLock = Any()
    private var recorder: AndroidVideoRecorder? = null
    private var videoCodecConfig: ByteArray? = null
    private val videoPackets = AtomicLong()
    private val videoBytes = AtomicLong()
    val decoderTextureId: Long get() = decoder.textureId
    val hasAudio: Boolean get() = audioPlayer != null
    val audioCodecName: String? get() = when (audioPlayer?.codecId) {
        0x6f707573 -> "opus"
        0x6d703461 -> "aac"
        0x664c6143 -> "flac"
        0x72617720 -> "raw"
        else -> null
    }
    @Volatile var width: Int = initialWidth
        private set
    @Volatile var height: Int = initialHeight
        private set

    fun startReading() {
        thread(isDaemon = true, name = "scrcpy-video-$id") { readVideo() }
        if (audioInput != null && audioPlayer != null) {
            thread(isDaemon = true, name = "scrcpy-audio-$id") { readAudio() }
        }
        if (controlStream != null) {
            thread(isDaemon = true, name = "scrcpy-control-reader-$id") { readControl() }
        }
    }

    fun setAudioMuted(muted: Boolean) = audioPlayer?.setMuted(muted)

    fun setAudioVolume(volume: Float) = audioPlayer?.setVolume(volume)

    fun capture(completed: (Result<AndroidVideoDecoder.CapturedFrame>) -> Unit) =
        decoder.capture(completed)

    fun startRecording(path: String) {
        synchronized(recordingLock) {
            check(recorder == null) { "Video recording is already active" }
            check(codecId == H264_CODEC_ID) {
                "MP4 recording currently requires the H.264 video codec"
            }
            val config = videoCodecConfig
                ?: throw IllegalStateException("Video codec configuration is not available yet")
            recorder = AndroidVideoRecorder(path, width, height, config)
        }
    }

    fun stopRecording(): Long = synchronized(recordingLock) {
        val active = recorder ?: return@synchronized 0L
        recorder = null
        val frames = active.frames
        active.close()
        frames
    }

    private fun stopRecordingAfterFailure(reason: String) {
        val active = synchronized(recordingLock) {
            val current = recorder ?: return
            recorder = null
            current
        }
        val frames = active.frames
        val finalReason = runCatching { active.close() }
            .exceptionOrNull()?.message?.let { "$reason; finalize failed: $it" }
            ?: reason
        onRecordingStopped(frames, finalReason)
    }

    private fun writeRecordingPacket(data: ByteArray, ptsUs: Long, keyFrame: Boolean) {
        val failure = synchronized(recordingLock) {
            val active = recorder ?: return
            runCatching { active.write(data, ptsUs, keyFrame) }.exceptionOrNull()
        }
        if (failure != null) {
            Log.e(TAG, "video recording failed", failure)
            stopRecordingAfterFailure(failure.message ?: failure.javaClass.simpleName)
        }
    }

    fun videoStats(): Map<String, Long> = mapOf(
        "bytesReceived" to videoBytes.get(),
        "packetsReceived" to videoPackets.get(),
        "framesRendered" to decoder.frames.get(),
        "decoderInputsDropped" to decoder.needMore.get(),
    )

    fun audioStats(): Map<String, Long> = audioPlayer?.stats() ?: emptyMap()

    fun sendControl(data: ByteArray, completed: (Throwable?) -> Unit) {
        controlExecutor.execute {
            val failure = runCatching {
                val output = controlOutput
                    ?: throw IllegalStateException("Control is disabled")
                synchronized(output) {
                    check(!closed.get()) { "scrcpy session is closed" }
                    output.write(data)
                    output.flush()
                }
            }.exceptionOrNull()
            completed(failure)
        }
    }

    private fun readVideo() {
        val header = ByteArray(12)
        var failure: String? = null
        try {
            while (!closed.get()) {
                videoInput.readFully(header)
                val flagsAndPts = ByteBuffer.wrap(header, 0, 8)
                    .order(ByteOrder.BIG_ENDIAN).long
                if ((flagsAndPts and SESSION_FLAG) != 0L) {
                    val newWidth = ByteBuffer.wrap(header, 4, 4)
                        .order(ByteOrder.BIG_ENDIAN).int
                    val newHeight = ByteBuffer.wrap(header, 8, 4)
                        .order(ByteOrder.BIG_ENDIAN).int
                    if (newWidth > 0 && newHeight > 0 &&
                        (newWidth != width || newHeight != height)
                    ) {
                        if (recorder != null) {
                            stopRecordingAfterFailure(
                                "Video size changed from ${width}x$height to ${newWidth}x$newHeight",
                            )
                        }
                        width = newWidth
                        height = newHeight
                        decoder.setSurfaceSize(newWidth, newHeight)
                        onSizeChanged(newWidth, newHeight)
                    }
                    continue
                }
                val size = ByteBuffer.wrap(header, 8, 4).order(ByteOrder.BIG_ENDIAN).int
                require(size in 1..MAX_PACKET_SIZE) { "Invalid video packet size: $size" }
                val payload = ByteArray(size)
                videoInput.readFully(payload)
                videoPackets.incrementAndGet()
                videoBytes.addAndGet(size.toLong())
                val config = (flagsAndPts and CONFIG_FLAG) != 0L
                val keyFrame = (flagsAndPts and KEY_FRAME_FLAG) != 0L
                if (config) {
                    videoCodecConfig = payload.copyOf()
                } else {
                    writeRecordingPacket(payload, flagsAndPts and PTS_MASK, keyFrame)
                }
                decoder.decodePacket(
                    payload,
                    flagsAndPts and PTS_MASK,
                    config,
                    keyFrame,
                )
            }
        } catch (_: EOFException) {
            if (!closed.get()) failure = "scrcpy video stream ended"
        } catch (error: Throwable) {
            if (!closed.get()) {
                failure = error.message ?: error.javaClass.simpleName
                Log.e(TAG, "video reader failed", error)
            }
        } finally {
            if (!closed.get()) onDisconnected(failure)
        }
    }

    private fun readAudio() {
        val input = audioInput ?: return
        val player = audioPlayer ?: return
        val header = ByteArray(12)
        try {
            while (!closed.get()) {
                input.readFully(header)
                val flagsAndPts = ByteBuffer.wrap(header, 0, 8).order(ByteOrder.BIG_ENDIAN).long
                val size = ByteBuffer.wrap(header, 8, 4).order(ByteOrder.BIG_ENDIAN).int
                require(size in 1..MAX_AUDIO_PACKET_SIZE) { "Invalid audio packet size: $size" }
                val payload = ByteArray(size)
                input.readFully(payload)
                player.decode(payload, flagsAndPts and AUDIO_PTS_MASK,
                    (flagsAndPts and CONFIG_FLAG) != 0L)
            }
        } catch (_: EOFException) {
            if (!closed.get()) {
                Log.i(TAG, "audio stream ended")
                onAudioStopped(null)
            }
        } catch (error: Throwable) {
            if (!closed.get()) {
                Log.e(TAG, "audio reader failed", error)
                onAudioStopped(error.message ?: error.javaClass.simpleName)
            }
        }
    }

    private fun readControl() {
        val input = DataInputStream(BufferedInputStream(controlStream?.inputStream ?: return))
        try {
            while (!closed.get()) {
                when (input.readUnsignedByte()) {
                    0 -> {
                        val size = input.readInt()
                        require(size in 0..MAX_DEVICE_MESSAGE_SIZE) {
                            "Invalid clipboard message size: $size"
                        }
                        val payload = ByteArray(size)
                        input.readFully(payload)
                        onClipboard(payload.toString(Charsets.UTF_8))
                    }
                    1 -> onClipboardAck(input.readLong())
                    2 -> {
                        input.readUnsignedShort()
                        val size = input.readUnsignedShort()
                        val payload = ByteArray(size)
                        input.readFully(payload)
                    }
                    else -> error("Unknown scrcpy device message type")
                }
            }
        } catch (_: EOFException) {
            if (!closed.get()) Log.i(TAG, "control response stream ended")
        } catch (error: Throwable) {
            if (!closed.get()) Log.e(TAG, "control reader failed", error)
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        controlExecutor.shutdown()
        runCatching { synchronized(recordingLock) { recorder?.close(); recorder = null } }
        runCatching { controlStream?.close() }
        runCatching { audioStream?.close() }
        runCatching { videoStream.close() }
        runCatching { serverStream.close() }
        decoder.close()
        audioPlayer?.close()
        runCatching { adb.shell("rm -f ${shellQuote(remotePath)}") }
    }

    companion object {
        private const val TAG = "AndroidScrcpySession"
        private const val SESSION_FLAG = Long.MIN_VALUE
        private const val CONFIG_FLAG = 1L shl 62
        private const val KEY_FRAME_FLAG = 1L shl 61
        private const val PTS_MASK = KEY_FRAME_FLAG - 1
        private const val MAX_PACKET_SIZE = 16 * 1024 * 1024
        private const val MAX_AUDIO_PACKET_SIZE = 4 * 1024 * 1024
        private const val MAX_DEVICE_MESSAGE_SIZE = 1 shl 18
        private const val AUDIO_PTS_MASK = CONFIG_FLAG - 1
        private const val H264_CODEC_ID = 0x68323634

        fun prepare(
            id: String,
            adb: AdbDeviceTransport,
            serverFile: File,
            arguments: Map<String, Any?>,
            createDecoder: (Int, Int, Int) -> AndroidVideoDecoder,
            createAudioPlayer: (Int) -> AndroidAudioPlayer,
            onSizeChanged: (Int, Int) -> Unit,
            onClipboard: (String) -> Unit,
            onClipboardAck: (Long) -> Unit,
            onRecordingStopped: (Long, String?) -> Unit,
            onAudioStopped: (String?) -> Unit,
            onDisconnected: (String?) -> Unit,
        ): AndroidScrcpySession {
            val remotePath = "/data/local/tmp/scrcpy-server-$id.jar"
            var serverStream: AdbSocketStream? = null
            var videoStream: AdbSocketStream? = null
            var controlStream: AdbSocketStream? = null
            var audioStream: AdbSocketStream? = null
            var decoder: AndroidVideoDecoder? = null
            var audioPlayer: AndroidAudioPlayer? = null
            try {
                adb.push(serverFile, remotePath)
                val socketName = "scrcpy_$id"
                val audioSource = if (arguments["audio"] == true) {
                    arguments["audioSource"]?.toString() ?: run {
                        val sdk = adb.shell("getprop ro.build.version.sdk").trim().toIntOrNull()
                        if (sdk != null && sdk >= 31) "playback" else "output"
                    }
                } else null
                val serverArguments = mutableListOf(
                    "CLASSPATH=${shellQuote(remotePath)}",
                    "app_process", "/", "com.genymobile.scrcpy.Server", "4.1",
                    "scid=$id", "log_level=info", "tunnel_forward=true",
                    "video=true", "audio=${arguments["audio"] == true}",
                    "control=${arguments["control"] != false}",
                    "clipboard_autosync=false", "cleanup=true",
                    "send_device_meta=false",
                    "video_codec=${arguments["videoCodec"] ?: "h264"}",
                    "max_size=${arguments["maxSize"]}",
                    "max_fps=${arguments["maxFps"]}",
                    "video_bit_rate=${arguments["bitRate"]}",
                )
                arguments["videoEncoder"]?.let { serverArguments += "video_encoder=$it" }
                arguments["videoCodecOptions"]?.let {
                    serverArguments += "video_codec_options=$it"
                }
                if (arguments["audio"] == true) {
                    serverArguments += "audio_codec=${arguments["audioCodec"] ?: "opus"}"
                    serverArguments += "audio_bit_rate=${arguments["audioBitRate"] ?: 128000}"
                    audioSource?.let { serverArguments += "audio_source=$it" }
                    if (arguments["audioDup"] == true) serverArguments += "audio_dup=true"
                }
                val reserved = setOf(
                    "deviceSerial", "maxSize", "maxFps", "bitRate", "control", "audio",
                    "videoCodec", "videoEncoder", "videoCodecOptions", "audioRequired",
                    "audioCodec", "audioBitRate", "audioSource", "audioDup",
                )
                arguments.forEach { (key, value) ->
                    if (key !in reserved && value != null) serverArguments += "$key=$value"
                }
                val activeServerStream = adb.open("shell:${serverArguments.joinToString(" ")}")
                serverStream = activeServerStream
                thread(isDaemon = true, name = "scrcpy-server-log-$id") {
                    runCatching {
                        activeServerStream.inputStream.bufferedReader().useLines { lines ->
                            lines.forEach { Log.i(TAG, "server[$id]: $it") }
                        }
                    }
                }
                val activeVideoStream = openSocket(adb, socketName, true)
                videoStream = activeVideoStream
                val activeAudioStream = if (arguments["audio"] == true) {
                    openSocket(adb, socketName, false)
                } else null
                audioStream = activeAudioStream
                val activeControlStream = if (arguments["control"] != false) {
                    openSocket(adb, socketName, false)
                } else null
                controlStream = activeControlStream
                val input = DataInputStream(
                    BufferedInputStream(activeVideoStream.inputStream, 256 * 1024),
                )
                val codecId = input.readInt()
                val activeAudioInput = activeAudioStream?.let {
                    DataInputStream(BufferedInputStream(it.inputStream, 64 * 1024))
                }
                val audioCodecId = activeAudioInput?.readInt()
                if (audioCodecId == 0 && arguments["audioRequired"] == true) {
                    error("scrcpy audio capture is unavailable")
                }
                val activeAudioPlayer = audioCodecId?.takeIf { it != 0 }?.let(createAudioPlayer)
                audioPlayer = activeAudioPlayer
                val sizeHeader = ByteArray(12)
                var width: Int
                var height: Int
                while (true) {
                    input.readFully(sizeHeader)
                    val flags = ByteBuffer.wrap(sizeHeader, 0, 8)
                        .order(ByteOrder.BIG_ENDIAN).long
                    require((flags and SESSION_FLAG) != 0L) {
                        "Video data arrived before session size"
                    }
                    width = ByteBuffer.wrap(sizeHeader, 4, 4)
                        .order(ByteOrder.BIG_ENDIAN).int
                    height = ByteBuffer.wrap(sizeHeader, 8, 4)
                        .order(ByteOrder.BIG_ENDIAN).int
                    if (width > 0 && height > 0) break
                }
                val activeDecoder = createDecoder(codecId, width, height)
                decoder = activeDecoder
                return AndroidScrcpySession(
                    id, adb, remotePath, activeDecoder, activeServerStream,
                    activeVideoStream, input, activeAudioStream, activeAudioInput,
                    activeAudioPlayer, activeControlStream, codecId, width,
                    height, onSizeChanged, onClipboard, onClipboardAck,
                    onRecordingStopped, onAudioStopped, onDisconnected,
                )
            } catch (error: Throwable) {
                runCatching { controlStream?.close() }
                runCatching { audioStream?.close() }
                runCatching { videoStream?.close() }
                runCatching { serverStream?.close() }
                runCatching { decoder?.close() }
                runCatching { audioPlayer?.close() }
                runCatching { adb.shell("rm -f ${shellQuote(remotePath)}") }
                throw error
            }
        }

        private fun openSocket(
            adb: AdbDeviceTransport,
            socketName: String,
            expectDummyByte: Boolean,
        ): AdbSocketStream {
            var lastError: Throwable? = null
            repeat(50) {
                try {
                    val stream = adb.open("localabstract:$socketName")
                    if (expectDummyByte) {
                        require(stream.inputStream.read() == 0) { "Invalid scrcpy dummy byte" }
                    }
                    return stream
                } catch (error: Throwable) {
                    lastError = error
                    Thread.sleep(100)
                }
            }
            throw IllegalStateException("Unable to open scrcpy socket", lastError)
        }

        private fun shellQuote(value: String) = "'${value.replace("'", "'\\''")}'"
    }
}
