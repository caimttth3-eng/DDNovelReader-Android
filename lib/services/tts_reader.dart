/// TTS 朗读服务：基于 Edge TTS 在线合成 + 后台预取队列。
/// 逐句朗读 + 逐句高亮回调 + 暂停/继续/停止 + 定时停止。
/// 预取后续句子（默认提前 8 句），合成期间播放零卡顿。
library;

import 'dart:async';
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
  static const systemVoice = SystemTtsClient.voiceId;
  final SystemTtsClient _system = SystemTtsClient();
  final Map<String, EdgeSynthCancelToken> _requestTokens = {};
  final Map<int, Object> _audioFailures = {};
  Object? lastFailure;
  ValueChanged<bool>? onLoadingChanged;
  bool get usesSystemVoice => _voice == systemVoice;
  static const defaultVoice = 'zh-CN-XiaoxiaoNeural';
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
  List<SpeechWord> _activeWords = [];
  int _activeAudioIndex = -1;
  int _lastWordStart = -1;
  int _contentGeneration = 0;
  int _playGeneration = 0;
  StreamSubscription<Duration>? _positionSubscription;
  void Function(int start, int end)? onWordChanged;
  int _prefetchIndex = -1; // 已预取到的位置
  bool _prefetching = false;
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

  TtsReader({AudioPlayer? player, OnlineSpeechSynthesizer? synthesize})
      : _player = player ?? AudioPlayer(), _synthesize = synthesize ?? edgeSynth {
    _player.positionUpdater = TimerPositionUpdater(interval: const Duration(milliseconds: 50),
      getPosition: _player.getCurrentPosition);
    _positionSubscription = _player.onPositionChanged.listen((position) {
      if (_disposed || _state != TtsState.playing || _activeAudioIndex != _index) return;
      final word = speechWordAt(_activeWords, position);
      final start = word?.textStart ?? -1;
      if (start != _lastWordStart) {
        _lastWordStart = start; onWordChanged?.call(start, word?.textEnd ?? -1);
      }
    });
    _player.onPlayerComplete.listen((_) {
      // 当前句播放完，推进到下一句
      if (_disposed) return;
      if (usesSystemVoice || _activeAudioIndex < 0 || _activeAudioIndex != _index) return;
      if (_state != TtsState.playing) return;
      _index++;
      if (_index >= _sentences.length) {
        _finishChapter();
      } else {
        _playCurrent();
      }
    });
  }

  /// 设置音色（zh-CN 等）
  void setVoice(String v) {
    if (_voice == v) return;
    _voice = v; _invalidateAudio();
  }

  void _invalidateAudio() {
    _cancelRequests(); _prefetchCache.clear(); _wordCache.clear();
    _prefetchIndex = _index;
  }

  /// 设置/替换磁盘缓存（切换书/音色/语速时由上层重建传入）
  void setCache(TtsCacheStore? store) => _cache = store;

  /// 设置语速（0.1~3.0，映射到 Edge rate 百分比 +200%）
  Future<void> setSpeechRate(double rate) async {
    final value = rate.clamp(0.1, 3.0);
    if (value != _speechRate) { _speechRate = value; _invalidateAudio(); }
  }

  double get speechRate => _speechRate;

  String _rateStr() => edgeRateStr(_speechRate);

  /// 开始朗读整章
  /// [offsets]：与 [sentences] 等长的章内 tts 字符偏移列表；长度不符则禁用缓存。
  /// [chapterIndex]：章节索引，缓存坐标的一部分。
  Future<void> start(List<String> sentences,
      {List<int>? offsets, int chapterIndex = 0, int from = 0}) async {
    if (sentences.isEmpty) {
      _setState(TtsState.stopped);
      onCompleted?.call();
      return;
    }
    _contentGeneration++;
    _wordCache.clear();
    await _stopInternal();
    _sentences
      ..clear()
      ..addAll(sentences);
    _offsets = (offsets != null && offsets.length == sentences.length)
        ? offsets
        : const [];
    _chapterIndex = chapterIndex;
    _index = from.clamp(0, sentences.length - 1);
    _prefetchCache.clear();
    _prefetchIndex = _index - 1;
    _prefetchCompletes = 0;
    _setState(TtsState.playing);
    await _playCurrent();
  }

  /// 暂停（暂停音频播放，保留进度）
  Future<void> pause() async {
    if (_state != TtsState.playing) return;
    _setState(TtsState.paused);
    _playGeneration++;
    onLoadingChanged?.call(false);
    _cancelRequests();
    if (usesSystemVoice) { await _system.stop(); return; }
    try {
      await _player.pause();
    } catch (_) {}
    _setState(TtsState.paused);
  }

  /// 继续播放：直接从当前句重新播放（缓存优先，否则重新合成）。
  /// 不依赖 MediaPlayer.resume()——它对已 stop / 长时间 pause / 反复
  /// pause-resume 的 BytesSource 播放器会静默失效（不抛异常但不出声），
  /// 这是'暂停后无法继续播放'的根因。
  /// 返回 false 表示彻底失败（onError 已触发，上层应退出朗读界面）。
  Future<bool> resume() async {
    // 已在播放：无需操作
    if (_state == TtsState.playing) return true;
    // 状态不在 paused（如被 stop / 章节结束改走）：
    // 不能静默假成功，从当前句重新开始，保证媒体控制器"继续"必定恢复
    if (_state != TtsState.paused) {
      if (_sentences.isEmpty || _index < 0) return false;
      _setState(TtsState.playing);
      _prefetchCache.clear();
      _prefetchIndex = _index - 1;
      _prefetchCompletes = 0;
      return _playCurrent();
    }
    _setState(TtsState.playing);
    // 重置预取状态并重启（pause 时预取循环已退出）
    _prefetchCache.clear();
    _prefetchIndex = _index - 1;
    _prefetchCompletes = 0;
    return _playCurrent();
  }

  /// 停止并回到起始
  Future<void> stop() async {
    await _stopInternal();
    _index = -1;
    _setState(TtsState.stopped);
  }

  Future<void> _stopInternal() async {
    _playGeneration++; _activeAudioIndex = -1; _activeWords = [];
    onLoadingChanged?.call(false); _cancelRequests();
    await _system.stop();
    _lastWordStart = -1; onWordChanged?.call(-1, -1);
    try {
      await _player.stop();
    } catch (_) {}
  }

  /// 跳到指定句子继续朗读
  Future<void> jumpTo(int sentenceIndex) async {
    if (sentenceIndex < 0 || sentenceIndex >= _sentences.length) return;
    await _stopInternal();
    _index = sentenceIndex;
    onSentenceChanged?.call(_index);
    if (_state == TtsState.playing) {
      _prefetchCache.clear();
      _prefetchIndex = _index - 1;
      _prefetchCompletes = 0;
      await _playCurrent();
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
    return _audioRequests.putIfAbsent(key, () => _fetchAudio(idx, generation)
      // Map.remove returns the same Future stored below. Returning it from
      // whenComplete would make this request wait for its own completion.
      .whenComplete(() { _audioRequests.remove(key); }));
  }

  Future<Uint8List> _fetchAudio(int idx, int generation) async {
    if (idx < 0 || idx >= _sentences.length) return Uint8List(0);
    final text = _sentences[idx], voice = _voice, rate = _rateStr();
    final off = _cacheOff(idx), chapter = _chapterIndex;
    final cache = _cache;
    if (off >= 0 && cache != null) {
      final disk = await cache.read(chapter, off);
      if (_disposed || generation != _contentGeneration) return Uint8List(0);
      if (disk != null && disk.isNotEmpty) {
        final words = await cache.readWords(chapter, off);
        if (_disposed || generation != _contentGeneration) return Uint8List(0);
        _wordCache[idx] = words; return disk;
      }
    }
    Uint8List audio;
    List<SpeechWord> words = [];
    final key = '$generation/$idx';
    final token = EdgeSynthCancelToken(); _requestTokens[key] = token;
    try { audio = await _synthesize(text, voice: voice, rate: rate,
      onWords: (value) => words = value, cancelToken: token); }
    catch (error) { if (generation == _contentGeneration) _audioFailures[idx] = error; return Uint8List(0); }
    finally { if (_requestTokens[key] == token) _requestTokens.remove(key); }
    if (_disposed || generation != _contentGeneration) return Uint8List(0);
    _wordCache[idx] = words;
    if (audio.isNotEmpty && off >= 0 && cache != null) {
      unawaited(cache.write(chapter, off, audio, words: words));
    }
    return audio;
  }

  /// 播放当前句（优先用预取缓存，否则查盘/现合成）。
  /// 返回 true=已进入播放；false=失败或章节结束（失败时会先触发 onError）。
  Future<bool> _playCurrent() async {
    if (_disposed) return false;
    if (_state != TtsState.playing) return false;
    if (_index < 0 || _index >= _sentences.length) {
      _finishChapter();
      return false;
    }
    final generation = ++_playGeneration;
    final sentence = _index;
    lastFailure = null; onLoadingChanged?.call(true);
    _activeAudioIndex = -1; _activeWords = []; _lastWordStart = -1;
    onWordChanged?.call(-1, -1);
    onSentenceChanged?.call(_index);

    if (usesSystemVoice) {
      try {
        await _system.speak(_sentences[sentence], _speechRate,
          onDone: () {
            if (_disposed || generation != _playGeneration || _state != TtsState.playing) return;
            _index++;
            if (_index >= _sentences.length) _finishChapter(); else _playCurrent();
          },
          onRange: (start, end) { if (generation == _playGeneration && _state == TtsState.playing) onWordChanged?.call(start, end); },
          onError: (error) { if (generation == _playGeneration) _fail(error); });
        if (_disposed || generation != _playGeneration) return false;
        onLoadingChanged?.call(false); return true;
      } on SystemSpeechCancelled { return false; }
      catch (error) { if (!_disposed && generation == _playGeneration) _fail(error); return false; }
    }
    // 取音频：内存/磁盘/在线。The deadline covers the actual operation,
    // not an unrelated UI timer that can report failure while still loading.
    Uint8List audio;
    try { audio = await _obtainAudio(sentence).timeout(const Duration(seconds: 30)); }
    catch (error) { if (!_disposed && generation == _playGeneration) _fail(error); return false; }
    if (_disposed || _state != TtsState.playing || generation != _playGeneration || sentence != _index) return false;
    _activeWords = _wordCache[sentence] ?? [];
    if (audio.isEmpty) {
      // Keep the current sentence on failure; do not silently skip unread text.
      _fail(_audioFailures[sentence] ?? const EdgeTtsException('no_audio')); return false;
    }

    _prefetchCompletes = 0;
    try {
      // 先 stop 重置播放器：audioplayers 在 paused 状态直接 play 新
      // BytesSource 会导致 onPlayerComplete 丢失（句子播完不推进），
      // 这是'反复暂停/恢复后卡死'的根因。stop 后再 play 保证回调可靠。
      await _player.stop();
      if (_disposed || generation != _playGeneration || sentence != _index) return false;
      await _player.play(BytesSource(audio)).timeout(const Duration(seconds: 15));
      if (generation == _playGeneration && sentence == _index) {
        _activeAudioIndex = sentence; onLoadingChanged?.call(false);
        // First sound has priority over background synthesis.
        if (_prefetchIndex < sentence) _prefetchIndex = sentence;
        _startPrefetch();
      }
      return true;
    } catch (error) {
      if (!_disposed && generation == _playGeneration) _fail(error);
      return false;
    }
  }

  void _cancelRequests() {
    _contentGeneration++;
    for (final token in _requestTokens.values.toList()) { token.cancel(); }
    _requestTokens.clear(); _audioFailures.clear(); _audioRequests.clear();
  }

  void _fail(Object error) {
    lastFailure = error;
    _playGeneration++; _cancelRequests();
    _setState(TtsState.stopped); onLoadingChanged?.call(false); onError?.call();
  }

  /// 后台预取：从当前句之后开始，提前合成若干句
  void _startPrefetch() {
    if (_prefetching || usesSystemVoice) return;
    _prefetching = true;
    _prefetchLoop();
  }

  static const int _maxAhead = 8;

  Future<void> _prefetchLoop() async {
    final generation = _contentGeneration;
    try {
      while (!_disposed && !usesSystemVoice && _state == TtsState.playing && generation == _contentGeneration) {
        // 计算下一个要预取的位置
        final nextToPrefetch = _prefetchIndex + 1;
        final maxPrefetch = _index + _maxAhead;
        if (nextToPrefetch > maxPrefetch ||
            nextToPrefetch >= _sentences.length) {
          await Future.delayed(const Duration(milliseconds: 200));
          continue;
        }
        _prefetchIndex = nextToPrefetch;
        // 取音频：内存/磁盘/在线（命中磁盘零网络，并异步落盘供下次）
        final audio = await _obtainAudio(nextToPrefetch);
        if (_disposed || _state != TtsState.playing || generation != _contentGeneration) return;
        if (audio.isNotEmpty) {
          _prefetchCache[nextToPrefetch] = audio;
          // 防止缓存无限膨胀（超过 maxAhead 的旧缓存清掉）
          final keepFrom = _index - 1;
          _prefetchCache.removeWhere((k, v) => k < keepFrom);
          _wordCache.removeWhere((k, v) => k < keepFrom);
        }
        // 避免连发过多请求
        await Future.delayed(const Duration(milliseconds: 80));
      }
    } catch (_) {} finally {
      _prefetching = false;
      if (!_disposed && !usesSystemVoice && _state == TtsState.playing && generation != _contentGeneration) {
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
    _cancelRequests(); await _system.dispose();
    await _positionSubscription?.cancel();
    try {
      await _player.stop();
      await _player.dispose();
    } catch (_) {}
  }
}
