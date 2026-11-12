package com.ddnovelreader

import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private val CHANNEL = "com.ddnovelreader/volume_keys"
    private var channel: MethodChannel? = null
    private var systemSpeech: SystemSpeech? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        systemSpeech = SystemSpeech(this, flutterEngine.dartExecutor.binaryMessenger)
        volumeControlStream = android.media.AudioManager.STREAM_MUSIC
        val logChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.ddnovelreader/debug_log")
        logChannel.setMethodCallHandler { call, _ ->
            if (call.method == "log") {
                android.util.Log.i("DDReader", call.arguments as? String ?: "")
            }
        }
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getMediaVolume" -> {
                    val am = getSystemService(AUDIO_SERVICE) as android.media.AudioManager
                    val max = am.getStreamMaxVolume(android.media.AudioManager.STREAM_MUSIC)
                    val cur = am.getStreamVolume(android.media.AudioManager.STREAM_MUSIC)
                    result.success(if (max > 0) cur.toDouble() / max else 1.0)
                }
                "setMediaVolume" -> {
                    val v = (call.arguments as Number).toFloat().coerceIn(0f, 1f)
                    val am = getSystemService(AUDIO_SERVICE) as android.media.AudioManager
                    val max = am.getStreamMaxVolume(android.media.AudioManager.STREAM_MUSIC)
                    am.setStreamVolume(android.media.AudioManager.STREAM_MUSIC, (v * max).toInt(), 0)
                    result.success(null)
                }
                "setKeepScreenOn" -> {
                    val on = call.arguments as Boolean
                    runOnUiThread {
                        if (on) {
                            window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                    }
                    result.success(null)
                }
                "setScreenBrightness" -> {
                    val v = (call.arguments as Number).toFloat().coerceIn(0.01f, 1f)
                    runOnUiThread {
                        val lp = window.attributes
                        lp.screenBrightness = v
                        window.attributes = lp
                    }
                    result.success(null)
                }
                "resetScreenBrightness" -> {
                    runOnUiThread {
                        val lp = window.attributes
                        lp.screenBrightness = -1f
                        window.attributes = lp
                    }
                    result.success(null)
                }
                "getSystemBrightness" -> {
                    val value = android.provider.Settings.System.getInt(
                        contentResolver, android.provider.Settings.System.SCREEN_BRIGHTNESS, 128)
                    result.success((value / 255.0).coerceIn(0.0, 1.0))
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        systemSpeech?.close()
        systemSpeech = null
        super.onDestroy()
    }
}
