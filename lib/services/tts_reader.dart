/// TTS 朗读服务：基于 Edge TTS 在线合成 + 后台预取队列。
/// 逐句朗读 + 逐句高亮回调 + 暂停/继续/停止 + 定时停止。
/// 预取后续句子（默认提前 8 句），合成期间播放零卡顿。
library;

import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'edge_tts.dart';
import 'tts_cache_store.dart';
import '../models/speech_word.dart';
import 'system_tts.dart';

enum TtsState { idle, playing, paused, stopped }

typedef OnlineSpeechSynthesizer = Future<Uint8List> Function(String text,
  {required String voice, required String rate, required void Function(List<SpeechWord>) onWords,
  required EdgeSynthCancelToken cancelToken});

/// 朗读服务：Edge TTS 在线合成 + 磁盘语音缓存 + 后台预取队列。
/// 音频获取优先级：内存预取 → 磁盘缓存（TtsCacheStore）→ 在线合成（并异步落盘）。
/// 缓存坐标 = (章节索引, 章内 tts 字符偏移)，与 BookCacheTask 共用，命中零网络。
class TtsReader {
  static const defaultPrefetchSentences = 8;
  static const minPrefetchSentences = 0;
  static const maxPrefetchSentences = 100;
  static const systemVoice = SystemTtsClient.voiceId;
  final SystemTtsClient _system = SystemTtsClient();
  final Map<String, EdgeSynthCancelToken> _requestTokens = {};
  final Map<int, Object> _audioFailures = {};
  Object? lastFailure;
  ValueChanged<bool>? onLoadingChanged;
  bool _networkAvailable = true;
  final _networkEvents = StreamController<bool>.broadcast(sync: true);
  bool _usingSystemFallback = false;
  Object? _onlineNetworkFailure;
  ValueChanged<bool>? onVoiceModeChanged;
  bool get usingSystemFallback => _usingSystemFallback;
  bool get usesSystemVoice => _voice == systemVoice || _usingSystemFallback;
  static const defaultVoice = 'zh-CN-XiaoxiaoNeural';
  static const _positionReadTimeout = Duration(seconds: 2);
  static final _leadingRangePunctuation = RegExp(r'^[\s\p{P}]+', unicode: true);
  final AudioPlayer _player;
  final OnlineSpeechSynthesizer _synthesize;
  final List<String> _sentences = [];
  int _index = -1;
  TtsState _state = TtsState.idle;
  bool _disposed = false;

  // 预取缓存：句索引 -> 已合成的 MP3 字节
  final Map<int, Uint8List> _prefetchCache = {};
  final Map<int, List<SpeechWord>> _wordCache = {};
  final Map<String, Future<Uint8List>> _audioRequests = {};
  final Set<Future<void>> _cacheWrites = {};
  List<SpeechWord> _activeWords = [];
  int _activeAudioIndex = -1;
  int _lastWordStart = -1;
  int _lastWordEnd = -1;
  Uint8List? _retainedAudio;
  List<SpeechWord> _retainedWords = [];
  int _retainedAudioIndex = -1;
  Duration _position = Duration.zero;
  Duration _resumePosition = Duration.zero;
  int _systemResumeOffset = 0;
  int _rateResumeWordOffset = -1;
  Future<void>? _pausing;
  Future<void> _playerOperations = Future<void>.value();
  int _resumeSerial = 0;
  List<int> _pauseAfterMilliseconds = [];
  final Stopwatch _delayClock = Stopwatch()..start();
  Timer? _sentenceDelay;
  Duration _delayDeadline = Duration.zero;
  Duration _remainingDelay = Duration.zero;
  bool _awaitingSentenceAdvance = false;
  int _contentGeneration = 0;
  int _playGeneration = 0;
  StreamSubscription<Duration>? _positionSubscription;
  void Function(int start, int end)? onWordChanged;
  int _prefetchIndex = -1; // 已预取到的位置
  bool _prefetching = false;
  int _prefetchGeneration = 0;
  int _prefetchSentences = defaultPrefetchSentences;
  int _prefetchCompletes = 0; // 连续合成失败计数（用于判定离线）

  String _voice = defaultVoice;
  double _speechRate = 0.5;

