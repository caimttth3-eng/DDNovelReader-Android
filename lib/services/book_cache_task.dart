import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/book.dart';
import '../models/speech_word.dart';
import 'edge_tts.dart';
import 'tts_cache_store.dart';

/// 全书缓存任务状态
class BookCacheStatus {
  final String state; // building / caching / paused / done / cancelled
  final int done;
  final int total;
  const BookCacheStatus(this.state, this.done, this.total);

  bool get isActive => state == 'building' || state == 'caching';
  bool get isPaused => state == 'paused';
  bool get isDone => state == 'done';
}

/// 全书预缓存任务：后台把整本书逐句合成并落盘。
///
/// 对齐 PC 端 WholeBookCacher 设计：
/// - 与朗读侧同一套坐标（章节+章内 tts 偏移），缓存命中零网络；
/// - 并发 3 路（手机网络/内存比 PC 保守，也避微软限流）；
/// - 失败不标记完成，留待续传补齐；全部完成→done，有失败→paused；
/// - 进度持久化 progress.json，resume 续传自动跳过已缓存文件；
/// - 完全独立于朗读（不占用 TtsReader，朗读时缓存照跑）。
class BookCacheTask {
  final Book book;
  final String bookId;
  final TtsCacheStore store;

  static const int workerCount = 3;
  static const int saveInterval = 20;

  List<(int, int, String)> _tasks = [];
  int _total = 0;
  int _done = 0;
  int _next = 0;
  final Set<int> _completed = {};
  String _state = 'idle'; // idle/building/caching/paused/done/cancelled

  // 缓存起点（从"目前进度"开始缓存时非空），随进度持久化，恢复时按同一起点重建
  int? _fromChapter;
  int? _fromOffset;

  bool _cancelled = false;
  bool _paused = false;
  int _aliveWorkers = 0;
  int _lastSave = 0;

  /// 进度变化回调（UI 刷新）
  ValueChanged<BookCacheStatus>? onProgress;

  /// 进度通知器（弹层 ValueListenableBuilder 直接绑定）
  final ValueNotifier<BookCacheStatus> statusNotifier =
      ValueNotifier(const BookCacheStatus('idle', 0, 0));

  BookCacheTask({required this.book, required this.bookId, required this.store});

  BookCacheStatus get status => BookCacheStatus(_state, _done, _total);

  // ---------- 任务构建 ----------

  /// 构建缓存任务表；fromChapter/fromOffset 非空时只缓存该位置之后的句子
  Future<void> _buildTasks({int? fromChapter, int? fromOffset}) async {
    final tasks = <(int, int, String)>[];
    for (var ci = 0; ci < book.chapters.length; ci++) {
      if (fromChapter != null && ci < fromChapter) continue;
      final ch = book.chapters[ci];
      final offs = chapterTtsSentenceOffsets(ch);
      var i = 0;
      for (final p in ch.paragraphs) {
        for (final s in p.sentences) {
          final off = offs[i];
          if (s.tts.isEmpty) {
            i++;
            continue;
          }
          if (fromChapter != null &&
              ci == fromChapter &&
              fromOffset != null &&
              off < fromOffset) {
            i++;
            continue;
          }
          tasks.add((ci, off, s.tts));
          i++;
        }
      }
    }
    _tasks = tasks;
    _total = tasks.length;
  }

  // ---------- 控制 ----------

  /// 开始缓存。resume=true 时按 progress.json 恢复（含缓存起点）；
  /// 全新开始时可用 fromChapter/fromOffset 指定"从目前进度开始缓存"。
  Future<void> start({
    bool resume = false,
    int? fromChapter,
    int? fromOffset,
  }) async {
    if (_state == 'caching' || _state == 'building') return;
    _state = 'building';
    _cancelled = false;
    _paused = false;
    _notify();
    if (resume) {
      final prog = await store.loadProgress();
      if (prog != null) {
        _fromChapter = prog.fromChapter;
        _fromOffset = prog.fromOffset;
      }
      await _buildTasks(fromChapter: _fromChapter, fromOffset: _fromOffset);
    } else {
      _fromChapter = fromChapter;
      _fromOffset = fromOffset;
      await _buildTasks(fromChapter: fromChapter, fromOffset: fromOffset);
    }
    await _initAndRun(resume: resume);
  }

