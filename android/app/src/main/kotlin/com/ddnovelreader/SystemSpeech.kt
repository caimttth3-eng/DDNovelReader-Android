package com.ddnovelreader

import android.content.Context
import android.media.AudioAttributes
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.embedding.engine.plugins.FlutterPlugin

/** AudioServiceActivity reuses a FlutterEngine, so speech must have the same
 * lifetime as that engine rather than whichever Activity currently hosts it. */
class SystemSpeechPlugin : FlutterPlugin {
    private var speech: SystemSpeech? = null
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        speech = SystemSpeech(binding.applicationContext, binding.binaryMessenger)
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        speech?.close()
        speech = null
    }
}

/** Uses the engine and voice selected in Android's text-to-speech settings. */
class SystemSpeech(context: Context, messenger: BinaryMessenger) {
    private val appContext = context.applicationContext
    private val channel = MethodChannel(messenger, "com.ddnovelreader/system_tts")
    private val main = Handler(Looper.getMainLooper())
    private var engine: TextToSpeech? = null
    private var ready = false
    private var closed = false
    private val initializers = mutableListOf<MethodChannel.Result>()
    private var requestId: String? = null
    private var chunks = emptyList<Pair<Int, String>>()
    private var chunkIndex = 0
    private var started = false

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "initialize" -> initialize(result)
                "speak" -> {
                    val id = call.argument<String>("id")
                    val text = call.argument<String>("text")
                    if (!ready || engine == null) result.error("not_ready", "System speech is not initialized", null)
                    else if (id == null || text.isNullOrBlank()) result.error("empty_text", "No speech text", null)
                    else {
                        stop()
                        requestId = id
                        val limit = TextToSpeech.getMaxSpeechInputLength().coerceAtLeast(2)
                        val parts = mutableListOf<Pair<Int, String>>()
                        var offset = 0
                        while (offset < text.length) {
                            var end = (offset + limit).coerceAtMost(text.length)
                            if (end < text.length && Character.isHighSurrogate(text[end - 1])) end--
                            parts.add(Pair(offset, text.substring(offset, end)))
                            offset = end
                        }
                        chunks = parts
                        chunkIndex = 0
                        started = false
                        val rate = call.argument<Number>("rate")?.toFloat() ?: 1f
                        if (!rate.isFinite() || engine!!.setSpeechRate(rate.coerceIn(0.1f, 3f)) != TextToSpeech.SUCCESS) {
                            requestId = null
                            result.error("speak_failed", "System engine rejected speech rate", null)
                        } else if (speakChunk()) result.success(null)
                        else { requestId = null; result.error("speak_failed", "System engine rejected speech", null) }
                    }
                }
                "stop" -> { stop(); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }

    private fun initialize(result: MethodChannel.Result) {
        if (closed) { result.error("closed", "System speech is closed", null); return }
        if (ready) { result.success(engine?.defaultEngine); return }
        initializers.add(result)
        if (engine != null) return
        try {
            engine = TextToSpeech(appContext) { status ->
            main.post {
                if (closed) return@post
                ready = status == TextToSpeech.SUCCESS
                if (ready) {
                    engine?.setAudioAttributes(AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                    installListener()
                }
                val pending = initializers.toList()
                initializers.clear()
                for (item in pending) {
                    if (ready) item.success(engine?.defaultEngine)
                    else item.error("no_engine", "No usable system text-to-speech engine", null)
                }
                if (!ready) { engine?.shutdown(); engine = null }
            }
            }
        } catch (error: RuntimeException) {
            ready = false
            engine?.shutdown(); engine = null
            val pending = initializers.toList()
            initializers.clear()
            for (item in pending) item.error("no_engine", "System text-to-speech initialization failed", null)
        }
    }

    private fun speakChunk(): Boolean {
        val id = requestId ?: return false
        val part = chunks.getOrNull(chunkIndex) ?: return false
        return try {
            engine?.speak(part.second, TextToSpeech.QUEUE_FLUSH, Bundle(), "$id:${part.first}") == TextToSpeech.SUCCESS
        } catch (error: RuntimeException) { false }
    }

    private fun event(name: String, id: String, extra: Map<String, Any> = emptyMap()) {
        channel.invokeMethod(name, mapOf("id" to id) + extra)
    }

    private fun installListener() {
        engine?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) { main.post {
                val id = requestId ?: return@post
                if (utteranceId != "$id:${chunks.getOrNull(chunkIndex)?.first}") return@post
                if (!started) { started = true; event("start", id) }
            } }
            override fun onDone(utteranceId: String?) { main.post {
                val id = requestId ?: return@post
                if (utteranceId != "$id:${chunks.getOrNull(chunkIndex)?.first}") return@post
                chunkIndex++
                if (chunkIndex < chunks.size) {
                    if (!speakChunk()) { requestId = null; event("error", id, mapOf("code" to TextToSpeech.ERROR_SYNTHESIS)) }
                } else { requestId = null; event("done", id) }
            } }
            @Deprecated("Deprecated in Android")
            override fun onError(utteranceId: String?) = onError(utteranceId, TextToSpeech.ERROR)
            override fun onError(utteranceId: String?, errorCode: Int) { main.post {
                val id = requestId ?: return@post
                if (utteranceId != "$id:${chunks.getOrNull(chunkIndex)?.first}") return@post
                requestId = null
                event("error", id, mapOf("code" to errorCode))
            } }
            override fun onRangeStart(utteranceId: String?, start: Int, end: Int, frame: Int) { main.post {
                val id = requestId ?: return@post
                val offset = chunks.getOrNull(chunkIndex)?.first ?: return@post
                if (utteranceId != "$id:$offset") return@post
                event("range", id, mapOf("start" to offset + start, "end" to offset + end))
            } }
        })
    }

    private fun stop() {
        requestId = null; chunks = emptyList()
        try { engine?.stop() } catch (error: RuntimeException) { /* Engine process may have exited. */ }
    }

    fun close() {
        closed = true
        stop()
        engine?.shutdown(); engine = null
        for (result in initializers) result.error("closed", "System speech is closed", null)
        initializers.clear()
        channel.setMethodCallHandler(null)
    }
}
