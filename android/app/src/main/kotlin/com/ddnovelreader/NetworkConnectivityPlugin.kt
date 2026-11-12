package com.ddnovelreader

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/** Default-network monitoring is owned by the shared engine, not an Activity. */
class NetworkConnectivityPlugin : FlutterPlugin, EventChannel.StreamHandler {
    private var manager: ConnectivityManager? = null
    private var methods: MethodChannel? = null
    private var events: EventChannel? = null
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var currentNetwork: Network? = null
    private var pendingOffline: Runnable? = null
    private var revision = 0

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        manager = binding.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        methods = MethodChannel(binding.binaryMessenger, "com.ddnovelreader/network").also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getAvailability" -> result.success(availability())
                    "isSupported" -> result.success(true)
                    else -> result.notImplemented()
                }
            }
        }
        events = EventChannel(binding.binaryMessenger, "com.ddnovelreader/network/events").also {
            it.setStreamHandler(this)
        }
    }

    private fun availability(): Boolean? = try {
        val network = manager?.activeNetwork
        if (network == null) false
        else manager?.getNetworkCapabilities(network)?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        // VALIDATED is intentionally not required. A vendor's connectivity
        // probe may be blocked while the speech endpoint remains reachable.
    } catch (_: RuntimeException) { null }

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) {
        stopMonitoring()
        sink = eventSink
        val generation = revision
        fun post(action: () -> Unit) {
            main.post { if (generation == revision) action() }
        }
        fun cancelOffline() {
            pendingOffline?.let { main.removeCallbacks(it) }
            pendingOffline = null
        }
        fun scheduleOffline() {
            cancelOffline()
            // Coalesce default-network handover callbacks. This is a local
            // grace period, never an HTTP connectivity probe or polling loop.
            val task = Runnable {
                pendingOffline = null
                if (generation == revision && currentNetwork == null) sink?.success(availability())
            }
            pendingOffline = task
            main.postDelayed(task, 150)
        }
        val listener = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = post {
                currentNetwork = network
                cancelOffline()
                // Wait for onCapabilitiesChanged, rather than read a possibly
                // stale capability snapshot from within onAvailable.
            }
            override fun onLost(network: Network) = post {
                if (currentNetwork == network) { currentNetwork = null; scheduleOffline() }
            }
            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) = post {
                if (currentNetwork == null) currentNetwork = network
                if (currentNetwork == network) {
                    cancelOffline()
                    sink?.success(capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET))
                }
            }
            override fun onUnavailable() = post { if (currentNetwork == null) scheduleOffline() }
        }
        callback = listener
        try {
            manager?.registerDefaultNetworkCallback(listener)
            post { if (currentNetwork == null) sink?.success(availability()) }
        } catch (_: RuntimeException) {
            callback = null
            sink?.error("network_monitor_unavailable", "Network state monitoring is unavailable", null)
        }
    }

    private fun stopMonitoring() {
        revision++
        pendingOffline?.let { main.removeCallbacks(it) }
        pendingOffline = null; currentNetwork = null
        val old = callback
        callback = null
        if (old != null) try { manager?.unregisterNetworkCallback(old) } catch (_: RuntimeException) { }
        sink = null
    }

    override fun onCancel(arguments: Any?) = stopMonitoring()

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopMonitoring()
        methods?.setMethodCallHandler(null)
        events?.setStreamHandler(null)
        methods = null; events = null; manager = null
    }
}