  /// 从磁盘恢复进度（进程重启/重进页面时调用；仅 idle 状态可用）。
  /// 有匹配的 progress.json 则恢复其进度；否则按磁盘实际文件数统计，
  /// 让"重进后整本缓存为 0"不再发生——已有缓存始终可见、可续传。
  Future<void> restoreFromDisk() async {
    if (_state != 'idle') return;
    final prog = await store.loadProgress();
    if (prog != null && prog.total > 0) {
      _fromChapter = prog.fromChapter;
      _fromOffset = prog.fromOffset;
      await _buildTasks(fromChapter: _fromChapter, fromOffset: _fromOffset);
      if (prog.total == _total) {
        _done = prog.done.clamp(0, _total);
        _completed
          ..clear()
          ..addAll(prog.completed.where((i) => i >= 0 && i < _total));
        _state = prog.state == 'done' ? 'done' : 'paused';
        _next = 0;
        while (_next < _total && _completed.contains(_next)) {
          _next++;
        }
        _notify();
        return;
      }
      // total 不匹配（书重解析/起点变化）：progress 作废，落回磁盘扫描
    } else {
      await _buildTasks();
    }
    var n = 0;
    final names = await store.listMp3Names();
    for (var i = 0; i < _tasks.length; i++) {
      final (ci, off, _) = _tasks[i];
      final fn = '${ci.toString().padLeft(4, '0')}_'
          '${off.toString().padLeft(8, '0')}.mp3';
      if (names.contains(fn)) {
        n++;
        _completed.add(i);
      }
    }
    _done = n;
    _state = n > 0 ? 'paused' : 'idle';
    _next = 0;
    _notify();
  }

  Future<void> _initAndRun({required bool resume}) async {
    if (_total == 0) {
      _state = 'done';
      _save();
      _notify();
      return;
    }
    if (resume) {
      final prog = await store.loadProgress();
      if (prog != null && prog.total == _total) {
        _done = prog.done.clamp(0, _total);
        _completed
          ..clear()
          ..addAll(prog.completed.where((i) => i >= 0 && i < _total));
        // 校验：标记完成但文件实际缺失的任务剔除（断网/失败误标，允许补齐）
        final bad = <int>[];
        for (final idx in _completed) {
          final (ci, off, _) = _tasks[idx];
          if (!await store.exists(ci, off)) bad.add(idx);
        }
        for (final idx in bad) {
          _completed.remove(idx);
          if (_done > 0) _done--;
        }
        _next = 0;
        while (_next < _total && _completed.contains(_next)) {
          _next++;
        }
        if (_next >= _total) {
          _state = 'done';
          _save();
          _notify();
          return;
        }
      } else {
        _done = 0;
        _next = 0;
        _completed.clear();
      }
    } else {
      _done = 0;
      _next = 0;
      _completed.clear();
    }
    _state = 'caching';
    _notify();
    _spawnWorkers();
  }

  void pause() {
    if (_state != 'caching') return;
    _paused = true;
    _state = 'paused';
    _save();
    _notify();
  }

  void resume() {
    if (_state != 'paused') return;
    _paused = false;
    _state = 'caching';
    _notify();
    _spawnWorkers();
  }

  void cancel() {
    _cancelled = true;
    _paused = false;
    _state = 'cancelled';
    _save();
    _notify();
  }

  void _spawnWorkers() {
    _aliveWorkers = workerCount;
    for (var i = 0; i < workerCount; i++) {
      unawaited(_worker());
    }
  }

  Future<void> _worker() async {
    while (true) {
      if (_cancelled) {
        _finalizeWorker();
        return;
      }
      if (_paused) {
        _finalizeWorker();
        return;
      }
      final idx = _next++;
      if (idx >= _total) break;
      if (_completed.contains(idx)) continue;
      final (ci, off, text) = _tasks[idx];
      if (await store.exists(ci, off)) {
        _markDone(idx);
        continue;
      }
      final Uint8List audio;
      List<SpeechWord> words = [];
      try {
        audio = await edgeSynth(
          text,
          voice: store.voice,
          rate: edgeRateStr(store.rate),
          onWords: (value) => words = value,
        );
      } catch (_) {
        continue; // 网络/合成失败：不标记完成，留待续传重试
      }
      if (audio.isEmpty) continue;
      await store.write(ci, off, audio, words: words);
      _markDone(idx);
    }
    _finalizeWorker();
  }

  void _markDone(int idx) {
    _completed.add(idx);
    _done++;
    if (_done - _lastSave >= saveInterval) {
      _lastSave = _done;
      _save();
      _notify();
    }
  }

  void _finalizeWorker() {
    _aliveWorkers--;
    if (_aliveWorkers > 0) return;
    // 最后一个 worker 退出：判定终态（单 isolate 内同步检查，无竞态）
    if (_cancelled) return;
    if (_done >= _total) {
      _state = 'done';
    } else if (_state == 'caching' || _state == 'building') {
      // 有任务因合成失败未完成：转暂停，进度保留，可续传补齐
      _state = 'paused';
    }
    _save();
    _notify();
  }

  void _save() {
    store.saveProgress(
      total: _total,
      done: _done,
      completed: _completed,
      state: _state,
      fromChapter: _fromChapter,
      fromOffset: _fromOffset,
    );
  }

  void _notify() {
    final st = status;
    statusNotifier.value = st;
    onProgress?.call(st);
  }
}

/// 全局进行中的全书缓存任务（按 bookId 索引）。
/// 退出阅读页后任务继续在后台跑，重进页面复用同一实例续绑进度。
final Map<String, BookCacheTask> activeBookCaches = {};