  // 磁盘缓存：坐标 (章节索引, 章内 tts 偏移)
  TtsCacheStore? _cache;
  int _chapterIndex = 0;
  List<int> _offsets = const [];

  // 回调
  ValueChanged<int>? onSentenceChanged;
  VoidCallback? onCompleted;
  VoidCallback? onStateChanged;
  VoidCallback? onError;

  TtsState get state => _state;
  int get currentIndex => _index;
  int get sentenceCount => _sentences.length;
  String get voice => _voice;
  int get currentWordStart => _lastWordStart;
  int get currentWordEnd => _lastWordEnd;
  int get currentTtsOffset => usesSystemVoice ? _systemResumeOffset : 0;
  int get prefetchSentences => _prefetchSentences;

  /// Restore the saved effective mode after restoring the selected voice.
  /// Connectivity changes and chapter starts never clear this sticky choice.
  void restoreSystemFallback(bool active) {
    final fallback = active && _voice != systemVoice;
    if (_usingSystemFallback == fallback) return;
    _usingSystemFallback = fallback;
    if (fallback) _cancelRequests();
    onVoiceModeChanged?.call(fallback);
  }

  void setNetworkAvailable(bool available) {
    if (_networkAvailable == available) return;
    _networkAvailable = available;
    // This is a passive OS signal, never a connectivity probe. Completed
    // prefetches and the retained current sentence survive disconnection.
    if (!available) {
      _prefetchGeneration++; _prefetching = false;
      for (final entry in _requestTokens.entries.toList()) {
        _audioRequests.remove(entry.key); _requestTokens.remove(entry.key);
        entry.value.cancel();
      }
      // Unlike stop/jump, do not change content generation: a cache read
      // already in progress may still supply perfectly usable offline audio.
      _networkEvents.add(false);
    } else { _networkEvents.add(true); _startPrefetch(); }
  }

  void setPrefetchSentences(int value) {
    final count = value.clamp(minPrefetchSentences, maxPrefetchSentences);
    if (count == _prefetchSentences) return;
    _prefetchSentences = count;
    // Replan only the background worker. The foreground request and playback
    // generation must survive a settings change, including while loading.
    _prefetchGeneration++; _prefetching = false; _prefetchIndex = _index;
    final maximum = _index + count;
    for (final entry in _requestTokens.entries.toList()) {
      final sentence = int.parse(entry.key.substring(entry.key.lastIndexOf('/') + 1));
      if (sentence <= _index || sentence <= maximum) continue;
      _requestTokens.remove(entry.key);
      _audioRequests.remove(entry.key);
      entry.value.cancel();
    }
    _prunePrefetch();
    _startPrefetch();
  }

  bool _inMemoryWindow(int sentence) => sentence >= _index && sentence <= _index + _prefetchSentences;

  void _prunePrefetch() {
    _prefetchCache.removeWhere((sentence, _) => sentence <= _index || !_inMemoryWindow(sentence));
    _wordCache.removeWhere((sentence, _) => !_inMemoryWindow(sentence));
    _audioFailures.removeWhere((sentence, _) => !_inMemoryWindow(sentence));
  }

  TtsReader({AudioPlayer? player, OnlineSpeechSynthesizer? synthesize})
      : _player = player ?? AudioPlayer(), _synthesize = synthesize ?? edgeSynth {
    _player.positionUpdater = TimerPositionUpdater(interval: const Duration(milliseconds: 50),
      getPosition: () async {
        final generation = _playGeneration, sentence = _activeAudioIndex;
        final position = await _readPosition();
        // A position query may finish after pause/seek or a new audio source.
        if (generation != _playGeneration || sentence < 0 || sentence != _activeAudioIndex || _state != TtsState.playing) return null;
        return position;
      });
    _positionSubscription = _player.onPositionChanged.listen((position) {
      if (_disposed || _state != TtsState.playing || _activeAudioIndex != _index) return;
      _position = position;
      _updateWord(position);
    });
    _player.onPlayerComplete.listen((_) {
      // 当前句播放完，推进到下一句
      if (_disposed) return;
      if (usesSystemVoice || _activeAudioIndex < 0 || _activeAudioIndex != _index) return;
      if (_state != TtsState.playing) return;
      _sentenceFinished();
    });
  }

