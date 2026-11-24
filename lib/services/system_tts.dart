// 来源：NayGnehz/DDNovelReader-Android 的 PR #2（commit 27b6a1e，部分代码，已修改适配本项目的缓存/同步架构）。
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// iOS / Android 系统语音的一个可选音色。
class SystemVoice {
  final String id;
  final String name;
  final String lang;
  final String quality; // default / enhanced / premium
  final String gender;
  final String engine;
  final bool isDefault;
  final bool requiresNetwork;

  const SystemVoice({
    required this.id,
    required this.name,
    required this.lang,
    this.quality = 'default',
    this.gender = '',
    this.engine = '',
    this.isDefault = false,
    this.requiresNetwork = false,
  });

  String get identifier => engine.isEmpty ? id : SystemTtsClient.engineVoiceIdentifier(engine, id);
}

class SystemTtsEngine {
  final String id, name, defaultVoiceId, defaultVoiceName, defaultVoiceQuality;
  final bool available;
  final List<SystemVoice> voices;
  const SystemTtsEngine({required this.id, required this.name,
    this.defaultVoiceId = '', this.defaultVoiceName = '', this.defaultVoiceQuality = 'unknown',
    this.available = true, this.voices = const []});
  bool get hasEnhancedDefaultVoice => defaultVoiceQuality == 'enhanced' || defaultVoiceQuality == 'premium';
}

class SystemVoiceCatalog {
  final List<SystemTtsEngine> engines;
  final String defaultEngine;
  const SystemVoiceCatalog({this.engines = const [], this.defaultEngine = ''});
  List<SystemVoice> get voices => [for (final engine in engines) ...engine.voices];
}

class SystemTtsLanguage {
  final String id, name;
  const SystemTtsLanguage({required this.id, required this.name});
}

class SystemTtsClient {
  static const voiceId = '__system_tts__';
  static const voicePrefix = '__system_tts__:';
  static const channel = MethodChannel('com.ddnovelreader/system_tts');
  static SystemTtsClient? _owner;

  /// 系统语音（默认音色或指定音色）都走同一个原生通道。
  static bool isSystemVoiceId(String id) =>
      id == voiceId || id.startsWith(voicePrefix);

  static String? identifierFrom(String id) =>
      id.startsWith(voicePrefix) ? id.substring(voicePrefix.length) : null;

  Future<void>? _initialization;
  String? _initializedEngine;
  int _initializationSerial = 0;
  String? _knownDefaultEngine;
  String currentVoiceName = '';
  String? _request;
  int _serial = 0;
  int _epoch = 0;
  int _textLength = 0;
  int _rangeOffset = 0;
  bool _disposed = false;
  final _disposeSignal = Completer<void>();
  bool _checkingLanguages = false;
  int _languageCheckSerial = 0;
  String? _languageCheckId;
  Completer<void>? _started;
  void Function()? _done;
  void Function(int, int)? _range;
  void Function(Object)? _error;

  SystemTtsClient() {
    if (_owner != null) unawaited(_owner!.stop());
    _owner = this;
    channel.setMethodCallHandler(_onEvent);
  }

  static String engineVoiceIdentifier(String engine, String voice) =>
      '@engine:${Uri.encodeComponent(engine)}:${Uri.encodeComponent(voice)}';

  static String engineLanguageIdentifier(String engine, String language) =>
      '@language:${Uri.encodeComponent(engine)}:${Uri.encodeComponent(language)}';

  static ({String engine, String language})? _languageSelection(String? identifier) {
    if (identifier == null || !identifier.startsWith('@language:')) return null;
    final parts = identifier.substring(10).split(':');
    if (parts.length != 2 || parts.any((part) => part.isEmpty)) throw const FormatException('Invalid system language identifier');
    final engine = Uri.decodeComponent(parts[0]), language = Uri.decodeComponent(parts[1]);
    if (engine.isEmpty || language.isEmpty) throw const FormatException('Invalid system language identifier');
    return (engine: engine, language: language);
  }

  static String? languageFromIdentifier(String? identifier) => _languageSelection(identifier)?.language;

