package com.ddnovelreader

import android.content.Context
import android.content.Intent
import android.app.Activity
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
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry.ActivityResultListener
import java.util.Locale

/** AudioServiceActivity reuses a FlutterEngine, so speech must have the same
 * lifetime as that engine rather than whichever Activity currently hosts it. */
class SystemSpeechPlugin : FlutterPlugin, ActivityAware, ActivityResultListener {
    private var speech: SystemSpeech? = null
    private var activityBinding: ActivityPluginBinding? = null
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        speech = SystemSpeech(binding.applicationContext, binding.binaryMessenger)
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        detachActivity()
        speech?.close()
        speech = null
    }
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addActivityResultListener(this)
        speech?.attachActivity(binding.activity)
    }
    private fun detachActivity() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        speech?.detachActivity()
    }
    override fun onDetachedFromActivityForConfigChanges() = detachActivity()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromActivity() = detachActivity()
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean =
        speech?.onActivityResult(requestCode, resultCode, data) ?: false
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
    private val catalogResults = mutableListOf<Pair<MethodChannel.Result, Boolean>>()
    private val catalogFullFollowUps = mutableListOf<MethodChannel.Result>()
    private var catalogRunning = false
    private var catalogEnginesOnly = false
    private var activity: Activity? = null
    private data class LanguageCheck(val id: String, val requestCode: Int, val result: MethodChannel.Result, val timeout: Runnable)
    private var languageCheck: LanguageCheck? = null
    private var nextLanguageRequest = 0x6300

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "initialize" -> initialize(result, call.argument<String>("engine"))
                "voiceCatalog" -> voiceCatalog(result, call.argument<Boolean>("enginesOnly") == true,
                    call.argument<Boolean>("namesOnly") == true)
                "checkLanguages" -> checkLanguages(result, call.argument<String>("engine"), call.argument<String>("id"))
                "cancelLanguageCheck" -> {
                    if (call.argument<String>("id") == languageCheck?.id) finishLanguageCheck()
                    result.success(null)
                }
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
                        val languageTag = call.argument<String>("language")
                        if (engine != null) {
                            try {
                                if (languageTag != null) {
                                    val locale = Locale.forLanguageTag(languageTag)
                                    if (locale.language.isBlank() || locale.language == "und" ||
                                        engine!!.isLanguageAvailable(locale) < TextToSpeech.LANG_AVAILABLE ||
                                        engine!!.setLanguage(locale) < TextToSpeech.LANG_AVAILABLE) {
                                        requestId = null
                                        result.error("language_unavailable", "System speech language is unavailable", null)
                                        return@setMethodCallHandler
                                    }
                                } else {
                                    val selected = if (voiceName == null) try { engine!!.defaultVoice } catch (_: RuntimeException) { null }
                                        else engine!!.voices?.firstOrNull { it.name == voiceName }
                                    // Older engines may support speech without the Voice API.
                                    if ((voiceName != null && selected == null) ||
                                        (selected != null && engine!!.setVoice(selected) != TextToSpeech.SUCCESS)) {
                                        requestId = null
                                        result.error("voice_unavailable", "System speech voice is unavailable", null)
                                        return@setMethodCallHandler
                                    }
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

    fun attachActivity(value: Activity) { activity = value }

    fun detachActivity() {
        activity = null
        finishLanguageCheck()
    }

    private fun finishLanguageCheck(requestCode: Int? = null, languages: List<Map<String, String>> = emptyList()) {
        val pending = languageCheck ?: return
        if (requestCode != null && requestCode != pending.requestCode) return
        languageCheck = null
        main.removeCallbacks(pending.timeout)
        pending.result.success(languages)
    }

    private fun checkLanguages(result: MethodChannel.Result, packageName: String?, id: String?) {
        val host = activity
        if (closed || host == null || host.isFinishing || packageName.isNullOrBlank() || id.isNullOrBlank() || languageCheck != null) {
            result.success(emptyList<Map<String, String>>()); return
        }
        val installed = try { installedEngines().any { it.first == packageName } } catch (_: RuntimeException) { false }
        val intent = Intent(TextToSpeech.Engine.ACTION_CHECK_TTS_DATA).setPackage(packageName)
        val canCheck = installed && try { intent.resolveActivity(host.packageManager) != null } catch (_: RuntimeException) { false }
        if (!canCheck) {
            result.success(emptyList<Map<String, String>>()); return
        }
        val code = nextLanguageRequest
        nextLanguageRequest = if (nextLanguageRequest == 0x63ff) 0x6300 else nextLanguageRequest + 1
        val timeout = Runnable { finishLanguageCheck(code) }
        languageCheck = LanguageCheck(id, code, result, timeout)
        main.postDelayed(timeout, 10000)
        try { host.startActivityForResult(intent, code) }
        catch (_: RuntimeException) { finishLanguageCheck(code) }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        val pending = languageCheck ?: return false
        if (pending.requestCode != requestCode) return false
        val languages = if (resultCode == TextToSpeech.Engine.CHECK_VOICE_DATA_PASS && data != null) try {
            val available = data.getStringArrayListExtra(TextToSpeech.Engine.EXTRA_AVAILABLE_VOICES)
                ?: data.getStringArrayExtra(TextToSpeech.Engine.EXTRA_AVAILABLE_VOICES)?.toList() ?: emptyList()
            available.mapNotNull { checkedLanguage(it) }.distinctBy { it["id"] }.sortedBy { it["name"] }
        } catch (_: RuntimeException) { emptyList() } else emptyList()
        finishLanguageCheck(requestCode, languages)
        return true
    }

    private fun checkedLanguage(value: String): Map<String, String>? = try {
        val parts = value.trim().replace('_', '-').split('-')
        val code = parts.first().lowercase()
        if (!code.matches(Regex("[a-z]{2,3}")) || code == "und") null else {
            val locales = Locale.getAvailableLocales()
            val language = if (code.length == 3) locales.firstOrNull {
                try { it.getISO3Language().equals(code, true) } catch (_: RuntimeException) { false }
            }?.language ?: code else code
            val builder = Locale.Builder().setLanguage(language)
            var next = 1
            if (next < parts.size && parts[next].matches(Regex("[A-Za-z]{4}"))) builder.setScript(parts[next++])
            if (next < parts.size && parts[next].matches(Regex("[A-Za-z]{2,3}|[0-9]{3}"))) {
                val country = parts[next++].uppercase()
                val region = if (country.length == 3 && country.all { it.isLetter() }) locales.firstOrNull {
                    try { it.getISO3Country().equals(country, true) } catch (_: RuntimeException) { false }
                }?.country ?: country else country
                builder.setRegion(region)
            }
            if (next < parts.size) builder.setVariant(parts.drop(next).joinToString("_"))
            val locale = builder.build()
            val tag = locale.toLanguageTag()
            mapOf("id" to tag, "name" to locale.getDisplayName(Locale.getDefault()).ifBlank { tag })
        }
    } catch (_: RuntimeException) { null }

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

    private fun voiceCatalog(result: MethodChannel.Result, enginesOnly: Boolean, namesOnly: Boolean = false) {
        if (closed) { result.error("closed", "System speech is closed", null); return }
        if (namesOnly) {
            try {
                result.success(mapOf("defaultEngine" to (systemDefaultEngine() ?: ""),
                    "engines" to installedEngines().map { (id, name) -> mapOf("id" to id, "name" to name) }))
            } catch (_: RuntimeException) {
                result.error("engine_list_failed", "Cannot list installed speech engines", null)
            }
            return
        }
        if (catalogRunning) {
            if (catalogEnginesOnly && !enginesOnly) catalogFullFollowUps.add(result)
            else catalogResults.add(Pair(result, enginesOnly))
            return
        }
        val packages = try { installedEngines() } catch (error: RuntimeException) {
            result.error("engine_list_failed", "Cannot list installed speech engines", null); return
        }
        catalogResults.add(Pair(result, enginesOnly))
        catalogRunning = true
        catalogEnginesOnly = enginesOnly
        val entries = packages.map { (id, name) -> mutableMapOf<String, Any>(
            "id" to id, "name" to name, "available" to false,
            "defaultVoiceId" to "", "defaultVoiceName" to "", "defaultVoiceQuality" to "unknown",
            "voices" to emptyList<Map<String, Any>>()) }
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
                for ((item, onlyEngines) in waiting) item.success(if (onlyEngines)
                    mapOf("defaultEngine" to (systemDefaultEngine() ?: ""),
                        "engines" to entries.map { entry -> entry.filterKeys { it != "voices" } }) else snapshot)
                val followUps = catalogFullFollowUps.toList(); catalogFullFollowUps.clear()
                for (item in followUps) voiceCatalog(item, false)
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
                                entry["defaultVoiceQuality"] = if (defaultVoice == null) "unknown"
                                    else if (defaultVoice.quality >= Voice.QUALITY_HIGH) "enhanced" else "default"
                                if (!enginesOnly) {
                                    val voices = (probe?.voices ?: emptySet()).toMutableSet()
                                    if (defaultVoice != null) voices.add(defaultVoice)
                                    entry["voices"] = voices.sortedBy { it.name }.map { voice -> mapOf(
                                        "id" to voice.name, "name" to voice.name,
                                        "lang" to voice.locale.toLanguageTag(),
                                        "quality" to if (voice.quality >= Voice.QUALITY_HIGH) "enhanced" else "default",
                                        "isDefault" to (voice.name == defaultVoice?.name),
                                        "requiresNetwork" to voice.isNetworkConnectionRequired)
                                    }
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
        activity = null
        finishLanguageCheck()
        initializationGeneration++
        for (finish in catalogClosers.toList()) finish()
        stop()
        engine?.shutdown(); engine = null
        for (result in initializers) result.error("closed", "System speech is closed", null)
        initializers.clear()
        channel.setMethodCallHandler(null)
    }
}