  /// 设置音色（zh-CN 等）
  void setVoice(String v) {
    if (_voice == v && !_usingSystemFallback && _onlineNetworkFailure == null) return;
    _onlineNetworkFailure = null;
    if (_usingSystemFallback) { _usingSystemFallback = false; onVoiceModeChanged?.call(false); }
    _voice = v; _invalidateAudio();
  }

  bool _isNetworkFailure(Object error) => error is TimeoutException || error is SocketException || error is WebSocketException || error is HandshakeException ||
    error is EdgeTtsException && (error.kind == 'connection' || error.kind == 'timeout');

  void _rememberNetworkFailure(Object error) {
    _onlineNetworkFailure = error;
    // Do not activate fallback from the background worker: upcoming memory or
    // disk audio must still be played before the first uncached sentence.
    _prefetchGeneration++; _prefetching = false;
  }

  Future<bool> _playSystemFallback(Object error) {
    _rememberNetworkFailure(error);
    _usingSystemFallback = true;
    _systemResumeOffset = 0;
    _cancelRequests();
    onVoiceModeChanged?.call(true);
    // The sentence is unchanged; do not emit a second sentence-start event.
    // A system-engine failure follows the ordinary error path, without retry.
    return _playCurrent(continueSentence: true);
  }

  void _invalidateAudio() {
    _playGeneration++;
    _activeAudioIndex = -1;
    _clearResume();
    _cancelRequests(); _prefetchCache.clear(); _wordCache.clear();
    _prefetchIndex = _index;
  }

  /// 设置/替换磁盘缓存（切换书/音色/语速时由上层重建传入）
  void setCache(TtsCacheStore? store) => _cache = store;

  /// 设置语速（0.1~3.0，映射到 Edge rate 百分比 +200%）
  Future<void> setSpeechRate(double rate) async {
    final value = rate.clamp(0.1, 3.0);
    if (_disposed || value == _speechRate) return;
    _speechRate = value;
    // An already completed sentence keeps its remaining punctuation silence.
    // Only the upcoming audio needs rebuilding in that case.
    if (_awaitingSentenceAdvance) {
      _cancelRequests(); _prefetchCache.clear(); _wordCache.clear();
      _prefetchIndex = _index;
      return;
    }
    final systemOffset = _systemResumeOffset;
    final wordOffset = _lastWordStart >= 0 ? _lastWordStart : _rateResumeWordOffset;
    _invalidateAudio();
    if (_state == TtsState.paused) {
      _systemResumeOffset = systemOffset;
      _rateResumeWordOffset = wordOffset;
      return;
    }
    if (_state != TtsState.playing || _index < 0 || _index >= _sentences.length) return;
    // Invalidating caches alone leaves the old audio speaking at the old rate
    // and disables its completion callback. Replace that audio immediately.
    final stopping = _stopInternal();
    final generation = _playGeneration;
    // Keep the cursor available to a second slider change or pause while the
    // first replacement is still stopping/loading.
    _systemResumeOffset = systemOffset;
    _rateResumeWordOffset = wordOffset;
    await stopping;
    if (_disposed || generation != _playGeneration || _state != TtsState.playing) return;
    await _playCurrent(continueSentence: true, initialWordOffset: wordOffset);
  }

  double get speechRate => _speechRate;

  String _rateStr() => edgeRateStr(_speechRate);

  Future<Duration?> _readPosition() async {
    try { return await _player.getCurrentPosition().timeout(_positionReadTimeout); }
    catch (_) { return null; }
  }

  Future<T> _runPlayer<T>(Future<T> Function() action) {
    final operation = _playerOperations.then((_) => action());
    _playerOperations = operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return operation;
  }

  void _clearResume() {
    _sentenceDelay?.cancel(); _sentenceDelay = null;
    _awaitingSentenceAdvance = false; _remainingDelay = Duration.zero;
    _retainedAudio = null; _retainedWords = []; _retainedAudioIndex = -1;
    _position = Duration.zero; _resumePosition = Duration.zero; _systemResumeOffset = 0;
    _rateResumeWordOffset = -1;
  }

