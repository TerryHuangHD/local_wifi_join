package io.github.terryhuanghd.local_wifi_join

import android.net.Network
import android.net.wifi.WifiManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/** Android implementation of the `local_wifi_join` method channel. */
class LocalWifiJoinPlugin : FlutterPlugin, MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var wifiManager: WifiManager
    private lateinit var coordinator: WifiJoinCoordinator<Network>

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val context = binding.applicationContext
        wifiManager = context.getSystemService(WifiManager::class.java)
        coordinator = WifiJoinCoordinator(AndroidWifiNetworkPlatform(context))
        channel = MethodChannel(binding.binaryMessenger, "local_wifi_join")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        coordinator.dispose()
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "join" -> join(call, result)
            "leave" -> {
                coordinator.leave()
                result.success(null)
            }
            "isWifiEnabled" -> result.success(wifiManager.isWifiEnabled)
            else -> result.notImplemented()
        }
    }

    private fun join(call: MethodCall, result: Result) {
        val args = call.arguments as? Map<*, *>
        val ssid = args?.get("ssid") as? String
        val passphrase = args?.get("passphrase") as? String
        val timeoutMillis = (args?.get("timeoutMillis") as? Number)?.toLong()
        if (ssid == null || passphrase == null || timeoutMillis == null || timeoutMillis <= 0) {
            result.success(
                JoinOutcome.invalidArguments(
                    "join requires String ssid, String passphrase and a positive int timeoutMillis",
                ).toMap(),
            )
            return
        }
        coordinator.join(ssid, passphrase, timeoutMillis) { outcome -> result.success(outcome.toMap()) }
    }
}
