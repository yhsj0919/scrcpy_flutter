package dev.scrcpy.flutter.transport

import android.content.Context
import android.util.Base64
import android.util.Log
import java.io.Closeable
import java.io.File
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.interfaces.RSAPrivateCrtKey
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.RSAPublicKeySpec

/** Routes Android plugin operations to network and USB Host ADB transports. */
internal class AndroidAdbTransport(context: Context) : Closeable {
    private val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
    private val lock = Any()
    private val keyPair by lazy(::loadOrCreateKeyPair)
    private val usb = AndroidUsbAdbTransport(context) { keyPair }

    @Volatile
    private var connection: DirectAdbConnection? = null

    @Volatile
    private var endpoint: String? = null

    private var desiredHost: String? = null
    private var desiredPort: Int? = null

    fun connect(host: String, port: Int) {
        val normalizedHost = host.trim()
        require(normalizedHost.isNotEmpty()) { "ADB host is empty" }
        require(port in 1..65535) { "Invalid ADB port: $port" }
        synchronized(lock) {
            val authority = "$normalizedHost:$port"
            if (endpoint == authority && connection?.isAlive() == true) return
            disconnectLocked(forgetEndpoint = false)
            desiredHost = normalizedHost
            desiredPort = port
            val candidate = createConnection(normalizedHost, port)
            connection = candidate
            endpoint = authority
        }
    }

    fun pair(host: String, port: Int, pairingCode: String) {
        val normalizedHost = host.trim()
        val normalizedCode = pairingCode.trim()
        require(normalizedHost.isNotEmpty()) { "ADB host is empty" }
        require(port in 1..65535) { "Invalid ADB pairing port: $port" }
        require(normalizedCode.isNotEmpty()) { "ADB pairing code is empty" }
        val keys = keyPair
        val pairingKey = AdbPairingKey(keys.first, DEFAULT_ADB_KEY_NAME)
        val paired = DirectAdbPairingClient(
            normalizedHost,
            port,
            normalizedCode,
            pairingKey,
        ).use { it.start() }
        check(paired) { "ADB pairing was rejected" }
    }

    fun disconnect() = synchronized(lock) { disconnectLocked(forgetEndpoint = true) }

    fun connectedEndpoint(): String? = synchronized(lock) {
        if (connection?.isAlive() != true) return@synchronized null
        endpoint
    }

    /** Restores the user-selected endpoint when its transport was interrupted. */
    fun restoreConnectedEndpoint(): String? = synchronized(lock) {
        if (desiredHost == null || desiredPort == null) return@synchronized null
        requireConnectionLocked()
        endpoint
    }

    fun hasDesiredEndpoint(): Boolean = synchronized(lock) {
        desiredHost != null && desiredPort != null
    }

    fun devices(requestUsbPermission: Boolean = true): List<DeviceInfo> {
        val result = mutableListOf<DeviceInfo>()
        runCatching { restoreConnectedEndpoint() }
            .onFailure { Log.w(TAG, "Unable to restore network ADB device", it) }
            .getOrNull()
            ?.let { result += DeviceInfo(it, "network", true, null) }
        result += usb.devices(requestUsbPermission).map {
            DeviceInfo(it.serial, "usb", it.authorized, it.model)
        }
        return result
    }

    fun device(serial: String): AdbDeviceTransport = if (serial.startsWith("usb:")) {
        usb.device(serial)
    } else {
        NetworkDevice(serial)
    }

    fun hasActiveTarget(): Boolean = hasDesiredEndpoint() || usb.hasActiveConnection()

    fun usbHostStatus(requestPermission: Boolean) = usb.status(requestPermission)

    fun shell(serial: String, command: String): String = device(serial).shell(command)

    fun shellResult(serial: String, command: String): ShellResult =
        device(serial).shellResult(command)

    private fun networkShellResult(command: String): ShellResult {
        val marker = "__SCRCPY_FLUTTER_EXIT_${java.util.UUID.randomUUID()}__"
        val wrapped = "$command; printf '\\n$marker%d\\n' ${'$'}?"
        val output = requireConnection().shell(wrapped)
        val match = Regex("\\n${Regex.escape(marker)}(\\d+)\\n?$").find(output)
            ?: throw IllegalStateException("ADB shell response has no exit status")
        return ShellResult(
            stdout = output.substring(0, match.range.first),
            exitCode = match.groupValues[1].toInt(),
        )
    }

    fun push(serial: String, localFile: File, remotePath: String) =
        device(serial).push(localFile, remotePath)

    fun pull(serial: String, remotePath: String, localFile: File) =
        device(serial).pull(remotePath, localFile)