  int _systemOffset(int sentence, int requested) {
    if (!usesSystemVoice || _sentences[sentence].isEmpty) return 0;
    final text = _sentences[sentence];
    var offset = requested.clamp(0, text.length - 1);
    if (_insideSurrogatePair(text, offset)) offset--;
    return offset;
  }

  bool _insideSurrogatePair(String text, int offset) => offset > 0 && offset < text.length &&
    text.codeUnitAt(offset) >= 0xDC00 && text.codeUnitAt(offset) <= 0xDFFF &&
    text.codeUnitAt(offset - 1) >= 0xD800 && text.codeUnitAt(offset - 1) <= 0xDBFF;

  void _emitWord(int start, int end) {
    _lastWordStart = start; _lastWordEnd = end;
    onWordChanged?.call(start, end);
  }

  void _updateWord(Duration position) {
    final word = speechWordAt(_activeWords, position);
    final start = word?.textStart ?? -1, end = word?.textEnd ?? -1;
    if (start != _lastWordStart || end != _lastWordEnd) _emitWord(start, end);
  }

  void _sentenceFinished() {
    if (_awaitingSentenceAdvance) return;
    _activeAudioIndex = -1;
    _awaitingSentenceAdvance = true;
    _remainingDelay = Duration(milliseconds: _pauseAfterMilliseconds[_index]);
    _continueSentenceDelay();
  }

  void _continueSentenceDelay() {
    final generation = ++_playGeneration;
    void advance() {
      if (_disposed || generation != _playGeneration || _state != TtsState.playing || !_awaitingSentenceAdvance) return;
      _sentenceDelay = null; _awaitingSentenceAdvance = false; _remainingDelay = Duration.zero;
      _index++;
      if (_index >= _sentences.length) { _finishChapter(); } else { _playCurrent(); }
    }
    if (_remainingDelay <= Duration.zero) { advance(); return; }
    _delayDeadline = _delayClock.elapsed + _remainingDelay;
    _sentenceDelay = Timer(_remainingDelay, advance);
  }

  /// 开始朗读整章
  /// [offsets]：与 [sentences] 等长的章内 tts 字符偏移列表；长度不符则禁用缓存。
  /// [chapterIndex]：章节索引，缓存坐标的一部分。
  Future<void> start(List<String> sentences,
      {List<int>? offsets, List<int>? pauseAfterMilliseconds, int chapterIndex = 0, int from = 0,
      int initialTtsOffset = 0}) async {
    if (sentences.isEmpty) {
      final stopping = _stopInternal();
      final generation = _playGeneration;
      await stopping;
      if (_disposed || generation != _playGeneration) return;
      _sentences.clear(); _pauseAfterMilliseconds.clear(); _index = -1;
      _setState(TtsState.stopped);
      onCompleted?.call();
      return;
    }
    _contentGeneration++;
    _wordCache.clear();
    final stopping = _stopInternal();
    final generation = _playGeneration;
    await stopping;
    if (_disposed || generation != _playGeneration) return;
    _sentences
      ..clear()
      ..addAll(sentences);
    _pauseAfterMilliseconds = List<int>.generate(sentences.length,
      (index) => pauseAfterMilliseconds != null && index < pauseAfterMilliseconds.length
        ? pauseAfterMilliseconds[index].clamp(0, 60000) : 0);
    _offsets = (offsets != null && offsets.length == sentences.length)
        ? offsets
        : const [];
    _chapterIndex = chapterIndex;
    _index = from.clamp(0, sentences.length - 1);
    _prefetchCache.clear();
    _prefetchIndex = _index - 1;
    _prefetchCompletes = 0;
    _setState(TtsState.playing);
    await _playCurrent(initialTtsOffset: initialTtsOffset);
  }

