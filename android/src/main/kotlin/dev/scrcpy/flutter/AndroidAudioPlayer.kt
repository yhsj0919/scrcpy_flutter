package dev.scrcpy.flutter

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaFormat
import android.util.Log
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicLong

internal class AndroidAudioPlayer(
    context: Context,
    val codecId: Int,
) : AutoCloseable {
    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var codec: MediaCodec? = null
    private var track: AudioTrack? = null
    private val bufferInfo = MediaCodec.BufferInfo()
    private var pcm = ByteArray(0)
    @Volatile private var muted = false
    @Volatile private var volume = 1f
    private val packets = AtomicLong()
    private val bytes = AtomicLong()
    private val decoded = AtomicLong()
    private val played = AtomicLong()
    private val dropped = AtomicLong()
    @Volatile private var closed = false

    fun decode(data: ByteArray, ptsUs: Long, config: Boolean) {
        if (closed) return
        if (config) {
            prepare(data)
            return
        }
        packets.incrementAndGet()
        bytes.addAndGet(data.size.toLong())
        if (codecId == RAW) {
            recordWrite(ensureTrack().write(data, 0, data.size, AudioTrack.WRITE_NON_BLOCKING))
            decoded.incrementAndGet()
            return
        }
        val decoder = codec ?: return
        val inputIndex = decoder.dequeueInputBuffer(10_000)
        if (inputIndex >= 0) {
            decoder.getInputBuffer(inputIndex)?.apply { clear(); put(data) }
            decoder.queueInputBuffer(inputIndex, 0, data.size, ptsUs, 0)
        }
        drain(decoder)
    }

    fun setMuted(muted: Boolean) {
        this.muted = muted
        applyVolume()
    }

    fun setVolume(volume: Float) {
        this.volume = volume.coerceIn(0f, 1f)
        applyVolume()
    }

    private fun applyVolume() {
        track?.setVolume(if (muted) 0f else volume)
    }

    private fun prepare(config: ByteArray) {
        if (codec != null || closed) return
        val mime = when (codecId) {
            OPUS -> MediaFormat.MIMETYPE_AUDIO_OPUS
            AAC -> MediaFormat.MIMETYPE_AUDIO_AAC
            FLAC -> MediaFormat.MIMETYPE_AUDIO_FLAC
            else -> throw IllegalArgumentException("Unsupported audio codec: 0x${codecId.toString(16)}")
        }
        val format = MediaFormat.createAudioFormat(mime, SAMPLE_RATE, CHANNELS)
        if (config.isNotEmpty()) format.setByteBuffer("csd-0", ByteBuffer.wrap(config))
        if (codecId == OPUS && config.size >= 12) {
            val preSkip = ((config[11].toInt() and 0xff) shl 8) or (config[10].toInt() and 0xff)
            format.setByteBuffer("csd-1", longBuffer(preSkip.toLong() * 1_000_000_000 / SAMPLE_RATE))
            format.setByteBuffer("csd-2", longBuffer(80_000_000))
        }
        val decoder = MediaCodec.createDecoderByType(mime)
        decoder.configure(format, null, null, 0)
        decoder.start()
        ensureTrack()
        codec = decoder
        Log.i(TAG, "audio decoder started: $mime")
    }

    private fun ensureTrack(): AudioTrack {
        track?.let { return it }
        val minimum = AudioTrack.getMinBufferSize(
            SAMPLE_RATE, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT,
        ).coerceAtLeast(1)
        val created = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build())
            .setAudioFormat(AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(SAMPLE_RATE)
                .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO).build())
            .setBufferSizeInBytes((minimum * 2).coerceAtLeast(16 * 1024))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
            .build()
        created.play()
        created.setVolume(if (muted) 0f else volume)
        track = created
        return created
    }

    private fun drain(decoder: MediaCodec) {
        val output = track ?: return
        var index = decoder.dequeueOutputBuffer(bufferInfo, 0)
        while (index >= 0) {
            decoder.getOutputBuffer(index)?.let { buffer ->
                if (bufferInfo.size > 0) {
                    if (pcm.size < bufferInfo.size) pcm = ByteArray(bufferInfo.size)
                    buffer.position(bufferInfo.offset)
                    buffer.get(pcm, 0, bufferInfo.size)
                    output.write(pcm, 0, bufferInfo.size, AudioTrack.WRITE_NON_BLOCKING)
                        .also(::recordWrite)
                    decoded.incrementAndGet()
                }
            }
            decoder.releaseOutputBuffer(index, false)
            index = decoder.dequeueOutputBuffer(bufferInfo, 0)
        }
    }

    override fun close() {
        if (closed) return
        closed = true
        runCatching { codec?.stop() }
        runCatching { codec?.release() }
        runCatching { track?.stop() }
        runCatching { track?.release() }
        codec = null
        track = null
    }

    fun stats(): Map<String, Long> = mapOf(
        "packetsReceived" to packets.get(),
        "bytesReceived" to bytes.get(),
        "decodedPackets" to decoded.get(),
        "playedBuffers" to played.get(),
        "droppedBuffers" to dropped.get(),
    )

    private fun recordWrite(bytes: Int) {
        if (bytes > 0) played.incrementAndGet() else dropped.incrementAndGet()
    }

    private fun longBuffer(value: Long) =
        ByteBuffer.allocate(8).order(ByteOrder.nativeOrder()).apply { putLong(value); flip() }

    private companion object {
        const val TAG = "AndroidAudioPlayer"
        const val SAMPLE_RATE = 48_000
        const val CHANNELS = 2
        const val OPUS = 0x6f707573
        const val AAC = 0x6d703461
        const val FLAC = 0x664c6143
        const val RAW = 0x72617720
    }
}
