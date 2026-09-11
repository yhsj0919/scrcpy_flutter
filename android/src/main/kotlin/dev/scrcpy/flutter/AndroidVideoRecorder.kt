package dev.scrcpy.flutter

import android.media.MediaCodec
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.File
import java.nio.ByteBuffer

/** Writes the encoded scrcpy H.264 access units without decoding or re-encoding. */
internal class AndroidVideoRecorder(
    path: String,
    width: Int,
    height: Int,
    codecConfig: ByteArray,
) : AutoCloseable {
    private val muxer: MediaMuxer
    private val track: Int
    private var firstPtsUs = -1L
    private var lastPtsUs = -1L
    private var waitingForKeyFrame = true
    private var closed = false
    var frames = 0L
        private set

    init {
        val output = File(path)
        output.parentFile?.mkdirs()
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height)
        val parameterSets = findParameterSets(codecConfig)
        parameterSets.first?.let { format.setByteBuffer("csd-0", ByteBuffer.wrap(it)) }
        parameterSets.second?.let { format.setByteBuffer("csd-1", ByteBuffer.wrap(it)) }
        require(parameterSets.first != null && parameterSets.second != null) {
            "scrcpy H.264 codec configuration does not contain SPS/PPS"
        }
        muxer = MediaMuxer(output.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        track = muxer.addTrack(format)
        muxer.start()
    }

    fun write(data: ByteArray, ptsUs: Long, keyFrame: Boolean) {
        check(!closed) { "Video recorder is closed" }
        if (waitingForKeyFrame) {
            if (!keyFrame) return
            waitingForKeyFrame = false
        }
        if (firstPtsUs < 0) firstPtsUs = ptsUs
        val normalizedPts = (ptsUs - firstPtsUs).coerceAtLeast(lastPtsUs + 1)
        lastPtsUs = normalizedPts
        val info = MediaCodec.BufferInfo().apply {
            offset = 0
            size = data.size
            presentationTimeUs = normalizedPts
            flags = if (keyFrame) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
        }
        muxer.writeSampleData(track, ByteBuffer.wrap(data), info)
        frames++
    }

    override fun close() {
        if (closed) return
        closed = true
        var failure: Throwable? = null
        runCatching { muxer.stop() }.onFailure { failure = it }
        runCatching { muxer.release() }.onFailure { if (failure == null) failure = it }
        failure?.let { throw it }
    }

    private companion object {
        fun findParameterSets(config: ByteArray): Pair<ByteArray?, ByteArray?> {
            var sps: ByteArray? = null
            var pps: ByteArray? = null
            val starts = mutableListOf<Pair<Int, Int>>()
            var index = 0
            while (index + 3 < config.size) {
                val length = when {
                    config[index] == 0.toByte() && config[index + 1] == 0.toByte() &&
                        config[index + 2] == 1.toByte() -> 3
                    index + 4 <= config.size && config[index] == 0.toByte() &&
                        config[index + 1] == 0.toByte() && config[index + 2] == 0.toByte() &&
                        config[index + 3] == 1.toByte() -> 4
                    else -> 0
                }
                if (length > 0) {
                    starts += index to length
                    index += length
                } else index++
            }
            starts.forEachIndexed { position, (start, prefixLength) ->
                val end = starts.getOrNull(position + 1)?.first ?: config.size
                val nalStart = start + prefixLength
                if (nalStart >= end) return@forEachIndexed
                val value = config.copyOfRange(start, end)
                when (config[nalStart].toInt() and 0x1f) {
                    7 -> sps = value
                    8 -> pps = value
                }
            }
            return sps to pps
        }
    }
}