  /// 暂停（暂停音频播放，保留进度）
  Future<void> pause() {
    _resumeSerial++;
    if (_state != TtsState.playing) return _pausing ?? Future<void>.value();
    final generation = ++_playGeneration;
    final hadAudio = _retainedAudioIndex == _index && _retainedAudio != null && !_awaitingSentenceAdvance;
    if (_awaitingSentenceAdvance) {
      _sentenceDelay?.cancel(); _sentenceDelay = null;
      _remainingDelay = _delayDeadline - _delayClock.elapsed;
      if (_remainingDelay < Duration.zero) _remainingDelay = Duration.zero;
    }
    _activeAudioIndex = -1;
    _resumePosition = hadAudio ? _position : Duration.zero;
    _setState(TtsState.paused);
    onLoadingChanged?.call(false);
    _cancelRequests();
    return _pausing = _runPlayer(() async {
      if (_disposed || generation != _playGeneration) return;
      if (usesSystemVoice) { await _system.stop(); return; }
      try {
        // AudioPlayer.pause also queries its position updater internally.
        // Neither that read nor our settled-position read may hold the queue.
        await _player.pause().timeout(_positionReadTimeout);
        // Read after pause has settled, not the last (up to 50 ms old) tick.
        final position = hadAudio ? await _readPosition() : null;
        if (generation == _playGeneration && _state == TtsState.paused && position != null && position >= Duration.zero) {
          _position = position; _resumePosition = position;
        }
      } catch (_) { /* Retain the last valid clock position if the platform detached. */ }
    });
  }

  /// 重建当前 BytesSource 并跳到暂停时的实际位置，避免依赖失效的原生 resume。
  /// 返回 false 表示彻底失败（onError 已触发，上层应退出朗读界面）。
  Future<bool> resume() async {
    if (_state == TtsState.playing) return true;
    final request = ++_resumeSerial;
    final generation = _playGeneration;
    await _pausing;
    if (_disposed || generation != _playGeneration || request != _resumeSerial) return _state == TtsState.playing;
    if (_sentences.isEmpty || _index < 0 || _index >= _sentences.length) return false;
    final continueSentence = _state == TtsState.paused;
    _setState(TtsState.playing);
    if (continueSentence && _awaitingSentenceAdvance) { _continueSentenceDelay(); return true; }
    // Completed prefetches remain useful, including while offline.
    _prefetchIndex = _index;
    _prefetchCompletes = 0;
    return _playCurrent(continueSentence: continueSentence, initialWordOffset: _rateResumeWordOffset);
  }

  /// 停止并回到起始
  Future<void> stop() async {
    final stopping = _stopInternal();
    final generation = _playGeneration;
    await stopping;
    if (_disposed || generation != _playGeneration) return;
    _index = -1;
    _setState(TtsState.stopped);
  }

  Future<void> _stopInternal() async {
    final generation = ++_playGeneration;
    _activeAudioIndex = -1; _activeWords = []; _clearResume();
    onLoadingChanged?.call(false); _cancelRequests();
    _emitWord(-1, -1);
    await _runPlayer(() async {
      if (_disposed || generation != _playGeneration) return;
      await _system.stop();
      if (_disposed || generation != _playGeneration) return;
      try { await _player.stop(); } catch (_) {}
    });
  }

  /// 跳到指定句子继续朗读
  Future<void> jumpTo(int sentenceIndex, {int ttsOffset = 0}) async {
    if (sentenceIndex < 0 || sentenceIndex >= _sentences.length) return;
    final stopping = _stopInternal();
    final generation = _playGeneration;
    await stopping;
    if (_disposed || generation != _playGeneration) return;
    _index = sentenceIndex;
    _systemResumeOffset = _systemOffset(sentenceIndex, ttsOffset);
    onSentenceChanged?.call(_index);
    if (_state == TtsState.playing) {
      _prefetchCache.clear();
      _prefetchIndex = _index - 1;
      _prefetchCompletes = 0;
      await _playCurrent(initialTtsOffset: ttsOffset);
    }
  }

  /// 下一句
  Future<void> next() async {
    if (_sentences.isEmpty) return;
    await jumpTo((_index + 1).clamp(0, _sentences.length - 1));
  }

  /// 上一句
  Future<void> prev() async {
    if (_sentences.isEmpty) return;
    await jumpTo((_index - 1).clamp(0, _sentences.length - 1));
  }

  /// 当前句的缓存偏移；offsets 未启用（长度不符）返回 -1（缓存关闭）
  int _cacheOff(int idx) =>
      (_offsets.length == _sentences.length) ? _offsets[idx] : -1;

