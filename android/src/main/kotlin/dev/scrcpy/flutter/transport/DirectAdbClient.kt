package dev.scrcpy.flutter.transport

import android.util.Base64
import android.util.Log
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.math.BigInteger
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.KeyFactory
import java.security.PrivateKey
import java.security.Signature
import java.security.spec.RSAPublicKeySpec
import java.security.spec.X509EncodedKeySpec
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.SSLSocket
import kotlin.concurrent.thread

internal const val DEFAULT_ADB_KEY_NAME = "scrcpy_flutter@android"

/**
 * A direct ADB connection imported from ScrcpyForAndroid.
 *
 * Exposes framed ADB streams via `openStream` and handles the protocol handshake,
 * reader thread and stream routing.
 *
 * 支持两种连接方式:
 * 1. TCP 连接: 通过 host:port 建立 Socket 连接
 * 2. 流式连接: 通过注入的 InputStream/OutputStream 建立连接 (用于 USB 等非 TCP 场景)
 */
internal class DirectAdbConnection(
    val host: String,
    val port: Int,
    private val privateKey: PrivateKey,
    private val publicKeyX509: ByteArray,
    private val keyName: String = DEFAULT_ADB_KEY_NAME,
): AutoCloseable {

    private val sha1DigestInfoPrefix = byteArrayOf(
        0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2B, 0x0E,
        0x03, 0x02, 0x1A, 0x05, 0x00, 0x04, 0x14,
    )

    // 连接类型标识
    enum class ConnectionType {
        TCP,    // TCP Socket 连接
        STREAM  // 流式连接 (USB 等)
    }

    var connectionType: ConnectionType = ConnectionType.TCP
        private set

    // TCP 连接相关
    var socket: Socket? = null
        private set

    // 流式连接相关 (USB 等)
    private var injectedInputStream: InputStream? = null
    private var injectedOutputStream: OutputStream? = null

    private lateinit var rawIn: BufferedInputStream
    private lateinit var rawOut: OutputStream
    private var tlsSocket: SSLSocket? = null
    private val nextLocalId = AtomicInteger(1)
    private val streams = ConcurrentHashMap<Int, AdbSocketStream>()

    @Volatile
    private var closed = false
    private val resourcesClosed = AtomicBoolean()
    private var readerThread: Thread? = null

    /**
     * TCP 连接构造函数
     */
    constructor(
        host: String,
        port: Int,
        privateKey: PrivateKey,
        publicKeyX509: ByteArray,
        keyName: String,
        @Suppress("UNUSED_PARAMETER") tcpMarker: Boolean = true,  // 用于区分构造函数
    ): this(host, port, privateKey, publicKeyX509, keyName) {
        this.connectionType = ConnectionType.TCP
        this.socket = Socket()
    }

    /**
     * 流式连接构造函数 (用于 USB 等非 TCP 场景)
     * 通过注入的 InputStream/OutputStream 建立 ADB 连接
     */
    constructor(
        inputStream: InputStream,
        outputStream: OutputStream,
        privateKey: PrivateKey,
        publicKeyX509: ByteArray,
        keyName: String = DEFAULT_ADB_KEY_NAME,
        deviceId: Int? = null,
    ): this(
        host = "usb:${deviceId ?: "unknown"}",  // 使用 USB 标识作为 host
        port = 0,  // USB 连接不使用端口
        privateKey = privateKey,
        publicKeyX509 = publicKeyX509,
        keyName = keyName,
    ) {
        this.connectionType = ConnectionType.STREAM
        this.socket = null
        this.injectedInputStream = inputStream
        this.injectedOutputStream = outputStream
    }

    companion object {
        private const val TAG = "DirectAdbConnection"

        /** 握手读阶段的 soTimeout 兜底下限: 无限连接超时模式下防止无响应设备永久锁死连接锁 */
        private const val HANDSHAKE_READ_SO_TIMEOUT_MS = 60_000

        private const val A_CNXN = 0x4e584e43
        private const val A_AUTH = 0x48545541
        private const val A_STLS = 0x534c5453
        private const val A_OPEN = 0x4e45504f
        private const val A_OKAY = 0x59414b4f
        private const val A_CLSE = 0x45534c43
        private const val A_WRTE = 0x45545257
        private const val STLS_VERSION = 0x01000000
        private const val AUTH_TOKEN = 1
        private const val AUTH_SIGNATURE = 2
        private const val AUTH_RSAPUBLICKEY = 3
        private const val VERSION = 0x01000001
        private const val MAX_PAYLOAD = 256 * 1024
    }

    /**
     * 执行 ADB 协议握手
     *
     * 支持两种连接方式:
     * 1. TCP 连接: 建立 Socket 连接, 支持 TLS 升级
     * 2. 流式连接: 使用注入的 InputStream/OutputStream (用于 USB 等场景)
     *
     * 握手流程:
     * - 发送 CNXN 消息
     * - 处理可选的 STLS(TLS 升级)
     * - 处理 AUTH 认证 (TOKEN -> SIGNATURE 或 PUBKEY 流程)
     * - 成功后启动读取线程
     */
    fun handshake(timeoutMs: Int = 10_000) {
        when (connectionType) {
            ConnectionType.TCP -> handshakeTcp(timeoutMs)
            ConnectionType.STREAM -> handshakeStream()
        }
    }

    /**
     * TCP 连接握手
     */
    private fun handshakeTcp(timeoutMs: Int) {
        Log.i(
            TAG,
            "handshakeTcp(): tcp connect -> $host:$port (timeout=${if (timeoutMs == 0) "infinite" else "${timeoutMs}ms"})",
        )
        val tcpSocket = socket ?: throw IllegalStateException("TCP socket is null")

        // timeoutMs 为 0 表示不超时
        tcpSocket.connect(InetSocketAddress(host, port), timeoutMs)
        tcpSocket.tcpNoDelay = true
        tcpSocket.keepAlive = true
        // 握手读阶段兜底: 至少 60s 上限, 防止无响应设备在无限连接超时模式下永久锁死连接锁;
        // 数据阶段的 soTimeout 在握手成功后清为无限 (该行为不变)
        tcpSocket.soTimeout = maxOf(timeoutMs, HANDSHAKE_READ_SO_TIMEOUT_MS)
        // 增大 Socket 缓冲区, 减少高码率视频传输时的阻塞和卡顿
        tcpSocket.receiveBufferSize = 1_048_576  // 1MB
        tcpSocket.sendBufferSize = 1_048_576     // 1MB
        rawIn = BufferedInputStream(tcpSocket.getInputStream(), 262_144)
        rawOut = tcpSocket.getOutputStream()

        performAdbHandshake()

        tcpSocket.soTimeout = 0
        readerThread = thread(isDaemon = true, name = "adb-reader-$host:$port") { readLoop() }
    }

    /**
     * 流式连接握手 (用于 USB 等非 TCP 场景)
     */
    private fun handshakeStream() {
        Log.i(TAG, "handshakeStream(): stream connect -> $host")

        val inputStream = injectedInputStream
            ?: throw IllegalStateException("Injected InputStream is null")
        val outputStream = injectedOutputStream
            ?: throw IllegalStateException("Injected OutputStream is null")

        rawIn = BufferedInputStream(inputStream, 262_144)
        rawOut = outputStream

        performAdbHandshake()

        readerThread = thread(isDaemon = true, name = "adb-reader-$host") { readLoop() }
    }

    /**
     * 执行 ADB 协议握手 (TCP 和流式连接共用)
     *
     * 处理 CNXN, STLS, AUTH 等消息
     */
    private fun performAdbHandshake() {
        sendMsg(A_CNXN, VERSION, MAX_PAYLOAD, "host::\u0000".toByteArray(Charsets.UTF_8))

        var first = recvMsg()
        if (first.command == A_STLS) {
            sendMsg(A_STLS, STLS_VERSION, 0)
            upgradeToTls()
            first = recvMsg()
        }

        when (first.command) {
            A_CNXN -> Unit
            A_AUTH -> {
                if (first.arg0 != AUTH_TOKEN) {
                    throw IOException("ADB: expected AUTH_TOKEN, got type=${first.arg0}")
                }
                sendMsg(A_AUTH, AUTH_SIGNATURE, 0, signToken(first.data))
                val afterSign = recvMsg()
                when (afterSign.command) {
                    A_CNXN -> Unit
                    A_AUTH -> {
                        if (afterSign.arg0 != AUTH_TOKEN) {
                            throw IOException("ADB: expected AUTH_TOKEN after rejected signature, got type=${afterSign.arg0}")
                        }
                        sendMsg(A_AUTH, AUTH_RSAPUBLICKEY, 0, buildAdbPubKey())
                        val cnxn = recvMsg()
                        if (cnxn.command != A_CNXN) {
                            throw IOException("ADB: connection rejected. Please accept the authorisation dialog on the target device.")
                        }
                    }

                    else -> throw IOException(
                        "ADB: unexpected message 0x${
                            afterSign.command.toString(
                                16,
                            )
                        } after AUTH_SIGNATURE",
                    )
                }
            }

            else -> throw IOException("ADB: unexpected initial message 0x${first.command.toString(16)}")
        }
    }

    /**
     * 升级到 TLS 连接
     *
     * 注意: USB 连接不支持 TLS 升级, 因为 USB 隧道已经提供了安全传输
     */
    private fun upgradeToTls() {
        when (connectionType) {
            ConnectionType.TCP -> {
                val tcpSocket = socket ?: throw IllegalStateException("TCP socket is null")
                val pairingKey = AdbPairingKey(
                    privateKey = privateKey,
                    alias = keyName,
                )
                val sslSocket = pairingKey.sslContext.socketFactory
                    .createSocket(tcpSocket, host, port, true) as SSLSocket
                sslSocket.startHandshake()
                tlsSocket = sslSocket
                rawIn = BufferedInputStream(sslSocket.inputStream, 65_536)
                rawOut = sslSocket.outputStream
            }

            ConnectionType.STREAM -> {
                // USB 连接不支持 TLS 升级, 跳过
                Log.w(TAG, "upgradeToTls(): TLS upgrade not supported for stream connections")
            }
        }
    }

    /**
     * Open a logical ADB stream for `service` and return an [AdbSocketStream].
     *
     * - Sends an A_OPEN message and waits for remote acknowledgment. The returned
     *   stream exposes blocking InputStream/OutputStream wrappers usable by callers.
     */
    fun openStream(service: String): AdbSocketStream {
        val localId = nextLocalId.getAndIncrement()
        val flowControlWindow = 0
        val stream = AdbSocketStream(
            localId,
            { command, arg0, arg1, data ->
                sendMsg(command, arg0, arg1, data)
            },
            flowControlWindow,
        )
        streams[localId] = stream
        sendMsg(A_OPEN, localId, 0, (service + "\u0000").toByteArray(Charsets.UTF_8))
        try {
            stream.awaitOpen(15_000)
        } catch (e: Exception) {
            streams.remove(localId)
            throw e
        }
        return stream
    }

    fun shell(command: String): String =
        openStream("shell:$command")
            .use { it.inputStream.readBytes().toString(Charsets.UTF_8) }

    /**
     * Push raw bytes to a remote path using the minimal ADB "sync" protocol.
     *
     * - Implements SEND/DATA/DONE/OKAY sequence and throws IOException on failure.
     */
    fun push(data: ByteArray, remotePath: String, unixMode: Int = 420) {
        data.inputStream().use { input ->
            push(input, remotePath, unixMode)
        }
    }

    fun push(input: InputStream, remotePath: String, unixMode: Int = 420) {
        openStream("sync:")
            .use { stream ->
                val out = stream.outputStream
                val inp = stream.inputStream
                val pathMode = "$remotePath,$unixMode".toByteArray(Charsets.UTF_8)

                out.write("SEND".toByteArray(Charsets.US_ASCII))
                out.writeIntLE(pathMode.size)
                out.write(pathMode)

                val chunkBuf = ByteArray(64 * 1024)
                while (true) {
                    val len = input.read(chunkBuf)
                    if (len <= 0) break

                    out.write("DATA".toByteArray(Charsets.US_ASCII))
                    out.writeIntLE(len)
                    out.write(chunkBuf, 0, len)
                }

                out.write("DONE".toByteArray(Charsets.US_ASCII))
                out.writeIntLE((System.currentTimeMillis() / 1000).toInt())
                out.flush()

                val idBuf = ByteArray(4).also { inp.readExact(it) }
                val msgLen = inp.readIntLE()
                val id = String(idBuf, Charsets.US_ASCII)
                if (id != "OKAY") {
                    val msg = if (msgLen > 0) ByteArray(msgLen).also { inp.readExact(it) }
                        .toString(Charsets.UTF_8) else id
                    throw IOException("ADB push failed: $msg")
                } else if (msgLen > 0) {
                    inp.skip(msgLen.toLong())
                }
            }
    }

    fun pull(remotePath: String): ByteArray {
        val output = ByteArrayOutputStream()
        pull(remotePath, output)
        return output.toByteArray()
    }

    fun pull(remotePath: String, output: OutputStream) {
        openStream("sync:")
            .use { stream ->
                val out = stream.outputStream
                val inp = stream.inputStream
                val pathBytes = remotePath.toByteArray(Charsets.UTF_8)

                out.write("RECV".toByteArray(Charsets.US_ASCII))
                out.writeIntLE(pathBytes.size)
                out.write(pathBytes)
                out.flush()

                while (true) {
                    val idBuf = ByteArray(4).also { inp.readExact(it) }
                    val msgLen = inp.readIntLE()
                    when (val id = String(idBuf, Charsets.US_ASCII)) {
                        "DATA" -> {
                            val chunk = ByteArray(msgLen)
                            inp.readExact(chunk)
                            output.write(chunk)
                        }

                        "DONE" -> {
                            // The second word is a protocol status/mtime field,
                            // not a payload length.
                            return
                        }

                        "FAIL" -> {
                            val msg = if (msgLen > 0) {
                                ByteArray(msgLen).also { inp.readExact(it) }
                                    .toString(Charsets.UTF_8)
                            } else {
                                "unknown error"
                            }
                            throw IOException("ADB pull failed: $msg")
                        }

                        else -> {
                            if (msgLen > 0) {
                                inp.skip(msgLen.toLong())
                            }
                            throw IOException("ADB pull failed: unexpected sync id $id")
                        }
                    }
                }
            }
    }

    /**
     * 检查连接是否存活
     *
     * TCP 连接: 检查 socket 状态
     * 流式连接: 检查 closed 标志和流是否可用
     */
    fun isAlive(): Boolean {
        if (closed) return false

        return when (connectionType) {
            ConnectionType.TCP -> {
                val tcpSocket = socket ?: return false
                !tcpSocket.isClosed && tcpSocket.isConnected
            }

            ConnectionType.STREAM -> {
                // 流式连接: 检查流是否仍然可用
                val inputStream = injectedInputStream
                val outputStream = injectedOutputStream
                inputStream != null && outputStream != null
            }
        }
    }

    override fun close() {
        closed = true
        if (!resourcesClosed.compareAndSet(false, true)) return
        streams.values.forEach { runCatching { it.forceClose() } }
        streams.clear()
        runCatching { tlsSocket?.close() }

        // 根据连接类型关闭相应的资源
        when (connectionType) {
            ConnectionType.TCP -> {
                runCatching { socket?.close() }
            }

            ConnectionType.STREAM -> {
                // 流式连接: 使用者仍拥有注入流, 这里只清除引用。
                injectedInputStream = null
                injectedOutputStream = null
            }
        }

        runCatching { readerThread?.interrupt() }
    }

    private fun readLoop() {
        try {
            while (!closed) {
                val msg = recvMsg()
                when (msg.command) {
                    A_OKAY -> streams[msg.arg1]?.onRemoteOkay(msg.arg0)
                    A_WRTE -> {
                        val s = streams[msg.arg1]
                        if (s != null) {
                            s.onData(msg.data)
                            sendMsg(A_OKAY, msg.arg1, msg.arg0)
                        } else {
                            sendMsg(A_CLSE, 0, msg.arg0)
                        }
                    }

                    A_CLSE -> streams.remove(msg.arg1)?.forceClose()
                    A_OPEN -> sendMsg(A_CLSE, 0, msg.arg0)
                }
            }
        } catch (error: Exception) {
            if (!closed) {
                Log.w(TAG, "ADB reader stopped", error)
                close()
            }
        }
    }

    /**
     * Send a framed ADB message (header + optional payload).
     *
     * - Header fields are little-endian as required by the ADB protocol.
     */
    @Synchronized
    private fun sendMsg(
        command: Int,
        arg0: Int = 0,
        arg1: Int = 0,
        data: ByteArray = ByteArray(0),
    ) {
        val crc = data.fold(0L) { acc, b -> acc + (b.toLong() and 0xFF) }.toInt()
        val header = ByteBuffer.allocate(24).order(ByteOrder.LITTLE_ENDIAN)
            .putInt(command).putInt(arg0).putInt(arg1)
            .putInt(data.size).putInt(crc).putInt(command xor -1)
            .array()
        rawOut.write(header)
        if (data.isNotEmpty()) rawOut.write(data)
        rawOut.flush()
    }

    /**
     * Receive and parse a single ADB framed message from the socket.
     *
     * - Blocks until the full 24-byte header is read and then reads the payload.
     */
    private fun recvMsg(): AdbMsg {
        val h = ByteArray(24)
        rawIn.readExact(h)
        val buf = ByteBuffer.wrap(h).order(ByteOrder.LITTLE_ENDIAN)
        val command = buf.int
        val arg0 = buf.int
        val arg1 = buf.int
        val dataLen = buf.int
        buf.int
        buf.int
        // ADB 协议限制: MAX_PAYLOAD = 256KB, 拒绝异常大的数据长度
        if (dataLen < 0 || dataLen > MAX_PAYLOAD) {
            throw IOException("ADB: corrupted message, invalid dataLen=$dataLen (max=$MAX_PAYLOAD)")
        }
        val data =
            if (dataLen > 0) ByteArray(dataLen).also { rawIn.readExact(it) } else ByteArray(0)
        return AdbMsg(command, arg0, arg1, data)
    }

    private data class AdbMsg(val command: Int, val arg0: Int, val arg1: Int, val data: ByteArray) {
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (javaClass != other?.javaClass) return false

            other as AdbMsg

            if (command != other.command) return false
            if (arg0 != other.arg0) return false
            if (arg1 != other.arg1) return false
            if (!data.contentEquals(other.data)) return false

            return true
        }

        override fun hashCode(): Int {
            var result = command
            result = 31 * result + arg0
            result = 31 * result + arg1
            result = 31 * result + data.contentHashCode()
            return result
        }
    }

    private fun signToken(token: ByteArray): ByteArray {
        // adbd expects RSA signature over SHA-1 digest info where token is the digest payload.
        val payload = ByteArray(sha1DigestInfoPrefix.size + token.size)
        sha1DigestInfoPrefix.copyInto(payload, destinationOffset = 0)
        token.copyInto(payload, destinationOffset = sha1DigestInfoPrefix.size)
        return Signature.getInstance("NONEwithRSA").apply {
            initSign(privateKey)
            update(payload)
        }.sign()
    }

    private fun buildAdbPubKey(): ByteArray {
        val kf = KeyFactory.getInstance("RSA")
        val pub = kf.generatePublic(X509EncodedKeySpec(publicKeyX509))
        val spec = kf.getKeySpec(pub, RSAPublicKeySpec::class.java)
        val adbKeyBytes = encodeAdbPublicKey(spec.modulus, spec.publicExponent.toInt())
        return "${Base64.encodeToString(adbKeyBytes, Base64.NO_WRAP)} $keyName\u0000"
            .toByteArray(Charsets.UTF_8)
    }

    private fun encodeAdbPublicKey(modulus: BigInteger, exponent: Int): ByteArray {
        val words = 64
        val bytes = 256
        val two32 = BigInteger.ONE.shiftLeft(32)
        val mask32 = two32.subtract(BigInteger.ONE)

        fun toBigEndianPadded(n: BigInteger): ByteArray {
            val raw = n.toByteArray()
            val arr = ByteArray(bytes)
            val src = if (raw[0] == 0.toByte()) raw.copyOfRange(1, raw.size) else raw
            src.copyInto(arr, destinationOffset = bytes - src.size)
            return arr
        }

        val modBE = toBigEndianPadded(modulus)
        // n0 is the least-significant 32 bits of modulus; for RSA modulus this must be odd.
        val n0 = modulus.and(mask32)
        val n0inv = n0.modInverse(two32).negate().mod(two32).toInt()
        val r = BigInteger.ONE.shiftLeft(bytes * 8)
        val rrBE = toBigEndianPadded(r.multiply(r).mod(modulus))

        val buf = ByteBuffer.allocate(4 + 4 + bytes + bytes + 4).order(ByteOrder.LITTLE_ENDIAN)
        buf.putInt(words)
        buf.putInt(n0inv)
        for (i in words - 1 downTo 0) {
            val o = i * 4
            buf.put(modBE[o + 3]); buf.put(modBE[o + 2]); buf.put(modBE[o + 1]); buf.put(modBE[o])
        }
        for (i in words - 1 downTo 0) {
            val o = i * 4
            buf.put(rrBE[o + 3]); buf.put(rrBE[o + 2]); buf.put(rrBE[o + 1]); buf.put(rrBE[o])
        }
        buf.putInt(exponent)
        return buf.array()
    }
}