  static ({String? engine, String? voice}) decodeIdentifier(String? identifier) {
    final language = _languageSelection(identifier);
    if (language != null) return (engine: language.engine, voice: null);
    if (identifier == null || !identifier.startsWith('@engine:')) return (engine: null, voice: identifier);
    final parts = identifier.substring(8).split(':');
    if (parts.length != 2 || parts[0].isEmpty) throw const FormatException('Invalid system voice identifier');
    final voice = Uri.decodeComponent(parts[1]);
    return (engine: Uri.decodeComponent(parts[0]), voice: voice.isEmpty ? null : voice);
  }

  /// Keep the identifying name; remove platform/type labels, never translate it.
  static String compactVoiceLabel(String label) {
    final original = label.trim();
    var compact = original;
    final prefix = RegExp(r'^(?:android|ios)[\s_\-–—:：·/]+', caseSensitive: false);
    final suffix = RegExp(r'(?:[\s_\-–—:：·/]+(?:tts|text[\s-]*to[\s-]*speech)|(?:文本转语音(?:引擎)?|文字转语音(?:引擎)?|语音引擎))$',
      caseSensitive: false);
    final locale = RegExp(r'[_-][a-z]{2,3}(?:[_-](?:Hans|Hant))?(?:[_-](?:[A-Z]{2}|[0-9]{3}))?$');
    for (var pass = 0; pass < 4; pass++) {
      final previous = compact;
      compact = compact.replaceFirst(prefix, '').replaceFirst(suffix, '').replaceFirst(locale, '').trim();
      compact = compact.replaceFirst(RegExp(r'[\s_\-–—:：·/]+$'), '').trim();
      if (compact.isEmpty || RegExp(r'^(?:tts|text[\s-]*to[\s-]*speech)$', caseSensitive: false).hasMatch(compact)) return original;
      if (compact == previous) break;
    }
    return compact;
  }

  Future<void> initialize({String? engine}) {
    if (engine != _initializedEngine) { _initialization = null; _initializedEngine = engine; }
    if (_initialization != null) return _initialization!;
    final serial = ++_initializationSerial;
    return _initialization = channel.invokeMethod('initialize', engine == null ? null : {'engine': engine})
      .timeout(const Duration(seconds: 15)).then<void>((value) {
        if (serial == _initializationSerial && value is Map) currentVoiceName = '${value['voiceName'] ?? ''}';
      }, onError: (Object error) {
        if (serial == _initializationSerial) _initialization = null;
        throw error;
      });
  }

  /// 打开系统设置（iOS 是 App 设置页，Android 是 TTS 设置页），引导用户下载更好音质。
  Future<bool> openSettings() async {
    try {
      return await channel.invokeMethod<bool>('openSettings') ?? false;
    } on PlatformException catch (error) {
      debugPrint('System speech settings unavailable: ${error.code}');
      return false;
    } on MissingPluginException {
      debugPrint('System speech settings are not supported.');
      return false;
    }
  }

  Future<void> _cancelLanguageCheck(String id) async {
    try { await channel.invokeMethod('cancelLanguageCheck', {'id': id}); }
    on PlatformException { /* The activity or engine may already be detached. */ }
    on MissingPluginException { /* Older hosts have no language checker. */ }
  }

  /// Explicit user action only. Installed-language results are independent of
  /// the engine's often synthetic getVoices()/locale catalogue.
  Future<List<SystemTtsLanguage>> checkLanguages(String engine) async {
    if (_disposed || _disposeSignal.isCompleted || _owner != this || engine.trim().isEmpty || _checkingLanguages) return const [];
    _checkingLanguages = true;
    final id = '${identityHashCode(this)}-language-${++_languageCheckSerial}';
    _languageCheckId = id;
    try {
      final raw = await Future.any<List<dynamic>?>([
        channel.invokeListMethod<dynamic>('checkLanguages', {'engine': engine, 'id': id}),
        _disposeSignal.future.then((_) => null),
      ]).timeout(const Duration(seconds: 15));
      if (_disposed || _disposeSignal.isCompleted || _owner != this) return const [];
      final languages = <String, SystemTtsLanguage>{};
      for (final entry in (raw ?? const []).whereType<Map>()) {
        final id = entry['id'];
        if (id is! String || id == 'und' || !RegExp(r'^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$').hasMatch(id)) continue;
        final name = entry['name'];
        languages[id] = SystemTtsLanguage(id: id, name: name is String && name.trim().isNotEmpty ? name : id);
      }
      return languages.values.toList();
    } on TimeoutException {
      if (_owner == this) unawaited(_cancelLanguageCheck(id));
      return const [];
    } on PlatformException { return const []; }
    on MissingPluginException { return const []; }
    catch (_) { return const []; }
    finally { _checkingLanguages = false; _languageCheckId = null; }
  }