  /// 取音频：内存预取 → 磁盘缓存 → 在线合成（成功后异步落盘，不阻塞播放）
  Future<Uint8List> _obtainAudio(int idx) {
    final fromMem = _prefetchCache.remove(idx);
    if (fromMem != null && fromMem.isNotEmpty) return Future.value(fromMem);
    final generation = _contentGeneration;
    final key = '$generation/$idx';
    final pending = _audioRequests[key];
    if (pending != null) return pending;
    late final Future<Uint8List> request;
    request = _fetchAudio(idx, generation).whenComplete(() {
      // Resizing can replace a cancelled request at this same coordinate.
      if (identical(_audioRequests[key], request)) _audioRequests.remove(key);
    });
    _audioRequests[key] = request;
    return request;
  }

  Future<Uint8List> _fetchAudio(int idx, int generation) async {
    if (idx < 0 || idx >= _sentences.length) return Uint8List(0);
    final text = _sentences[idx], voice = _voice, rate = _rateStr();
    final off = _cacheOff(idx), chapter = _chapterIndex;
    final cache = _cache;
    if (off >= 0 && cache != null) {
      final disk = await cache.read(chapter, off);
      if (_disposed || generation != _contentGeneration || !_inMemoryWindow(idx)) return Uint8List(0);
      if (disk != null && disk.isNotEmpty) {
        final words = await cache.readWords(chapter, off);
        if (_disposed || generation != _contentGeneration) return Uint8List(0);
        if (_inMemoryWindow(idx)) _wordCache[idx] = words;
        return disk;
      }
    }
    if (!_networkAvailable || _onlineNetworkFailure != null) {
      _audioFailures[idx] = _onlineNetworkFailure ?? const EdgeTtsException('connection');
      return Uint8List(0);
    }
    Uint8List audio;
    List<SpeechWord> words = [];
    final key = '$generation/$idx';
    final token = EdgeSynthCancelToken(); _requestTokens[key] = token;
    final disconnected = Completer<Uint8List>();
    final networkSubscription = _networkEvents.stream.listen((available) {
      if (!available && !disconnected.isCompleted) disconnected.completeError(const EdgeTtsException('connection'));
    }, onDone: () {
      if (!disconnected.isCompleted) disconnected.completeError(const EdgeTtsException('cancelled'));
    });
    try {
      audio = await Future.any<Uint8List>([
        disconnected.future,
        Future<Uint8List>.sync(() => _synthesize(text, voice: voice, rate: rate,
          onWords: (value) => words = value, cancelToken: token)),
      ]);
    }
    catch (error) {
      if (!token.cancelled && generation == _contentGeneration) {
        if (_isNetworkFailure(error)) _rememberNetworkFailure(error);
        if (_inMemoryWindow(idx)) _audioFailures[idx] = error;
      }
      return Uint8List(0);
    }
    finally {
      await networkSubscription.cancel();
      if (_requestTokens[key] == token) _requestTokens.remove(key);
    }
    if (_disposed || generation != _contentGeneration || token.cancelled) return Uint8List(0);
    if (_inMemoryWindow(idx)) _wordCache[idx] = words;
    if (audio.isNotEmpty && off >= 0 && cache != null) {
      late final Future<void> pending;
      pending = Future<void>.sync(() => cache.write(chapter, off, audio, words: words))
        // Cache persistence is optional for playback, including storage errors.
        .then<void>((_) {}, onError: (Object _, StackTrace __) {})
        .whenComplete(() { _cacheWrites.remove(pending); });
      _cacheWrites.add(pending);
      unawaited(pending);
    }
    return audio;
  }

