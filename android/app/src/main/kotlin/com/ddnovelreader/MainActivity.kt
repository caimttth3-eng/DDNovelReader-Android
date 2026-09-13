package com.ddnovelreader

import android.view.KeyEvent
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private val CHANNEL = "com.ddnovelreader/volume_keys"
    private var channel: MethodChannel? = null
    private var volumeKeysEnabled = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "setVolumeKeysEnabled" -> {
                    volumeKeysEnabled = call.arguments as Boolean
                    result.success(null)
                }
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
                else -> result.notImplemented()
            }
        }
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (volumeKeysEnabled) {
            if (keyCode == KeyEvent.KEYCODE_VOLUME_UP) {
                channel?.invokeMethod("volumeUp", null)
                return true
            }
            if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) {
                channel?.invokeMethod("volumeDown", null)
                return true
            }
        }
        return super.onKeyDown(keyCode, event)
    }
}