  /// 列出系统可用音色（iOS AVSpeechSynthesisVoice / Android TTS voices）。
  /// 不支持或未实现时返回空列表，调用方保留默认音色入口。
  Future<List<SystemVoice>> voices() async => (await catalog()).voices;

  static SystemVoice _voice(Map raw, {String engine = ''}) => SystemVoice(
    id: '${raw['id'] ?? ''}', name: '${raw['name'] ?? raw['id'] ?? ''}',
    lang: '${raw['lang'] ?? ''}', quality: '${raw['quality'] ?? 'default'}',
    gender: '${raw['gender'] ?? ''}', engine: engine,
    isDefault: raw['isDefault'] == true, requiresNetwork: raw['requiresNetwork'] == true);

  Future<SystemVoiceCatalog> catalog({bool enginesOnly = false, bool namesOnly = false}) async {
    if (_disposed || _disposeSignal.isCompleted || _owner != this) return const SystemVoiceCatalog();
    try {
      Map<dynamic, dynamic>? result;
      final onlyEngines = enginesOnly || namesOnly;
      try { result = await Future.any<Map<dynamic, dynamic>?>([
        channel.invokeMapMethod('voiceCatalog', onlyEngines
          ? {'enginesOnly': true, if (namesOnly) 'namesOnly': true} : null),
        _disposeSignal.future.then((_) => null),
      ]).timeout(const Duration(seconds: 15)); }
      on MissingPluginException { /* Older plugins and iOS use voice enumeration below. */ }
      if (_disposed || _disposeSignal.isCompleted || _owner != this) return const SystemVoiceCatalog();
      if (result != null && result['engines'] is List && (result['engines'] as List).isNotEmpty) {
        final defaultEngine = '${result['defaultEngine'] ?? ''}';
        if (!namesOnly && _initializedEngine == null && _knownDefaultEngine != defaultEngine) {
          _initialization = null;
          _initializationSerial++;
        }
        if (!namesOnly) _knownDefaultEngine = defaultEngine;
        return SystemVoiceCatalog(defaultEngine: '${result['defaultEngine'] ?? ''}', engines: [
          for (final raw in (result['engines'] as List).whereType<Map>())
            SystemTtsEngine(id: '${raw['id'] ?? ''}', name: '${raw['name'] ?? raw['id'] ?? ''}',
              defaultVoiceId: '${raw['defaultVoiceId'] ?? ''}', defaultVoiceName: '${raw['defaultVoiceName'] ?? ''}',
              defaultVoiceQuality: '${raw['defaultVoiceQuality'] ?? 'unknown'}',
              available: raw['available'] != false,
              voices: onlyEngines ? const [] : [for (final voice in (raw['voices'] as List? ?? const []).whereType<Map>())
                if ('${voice['id'] ?? ''}'.isNotEmpty) _voice(voice, engine: '${raw['id'] ?? ''}')]),
        ]);
      }
      // Names are optional display metadata. Older hosts must not be initialized
      // merely to fill a toolbar label before the user opens the voice menu.
      if (namesOnly) return SystemVoiceCatalog(defaultEngine: '${result?['defaultEngine'] ?? ''}');
      final raw = await _enumerateVoices().timeout(const Duration(seconds: 15));
      return SystemVoiceCatalog(engines: [SystemTtsEngine(id: '', name: '', defaultVoiceName: currentVoiceName,
        voices: (raw ?? const []).whereType<Map>().map((m) => _voice(m)).where((v) => v.id.isNotEmpty).toList())]);
    } on MissingPluginException {
      debugPrint('System voice enumeration is not supported.');
      return const SystemVoiceCatalog();
    } on PlatformException catch (error) {
      debugPrint('System voice enumeration failed: ${error.code}');
      return const SystemVoiceCatalog();
    } on TimeoutException catch (error) {
      debugPrint('System voice enumeration timed out; keeping the default entry: $error');
      return const SystemVoiceCatalog();
    } catch (error) {
      debugPrint('System voice enumeration failed; keeping the default entry: $error');
      return const SystemVoiceCatalog();
    }
  }