  /// 播放当前句（优先用预取缓存，否则查盘/现合成）。
  /// 返回 true=已进入播放；false=失败或章节结束（失败时会先触发 onError）。
  Future<bool> _playCurrent({bool continueSentence = false, int initialTtsOffset = 0, int initialWordOffset = -1}) async {
    if (_disposed) return false;
    if (_state != TtsState.playing) return false;
    if (_index < 0 || _index >= _sentences.length) {
      _finishChapter();
      return false;
    }
    final generation = ++_playGeneration;
    final sentence = _index;
    lastFailure = null; onLoadingChanged?.call(true);
    _activeAudioIndex = -1; _activeWords = [];
    if (!continueSentence) {
      _clearResume();
      _systemResumeOffset = _systemOffset(sentence, initialTtsOffset);
      _emitWord(-1, -1);
      onSentenceChanged?.call(_index);
    }

    if (usesSystemVoice) {
      try {
        await _system.speak(_sentences[sentence], _speechRate,
          startOffset: _systemResumeOffset,
          onDone: () {
            if (_disposed || generation != _playGeneration || _state != TtsState.playing) return;
            _sentenceFinished();
          },
          onRange: (start, end) {
            if (generation == _playGeneration && _state == TtsState.playing) {
              // Some engines report punctuation as a separate range. It is
              // still spoken in its original sentence context, but is not a
              // word from which to start a fresh utterance after pause/rate.
              final text = _sentences[sentence];
              if (_insideSurrogatePair(text, start) || _insideSurrogatePair(text, end)) return;
              final prefix = _leadingRangePunctuation.matchAsPrefix(text.substring(start, end));
              final contentStart = start + (prefix?.end ?? 0);
              if (contentStart >= end) return;
              _systemResumeOffset = contentStart; _emitWord(contentStart, end);
            }
          },
          onError: (error) { if (generation == _playGeneration) _fail(error); });
        if (_disposed || generation != _playGeneration) return false;
        onLoadingChanged?.call(false); return true;
      } on SystemSpeechCancelled { return false; }
      catch (error) { if (!_disposed && generation == _playGeneration) _fail(error); return false; }
    }
    // 取音频：内存/磁盘/在线。The deadline covers the actual operation,
    // not an unrelated UI timer that can report failure while still loading.
    Uint8List audio;
    final retained = continueSentence && _retainedAudioIndex == sentence ? _retainedAudio : null;
    var resumePosition = retained != null ? _resumePosition : Duration.zero;
    try { audio = retained ?? await _obtainAudio(sentence).timeout(const Duration(seconds: 30)); }
    catch (error) {
      if (!_disposed && generation == _playGeneration) {
        if (_isNetworkFailure(error)) return _playSystemFallback(error);
        _fail(error);
      }
      return false;
    }
    if (_disposed || _state != TtsState.playing || generation != _playGeneration || sentence != _index) return false;
    _activeWords = retained != null ? _retainedWords : (_wordCache[sentence] ?? []);
    // A newly synthesized rate has different timings. Resume only at the same
    // reported word's new, actual boundary; never estimate a proportional seek.
    if (retained == null && initialWordOffset >= 0) {
      SpeechWord? containingWord;
      SpeechWord? exactWord;
      for (final word in _activeWords) {
        if (word.textStart == initialWordOffset) {
          exactWord = word;
          break;
        }
        if (word.textStart <= initialWordOffset && initialWordOffset < word.textEnd) containingWord ??= word;
      }
      // A rate change can change tokenization. A real enclosing word boundary
      // limits any reread to that word instead of restarting the whole sentence.
      final boundary = exactWord ?? containingWord;
      if (boundary != null) resumePosition = Duration(microseconds: boundary.startMicros);
    }
    if (audio.isEmpty) {
      // Keep the current sentence on failure; do not silently skip unread text.
      final error = _audioFailures[sentence] ?? (!_networkAvailable
        ? const EdgeTtsException('connection') : const EdgeTtsException('no_audio'));
      if (_isNetworkFailure(error)) return _playSystemFallback(error);
      _fail(error); return false;
    }
    _retainedAudio = audio; _retainedAudioIndex = sentence; _retainedWords = _activeWords;

    _prefetchCompletes = 0;
    try {
      return await _runPlayer(() async {
        if (_disposed || generation != _playGeneration || sentence != _index) return false;
        // Stop/reload avoids the historical paused BytesSource resume failure.
        // AudioPlayer.play seeks after preparation and before starting audio.
        await _player.stop();
        if (_disposed || generation != _playGeneration || sentence != _index) return false;
        await _player.play(BytesSource(audio), position: resumePosition > Duration.zero ? resumePosition : null)
          .timeout(const Duration(seconds: 15));
        if (_disposed || generation != _playGeneration || sentence != _index || _state != TtsState.playing) return false;
        _activeAudioIndex = sentence; _position = resumePosition;
        _rateResumeWordOffset = -1;
        if (continueSentence || initialWordOffset >= 0) _updateWord(resumePosition);
        onLoadingChanged?.call(false);
        if (_prefetchIndex < sentence) _prefetchIndex = sentence;
        _startPrefetch();
        return true;
      });
    } catch (error) {
      if (!_disposed && generation == _playGeneration) _fail(error);
      return false;
    }
  }

