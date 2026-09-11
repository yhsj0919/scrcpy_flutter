package dev.scrcpy.flutter

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import dev.scrcpy.flutter.transport.AndroidAdbTransport
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.security.MessageDigest

class ScrcpyFlutterPlugin : FlutterPlugin {
    private lateinit var adbChannel: MethodChannel
    private lateinit var sessionChannel: MethodChannel
    private lateinit var textures: TextureRegistry
    private lateinit var applicationContext: Context
    private val sessions = ConcurrentHashMap<String, AndroidScrcpySession>()
    private var ioExecutor: ExecutorService = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())
    private lateinit var adb: AndroidAdbTransport
    private lateinit var scrcpyServerFile: java.io.File
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        if (ioExecutor.isShutdown) ioExecutor = Executors.newCachedThreadPool()
        applicationContext = binding.applicationContext
        textures = binding.textureRegistry
        adb = AndroidAdbTransport(binding.applicationContext)
        scrcpyServerFile = extractScrcpyServer(binding.applicationContext)
        adbChannel = MethodChannel(binding.binaryMessenger, "scrcpy_flutter/android_adb")
        sessionChannel = MethodChannel(binding.binaryMessenger, "scrcpy_flutter/android_session")
        adbChannel.setMethodCallHandler(::handleAdbCall)
        sessionChannel.setMethodCallHandler(::handleSessionCall)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        adbChannel.setMethodCallHandler(null)
        sessionChannel.setMethodCallHandler(null)
        sessions.values.forEach(AndroidScrcpySession::close)
        sessions.clear()
        runCatching { ScrcpySessionService.update(applicationContext, -1) }
        releaseNetworkLocks()
        adb.close()
        ioExecutor.shutdownNow()
    }

    private fun handleSessionCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "control" -> {
                try {
                    requireSession(call).sendControl(
                        requireNotNull(call.argument<ByteArray>("data")) { "Missing data" },
                    ) { error ->
                        mainHandler.post {
                            if (error == null) {
                                result.success(null)
                            } else {
                                Log.e(TAG, "control request failed", error)
                                result.error(
                                    "android_control_error",
                                    error.message ?: error.javaClass.simpleName,
                                    Log.getStackTraceString(error),
                                )
                            }
                        }
                    }
                } catch (error: Throwable) {
                    Log.e(TAG, "control request failed", error)
                    result.error(
                        "android_control_error",
                        error.message ?: error.javaClass.simpleName,
                        Log.getStackTraceString(error),
                    )
                }
            }
            "audioMuted", "audioVolume" -> {
                try {
                    val session = requireSession(call)
                    if (call.method == "audioMuted") {
                        session.setAudioMuted(call.argument<Boolean>("muted") == true)
                    } else {
                        session.setAudioVolume(
                            requireNotNull(call.argument<Number>("volume")) { "Missing volume" }
                                .toFloat(),
                        )
                    }
                    result.success(null)
                } catch (error: Throwable) {
                    result.error(
                        "android_audio_error",
                        error.message ?: error.javaClass.simpleName,
                        Log.getStackTraceString(error),
                    )
                }
            }
            "capture" -> {
                try {
                    requireSession(call).capture { capture ->
                        mainHandler.post {
                            capture.fold(
                                onSuccess = { frame -> result.success(mapOf(
                                    "width" to frame.width,
                                    "height" to frame.height,
                                    "png" to frame.png,
                                )) },
                                onFailure = { error -> result.error(
                                    "android_capture_error",
                                    error.message ?: error.javaClass.simpleName,
                                    Log.getStackTraceString(error),
                                ) },
                            )
                        }
                    }
                } catch (error: Throwable) {
                    result.error(
                        "android_capture_error",
                        error.message ?: error.javaClass.simpleName,
                        Log.getStackTraceString(error),
                    )
                }
            }
            "videoStats" -> {
                try {
                    result.success(requireSession(call).videoStats())
                } catch (error: Throwable) {
                    result.error(
                        "android_video_stats_error",
                        error.message ?: error.javaClass.simpleName,
                        Log.getStackTraceString(error),
                    )
                }
            }
            "audioStats" -> {
                try {
                    result.success(requireSession(call).audioStats())
                } catch (error: Throwable) {
                    result.error(
                        "android_audio_stats_error",
                        error.message ?: error.javaClass.simpleName,
                        Log.getStackTraceString(error),
                    )
                }
            }
            "start", "stop", "startRecording", "stopRecording" -> ioExecutor.execute {
                runCatching {
                    when (call.method) {
                        "start" -> startSession(call)
                        "stop" -> {
                            closeSession(call.stringArgument("sessionId"))
                            null
                        }
                        "startRecording" -> {
                            requireSession(call).startRecording(call.stringArgument("path"))
                            null
                        }
                        else -> requireSession(call).stopRecording()
                    }
                }.fold(
                    onSuccess = { value -> mainHandler.post { result.success(value) } },
                    onFailure = { error ->
                        Log.e(TAG, "session request failed", error)
                        mainHandler.post {
                            result.error(
                                "android_session_error",
                                error.message ?: error.javaClass.simpleName,
                                Log.getStackTraceString(error),
                            )
                        }
                    },
                )
            }
            else -> result.notImplemented()
        }
    }

    private fun startSession(call: MethodCall): Map<String, Any?> {
        val arguments = requireNotNull(call.arguments as? Map<*, *>) { "Missing session arguments" }
            .entries.associate { it.key.toString() to it.value }
        val deviceSerial = requireNotNull(arguments["deviceSerial"] as? String) {
            "Missing deviceSerial"
        }
        val id = java.util.concurrent.ThreadLocalRandom.current()
            .nextInt(1, Int.MAX_VALUE)
            .toString(16)
            .padStart(8, '0')
        val session = AndroidScrcpySession.prepare(
            id = id,
            adb = adb.device(deviceSerial),
            serverFile = scrcpyServerFile,
            arguments = arguments,
            createDecoder = { codecId, width, height ->
                createSessionDecoder(codecId, width, height)
            },
            createAudioPlayer = { codecId -> AndroidAudioPlayer(applicationContext, codecId) },
            onSizeChanged = { width, height -> notifySessionResized(id, width, height) },
            onClipboard = { text -> notifySessionClipboard(id, text) },
            onClipboardAck = { sequence -> notifySessionClipboardAck(id, sequence) },
            onRecordingStopped = { frames, error ->
                notifySessionRecordingStopped(id, frames, error)
            },
            onAudioStopped = { error -> notifySessionAudioStopped(id, error) },
            onDisconnected = { error -> notifySessionDisconnected(id, error) },
        )
        sessions[id] = session
        session.startReading()
        updateSessionRuntime()
        return mapOf(
            "sessionId" to id,
            "textureId" to session.decoderTextureId,
            "codecId" to session.codecId,
            "width" to session.width,
            "height" to session.height,
            "audioEnabled" to session.hasAudio,
            "audioCodec" to session.audioCodecName,
        )
    }

    private fun createSessionDecoder(codecId: Int, width: Int, height: Int): AndroidVideoDecoder {
        val latch = java.util.concurrent.CountDownLatch(1)
        var decoder: AndroidVideoDecoder? = null
        var failure: Throwable? = null
        mainHandler.post {
            try {
                val producer = textures.createSurfaceProducer()
                producer.setSize(width, height)
                decoder = AndroidVideoDecoder(producer, codecId, width, height)
            } catch (error: Throwable) {
                failure = error
            } finally {
                latch.countDown()
            }
        }
        check(latch.await(10, TimeUnit.SECONDS)) { "Timed out creating video texture" }
        failure?.let { throw it }
        return requireNotNull(decoder)
    }

    private fun notifySessionDisconnected(id: String, error: String?) {
        val session = sessions.remove(id) ?: return
        session.close()
        updateSessionRuntime()
        mainHandler.post {
            sessionChannel.invokeMethod(
                "disconnected",
                mapOf("sessionId" to id, "error" to error),
            )
        }
    }

    private fun notifySessionResized(id: String, width: Int, height: Int) {
        if (!sessions.containsKey(id)) return
        mainHandler.post {
            sessionChannel.invokeMethod(
                "resized",
                mapOf("sessionId" to id, "width" to width, "height" to height),
            )
        }
    }

    private fun notifySessionClipboard(id: String, text: String) {
        if (!sessions.containsKey(id)) return
        mainHandler.post {
            sessionChannel.invokeMethod(
                "clipboard",
                mapOf("sessionId" to id, "text" to text),
            )
        }
    }

    private fun notifySessionClipboardAck(id: String, sequence: Long) {
        if (!sessions.containsKey(id)) return
        mainHandler.post {
            sessionChannel.invokeMethod(
                "clipboardAck",
                mapOf("sessionId" to id, "sequence" to sequence),
            )
        }
    }

    private fun notifySessionRecordingStopped(id: String, frames: Long, error: String?) {
        if (!sessions.containsKey(id)) return
        mainHandler.post {
            sessionChannel.invokeMethod(
                "recordingStopped",
                mapOf("sessionId" to id, "frames" to frames, "error" to error),
            )
        }
    }

    private fun notifySessionAudioStopped(id: String, error: String?) {
        if (!sessions.containsKey(id)) return
        mainHandler.post {
            sessionChannel.invokeMethod(
                "audioStopped",
                mapOf("sessionId" to id, "error" to error),
            )
        }
    }

    private fun closeSession(id: String) {
        sessions.remove(id)?.close()
        updateSessionRuntime()
    }

    private fun updateSessionRuntime() {
        val count = sessions.size
        val keepConnected = count > 0 || adb.hasActiveTarget()
        if (keepConnected) acquireNetworkLocks() else releaseNetworkLocks()
        runCatching {
            ScrcpySessionService.update(
                applicationContext,
                if (keepConnected) count else -1,
            )
        }
            .onFailure { Log.e(TAG, "Unable to update session foreground service", it) }
    }

    private fun requireSession(call: MethodCall): AndroidScrcpySession =
        requireNotNull(sessions[call.stringArgument("sessionId")]) { "Unknown session" }

    private fun handleAdbCall(call: MethodCall, result: MethodChannel.Result) {
        ioExecutor.execute {
            runCatching {
                when (call.method) {
                    "connect" -> {
                        adb.connect(call.stringArgument("host"), call.intArgument("port"))
                        updateSessionRuntime()
                        null
                    }
                    "disconnect" -> {
                        adb.disconnect()
                        updateSessionRuntime()
                        null
                    }
                    "pair" -> {
                        adb.pair(
                            call.stringArgument("host"),
                            call.intArgument("port"),
                            call.stringArgument("pairingCode"),
                        )
                        null
                    }
                    "listDevices" -> adb.devices().map { device ->
                        val model = device.model ?: if (
                            device.authorized && device.connectionType == "network"
                        ) {
                            runCatching {
                                adb.shell(device.serial, "getprop ro.product.model").trim()
                            }.getOrNull()
                        } else null
                        mapOf(
                            "serial" to device.serial,
                            "model" to model,
                            "connectionType" to device.connectionType,
                            "state" to if (device.authorized) "device" else "noPermissions",
                        )
                    }
                    "usbHostStatus" -> adb.usbHostStatus(
                        call.argument<Boolean>("requestPermission") == true,
                    ).let { status ->
                        mapOf(
                            "attachedDeviceCount" to status.attachedDeviceCount,
                            "adbDeviceCount" to status.adbDeviceCount,
                            "authorizedDeviceCount" to status.authorizedDeviceCount,
                            "permissionRequestPending" to status.permissionRequestPending,
                            "permissionDenied" to status.permissionDenied,
                        )
                    }
                    "shell" -> adb.shellResult(
                        call.stringArgument("serial"),
                        call.stringArgument("command"),
                    ).let {
                        mapOf("stdout" to it.stdout, "exitCode" to it.exitCode)
                    }
                    "push" -> {
                        adb.push(
                            call.stringArgument("serial"),
                            java.io.File(call.stringArgument("localPath")),
                            call.stringArgument("remotePath"),
                        )
                        null
                    }
                    "pull" -> {
                        adb.pull(
                            call.stringArgument("serial"),
                            call.stringArgument("remotePath"),
                            java.io.File(call.stringArgument("localPath")),
                        )
                        null
                    }
                    "install" -> {
                        installPackage(
                            call.stringArgument("serial"),
                            java.io.File(call.stringArgument("apkPath")),
                            call.argument<Boolean>("replaceExisting") == true,
                        )
                        null
                    }
                    "uninstall" -> {
                        uninstallPackage(
                            call.stringArgument("serial"),
                            call.stringArgument("packageName"),
                            call.argument<Boolean>("keepData") == true,
                        )
                        null
                    }
                    "listApplicationLabels" -> listApplicationLabels(
                        call.stringArgument("serial"),
                    )
                    "listVideoEncoders" -> runScrcpyProbe(
                        call.stringArgument("serial"),
                        "list_encoders=true",
                    )
                    else -> throw NotImplementedError(call.method)
                }
            }.fold(
                onSuccess = { value -> mainHandler.post { result.success(value) } },
                onFailure = { error ->
                    Log.e(TAG, "ADB request failed", error)
                    mainHandler.post {
                        if (error is NotImplementedError) result.notImplemented()
                        else result.error(
                            "android_adb_error",
                            error.message ?: error.javaClass.simpleName,
                            android.util.Log.getStackTraceString(error),
                        )
                    }
                },
            )
        }
    }

    @Suppress("DEPRECATION")
    private fun acquireNetworkLocks() {
        if (wakeLock?.isHeld != true) {
            val powerManager = applicationContext.getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "scrcpy_flutter:stream",
            ).apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        if (wifiLock?.isHeld != true) {
            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            wifiLock = wifiManager.createWifiLock(
                WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                "scrcpy_flutter:stream",
            ).apply {
                setReferenceCounted(false)
                acquire()
            }
        }
    }

    private fun releaseNetworkLocks() {
        wakeLock?.runCatching { if (isHeld) release() }
        wifiLock?.runCatching { if (isHeld) release() }
        wakeLock = null
        wifiLock = null
    }

    private fun extractScrcpyServer(context: android.content.Context): java.io.File {
        val target = java.io.File(context.codeCacheDir, "scrcpy-server-v4.1")
        if (!target.isFile || sha256(target) != SCRCPY_SERVER_SHA256) {
            context.assets.open("scrcpy-server-v4.1").use { input ->
                val temporary = java.io.File(target.parentFile, "${target.name}.partial")
                try {
                    temporary.outputStream().use(input::copyTo)
                    check(sha256(temporary) == SCRCPY_SERVER_SHA256) {
                        "Bundled scrcpy server checksum mismatch"
                    }
                    if (target.exists() && !target.delete()) {
                        error("Unable to replace extracted scrcpy server")
                    }
                    check(temporary.renameTo(target)) {
                        "Unable to finish scrcpy server extraction"
                    }
                } finally {
                    if (temporary.exists()) temporary.delete()
                }
            }
        }
        return target
    }

    private fun sha256(file: java.io.File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                if (read > 0) digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun installPackage(serial: String, apk: java.io.File, replaceExisting: Boolean) {
        require(apk.isFile) { "APK does not exist: ${apk.absolutePath}" }
        val remote = "/data/local/tmp/scrcpy-flutter-${java.util.UUID.randomUUID()}.apk"
        try {
            adb.push(serial, apk, remote)
            val replace = if (replaceExisting) "-r " else ""
            val output = adb.shell(serial, "pm install ${replace}${shellQuote(remote)}").trim()
            check(output.lineSequence().any { it.trim() == "Success" }) {
                "Package installation failed: $output"
            }
        } finally {
            runCatching { adb.shell(serial, "rm -f ${shellQuote(remote)}") }
        }
    }

    private fun uninstallPackage(serial: String, packageName: String, keepData: Boolean) {
        require(packageName.matches(Regex("[A-Za-z0-9_.]+"))) { "Invalid package name" }
        val keep = if (keepData) "-k " else ""
        val output = adb.shell(serial, "pm uninstall $keep$packageName").trim()
        check(output.lineSequence().any { it.trim() == "Success" }) {
            "Package uninstall failed: $output"
        }
    }

    private fun listApplicationLabels(serial: String): String {
        return runScrcpyProbe(serial, "list_apps=true")
    }

    private fun runScrcpyProbe(serial: String, argument: String): String {
        require(argument == "list_apps=true" || argument == "list_encoders=true") {
            "Unsupported scrcpy probe"
        }
        val remote = "/data/local/tmp/scrcpy-server-apps-${java.util.UUID.randomUUID()}.jar"
        return try {
            adb.push(serial, scrcpyServerFile, remote)
            adb.shell(
                serial,
                "CLASSPATH=${shellQuote(remote)} app_process / " +
                    "com.genymobile.scrcpy.Server 4.1 $argument cleanup=true",
            )
        } finally {
            runCatching { adb.shell(serial, "rm -f ${shellQuote(remote)}") }
        }
    }

    private fun shellQuote(value: String) = "'${value.replace("'", "'\\''")}'"

    private fun MethodCall.intArgument(name: String): Int =
        requireNotNull(argument<Number>(name)) { "Missing $name" }.toInt()

    private fun MethodCall.stringArgument(name: String): String =
        requireNotNull(argument<String>(name)) { "Missing $name" }

    private companion object {
        const val TAG = "ScrcpyFlutterPlugin"
        const val SCRCPY_SERVER_SHA256 =
            "deacb991ed2509715160ffdc7907e47b4160eb30d1566217e9047fd5b8850cae"
    }
}
