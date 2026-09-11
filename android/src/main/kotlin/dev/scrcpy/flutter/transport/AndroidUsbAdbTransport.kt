package dev.scrcpy.flutter.transport

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import java.io.Closeable
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.security.PrivateKey
import java.util.concurrent.ConcurrentHashMap

internal data class AndroidUsbDeviceInfo(
    val serial: String,
    val model: String?,
    val authorized: Boolean,
)

internal data class AndroidUsbHostStatus(
    val attachedDeviceCount: Int,
    val adbDeviceCount: Int,
    val authorizedDeviceCount: Int,
    val permissionRequestPending: Boolean,
    val permissionDenied: Boolean,
)

/** Owns Android USB Host permission, bulk endpoints and direct ADB links. */
internal class AndroidUsbAdbTransport(
    context: Context,
    private val keys: () -> Pair<PrivateKey, ByteArray>,
) : Closeable {
    private val context = context.applicationContext
    private val manager = this.context.getSystemService(Context.USB_SERVICE) as UsbManager
    private val links = ConcurrentHashMap<Int, UsbLink>()
    private val permissionRequests = ConcurrentHashMap.newKeySet<Int>()
    private val permissionDenied = ConcurrentHashMap.newKeySet<Int>()
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val device = intent?.usbDevice() ?: return
            when (intent.action) {
                ACTION_USB_PERMISSION -> {
                    permissionRequests.remove(device.deviceId)
                    if (intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)) {
                        permissionDenied.remove(device.deviceId)
                    } else {
                        permissionDenied.add(device.deviceId)
                    }
                }
                UsbManager.ACTION_USB_DEVICE_DETACHED -> {
                    permissionRequests.remove(device.deviceId)
                    permissionDenied.remove(device.deviceId)
                    links.remove(device.deviceId)?.close()
                }
            }
        }
    }

    init {
        val filter = IntentFilter().apply {
            addAction(ACTION_USB_PERMISSION)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        }
        if (Build.VERSION.SDK_INT >= 33) {
            this.context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            this.context.registerReceiver(receiver, filter)
        }
    }

    fun devices(requestPermission: Boolean): List<AndroidUsbDeviceInfo> = manager.deviceList.values
        .filter { findAdbInterface(it) != null }
        .map { device ->
            val authorized = manager.hasPermission(device)
            if (!authorized && requestPermission) requestPermission(device)
            AndroidUsbDeviceInfo(
                serial = serial(device.deviceId),
                model = device.productName ?: device.deviceName,
                authorized = authorized,
            )
        }

    fun status(requestPermission: Boolean): AndroidUsbHostStatus {
        if (requestPermission) permissionDenied.clear()
        val attached = manager.deviceList.values.toList()
        val adbDevices = attached.filter { findAdbInterface(it) != null }
        if (requestPermission) {
            adbDevices.filterNot(manager::hasPermission).forEach(::requestPermission)
        }
        return AndroidUsbHostStatus(
            attachedDeviceCount = attached.size,
            adbDeviceCount = adbDevices.size,
            authorizedDeviceCount = adbDevices.count(manager::hasPermission),
            permissionRequestPending = adbDevices.any { it.deviceId in permissionRequests },
            permissionDenied = adbDevices.any { it.deviceId in permissionDenied },
        )
    }

    fun hasActiveConnection(): Boolean = links.values.any { it.connection.isAlive() }

    fun device(serial: String): AdbDeviceTransport {
        val deviceId = parseSerial(serial)
        return object : AdbDeviceTransport {
            override fun shell(command: String) = connection(deviceId).shell(command)

            override fun shellResult(command: String): AndroidAdbTransport.ShellResult {
                val marker = "__SCRCPY_FLUTTER_EXIT_${java.util.UUID.randomUUID()}__"
                val wrapped = "$command; printf '\\n$marker%d\\n' ${'$'}?"
                val output = connection(deviceId).shell(wrapped)
                val match = Regex("\\n${Regex.escape(marker)}(\\d+)\\n?$").find(output)
                    ?: throw IllegalStateException("ADB shell response has no exit status")
                return AndroidAdbTransport.ShellResult(
                    output.substring(0, match.range.first),
                    match.groupValues[1].toInt(),
                )
            }

            override fun push(localFile: java.io.File, remotePath: String) {
                localFile.inputStream().use { connection(deviceId).push(it, remotePath) }
            }

            override fun pull(remotePath: String, localFile: java.io.File) {
                writePartial(localFile) { connection(deviceId).pull(remotePath, it) }
            }

            override fun open(service: String) = connection(deviceId).openStream(service)
        }
    }

    override fun close() {
        runCatching { context.unregisterReceiver(receiver) }
        links.values.forEach(UsbLink::close)
        links.clear()
        permissionRequests.clear()
        permissionDenied.clear()
    }

    @Synchronized
    private fun connection(deviceId: Int): DirectAdbConnection {
        links[deviceId]?.connection?.takeIf(DirectAdbConnection::isAlive)?.let { return it }
        links.remove(deviceId)?.close()
        val device = manager.deviceList.values.firstOrNull { it.deviceId == deviceId }
            ?: throw IOException("USB ADB device is disconnected")
        check(manager.hasPermission(device)) { "USB permission is required" }
        val adbInterface = findAdbInterface(device)
            ?: throw IOException("USB device has no ADB interface")
        val input = (0 until adbInterface.endpointCount)
            .map(adbInterface::getEndpoint)
            .firstOrNull { it.direction == UsbConstants.USB_DIR_IN }
            ?: throw IOException("USB ADB input endpoint is missing")
        val output = (0 until adbInterface.endpointCount)
            .map(adbInterface::getEndpoint)
            .firstOrNull { it.direction == UsbConstants.USB_DIR_OUT }
            ?: throw IOException("USB ADB output endpoint is missing")
        val usb = manager.openDevice(device)
            ?: throw IOException("Unable to open USB ADB device")
        if (!usb.claimInterface(adbInterface, true)) {
            usb.close()
            throw IOException("Unable to claim USB ADB interface")
        }
        val inputStream = UsbBulkInputStream(manager, deviceId, usb, input)
        val outputStream = UsbBulkOutputStream(usb, output)
        val keyPair = keys()
        val connection = DirectAdbConnection(
            inputStream,
            outputStream,
            keyPair.first,
            keyPair.second,
            DEFAULT_ADB_KEY_NAME,
            deviceId,
        )
        val link = UsbLink(usb, adbInterface, inputStream, outputStream, connection)
        try {
            connection.handshake(USB_HANDSHAKE_TIMEOUT_MS)
            inputStream.finishHandshake()
            links[deviceId] = link
            return connection
        } catch (error: Throwable) {
            link.close()
            throw error
        }
    }

    private fun requestPermission(device: UsbDevice) {
        if (device.deviceId in permissionDenied) return
        if (!permissionRequests.add(device.deviceId)) return
        val intent = Intent(ACTION_USB_PERMISSION).setPackage(context.packageName)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
        manager.requestPermission(
            device,
            PendingIntent.getBroadcast(context, device.deviceId, intent, flags),
        )
    }

    private fun findAdbInterface(device: UsbDevice): UsbInterface? =
        (0 until device.interfaceCount)
            .map(device::getInterface)
            .firstOrNull {
                it.interfaceClass == UsbConstants.USB_CLASS_VENDOR_SPEC &&
                    it.interfaceSubclass == ADB_SUBCLASS &&
                    it.interfaceProtocol == ADB_PROTOCOL
            }

    private fun parseSerial(serial: String): Int {
        require(serial.startsWith(USB_SERIAL_PREFIX)) { "Invalid USB ADB serial" }
        return serial.removePrefix(USB_SERIAL_PREFIX).toInt()
    }

    private class UsbLink(
        private val usb: UsbDeviceConnection,
        private val adbInterface: UsbInterface,
        private val input: Closeable,
        private val output: Closeable,
        val connection: DirectAdbConnection,
    ) : Closeable {
        override fun close() {
            connection.close()
            input.close()
            output.close()
            runCatching { usb.releaseInterface(adbInterface) }
            usb.close()
        }
    }

    private class UsbBulkInputStream(
        private val manager: UsbManager,
        private val deviceId: Int,
        private val connection: UsbDeviceConnection,
        private val endpoint: UsbEndpoint,
    ) : InputStream() {
        @Volatile private var closed = false
        @Volatile private var handshakeDeadline =
            System.currentTimeMillis() + USB_HANDSHAKE_TIMEOUT_MS

        fun finishHandshake() { handshakeDeadline = Long.MAX_VALUE }

        override fun read(): Int {
            val single = ByteArray(1)
            return if (read(single, 0, 1) < 0) -1 else single[0].toInt() and 0xff
        }

        override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
            if (closed) return -1
            if (length == 0) return 0
            val target = if (offset == 0) buffer else ByteArray(length)
            while (!closed) {
                val read = connection.bulkTransfer(
                    endpoint,
                    target,
                    0,
                    minOf(length, USB_READ_SIZE),
                    USB_TIMEOUT_MS,
                )
                if (read > 0) {
                    if (target !== buffer) target.copyInto(buffer, offset, 0, read)
                    return read
                }
                if (manager.deviceList.values.none { it.deviceId == deviceId }) {
                    throw EOFException("USB ADB device was detached")
                }
                if (System.currentTimeMillis() >= handshakeDeadline) {
                    throw IOException("USB ADB authorization timed out")
                }
            }
            return -1
        }

        override fun close() { closed = true }
    }

    private class UsbBulkOutputStream(
        private val connection: UsbDeviceConnection,
        private val endpoint: UsbEndpoint,
    ) : OutputStream() {
        @Volatile private var closed = false

        override fun write(value: Int) = write(byteArrayOf(value.toByte()))

        override fun write(buffer: ByteArray, offset: Int, length: Int) {
            check(!closed) { "USB ADB output is closed" }
            var position = offset
            val end = offset + length
            while (position < end) {
                val count = minOf(USB_WRITE_SIZE, end - position)
                val written = connection.bulkTransfer(
                    endpoint,
                    buffer,
                    position,
                    count,
                    USB_TIMEOUT_MS,
                )
                if (written <= 0) throw IOException("USB ADB write failed")
                position += written
            }
        }

        override fun close() { closed = true }
    }

    private companion object {
        const val ACTION_USB_PERMISSION = "dev.scrcpy.flutter.USB_PERMISSION"
        const val USB_SERIAL_PREFIX = "usb:"
        const val ADB_SUBCLASS = 0x42
        const val ADB_PROTOCOL = 0x01
        const val USB_TIMEOUT_MS = 1_000
        const val USB_HANDSHAKE_TIMEOUT_MS = 15_000
        const val USB_READ_SIZE = 16 * 1024
        const val USB_WRITE_SIZE = 16 * 1024

        fun serial(deviceId: Int) = "$USB_SERIAL_PREFIX$deviceId"

        @Suppress("DEPRECATION")
        fun Intent.usbDevice(): UsbDevice? = if (Build.VERSION.SDK_INT >= 33) {
            getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
        } else {
            getParcelableExtra(UsbManager.EXTRA_DEVICE)
        }

        fun writePartial(file: java.io.File, writer: (OutputStream) -> Unit) {
            val parent = file.absoluteFile.parentFile
                ?: error("Local destination has no parent directory")
            parent.mkdirs()
            val partial = java.io.File(parent, ".${file.name}.partial")
            try {
                partial.outputStream().use(writer)
                if (file.exists() && !file.delete()) error("Unable to replace ${file.absolutePath}")
                check(partial.renameTo(file)) { "Unable to finish ${file.absolutePath}" }
            } finally {
                if (partial.exists()) partial.delete()
            }
        }
    }
}
