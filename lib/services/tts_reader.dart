/// TTS 朗读服务：基于 Edge TTS 在线合成 + 后台预取队列。
/// 逐句朗读 + 逐句高亮回调 + 暂停/继续/停止 + 定时停止。
/// 预取后续句子（默认提前 8 句），合成期间播放零卡顿。
library;

import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'edge_tts.dart';

enum TtsState { idle, playing, paused, stopped }

class TtsReader {
  final AudioPlayer _player = AudioPlayer();
  final List<String> _sentences = [];
  int _index = -1;
  TtsState _state = TtsState.idle;
  bool _disposed = false;

  // 预取缓存：句索引 -> 已合成的 MP3 字节
  final Map<int, Uint8List> _prefetchCache = {};
  int _prefetchIndex = -1; // 已预取到的位置
  bool _prefetching = false;
  int _prefetchCompletes = 0; // 连续合成失败计数（用于判定离线）

  String _voice = 'zh-CN-XiaoxiaoNeural';
  double _speechRate = 0.5;

  // 回调
  ValueChanged<int>? onSentenceChanged;
  VoidCallback? onCompleted;
  VoidCallback? onStateChanged;
  VoidCallback? onError;

  TtsState get state => _state;
  int get currentIndex => _index;
  int get sentenceCount => _sentences.length;
  String get voice => _voice;

