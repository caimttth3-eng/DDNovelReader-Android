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

  const SystemVoice({
    required this.id,
    required this.name,
    required this.lang,
    this.quality = 'default',
    this.gender = '',
  });
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
  String? _request;
  int _serial = 0;
  int _epoch = 0;
  int _textLength = 0;
  int _rangeOffset = 0;
  bool _disposed = false;
  Completer<void>? _started;
  void Function()? _done;
  void Function(int, int)? _range;
  void Function(Object)? _error;

  SystemTtsClient() {
    if (_owner != null) unawaited(_owner!.stop());
    _owner = this;
    channel.setMethodCallHandler(_onEvent);
  }

  Future<void> initialize() => _initialization ??= channel.invokeMethod('initialize')
      .timeout(const Duration(seconds: 15)).then<void>((_) {}, onError: (Object error) {
        _initialization = null; throw error;
      });

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

  /// 列出系统可用的离线音色（iOS AVSpeechSynthesisVoice / Android TTS voices）。
  /// 不支持或未实现时返回空列表，调用方保留默认音色入口。
  Future<List<SystemVoice>> voices() async {
    try {
      final raw = await _enumerateVoices().timeout(const Duration(seconds: 15));
      if (raw == null) return const [];
      return raw.whereType<Map>().map((m) => SystemVoice(
        id: '${m['id'] ?? ''}',
        name: '${m['name'] ?? ''}',
        lang: '${m['lang'] ?? ''}',
        quality: '${m['quality'] ?? 'default'}',
        gender: '${m['gender'] ?? ''}',
      )).where((v) => v.id.isNotEmpty).toList();
    } on MissingPluginException {
      debugPrint('System voice enumeration is not supported.');
      return const [];
    } on PlatformException catch (error) {
      debugPrint('System voice enumeration failed: ${error.code}');
      return const [];
    } on TimeoutException catch (error) {
      debugPrint('System voice enumeration timed out; keeping the default entry: $error');
      return const [];
    } catch (error) {
      debugPrint('System voice enumeration failed; keeping the default entry: $error');
      return const [];
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
    await initialize();
    if (_disposed || epoch != _epoch || _owner != this) throw const SystemSpeechCancelled();
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
          if (voiceId != null) 'voice': voiceId,
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
    _disposed = true;
    await stop();
    if (_owner == this) { _owner = null; channel.setMethodCallHandler(null); }
  }
}

class SystemSpeechCancelled implements Exception { const SystemSpeechCancelled(); }