    private fun networkPull(remotePath: String, localFile: File) {
        val parent = localFile.absoluteFile.parentFile
            ?: error("Local destination has no parent directory")
        parent.mkdirs()
        val partial = File(parent, ".${localFile.name}.partial")
        try {
            partial.outputStream().use { requireConnection().pull(remotePath, it) }
            if (localFile.exists() && !localFile.delete()) {
                error("Unable to replace ${localFile.absolutePath}")
            }
            check(partial.renameTo(localFile)) { "Unable to finish ${localFile.absolutePath}" }
        } finally {
            if (partial.exists()) partial.delete()
        }
    }

    override fun close() {
        disconnect()
        usb.close()
    }

    private fun requireConnection(): DirectAdbConnection = synchronized(lock) {
        requireConnectionLocked()
    }

    private fun requireConnectionLocked(): DirectAdbConnection {
        connection?.takeIf(DirectAdbConnection::isAlive)?.let { return it }
        val host = desiredHost ?: throw IllegalStateException("ADB is not connected")
        val port = desiredPort ?: throw IllegalStateException("ADB is not connected")
        disconnectLocked(forgetEndpoint = false)
        val restored = createConnection(host, port)
        connection = restored
        endpoint = "$host:$port"
        return restored
    }

    private fun createConnection(host: String, port: Int): DirectAdbConnection {
        val keys = keyPair
        val candidate = DirectAdbConnection(
            host,
            port,
            keys.first,
            keys.second,
            DEFAULT_ADB_KEY_NAME,
            true,
        )
        try {
            candidate.handshake(CONNECT_TIMEOUT_MS)
            return candidate
        } catch (error: Throwable) {
            candidate.close()
            throw error
        }
    }

    private inner class NetworkDevice(private val serial: String) : AdbDeviceTransport {
        private fun checkedConnection(): DirectAdbConnection {
            val selected = synchronized(lock) {
                desiredHost?.let { host -> desiredPort?.let { "$host:$it" } }
            }
            check(selected == serial) { "ADB device is not connected: $serial" }
            return requireConnection()
        }

        override fun shell(command: String): String = checkedConnection().shell(command)

        override fun shellResult(command: String): ShellResult {
            checkedConnection()
            return networkShellResult(command)
        }

        override fun push(localFile: File, remotePath: String) {
            localFile.inputStream().use { checkedConnection().push(it, remotePath) }
        }

        override fun pull(remotePath: String, localFile: File) =
            networkPull(remotePath, localFile)

        override fun open(service: String): AdbSocketStream =
            checkedConnection().openStream(service)
    }

    private fun disconnectLocked(forgetEndpoint: Boolean) {
        runCatching { connection?.close() }
        connection = null
        endpoint = null
        if (forgetEndpoint) {
            desiredHost = null
            desiredPort = null
        }
    }

    private fun loadOrCreateKeyPair(): Pair<PrivateKey, ByteArray> {
        val privateKey = preferences.getString(PRIVATE_KEY, null)
        val publicKey = preferences.getString(PUBLIC_KEY, null)
        if (privateKey != null && publicKey != null) {
            runCatching {
                val decodedPrivate = Base64.decode(privateKey, Base64.DEFAULT)
                val decodedPublic = Base64.decode(publicKey, Base64.DEFAULT)
                val key = KeyFactory.getInstance("RSA")
                    .generatePrivate(PKCS8EncodedKeySpec(decodedPrivate))
                return key to decodedPublic
            }
        }
        val generated = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }
            .generateKeyPair()
        val privateCrt = generated.private as RSAPrivateCrtKey
        val publicBytes = KeyFactory.getInstance("RSA").generatePublic(
            RSAPublicKeySpec(privateCrt.modulus, privateCrt.publicExponent),
        ).encoded
        preferences.edit()
            .putString(PRIVATE_KEY, Base64.encodeToString(generated.private.encoded, Base64.NO_WRAP))
            .putString(PUBLIC_KEY, Base64.encodeToString(publicBytes, Base64.NO_WRAP))
            .apply()
        return generated.private to publicBytes
    }

    private companion object {
        const val TAG = "AndroidAdbTransport"
        const val PREFERENCES = "scrcpy_flutter_adb"
        const val PRIVATE_KEY = "private_key_pkcs8"
        const val PUBLIC_KEY = "public_key_x509"
        const val CONNECT_TIMEOUT_MS = 10_000
    }

    data class ShellResult(val stdout: String, val exitCode: Int)

    data class DeviceInfo(
        val serial: String,
        val connectionType: String,
        val authorized: Boolean,
        val model: String?,
    )
}
