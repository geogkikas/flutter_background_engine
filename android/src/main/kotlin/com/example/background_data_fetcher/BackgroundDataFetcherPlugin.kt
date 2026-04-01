package com.example.background_data_fetcher

import android.content.Context
import android.os.PowerManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/** BackgroundDataFetcherPlugin */
class BackgroundDataFetcherPlugin : FlutterPlugin, MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        context = flutterPluginBinding.applicationContext
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "background_data_fetcher")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "acquireWakelock" -> {
                // Default to a 30-second max timeout as a safety net so we don't drain the battery if Dart crashes
                val timeout = call.argument<Int>("timeoutMs")?.toLong() ?: 30000L

                if (wakeLock == null) {
                    val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
                    wakeLock = powerManager.newWakeLock(
                        PowerManager.PARTIAL_WAKE_LOCK,
                        "BackgroundDataFetcher::CpuLock"
                    )
                }

                if (wakeLock?.isHeld == false) {
                    wakeLock?.acquire(timeout)
                }
                result.success(true)
            }
            "releaseWakelock" -> {
                if (wakeLock?.isHeld == true) {
                    wakeLock?.release()
                }
                result.success(true)
            }
            "getPlatformVersion" -> {
                result.success("Android ${android.os.Build.VERSION.RELEASE}")
            }
            else -> {
                result.notImplemented()
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        // Safety cleanup
        if (wakeLock?.isHeld == true) {
            wakeLock?.release()
        }
    }
}