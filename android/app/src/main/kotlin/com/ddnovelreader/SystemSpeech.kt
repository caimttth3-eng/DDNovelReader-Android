package com.ddnovelreader

import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.provider.Settings
import android.speech.tts.Voice
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
    private var enginePackage: String? = null
    private var initializationGeneration = 0
    private val catalogClosers = mutableSetOf<() -> Unit>()
    private val catalogResults = mutableListOf<MethodChannel.Result>()
    private var catalogRunning = false

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "initialize" -> initialize(result, call.argument<String>("engine"))
                "voiceCatalog" -> voiceCatalog(result)
                "speak" -> {
                    val id = call.argument<String>("id")
                    val text = call.argument<String>("text")
                    val requestedEngine = call.argument<String>("engine")
                    if (!ready || engine == null) result.error("not_ready", "System speech is not initialized", null)
                    else if (requestedEngine != null && requestedEngine != enginePackage) result.error("engine_changed", "System speech engine changed", null)
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
                        val rate = call.argument<Number>("rate")?.toDouble() ?: 1.0
                        val voiceName = call.argument<String>("voice")
                        if (engine != null) {
                            try {
                                val selected = if (voiceName == null) try { engine!!.defaultVoice } catch (_: RuntimeException) { null }
                                    else engine!!.voices?.firstOrNull { it.name == voiceName }
                                // Older engines may support speech without the Voice API.
                                if ((voiceName != null && selected == null) ||
                                    (selected != null && engine!!.setVoice(selected) != TextToSpeech.SUCCESS)) {
                                    requestId = null
                                    result.error("voice_unavailable", "System speech voice is unavailable", null)
                                    return@setMethodCallHandler
                                }
                            } catch (error: RuntimeException) {
                                requestId = null
                                result.error("voice_unavailable", "System speech voice selection failed", null)
                                return@setMethodCallHandler
                            }
                        }
                        if (!rate.isFinite() || engine!!.setSpeechRate(SystemSpeechRate.toPlatformRate(rate)) != TextToSpeech.SUCCESS) {
                            requestId = null
                            result.error("speak_failed", "System engine rejected speech rate", null)
                        } else if (speakChunk()) result.success(null)
                        else { requestId = null; result.error("speak_failed", "System engine rejected speech", null) }
                    }
                }
                "voices" -> {
                    val list = mutableListOf<Map<String, String>>()
                    val voices = if (ready) engine?.voices else null
                    voices?.forEach { voice ->
                        val lang = voice.locale.toLanguageTag().lowercase()
                        run {
                            list.add(mapOf(
                                "id" to voice.name,
                                "name" to voice.name,
                                "lang" to lang,
                                "quality" to if (voice.quality >= Voice.QUALITY_HIGH) "enhanced" else "default",
                                "gender" to ""))
                        }
                    }
                    result.success(list.sortedBy { it["name"] })
                }
                "openSettings" -> {
                    val opened = try {
                        appContext.startActivity(Intent("com.android.settings.TTS_SETTINGS")
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        true
                    } catch (error: RuntimeException) {
                        try {
                            appContext.startActivity(Intent(Settings.ACTION_SETTINGS)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                            true
                        } catch (inner: RuntimeException) { false }
                    }
                    result.success(opened)
                }
                "stop" -> { stop(); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }

    private fun systemDefaultEngine(): String? = try {
        Settings.Secure.getString(appContext.contentResolver, "tts_default_synth") ?: engine?.defaultEngine
    } catch (error: RuntimeException) { engine?.defaultEngine }

    private fun currentVoiceName(): String = try {
        engine?.voice?.name ?: engine?.defaultVoice?.name ?: ""
    } catch (_: RuntimeException) { "" }

    private fun installedEngines(): List<Pair<String, String>> {
        val manager = appContext.packageManager
        return manager.queryIntentServices(Intent(TextToSpeech.Engine.INTENT_ACTION_TTS_SERVICE), 0)
            .filter { it.serviceInfo != null && it.serviceInfo.enabled && it.serviceInfo.applicationInfo.enabled }
            .map { Pair(it.serviceInfo.packageName, it.loadLabel(manager).toString().ifBlank { it.serviceInfo.packageName }) }
            .distinctBy { it.first }.sortedBy { it.second }
    }

    private fun voiceCatalog(result: MethodChannel.Result) {
        if (closed) { result.error("closed", "System speech is closed", null); return }
        if (catalogRunning) { catalogResults.add(result); return }
        val packages = try { installedEngines() } catch (error: RuntimeException) {
            result.error("engine_list_failed", "Cannot list installed speech engines", null); return
        }
        catalogResults.add(result)
        catalogRunning = true
        val entries = packages.map { (id, name) -> mutableMapOf<String, Any>(
            "id" to id, "name" to name, "available" to false,
            "defaultVoiceId" to "", "defaultVoiceName" to "", "voices" to emptyList<Map<String, Any>>()) }
        val probes = mutableSetOf<TextToSpeech>()
        val timers = mutableSetOf<Runnable>()
        var next = 0
        var active = 0
        var finished = false
        lateinit var finish: () -> Unit
        lateinit var launch: () -> Unit
        finish = {
            if (!finished) {
                finished = true
                for (timer in timers) main.removeCallbacks(timer)
                for (probe in probes) try { probe.shutdown() } catch (_: RuntimeException) { }
                probes.clear()
                catalogClosers.remove(finish)
                val snapshot = mapOf("defaultEngine" to (systemDefaultEngine() ?: ""), "engines" to entries)
                val waiting = catalogResults.toList(); catalogResults.clear(); catalogRunning = false
                for (item in waiting) item.success(snapshot)
            }
        }
        launch = {
            while (!finished && active < 2 && next < entries.size) {
                val entry = entries[next++]
                val packageName = entry["id"] as String
                active++
                var probe: TextToSpeech? = null
                var completed = false
                lateinit var timeout: Runnable
                fun complete(status: Int) {
                    if (!completed && !finished) {
                        completed = true
                        main.removeCallbacks(timeout)
                        timers.remove(timeout)
                        if (status == TextToSpeech.SUCCESS) {
                            entry["available"] = true
                            try {
                                val defaultVoice = probe?.defaultVoice ?: probe?.voice
                                entry["defaultVoiceId"] = defaultVoice?.name ?: ""
                                entry["defaultVoiceName"] = defaultVoice?.name ?: ""
                                val voices = (probe?.voices ?: emptySet()).toMutableSet()
                                if (defaultVoice != null) voices.add(defaultVoice)
                                entry["voices"] = voices.sortedBy { it.name }.map { voice -> mapOf(
                                    "id" to voice.name, "name" to voice.name,
                                    "lang" to voice.locale.toLanguageTag(),
                                    "quality" to if (voice.quality >= Voice.QUALITY_HIGH) "enhanced" else "default",
                                    "isDefault" to (voice.name == defaultVoice?.name),
                                    "requiresNetwork" to voice.isNetworkConnectionRequired)
                                }
                            } catch (_: RuntimeException) { /* Keep the selectable engine even without Voice API support. */ }
                        }
                        probe?.let { probes.remove(it); try { it.shutdown() } catch (_: RuntimeException) { } }
                        active--
                        if (next == entries.size && active == 0) finish() else launch()
                    }
                }
                timeout = Runnable { complete(TextToSpeech.ERROR) }
                timers.add(timeout)
                main.postDelayed(timeout, 5000)
                try {
                    probe = TextToSpeech(appContext, { status -> main.post { complete(status) } }, packageName)
                    probe?.let { probes.add(it) }
                } catch (_: RuntimeException) { complete(TextToSpeech.ERROR) }
            }
        }
        catalogClosers.add(finish)
        val deadline = Runnable { finish() }
        timers.add(deadline)
        main.postDelayed(deadline, 12000)
        if (entries.isEmpty()) finish() else launch()
    }

    private fun initialize(result: MethodChannel.Result, requestedEngine: String?) {
        if (closed) { result.error("closed", "System speech is closed", null); return }
        val target = requestedEngine ?: systemDefaultEngine()
        if (requestedEngine != null) {
            val installed = try { installedEngines().any { it.first == requestedEngine } }
                catch (_: RuntimeException) { false }
            if (!installed) { result.error("engine_unavailable", "Requested speech engine is not installed", null); return }
        }
        if (ready && target == enginePackage) {
            result.success(mapOf("engine" to enginePackage, "voiceName" to currentVoiceName())); return
        }
        if (engine != null && target != enginePackage) {
            initializationGeneration++
            stop()
            engine?.shutdown(); engine = null; ready = false
            for (pending in initializers) pending.error("engine_changed", "System speech engine changed", null)
            initializers.clear()
        }
        initializers.add(result)
        if (engine != null) return
        enginePackage = target
        val generation = ++initializationGeneration
        try {
            engine = TextToSpeech(appContext, { status ->
            main.post {
                if (closed || generation != initializationGeneration) return@post
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
                    if (ready) item.success(mapOf("engine" to enginePackage, "voiceName" to currentVoiceName()))
                    else item.error("no_engine", "No usable system text-to-speech engine", null)
                }
                if (!ready) { engine?.shutdown(); engine = null }
            }
            }, target)
            main.postDelayed({
                if (!closed && generation == initializationGeneration && !ready) {
                    initializationGeneration++
                    engine?.shutdown(); engine = null
                    val pending = initializers.toList(); initializers.clear()
                    for (item in pending) item.error("engine_timeout", "System speech initialization timed out", null)
                }
            }, 12000)
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
        initializationGeneration++
        for (finish in catalogClosers.toList()) finish()
        stop()
        engine?.shutdown(); engine = null
        for (result in initializers) result.error("closed", "System speech is closed", null)
        initializers.clear()
        channel.setMethodCallHandler(null)
    }
}