  Future<List<dynamic>?> _enumerateVoices() async {
    await initialize();
    if (_disposed || _owner != this) return null;
    return channel.invokeMethod<List<dynamic>>('voices');
  }

  /// [startOffset] is a requested visible-text cursor or the latest reported
  /// word start in the original sentence, measured in UTF-16 code units.
  /// Engines without ranges retain the requested cursor when resuming.
  /// Callbacks remain relative to [text], even when speaking only its suffix.
  Future<void> speak(String text, double rate, {int startOffset = 0, String? voiceId,
    required void Function() onDone, required void Function(int, int) onRange,
    required void Function(Object) onError}) async {
    if (_disposed || _owner != this) throw const SystemSpeechCancelled();
    RangeError.checkValueInInterval(startOffset, 0, text.isEmpty ? 0 : text.length - 1, 'startOffset');
    final spokenText = text.substring(startOffset);
    // Claim this operation before awaiting anything. A second speak or a stop
    // invalidates the earlier operation even while the engine is initializing.
    final stopping = stop();
    final epoch = _epoch;
    await stopping;
    if (_disposed || epoch != _epoch || _owner != this) throw const SystemSpeechCancelled();
    final selection = decodeIdentifier(voiceId);
    final language = languageFromIdentifier(voiceId);
    await initialize(engine: selection.engine);
    if (_disposed || epoch != _epoch || _owner != this) throw const SystemSpeechCancelled();
    if (selection.voice != null) currentVoiceName = selection.voice!;
    final id = '${identityHashCode(this)}-${++_serial}';
    _request = id; _done = onDone; _range = onRange; _error = onError;
    _textLength = spokenText.length;
    _rangeOffset = startOffset;
    final started = Completer<void>(); _started = started;
    try {
      await Future.wait<void>([
        channel.invokeMethod<void>('speak', {
          'id': id,
          'text': spokenText,
          'rate': rate,
          if (selection.voice != null) 'voice': selection.voice,
          if (language != null) 'language': language,
          if (selection.engine != null) 'engine': selection.engine,
        }),
        started.future.timeout(const Duration(seconds: 30)),
      ], eagerError: true);
    } catch (_) {
      if (_request == id) await stop();
      rethrow;
    }
  }

  Future<dynamic> _onEvent(MethodCall call) async {
    final data = call.arguments;
    if (_disposed || _request == null || data is! Map || data['id'] != _request) return;
    switch (call.method) {
      case 'start':
        if (!(_started?.isCompleted ?? true)) _started!.complete();
      case 'range':
        final start = data['start'], end = data['end'];
        if (start is! int || end is! int || start < 0 || end <= start || end > _textLength) return;
        if (!(_started?.isCompleted ?? true)) _started!.complete();
        _range?.call(_rangeOffset + start, _rangeOffset + end);
      case 'done':
        if (!(_started?.isCompleted ?? true)) _started!.complete();
        final done = _done;
        _request = null; _done = null; _range = null; _error = null;
        done?.call();
      case 'error':
        final error = PlatformException(code: 'system_speech_${data['code']}', message: 'System speech failed');
        final onError = _error;
        _request = null;
        _done = null; _range = null; _error = null;
        if (!(_started?.isCompleted ?? true)) { _started!.completeError(error); }
        else { onError?.call(error); }
    }
  }

  Future<void> stop() async {
    _epoch++;
    final hadRequest = _request != null;
    _request = null; _done = null; _range = null; _error = null;
    if (!(_started?.isCompleted ?? true)) _started!.completeError(const SystemSpeechCancelled());
    _started = null;
    if (hadRequest && _owner == this) {
      // Logical cancellation is already complete; activity teardown or a
      // disappearing engine must not prevent audio-player cleanup by callers.
      try { await channel.invokeMethod('stop'); }
      on PlatformException { /* Native engine is no longer available. */ }
      on MissingPluginException { /* Activity or Flutter engine was detached. */ }
    }
  }

  Future<void> dispose() async {
    final checking = _languageCheckId;
    if (checking != null && _owner == this) unawaited(_cancelLanguageCheck(checking));
    if (!_disposeSignal.isCompleted) _disposeSignal.complete();
    _disposed = true;
    await stop();
    if (_owner == this) { _owner = null; channel.setMethodCallHandler(null); }
  }
}

class SystemSpeechCancelled implements Exception { const SystemSpeechCancelled(); }
