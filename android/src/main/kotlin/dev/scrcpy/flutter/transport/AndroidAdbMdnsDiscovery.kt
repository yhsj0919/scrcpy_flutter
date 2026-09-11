package dev.scrcpy.flutter.transport

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.util.Log
import java.io.Closeable
import java.util.ArrayDeque
import java.util.concurrent.ConcurrentHashMap

internal data class AndroidAdbMdnsService(
    val name: String,
    val type: String,
    val host: String,
    val port: Int,
)

/** Maintains a resolved cache of Wireless Debugging DNS-SD services. */
internal class AndroidAdbMdnsDiscovery(context: Context) : Closeable {
    private val applicationContext = context.applicationContext
    private val manager = applicationContext.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val wifiManager =
        applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private val services = ConcurrentHashMap<String, AndroidAdbMdnsService>()
    private val listeners = mutableMapOf<String, NsdManager.DiscoveryListener>()
    private val resolveLock = Any()
    private val resolveQueue = ArrayDeque<NsdServiceInfo>()
    private val queuedKeys = mutableSetOf<String>()
    private var resolving = false
    private var multicastLock: WifiManager.MulticastLock? = null
    @Volatile private var closed = false

    fun snapshot(waitMillis: Long = 0): List<AndroidAdbMdnsService> {
        ensureStarted()
        val deadline = System.currentTimeMillis() + waitMillis.coerceAtLeast(0)
        do {
            val current = services.values.sortedWith(
                compareBy({ it.type }, { it.name }, { it.host }, { it.port }),
            )
            if (current.isNotEmpty() || System.currentTimeMillis() >= deadline) return current
            Thread.sleep(DISCOVERY_POLL_MS)
        } while (!closed)
        return emptyList()
    }

    @Synchronized
    private fun ensureStarted() {
        if (closed) return
        if (multicastLock?.isHeld != true) {
            multicastLock = wifiManager.createMulticastLock(MULTICAST_LOCK_TAG).apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        for (type in SERVICE_TYPES) {
            if (listeners.containsKey(type)) continue
            val listener = discoveryListener(type)
            listeners[type] = listener
            try {
                manager.discoverServices(type, NsdManager.PROTOCOL_DNS_SD, listener)
            } catch (error: RuntimeException) {
                listeners.remove(type)
                Log.w(TAG, "Unable to start mDNS discovery for $type", error)
            }
        }
    }

    private fun discoveryListener(type: String) = object : NsdManager.DiscoveryListener {
        override fun onDiscoveryStarted(serviceType: String) {
            Log.i(TAG, "mDNS discovery started: $serviceType")
        }

        override fun onServiceFound(serviceInfo: NsdServiceInfo) {
            if (normalizeType(serviceInfo.serviceType) != normalizeType(type)) return
            enqueueResolve(serviceInfo)
        }

        override fun onServiceLost(serviceInfo: NsdServiceInfo) {
            services.remove(serviceKey(serviceInfo))
            synchronized(resolveLock) {
                val key = serviceKey(serviceInfo)
                resolveQueue.removeAll { serviceKey(it) == key }
                queuedKeys.remove(key)
            }
        }

        override fun onDiscoveryStopped(serviceType: String) {
            synchronized(this@AndroidAdbMdnsDiscovery) { listeners.remove(type) }
        }

        override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
            Log.w(TAG, "mDNS discovery start failed: $serviceType ($errorCode)")
            stopFailedDiscovery(type, this)
        }

        override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
            Log.w(TAG, "mDNS discovery stop failed: $serviceType ($errorCode)")
            synchronized(this@AndroidAdbMdnsDiscovery) { listeners.remove(type) }
        }
    }

    private fun stopFailedDiscovery(type: String, listener: NsdManager.DiscoveryListener) {
        runCatching { manager.stopServiceDiscovery(listener) }
        synchronized(this) { listeners.remove(type) }
    }

    private fun enqueueResolve(serviceInfo: NsdServiceInfo) {
        synchronized(resolveLock) {
            val key = serviceKey(serviceInfo)
            if (!queuedKeys.add(key)) return
            resolveQueue.addLast(serviceInfo)
            resolveNextLocked()
        }
    }

    @Suppress("DEPRECATION")
    private fun resolveNextLocked() {
        if (resolving || closed) return
        if (resolveQueue.isEmpty()) return
        val serviceInfo = resolveQueue.removeFirst()
        resolving = true
        manager.resolveService(serviceInfo, object : NsdManager.ResolveListener {
            override fun onServiceResolved(resolved: NsdServiceInfo) {
                val host = resolved.host?.hostAddress
                if (!host.isNullOrBlank() && resolved.port in 1..65535) {
                    services[serviceKey(resolved)] = AndroidAdbMdnsService(
                        name = resolved.serviceName,
                        type = normalizeType(resolved.serviceType),
                        host = host,
                        port = resolved.port,
                    )
                }
                finishResolve(serviceInfo)
            }

            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "Unable to resolve ${serviceInfo.serviceName}: $errorCode")
                services.remove(serviceKey(serviceInfo))
                finishResolve(serviceInfo)
            }
        })
    }

    private fun finishResolve(serviceInfo: NsdServiceInfo) {
        synchronized(resolveLock) {
            queuedKeys.remove(serviceKey(serviceInfo))
            resolving = false
            resolveNextLocked()
        }
    }

    override fun close() {
        closed = true
        val active = synchronized(this) {
            val result = listeners.values.toList()
            listeners.clear()
            result
        }
        active.forEach { runCatching { manager.stopServiceDiscovery(it) } }
        synchronized(resolveLock) {
            resolveQueue.clear()
            queuedKeys.clear()
        }
        services.clear()
        multicastLock?.runCatching { if (isHeld) release() }
        multicastLock = null
    }

    private companion object {
        const val TAG = "AndroidAdbMdns"
        const val MULTICAST_LOCK_TAG = "scrcpy_flutter:mdns"
        const val DISCOVERY_POLL_MS = 50L
        const val PAIRING_TYPE = "_adb-tls-pairing._tcp."
        const val CONNECT_TYPE = "_adb-tls-connect._tcp."
        val SERVICE_TYPES = listOf(PAIRING_TYPE, CONNECT_TYPE)

        fun normalizeType(value: String) = value.trim().trimEnd('.').lowercase()

        fun serviceKey(serviceInfo: NsdServiceInfo) =
            "${normalizeType(serviceInfo.serviceType)}:${serviceInfo.serviceName}"
    }
}