  void _cancelRequests() {
    _contentGeneration++;
    _prefetchGeneration++; _prefetching = false;
    for (final token in _requestTokens.values.toList()) { token.cancel(); }
    _requestTokens.clear(); _audioFailures.clear(); _audioRequests.clear();
  }

  void _fail(Object error) {
    lastFailure = error;
    _playGeneration++; _cancelRequests();
    _activeAudioIndex = -1; _activeWords = []; _clearResume();
    _setState(TtsState.stopped); onLoadingChanged?.call(false); onError?.call();
  }

  /// 后台预取：从当前句之后开始，提前合成若干句
  void _startPrefetch() {
    _prunePrefetch();
    if (_disposed || _prefetching || usesSystemVoice || !_networkAvailable || _onlineNetworkFailure != null || _prefetchSentences == 0 || _state != TtsState.playing) return;
    if (_activeAudioIndex != _index && !_awaitingSentenceAdvance) return;
    _prefetching = true;
    _prefetchLoop();
  }

  Future<void> _prefetchLoop() async {
    final generation = _contentGeneration;
    final worker = _prefetchGeneration;
    try {
      while (!_disposed && !usesSystemVoice && _networkAvailable && _onlineNetworkFailure == null && _state == TtsState.playing && generation == _contentGeneration && worker == _prefetchGeneration) {
        // 计算下一个要预取的位置
        final nextToPrefetch = _prefetchIndex + 1;
        final maxPrefetch = _index + _prefetchSentences;
        if (nextToPrefetch > maxPrefetch ||
            nextToPrefetch >= _sentences.length) {
          await Future.delayed(const Duration(milliseconds: 200));
          continue;
        }
        _prefetchIndex = nextToPrefetch;
        // Replanning must not temporarily remove reusable audio from memory:
        // a second resize could otherwise synthesize that same sentence again.
        if (_prefetchCache.containsKey(nextToPrefetch)) continue;
        // 取音频：内存/磁盘/在线（命中磁盘零网络，并异步落盘供下次）
        final audio = await _obtainAudio(nextToPrefetch);
        if (_disposed || _state != TtsState.playing || generation != _contentGeneration || worker != _prefetchGeneration) return;
        if (audio.isNotEmpty && nextToPrefetch > _index && _inMemoryWindow(nextToPrefetch)) {
          _prefetchCache[nextToPrefetch] = audio;
        }
        _prunePrefetch();
        // 避免连发过多请求
        await Future.delayed(const Duration(milliseconds: 80));
      }
    } catch (_) {} finally {
      if (worker == _prefetchGeneration) _prefetching = false;
      if (worker == _prefetchGeneration && !_disposed && !usesSystemVoice && _state == TtsState.playing && generation != _contentGeneration) {
        _startPrefetch();
      }
    }
  }

  Future<void> _finishChapter() async {
    _setState(TtsState.stopped);
    onCompleted?.call();
  }

  void _setState(TtsState s) {
    _state = s;
    onStateChanged?.call();
  }

  Future<void> dispose() async {
    _disposed = true; _contentGeneration++; _playGeneration++;
    _sentenceDelay?.cancel(); _delayClock.stop();
    _cancelRequests(); await _networkEvents.close(); await _system.dispose();
    await _positionSubscription?.cancel();
    await _playerOperations;
    try {
      await _player.stop();
      await _player.dispose();
    } catch (_) {}
    // No new writes can start after the disposed/generation checks above.
    // Draining here leaves playback non-blocking while making cache teardown
    // and removal safe once disposal completes.
    await Future.wait<void>(_cacheWrites.toList());
  }
}