/**
 * Logical ADB stream abstraction mapped to a local id. Provides blocking
 * `InputStream`/`OutputStream` implementations and lifecycle helpers used by callers.
 */
class AdbSocketStream(
    val localId: Int,
    private val sender: (cmd: Int, arg0: Int, arg1: Int, `data`: ByteArray) -> Unit,
    private val flowControlWindow: Int = 0,
): Closeable {

    companion object {
        private const val A_WRTE = 0x45545257
        private const val A_CLSE = 0x45534c43
    }

    @Volatile
    var remoteId: Int = 0

    @Volatile
    var closed: Boolean = false

    private val latch = CountDownLatch(1)
    private val latchOk = AtomicBoolean(false)
    private val queue = LinkedBlockingQueue<Any>()

    // need notifyAll() / wait()
    private val writeLock = Object()

    @Volatile
    private var inflightWrites = 0

    private object EndOfStreamMarker

    val inputStream: InputStream = InStream()
    val outputStream: OutputStream = OutStream()

    internal fun onRemoteOkay(remote: Int) {
        if (remoteId == 0) {
            remoteId = remote
            latchOk.set(true)
            latch.countDown()
        }
        if (flowControlWindow > 0) {
            synchronized(writeLock) {
                if (inflightWrites > 0) inflightWrites--
                writeLock.notifyAll()
            }
        }
    }

    internal fun onData(data: ByteArray) {
        if (!closed) queue.offer(data)
    }

    internal fun forceClose() {
        closed = true
        queue.offer(EndOfStreamMarker)
        latch.countDown()
        if (flowControlWindow > 0) {
            synchronized(writeLock) { writeLock.notifyAll() }
        }
    }

    fun awaitOpen(timeoutMs: Long) {
        if (!latch.await(timeoutMs, TimeUnit.MILLISECONDS)) {
            throw IOException("ADB stream open timed out (localId=$localId)")
        }
        if (!latchOk.get()) {
            throw IOException("ADB stream rejected by device (localId=$localId)")
        }
    }

    override fun close() {
        if (closed) return

        closed = true
        if (remoteId != 0) runCatching {
            sender(A_CLSE, localId, remoteId, ByteArray(0))
        }
        queue.offer(EndOfStreamMarker)
        if (flowControlWindow > 0) {
            synchronized(writeLock) { writeLock.notifyAll() }
        }
    }

    private inner class InStream: InputStream() {
        private var chunk: ByteArray? = null
        private var off = 0

        override fun read(): Int {
            val b = ByteArray(1)
            return if (read(b, 0, 1) == -1) -1 else (b[0].toInt() and 0xFF)
        }

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            while (true) {
                val c = chunk
                if (c != null && this.off < c.size) {
                    val n = minOf(len, c.size - this.off)
                    c.copyInto(b, off, this.off, this.off + n)
                    this.off += n
                    return n
                }
                chunk = null
                this.off = 0
                val next = queue.take()
                if (next === EndOfStreamMarker) {
                    return -1
                }
                chunk = next as ByteArray
            }
        }

        override fun available(): Int = chunk?.let { it.size - off } ?: 0
    }

    private inner class OutStream: OutputStream() {
        override fun write(b: Int) = write(byteArrayOf(b.toByte()))
        override fun write(b: ByteArray, off: Int, len: Int) {
            if (closed) throw IOException("ADB stream closed")
            if (len == 0) return
            if (flowControlWindow > 0) {
                synchronized(writeLock) {
                    while (inflightWrites >= flowControlWindow && !closed) {
                        writeLock.wait()
                    }
                    if (closed) throw IOException("ADB stream closed")
                    inflightWrites++
                }
            }
            sender(A_WRTE, localId, remoteId, b.copyOfRange(off, off + len))
        }

        override fun flush() {}
    }
}

private fun InputStream.readExact(buf: ByteArray) {
    var off = 0
    while (off < buf.size) {
        val n = read(buf, off, buf.size - off)
        if (n < 0) throw EOFException("readExact: expected ${buf.size} bytes, got $off")
        // len>0 时 read 合法返回值不含 0, 出现即为异常流状态, 防死循环
        if (n == 0) throw IOException("readExact: stream returned 0 bytes at offset $off")
        off += n
    }
}

private fun InputStream.readIntLE(): Int {
    val b0 = read()
    val b1 = read()
    val b2 = read()
    val b3 = read()
    if (b3 < 0) throw EOFException("readIntLE: EOF")
    return b0 or (b1 shl 8) or (b2 shl 16) or (b3 shl 24)
}

private fun OutputStream.writeIntLE(v: Int) {
    write(v and 0xFF)
    write(v shr 8 and 0xFF)
    write(v shr 16 and 0xFF)
    write(v shr 24 and 0xFF)
}