  TtsReader() {
    _player.onPlayerComplete.listen((_) {
      // 当前句播放完，推进到下一句
      if (_disposed) return;
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
  void setVoice(String v) => _voice = v;

  /// 设置语速（0.1~3.0，映射到 Edge rate 百分比 +200%）
  Future<void> setSpeechRate(double rate) async {
    _speechRate = rate.clamp(0.1, 3.0);
  }

  double get speechRate => _speechRate;

  String _rateStr() {
    // 0.5 -> -75%, 1.0 -> +0%, 1.5 -> +50%
    final pct = ((_speechRate - 1.0) * 100).round();
    return pct >= 0 ? '+$pct%' : '$pct%';
  }

  /// 开始朗读整章
  Future<void> start(List<String> sentences, {int from = 0}) async {
    if (sentences.isEmpty) {
      _setState(TtsState.stopped);
      onCompleted?.call();
      return;
    }
    await _stopInternal();
    _sentences
      ..clear()
      ..addAll(sentences);
    _index = from.clamp(0, sentences.length - 1);
    _prefetchCache.clear();
    _prefetchIndex = _index - 1;
    _prefetchCompletes = 0;
    _setState(TtsState.playing);
    _startPrefetch();
    await _playCurrent();
  }

  /// 暂停（暂停音频播放，保留进度）
  Future<void> pause() async {
    if (_state != TtsState.playing) return;
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
    if (_state != TtsState.paused) return true;
    _setState(TtsState.playing);
    // 重置预取状态并重启（pause 时预取循环已退出）
    _prefetchCache.clear();
    _prefetchIndex = _index - 1;
    _prefetchCompletes = 0;
    _startPrefetch();
    return _playCurrent();
  }

  /// 停止并回到起始
  Future<void> stop() async {
    await _stopInternal();
    _index = -1;
    _setState(TtsState.stopped);
  }

  Future<void> _stopInternal() async {
    try {
      await _player.stop();
    } catch (_) {}
  }

  /// 跳到指定句子继续朗读
  Future<void> jumpTo(int sentenceIndex) async {
    if (sentenceIndex < 0 || sentenceIndex >= _sentences.length) return;
    try {
      await _player.stop();
    } catch (_) {}
    _index = sentenceIndex;
    onSentenceChanged?.call(_index);
    if (_state == TtsState.playing) {
      _prefetchCache.clear();
      _prefetchIndex = _index - 1;
      _prefetchCompletes = 0;
      _startPrefetch();
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

  /// 播放当前句（优先用预取缓存，否则现合成）。
  /// 返回 true=已进入播放；false=失败或章节结束（失败时会先触发 onError）。
  Future<bool> _playCurrent() async {
    if (_disposed) return false;
    if (_state != TtsState.playing) return false;
    if (_index < 0 || _index >= _sentences.length) {
      _finishChapter();
      return false;
    }
    onSentenceChanged?.call(_index);

    // 取音频：缓存优先
    Uint8List? audio = _prefetchCache.remove(_index);
    if (audio == null || audio.isEmpty) {
      // 没缓存则现合成
      try {
        audio = await edgeSynth(
            _sentences[_index], voice: _voice, rate: _rateStr());
      } catch (_) {
        audio = Uint8List(0);
      }
      if (_disposed || _state != TtsState.playing) return false;
      if (audio.isEmpty) {
        // 合成失败（可能离线）：计入失败，连续 3 次判定无法播放
        return _handlePlayFailure();
      }
    }

    _prefetchCompletes = 0;
    try {
      // 先 stop 重置播放器：audioplayers 在 paused 状态直接 play 新
      // BytesSource 会导致 onPlayerComplete 丢失（句子播完不推进），
      // 这是'反复暂停/恢复后卡死'的根因。stop 后再 play 保证回调可靠。
      await _player.stop();
      await _player.play(BytesSource(audio));
      return true;
    } catch (_) {
      // 播放失败：重新合成一次重试，仍失败计入失败数
      try {
        final retry = await edgeSynth(
            _sentences[_index], voice: _voice, rate: _rateStr());
        if (_disposed || _state != TtsState.playing) return false;
        if (retry.isEmpty) throw Exception('empty synth');
        await _player.stop();
        await _player.play(BytesSource(retry));
        return true;
      } catch (_) {
        return _handlePlayFailure();
      }
    }
  }

  /// 单句播放/合成失败处理：连续失败 >=3 判定彻底无法播放，触发 onError；
  /// 否则跳过该句继续。
  Future<bool> _handlePlayFailure() async {
    _prefetchCompletes++;
    if (_prefetchCompletes >= 3) {
      // 连续失败，判定无法播放（离线/播放器异常）：通知上层退出
      _setState(TtsState.stopped);
      onError?.call();
      return false;
    }
    _index++;
    if (_index >= _sentences.length) {
      _finishChapter();
      return false;
    }
    return _playCurrent();
  }

  /// 后台预取：从当前句之后开始，提前合成若干句
  void _startPrefetch() {
    if (_prefetching) return;
    _prefetching = true;
    _prefetchLoop();
  }

  static const int _maxAhead = 8;

  Future<void> _prefetchLoop() async {
    try {
      while (!_disposed && _state == TtsState.playing) {
        // 计算下一个要预取的位置
        final nextToPrefetch = _prefetchIndex + 1;
        final maxPrefetch = _index + _maxAhead;
        if (nextToPrefetch > maxPrefetch ||
            nextToPrefetch >= _sentences.length) {
          await Future.delayed(const Duration(milliseconds: 200));
          continue;
        }
        _prefetchIndex = nextToPrefetch;
        final text = _sentences[nextToPrefetch];
        // 控制并发：最多同时预取 2 个
        Uint8List? audio;
        try {
          audio = await edgeSynth(text, voice: _voice, rate: _rateStr());
        } catch (_) {
          audio = Uint8List(0);
        }
        if (_disposed || _state != TtsState.playing) return;
        if (audio.isNotEmpty) {
          _prefetchCache[nextToPrefetch] = audio;
          // 防止缓存无限膨胀（超过 maxAhead 的旧缓存清掉）
          final keepFrom = _index - 1;
          _prefetchCache.removeWhere((k, v) => k < keepFrom);
        }
        // 避免连发过多请求
        await Future.delayed(const Duration(milliseconds: 80));
      }
    } catch (_) {} finally {
      _prefetching = false;
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
    _disposed = true;
    try {
      await _player.stop();
      await _player.dispose();
    } catch (_) {}
  }
}
