package io.github.terryhuanghd.local_wifi_join

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiNetworkSpecifier
import android.os.Handler
import android.os.Looper

/**
 * [WifiNetworkPlatform] backed by `WifiNetworkSpecifier` + `ConnectivityManager.requestNetwork`
 * (API 29+). Callbacks and scheduled actions run on the main looper.
 */
internal class AndroidWifiNetworkPlatform(context: Context) : WifiNetworkPlatform<Network> {
    private val connectivityManager = context.getSystemService(ConnectivityManager::class.java)
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun requestNetwork(
        ssid: String,
        passphrase: String,
        listener: NetworkRequestListener<Network>,
    ): Cancellable {
        val specifier = WifiNetworkSpecifier.Builder()
            .setSsid(ssid)
            .setWpa2Passphrase(passphrase)
            .build()
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()
        // The callback must stay registered while joined: unregistering it disconnects the network.
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = listener.onAvailable(network)

            override fun onUnavailable() = listener.onUnavailable()

            override fun onLost(network: Network) = listener.onLost(network)
        }
        connectivityManager.requestNetwork(request, callback, mainHandler)
        return Cancellable {
            try {
                connectivityManager.unregisterNetworkCallback(callback)
            } catch (_: IllegalArgumentException) {
                // Already released by the system, e.g. after onUnavailable.
            }
        }
    }

    override fun bindProcessToNetwork(network: Network): Boolean =
        connectivityManager.bindProcessToNetwork(network)

    override fun unbindProcessFrom(network: Network) {
        if (connectivityManager.boundNetworkForProcess == network) {
            connectivityManager.bindProcessToNetwork(null)
        }
    }

    override fun schedule(delayMillis: Long, action: () -> Unit): Cancellable {
        val runnable = Runnable(action)
        mainHandler.postDelayed(runnable, delayMillis)
        return Cancellable { mainHandler.removeCallbacks(runnable) }
    }
}
