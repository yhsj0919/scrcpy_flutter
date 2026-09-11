package dev.scrcpy.flutter

import android.media.MediaCodec
import android.media.MediaFormat
import android.graphics.Bitmap
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.PixelCopy
import io.flutter.view.TextureRegistry
import java.io.ByteArrayOutputStream
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/** MediaCodec decoder whose input and output are driven by codec callbacks. */
internal class AndroidVideoDecoder(
    private val producer: TextureRegistry.SurfaceProducer,
    codecId: Int,
    width: Int,
    height: Int,
) {
    val textureId: Long get() = producer.id()
    val frames = AtomicLong()
    val inputs = AtomicLong()
    val needMore = AtomicLong()
    val lastFrameNanos = AtomicLong()

    private val closed = AtomicBoolean()
    private val terminalError = AtomicReference<Throwable?>()
    private val worker = HandlerThread("scrcpy-mediacodec-${producer.id()}").apply { start() }
    private val handler = Handler(worker.looper)
    private val pendingInputs = ArrayDeque<VideoInput>()
    private val availableInputBuffers = ArrayDeque<Int>()
    private val latestInputPtsUs = AtomicLong()
    private val latestOutputPtsUs = AtomicLong()
    private val lastStatsLogNanos = AtomicLong()
    private var awaitingKeyFrame = false
    @Volatile private var width = width
    @Volatile private var height = height

    private val mime = mimeForCodec(codecId)
    private val codec = MediaCodec.createDecoderByType(mime).apply {
        setCallback(object : MediaCodec.Callback() {
            override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
                availableInputBuffers.addLast(index)
                feedAvailableInputs(codec)
            }

            override fun onOutputBufferAvailable(
                codec: MediaCodec,
                index: Int,
                info: MediaCodec.BufferInfo,
            ) {
                latestOutputPtsUs.set(info.presentationTimeUs)
                codec.releaseOutputBuffer(index, true)
                frames.incrementAndGet()
                lastFrameNanos.set(System.nanoTime())
                logStats()
            }

            override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) = Unit

            override fun onError(codec: MediaCodec, error: MediaCodec.CodecException) {
                terminalError.compareAndSet(null, error)
                Log.e(TAG, "decoder failed", error)
            }
        }, handler)

        val supportsLowLatency = if (Build.VERSION.SDK_INT >= 30) {
            codecInfo.getCapabilitiesForType(mime).isFeatureSupported(
                android.media.MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency,
            )
        } else {
            false
        }
        val format = MediaFormat.createVideoFormat(mime, width, height).apply {
            setInteger(MediaFormat.KEY_PRIORITY, 0)
            setInteger(MediaFormat.KEY_FRAME_RATE, EXPECTED_FRAME_RATE)
            if (Build.VERSION.SDK_INT >= 23) {
                setFloat(MediaFormat.KEY_OPERATING_RATE, EXPECTED_FRAME_RATE.toFloat())
            }
            if (Build.VERSION.SDK_INT >= 30 && supportsLowLatency) {
                setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }
        }
        configure(format, producer.surface, null, 0)
        start()
        val runtimeLowLatency = if (Build.VERSION.SDK_INT >= 30 && supportsLowLatency) {
            runCatching {
                setParameters(Bundle().apply {
                    putInt(MediaCodec.PARAMETER_KEY_LOW_LATENCY, 1)
                })
            }.isSuccess
        } else {
            false
        }
        val vendorLowLatency = enableVendorLowLatency(this)
        Log.i(
            TAG,
            "decoder=${codecInfo.name} mime=$mime async=true lowLatencyFeature=$supportsLowLatency " +
                "runtimeLowLatency=$runtimeLowLatency vendorLowLatency=$vendorLowLatency",
        )
    }

    init {
        val initialSurfaceCallback = AtomicBoolean(true)
        producer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
            override fun onSurfaceAvailable() {
                if (initialSurfaceCallback.compareAndSet(true, false)) return
                handler.post {
                    if (!closed.get()) {
                        runCatching { codec.setOutputSurface(producer.surface) }
                            .onFailure { terminalError.compareAndSet(null, it) }
                    }
                }
            }
        })
    }

    fun decodePacket(data: ByteArray, ptsUs: Long, config: Boolean, keyFrame: Boolean) {
        if (closed.get() || terminalError.get() != null) return
        handler.post {
            if (closed.get()) return@post
            enqueue(VideoInput(data, ptsUs, config, keyFrame))
            feedAvailableInputs(codec)
        }
    }

    fun setSurfaceSize(width: Int, height: Int) {
        if (width <= 0 || height <= 0 || closed.get()) return
        this.width = width
        this.height = height
        handler.post {
            if (!closed.get()) producer.setSize(width, height)
        }
    }

    fun capture(completed: (Result<CapturedFrame>) -> Unit) {
        if (closed.get()) {
            completed(Result.failure(IllegalStateException("Video decoder is closed")))
            return
        }
        val captureWidth = width
        val captureHeight = height
        val bitmap = Bitmap.createBitmap(captureWidth, captureHeight, Bitmap.Config.ARGB_8888)
        PixelCopy.request(producer.surface, bitmap, { status ->
            if (status != PixelCopy.SUCCESS) {
                bitmap.recycle()
                completed(Result.failure(IllegalStateException("PixelCopy failed: $status")))
                return@request
            }
            runCatching {
                val output = ByteArrayOutputStream()
                check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) {
                    "Unable to encode captured frame"
                }
                CapturedFrame(captureWidth, captureHeight, output.toByteArray())
            }.also {
                bitmap.recycle()
                completed(it)
            }
        }, handler)
    }

    private fun enqueue(input: VideoInput) {
        if (awaitingKeyFrame) {
            if (input.config) pendingInputs.addLast(input)
            if (!input.keyFrame) return
            awaitingKeyFrame = false
        }
        if (pendingInputs.size < MAX_PENDING_INPUTS) {
            pendingInputs.addLast(input)
            return
        }
        needMore.incrementAndGet()
        pendingInputs.clear()
        awaitingKeyFrame = !input.keyFrame
        if (input.config || input.keyFrame) {
            pendingInputs.addLast(input)
        }
    }

    private fun feedAvailableInputs(codec: MediaCodec) {
        while (availableInputBuffers.isNotEmpty() && pendingInputs.isNotEmpty()) {
            val index = availableInputBuffers.removeFirst()
            val input = pendingInputs.removeFirst()
            try {
                val buffer = requireNotNull(codec.getInputBuffer(index))
                require(buffer.capacity() >= input.data.size) {
                    "Video packet (${input.data.size}) exceeds MediaCodec input capacity (${buffer.capacity()})"
                }
                buffer.clear()
                buffer.put(input.data)
                var flags = 0
                if (input.config) flags = flags or MediaCodec.BUFFER_FLAG_CODEC_CONFIG
                if (input.keyFrame) flags = flags or MediaCodec.BUFFER_FLAG_KEY_FRAME
                codec.queueInputBuffer(index, 0, input.data.size, input.ptsUs, flags)
                latestInputPtsUs.set(input.ptsUs)
                inputs.incrementAndGet()
            } catch (error: Throwable) {
                terminalError.compareAndSet(null, error)
                Log.e(TAG, "unable to queue decoder input", error)
                pendingInputs.clear()
                availableInputBuffers.clear()
                return
            }
        }
    }

    private fun logStats() {
        val now = System.nanoTime()
        val previous = lastStatsLogNanos.get()
        if (now - previous < STATS_LOG_INTERVAL_NS || !lastStatsLogNanos.compareAndSet(previous, now)) return
        val lagMs = ((latestInputPtsUs.get() - latestOutputPtsUs.get()).coerceAtLeast(0L)) / 1000
        Log.i(
            TAG,
            "frames=${frames.get()} inputs=${inputs.get()} dropped=${needMore.get()} " +
                "pending=${pendingInputs.size} decoderLagMs=$lagMs",
        )
    }

    fun close() {
        if (!closed.compareAndSet(false, true)) return
        handler.post {
            pendingInputs.clear()
            availableInputBuffers.clear()
            runCatching { codec.stop() }
            runCatching { codec.release() }
            runCatching { producer.release() }
            worker.quitSafely()
        }
    }

    private data class VideoInput(
        val data: ByteArray,
        val ptsUs: Long,
        val config: Boolean,
        val keyFrame: Boolean,
    )

    data class CapturedFrame(val width: Int, val height: Int, val png: ByteArray)

    private companion object {
        const val EXPECTED_FRAME_RATE = 60
        const val MAX_PENDING_INPUTS = 8
        const val STATS_LOG_INTERVAL_NS = 2_000_000_000L
        const val TAG = "ScrcpyVideoDecoder"

        private fun mimeForCodec(codecId: Int): String = when (codecId) {
            0x68323634 -> MediaFormat.MIMETYPE_VIDEO_AVC
            0x68323635 -> MediaFormat.MIMETYPE_VIDEO_HEVC
            0x61763031 -> MediaFormat.MIMETYPE_VIDEO_AV1
            else -> throw IllegalArgumentException(
                "Unsupported video codec: 0x${codecId.toString(16)}",
            )
        }

        private fun enableVendorLowLatency(codec: MediaCodec): String {
            if (Build.VERSION.SDK_INT < 31) return "unsupported-api"
            val parameters = runCatching { codec.supportedVendorParameters }
                .getOrDefault(emptyList())
                .filter {
                    val name = it.lowercase()
                    "low" in name && "latency" in name
                }
            if (parameters.isEmpty()) return "none"
            val enabled = parameters.filter { parameter ->
                runCatching {
                    codec.setParameters(Bundle().apply { putInt(parameter, 1) })
                }.isSuccess
            }
            return if (enabled.isEmpty()) "rejected:${parameters.joinToString()}" else enabled.joinToString()
        }
    }
}
