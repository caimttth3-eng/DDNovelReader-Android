import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../models/book.dart';
import '../models/progress.dart';
import '../services/app_storage.dart';
import '../services/edge_tts.dart';
import '../services/tts_audio_handler.dart';
import '../services/tts_reader.dart';

/// 打原生日志（release 下 debugPrint 不输出，走 MethodChannel 到 logcat）
void _debugLog(String msg) {
  try {
    const MethodChannel('com.ddnovelreader/debug_log')
        .invokeMethod('log', msg);
  } catch (_) {}
}

/// 阅读页：全屏沉浸式阅读 + 三区点击翻页 + TTS 朗读高亮 + 进度条 + 章节悬浮球。
///
/// 采用"扁平段落列表"渲染全书：每个段落是一个 item，
/// 章节标题作为分隔 item。滚动即翻页；点击上/下区滚动一屏；点中区弹控制 UI。
class ReaderScreen extends StatefulWidget {
  final Book book;
  final AppStorage storage;
  final BookProgress? initialProgress;
  final Future<void> Function(BookProgress p)? onProgressChanged;

  const ReaderScreen({
    super.key,
    required this.book,
    required this.storage,
    this.initialProgress,
    this.onProgressChanged,
  });

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

/// 扁平 item：章节标题 或 句子（段落拆为句子级，便于高亮跟随滚动）
/// 书页背景主题
class BookTheme {
  final String name;
  final Color bg;
  final Color text;
  final Color title;
  const BookTheme({required this.name, required this.bg, required this.text, required this.title});
}

const List<BookTheme> _bookThemes = [
  BookTheme(name: '羊皮纸', bg: Color(0xFFF5EFE0), text: Color(0xFF3A2E1E), title: Color(0xFF5D3A1A)),
  BookTheme(name: '护眼绿', bg: Color(0xFFC7EDCC), text: Color(0xFF1F3A1F), title: Color(0xFF2D5A2D)),
  BookTheme(name: '夜间黑', bg: Color(0xFF1A1A1A), text: Color(0xFFBBBBBB), title: Color(0xFFDDDDDD)),
  BookTheme(name: '纯白', bg: Color(0xFFFFFFFF), text: Color(0xFF333333), title: Color(0xFF555555)),
  BookTheme(name: '浅灰', bg: Color(0xFFEDEDED), text: Color(0xFF333333), title: Color(0xFF555555)),
  BookTheme(name: '复古棕', bg: Color(0xFFE8D5B7), text: Color(0xFF4A3728), title: Color(0xFF6B4A2A)),
];

class _Item {
  final bool isTitle;
  final int chapterIndex;
  final int paragraphIndex; // 仅当 !isTitle
  final int sentenceIndex; // 仅当 !isTitle，段内句子索引
  final String title; // 仅当 isTitle
  final bool isParaStart; // 段落首句（用于段间距）
  const _Item.title(this.chapterIndex, this.title)
      : isTitle = true,
        paragraphIndex = -1,
        sentenceIndex = -1,
        isParaStart = false;
  const _Item.sentence(this.chapterIndex, this.paragraphIndex, this.sentenceIndex,
      {this.isParaStart = false})
      : isTitle = false,
        title = '';
}

class _ReaderScreenState extends State<ReaderScreen> {
  late final TtsReader _tts;
  late final List<_Item> _items;
  final ItemScrollController _itemScrollController = ItemScrollController();
  final ItemPositionsListener _itemPositionsListener =
      ItemPositionsListener.create();

  ReadingSettings _settings = ReadingSettings();
  bool _settingsLoaded = false;

  // 控制 UI 显隐
  bool _showControls = true;

  // 朗读模式（全屏播放/暂停，顶栏隐藏，暂停时底部弹控制面板）
  bool _inReadingMode = false;
  bool _showReadingPanel = false;

  // 定时播放
  Timer? _sleepTimer;
  int _sleepMinutes = 0; // 0=未设置

  // 音量键操作提示条（开始播放时短暂提示）
  Timer? _volumeTipTimer;
  bool _volumeTipVisible = false;

  // 当前阅读位置（章节/段落）
  int _chapter = 0;
  int _para = 0;
  // 当前 TTS 句子索引（-1 表示未在朗读）
  int _ttsSentence = -1;
  bool _isPlaying = false;
  // TTS 正在朗读的章节（与 _chapter 可能因滚动不同步）
  int _ttsChapter = 0;
  // TTS 合成加载中（点击播放/恢复后等待首句出声；期间防误触）
  bool _ttsLoading = false;
  Timer? _ttsLoadingTimer;

  // 系统媒体音量（音量键被 TTS 上下句占用，暂停面板提供滑条调节）
  double _mediaVolume = 1.0;

  // 假锁屏（保持 app 前台，蓝牙耳机键可控；长按 2 秒解锁）
  bool _fakeLock = false;
  Timer? _lockTimer;
  bool _lockPressing = false;

  // 跳转逼近计数（防震荡死循环）
  int _approaches = 0;
  bool _suppressScrollTrack = false;
  bool _scrollThrottle = false;
  int? _pendingScrollIndex; // 待跳转 item，渲染出真实高度后校正视口

  // 全屏朗读拖动 seek 状态（字符位置线性定位，与书长无关）
  bool _dragging = false;
  int _dragCharPos = 0; // 拖动累计字符位置
  static const double _charsPerPixel = 2.0; // 每像素对应字数（满屏约 4800 字 ≈ 一章）
  List<int> _itemCharPrefix = [0]; // 每个 item 的 display 字符前缀和（用于 O(log n) 按字定位）

  // 章节 display 长度前缀和（用于 O(log n) 定位进度，避免每次全扫全书）
  List<int> _chapterPrefix = [0];

  // 查找结果
  List<_SearchHit> _searchHits = [];
  int _searchIndex = 0;
  String _searchQuery = '';

  Timer? _saveDebounce;

  double get _fontSize => _settings.fontSize;
  double get _lineHeight => _settings.lineHeight;
  BookTheme get _theme => _bookThemes[_settings.themeIndex.clamp(0, _bookThemes.length - 1)];

  @override
  void initState() {
    super.initState();
    _tts = TtsReader();
    _tts.onSentenceChanged = _onTtsSentenceChanged;
    _tts.onCompleted = _onTtsCompleted;
    _tts.onError = _onTtsError;
    _items = _flatten(widget.book);
    _initLocate();
    _initCharPrefix();
    _itemPositionsListener.itemPositions.addListener(_onScroll);
    // 音量键逐句控制（原生 MethodChannel）
    _volumeChannel.setMethodCallHandler(_onVolumeKey);
    // 绑定全局 audio_service 回调（耳机播放键）
    globalAudioHandler?.onPlayRequested = _onHeadsetPlay;
    globalAudioHandler?.onPauseRequested = _onHeadsetPause;
    globalAudioHandler?.onStopRequested = _onHeadsetStop;
    globalAudioHandler?.onCustomResumeRequested = _onCustomResume;
    _loadSettings();
    // 记录最后阅读的书籍，下次启动直接恢复
    widget.storage.saveLastBookId(widget.book.id);
    // 读取系统媒体音量用于暂停面板滑条
    _loadMediaVolume();
  }

  static const _volumeChannel =
      MethodChannel('com.ddnovelreader/volume_keys');

  /// 原生音量键回调：上=上一句，下=下一句
  Future<dynamic> _onVolumeKey(MethodCall call) async {
    if (!_isPlaying || _showControls) return;
    switch (call.method) {
      case 'volumeUp':
        _prevSentence();
        break;
      case 'volumeDown':
        _nextSentence();
        break;
    }
  }

  /// 耳机播放键：未进入→开始，播放中→暂停，暂停中→恢复
  void _onHeadsetPlay() {
    print('SCREEN onHeadsetPlay ttsState=${_tts.state} reading=$_inReadingMode loading=$_ttsLoading');
    _debugLog('SCREEN onHeadsetPlay state=${_tts.state} reading=$_inReadingMode');
    if (!mounted) return;
    if (!_inReadingMode) {
      _play();
    } else if (_tts.state == TtsState.playing) {
      _pauseReading();
    } else {
      // paused / stopped / idle 一律尝试恢复（_resumeReading 内部处理）
      _resumeReading();
    }
  }

  /// 自定义"继续播放"按钮（通知栏），绕开系统 play 路由问题
  void _onCustomResume() {
    _debugLog('SCREEN onCustomResume state=${_tts.state}');
    if (!mounted) return;
    if (_tts.state == TtsState.playing) return;
    _resumeReading();
  }

  void _onHeadsetPause() {
    print('SCREEN onHeadsetPause ttsState=${_tts.state}');
    _debugLog('SCREEN onHeadsetPause state=${_tts.state}');
    if (!mounted) return;
    if (_tts.state == TtsState.playing) {
      _pauseReading();
    } else {
      // 状态已非播放但 MediaSession 可能仍显示暂停按钮：
      // 同步状态，避免用户点"暂停"（实际想继续）时按钮图标错乱无反应
      globalAudioHandler?.notifyPaused();
    }
  }

  void _onHeadsetStop() {
    if (!mounted) return;
    _exitReadingMode();
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    // 退出前确保最后一次进度写入（防抖可能未触发）
    _saveProgress();
    _sleepTimer?.cancel();
    _exitFullscreen();
    // 恢复系统默认系统栏样式（书架页浅色背景使用深色图标）
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.dark,
    ));
    _tts.dispose();
    _itemPositionsListener.itemPositions.removeListener(_onScroll);
    _volumeChannel.setMethodCallHandler(null);
    _volumeChannel.invokeMethod('setVolumeKeysEnabled', false);
    // 解绑耳机回调并停止 MediaSession（handler 实例保留供下次进入复用）
    globalAudioHandler?.onPlayRequested = null;
    globalAudioHandler?.onPauseRequested = null;
    globalAudioHandler?.onStopRequested = null;
    globalAudioHandler?.onCustomResumeRequested = null;
    globalAudioHandler?.stop();
    super.dispose();
  }
  // ---------- 数据 ----------

  List<_Item> _flatten(Book book) {
    final list = <_Item>[];
    for (var c = 0; c < book.chapters.length; c++) {
      final ch = book.chapters[c];
      list.add(_Item.title(c, ch.title));
      for (var p = 0; p < ch.paragraphs.length; p++) {
        final para = ch.paragraphs[p];
        for (var s = 0; s < para.sentences.length; s++) {
          list.add(_Item.sentence(c, p, s, isParaStart: s == 0));
        }
        // 空段落兜底：加一个空句子 item 保持段落结构
        if (para.sentences.isEmpty) {
          list.add(_Item.sentence(c, p, 0, isParaStart: true));
        }
      }
    }
    return list;
  }

  int _itemIndexOf(int chapter, int para, [int sentence = 0]) {
    for (var i = 0; i < _items.length; i++) {
      final it = _items[i];
      if (!it.isTitle &&
          it.chapterIndex == chapter &&
          it.paragraphIndex == para &&
          it.sentenceIndex == sentence) {
        return i;
      }
    }
    // 兜底：找该段第一个句子
    for (var i = 0; i < _items.length; i++) {
      final it = _items[i];
      if (!it.isTitle && it.chapterIndex == chapter && it.paragraphIndex == para) {
        return i;
      }
    }
    return 0;
  }

  // ---------- 设置 ----------

  Future<void> _loadSettings() async {
    final raw = await widget.storage.loadSettings();
    _settings = ReadingSettings.fromJson(raw);
    await _tts.setSpeechRate(_settings.speechRate);
    if (_settings.voice.isNotEmpty) _tts.setVoice(_settings.voice);
    setState(() => _settingsLoaded = true);

    // 恢复进度
    final p = widget.initialProgress ??
        BookProgress(bookId: widget.book.id);
    _chapter = p.chapterIndex;
    _para = p.paragraphIndex;
    if (_chapter >= widget.book.chapters.length) _chapter = 0;
    if (_para >= widget.book.chapters[_chapter].paragraphs.length) _para = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _jumpToItem(_itemIndexOf(_chapter, _para), animate: false);
    });
  }

  Future<void> _saveProgress() async {
    final p = BookProgress(
      bookId: widget.book.id,
      chapterIndex: _chapter,
      paragraphIndex: _para,
      offsetInParagraph: 0,
      percent: widget.book.progressRatio(_chapter, _para),
    );
    await widget.onProgressChanged?.call(p);
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 400), _saveProgress);
  }

  // ---------- 滚动/翻页 ----------

  void _jumpToItem(int index, {bool animate = true}) {
    if (index < 0 || index >= _items.length) return;
    if (!_itemScrollController.isAttached) {
      // 列表尚未布局：下一帧重试，确保恢复/跳转真正生效
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _jumpToItem(index, animate: animate);
      });
      return;
    }
    // 用 scrollable_positioned_list 按 index 定位（itemExtentBuilder 估算高度）
    _pendingScrollIndex = index;
    _approaches = 0;
    if (animate) {
      _itemScrollController
          .scrollTo(
            index: index,
            alignment: 0,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          )
          .whenComplete(() {
        if (mounted) _maybeCorrectScroll();
      });
    } else {
      _itemScrollController.jumpTo(index: index, alignment: 0);
      // 渲染出真实高度后校正视口（估算偏差时二次 jumpTo 收敛）
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _maybeCorrectScroll();
      });
    }
  }

  /// 跳转后校正：用 itemPositions 检查目标 item 是否在视口顶部，
  /// 偏差大则用更新后的 item 尺寸再 jumpTo 一次（有上限防死循环）。
  void _maybeCorrectScroll() {
    final pending = _pendingScrollIndex;
    if (pending == null) return;
    if (!_itemScrollController.isAttached) return;
    _approaches++;
    if (_approaches > 5) {
      _pendingScrollIndex = null;
      _approaches = 0;
      return;
    }
    final positions = _itemPositionsListener.itemPositions.value;
    ItemPosition? target;
    for (final p in positions) {
      if (p.index == pending) {
        target = p;
        break;
      }
    }
    if (target == null) {
      // 目标 item 尚未渲染：再 jumpTo 一次让其渲染，下帧复查
      _itemScrollController.jumpTo(index: pending, alignment: 0);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _maybeCorrectScroll();
      });
      return;
    }
    final leading = target.itemLeadingEdge;
    if (leading.abs() > 0.02) {
      // 目标不在视口顶部：用更新后的 item 尺寸再跳一次收敛
      _itemScrollController.jumpTo(index: pending, alignment: 0);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _maybeCorrectScroll();
      });
      return;
    }
    _pendingScrollIndex = null;
    _approaches = 0;
  }

  void _pageUp() {
    final current = _itemIndexOf(_chapter, _para);
    // 向上翻一屏：跳到当前 item 前若干屏
    final target = (current - 5).clamp(0, _items.length - 1);
    _jumpToItem(target);
    _updatePositionFromItem(target);
  }

  void _pageDown() {
    final current = _itemIndexOf(_chapter, _para);
    final target = (current + 5).clamp(0, _items.length - 1);
    _jumpToItem(target);
    _updatePositionFromItem(target);
  }

  void _updatePositionFromItem(int index) {
    final it = _items[index];
    if (it.isTitle) return;
    if (it.chapterIndex != _chapter ||
        it.paragraphIndex != _para ||
        it.sentenceIndex != _ttsSentence) {
      setState(() {
        _chapter = it.chapterIndex;
        _para = it.paragraphIndex;
        _ttsSentence = it.sentenceIndex;
      });
      _scheduleSave();
    }
  }

  void _onScroll() {
    // 程序化跳转（章节/进度条/TTS 高亮）期间不覆盖正确位置；
    // 拖动 seek 期间由拖动逻辑控制位置。
    // TTS 朗读期间位置由 TTS 句子主导（_onTtsSentenceChanged），
    // 禁止 onScroll 覆盖，否则高亮会错位到视口顶部 item。
    if (_suppressScrollTrack || _dragging || _isPlaying) return;
    if (_scrollThrottle) return;
    _scrollThrottle = true;
    Timer(const Duration(milliseconds: 60), () => _scrollThrottle = false);
    final positions = _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return;
    // 取视口顶部可见 item
    ItemPosition? top;
    for (final p in positions) {
      if (p.itemLeadingEdge < 1 && p.itemTrailingEdge > 0) {
        if (top == null || p.itemLeadingEdge < top.itemLeadingEdge) {
          top = p;
        }
      }
    }
    if (top == null) return;
    final idx = top.index;
    if (idx < 0 || idx >= _items.length) return;
    final it = _items[idx];
    if (it.isTitle) {
      // 章节标题处：定位到该章第一段
      if (it.chapterIndex != _chapter || _para != 0) {
        setState(() {
          _chapter = it.chapterIndex;
          _para = 0;
        });
        _scheduleSave();
      }
      return;
    }
    if (it.chapterIndex != _chapter ||
        it.paragraphIndex != _para ||
        it.sentenceIndex != _ttsSentence) {
      setState(() {
        _chapter = it.chapterIndex;
        _para = it.paragraphIndex;
        _ttsSentence = it.sentenceIndex;
      });
      _scheduleSave();
    }
  }

  /// 报告 item 实际渲染高度。scrollable_positioned_list 自管 item 定位，
  /// 这里仅用渲染回调驱动跳转后校正（itemPositions 二次收敛）。
  void _recordHeight(int index, double height) {
    _maybeCorrectScroll();
  }

  // ---------- TTS ----------

  /// 当前章节全部句子的 tts 文本（用于 TtsReader 整章朗读）
  List<String> _chapterTtsSentences(int c) {
    final out = <String>[];
    if (c < 0 || c >= widget.book.chapters.length) return out;
    for (final p in widget.book.chapters[c].paragraphs) {
      for (final s in p.sentences) {
        out.add(s.tts);
      }
    }
    return out;
  }

  /// 章节内段落 p 之前的句子总数（TtsReader 的起始索引）
  int _chapterSentenceStart(int c, int p) {
    if (c < 0 || c >= widget.book.chapters.length) return 0;
    var n = 0;
    for (var i = 0; i < p && i < widget.book.chapters[c].paragraphs.length; i++) {
      n += widget.book.chapters[c].paragraphs[i].sentences.length;
    }
    return n;
  }

  /// 视口当前显示的第一个句子位置（进度 = 滑到哪读到哪）
  (int, int, int)? _viewportPosition() {
    final items = _itemPositionsListener.itemPositions.value.toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    if (items.isEmpty) return null;
    final first = items.firstWhere(
      (p) => p.itemLeadingEdge < 1.0 && p.itemTrailingEdge > 0.0,
      orElse: () => items.first,
    );
    final idx = first.index.clamp(0, _items.length - 1);
    final it = _items[idx];
    if (it.isTitle) {
      // 视口停在章节标题：从该章 0 段 0 句开始
      return (it.chapterIndex, 0, 0);
    }
    return (it.chapterIndex, it.paragraphIndex, it.sentenceIndex);
  }

  /// 开始 TTS 加载态：显示 loading，15 秒未出声则超时提示并退出加载态
  void _startTtsLoading() {
    _ttsLoadingTimer?.cancel();
    setState(() => _ttsLoading = true);
    _ttsLoadingTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      setState(() => _ttsLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('语音加载超时，请检查网络后重试')),
        );
      }
    });
  }

  /// 结束 TTS 加载态（首句已开始播放或已退出）
  void _stopTtsLoading() {
    _ttsLoadingTimer?.cancel();
    _ttsLoadingTimer = null;
    if (mounted) setState(() => _ttsLoading = false);
  }

  /// 进入朗读模式：全屏隐藏UI，开始TTS播放
  Future<void> _play() async {
    if (_inReadingMode) return;
    _dragging = false;
    final vp = _captureViewport();
    final delta = _chapterBarTop(); // 进入朗读后顶栏偏移归 0
    // 朗读起点 = 视口当前显示的位置（进度 = 滑到哪读到哪）
    final pos = _viewportPosition();
    final startC = pos?.$1 ?? _chapter;
    final startP = pos?.$2 ?? _para;
    final startS = pos?.$3 ?? (_ttsSentence >= 0 ? _ttsSentence : 0);
    _enterFullscreen();
    setState(() {
      _inReadingMode = true;
      _showControls = false;
      _isPlaying = true;
      _showReadingPanel = false;
      _ttsChapter = startC;
      _chapter = startC;
      _para = startP;
      _ttsSentence = startS;
    });
    _applySystemUi();
    globalAudioHandler?.notifyPlaying();
    _showVolumeTip();
    if (vp != null) _compensateViewport(vp.$1, vp.$2, delta);
    // 从视口当前句子开始朗读（合成首句期间显示 loading）
    _startTtsLoading();
    await _startTtsFrom(startC, startP, startS);
    _stopTtsLoading();
  }

  /// 显示音量键操作提示：立即显现，2.5s 后透明度 500ms 淡出
  void _showVolumeTip() {
    _volumeTipTimer?.cancel();
    setState(() => _volumeTipVisible = true);
    _volumeTipTimer = Timer(const Duration(milliseconds: 2500), () {
      if (!mounted) return;
      setState(() => _volumeTipVisible = false);
    });
  }

  /// 朗读模式中暂停：保留全屏，弹出底部控制面板
  Future<void> _pauseReading() async {
    if (_ttsLoading) return; // 加载中忽略暂停，防误触
    if (_tts.state != TtsState.playing) return;
    await _tts.pause();
    globalAudioHandler?.notifyPaused();
    if (!mounted) return;
    setState(() {
      _isPlaying = false;
      _showReadingPanel = true;
    });
  }

  /// 从暂停恢复播放，隐藏底部面板
  /// - 暂停中滑动跨章：重新加载目标章，从当前句开始播放
  /// - 同章恢复：TtsReader 直接重播当前句；彻底失败时 onError 已触发退出
  Future<void> _resumeReading() async {
    print('SCREEN resumeReading state=${_tts.state} loading=$_ttsLoading');
    _debugLog('SCREEN resumeReading state=${_tts.state}');
    if (_ttsLoading) return; // 加载中忽略恢复，防误触
    if (_tts.state != TtsState.paused) {
      // 状态丢失（stopped/idle，如章节播完/曾失败）：从当前阅读位置重新加载
      if (_tts.state == TtsState.stopped || _tts.state == TtsState.idle) {
        _startTtsLoading();
        await _startTtsFrom(
            _chapter, _para, _ttsSentence >= 0 ? _ttsSentence : 0);
        _stopTtsLoading();
        globalAudioHandler?.notifyPlaying();
        if (!mounted) return;
        setState(() {
          _isPlaying = true;
          _showReadingPanel = false;
        });
      }
      return;
    }
    _startTtsLoading();
    if (_ttsChapter != _chapter) {
      // 暂停期间滑到了其他章节：TtsReader 内部仍是旧章句子，需重新加载
      await _startTtsFrom(
          _chapter, _para, _ttsSentence >= 0 ? _ttsSentence : 0);
      _stopTtsLoading();
      globalAudioHandler?.notifyPlaying();
      if (!mounted) return;
      setState(() {
        _isPlaying = true;
        _showReadingPanel = false;
      });
      return;
    }
    final ok = await _tts.resume();
    _stopTtsLoading();
    if (!ok || !mounted) {
      // 失败且未触发退出：同步 MediaSession 为停止，避免假 playing 状态
      globalAudioHandler?.notifyStopped();
      return;
    }
    globalAudioHandler?.notifyPlaying();
    setState(() {
      _isPlaying = true;
      _showReadingPanel = false;
    });
  }

  /// 彻底退出朗读模式：停止TTS，恢复正常阅读页UI
  Future<void> _exitReadingMode() async {
    final vp = _captureViewport();
    final delta = -_chapterBarTop(); // 退出朗读后顶栏偏移恢复
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepMinutes = 0;
    _volumeTipTimer?.cancel();
    _volumeTipTimer = null;
    _volumeTipVisible = false;
    _ttsLoadingTimer?.cancel();
    _ttsLoadingTimer = null;
    _ttsLoading = false;
    await _tts.stop();
    globalAudioHandler?.notifyStopped();
    _exitFullscreen();
    if (!mounted) return;
    setState(() {
      _inReadingMode = false;
      _showControls = true;
      _isPlaying = false;
      _showReadingPanel = false;
      _ttsSentence = -1;
    });
    _applySystemUi();
    if (vp != null) _compensateViewport(vp.$1, vp.$2, delta);
    _scheduleSave();
  }

  /// 根据当前 UI 状态应用系统栏样式：
  /// - 朗读/全屏模式：immersiveSticky 彻底隐藏状态栏与导航条
  /// - UI 模式：edgeToEdge + 状态栏/导航条与 UI 栏同色(深暖黑)+白色图标，
  ///   系统栏与顶栏/底栏视觉融为一体，无突兀白条
  void _applySystemUi() {
    if (_inReadingMode || !_showControls) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
        statusBarColor: Color(0xFF241F18),
        statusBarIconBrightness: Brightness.light,
        systemStatusBarContrastEnforced: false,
        systemNavigationBarColor: Color(0xFF241F18),
        systemNavigationBarIconBrightness: Brightness.light,
        systemNavigationBarContrastEnforced: false,
        systemNavigationBarDividerColor: Colors.transparent,
      ));
    }
  }

  void _enterFullscreen() {
    _applySystemUi();
    _volumeChannel.invokeMethod('setVolumeKeysEnabled', true);
  }

  void _exitFullscreen() {
    _applySystemUi();
    _volumeChannel.invokeMethod('setVolumeKeysEnabled', false);
  }

  // ---- 全屏朗读：上下滑动快速跳进，语音跟随 ----

  void _onDragSeekStart(DragStartDetails d) {
    _dragging = true;
    _dragCharPos = _currentCharPos; // 基准：当前字符位置
  }

  void _onDragSeekUpdate(DragUpdateDetails d) {
    // 字符线性定位：每像素 _charsPerPixel 字，与整书长度无关，体感一致
    // 方向：上滑 dy<0 → 字符位置减小=快退，下滑 dy>0 → 增大=快进
    final total = _itemCharPrefix.isEmpty ? 0 : _itemCharPrefix.last;
    _dragCharPos =
        (_dragCharPos + (d.delta.dy * _charsPerPixel).round()).clamp(0, total);
    final (c, p, s, itemIdx) = _locateByChar(_dragCharPos);
    if (_chapter != c || _para != p || _ttsSentence != s) {
      setState(() {
        _chapter = c;
        _para = p;
        _ttsSentence = s; // 句子级高亮跟随
      });
      if (_itemScrollController.isAttached) {
        _itemScrollController.jumpTo(index: itemIdx, alignment: 0);
      }
    }
  }

  void _onDragSeekEnd() {
    _dragging = false;
    _ttsFollowSeek(_chapter, _para, _ttsSentence); // 语音跟随到句子
    _scheduleSave();
  }

  /// 让语音跟随到 (c, p, 段内句子s)
  /// 播放中：跨章重新加载整章，同章 jumpTo 当前句
  /// 暂停/未播放：只更新阅读位置，不触发播放；跨章时保持 _ttsChapter
  /// 不变，恢复播放时由 _resumeReading 检测到不一致而重新加载
  void _ttsFollowSeek(int c, int p, int s) {
    if (c < 0 || c >= widget.book.chapters.length) return;
    if (_tts.state == TtsState.paused || !_isPlaying) {
      if (c == _ttsChapter) {
        _tts.jumpTo(_chapterSentenceStart(c, p) + s); // 同章：更新待播索引
      }
      return;
    }
    if (c != _ttsChapter) {
      _startTtsFrom(c, p, s);
    } else {
      _tts.jumpTo(_chapterSentenceStart(c, p) + s);
    }
  }

  Future<void> _startTtsFrom(int c, int p, int s) async {
    if (c >= widget.book.chapters.length) {
      _exitFullscreen();
      setState(() {
        _showControls = true;
        _isPlaying = false;
      });
      return;
    }
    final sentences = _chapterTtsSentences(c);
    if (sentences.isEmpty) {
      // 空章：跳过到下一章
      if (c + 1 < widget.book.chapters.length) {
        setState(() {
          _ttsChapter = c + 1;
          _chapter = c + 1;
          _para = 0;
        });
        await _startTtsFrom(c + 1, 0, 0);
      } else {
        setState(() => _isPlaying = false);
      }
      return;
    }
    final startIdx = _chapterSentenceStart(c, p) + s;
    _ttsChapter = c;
    // 保证播放位置有效
    final from = startIdx.clamp(0, sentences.length - 1);
    setState(() {
      _chapter = c;
      _para = p;
      _ttsSentence = from;
    });
    _jumpToItem(_itemIndexOf(c, p));
    _scheduleSave();
    await _tts.start(sentences, from: from);
  }

  void _onTtsSentenceChanged(int idx) {
    if (!mounted) return;
    if (idx < 0) return;
    // 把 TtsReader 的句子索引映射回 (chapter, para, sIndex)
    final c = _ttsChapter;
    if (c < 0 || c >= widget.book.chapters.length) return;
    var remain = idx;
    int p = 0;
    int s = 0;
    var found = false;
    for (var pi = 0; pi < widget.book.chapters[c].paragraphs.length; pi++) {
      final n = widget.book.chapters[c].paragraphs[pi].sentences.length;
      if (remain < n) {
        p = pi;
        s = remain;
        found = true;
        break;
      }
      remain -= n;
    }
    if (!found) return;
    final changed = (_chapter != c || _para != p || _ttsSentence != s);
    if (changed) {
      setState(() {
        _chapter = c;
        _para = p;
        _ttsSentence = s;
      });
      // 高亮跟随：每次句子变化都滚动到该句子 item，保持在视口 25% 位置
      if (!_dragging && _itemScrollController.isAttached) {
        final idx = _itemIndexOf(c, p, s);
        _itemScrollController.jumpTo(index: idx, alignment: 0.25);
      }
      _scheduleSave();
    }
  }

  void _onTtsCompleted() {
    if (!mounted) return;
    // 本章读完：自动进入下一章继续朗读
    final next = _ttsChapter + 1;
    if (next < widget.book.chapters.length) {
      setState(() {
        _ttsChapter = next;
        _chapter = next;
        _para = 0;
      });
      _jumpToItem(_itemIndexOf(next, 0));
      _scheduleSave();
      _startTtsFrom(next, 0, 0);
    } else {
      _exitReadingMode();
    }
  }

  void _onTtsError() {
    if (!mounted) return;
    _exitReadingMode();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('朗读失败：请检查网络连接')),
    );
  }

  // 上一句 / 下一句
  void _prevSentence() {
    if (_ttsLoading) return; // 加载中忽略，防误触
    if (!_isPlaying) return;
    _tts.prev();
  }

  void _nextSentence() {
    if (_ttsLoading) return; // 加载中忽略，防误触
    if (!_isPlaying) return;
    _tts.next();
  }

  // ---------- 进度条 ----------

  /// 用章节前缀和快速算百分比（O(log n + 章内段数)，避免每次全扫全书）
  double get _percent {
    if (_chapterPrefix.isEmpty || _chapterPrefix.last == 0) return 0;
    if (widget.book.chapters.isEmpty) return 0;
    final c = _chapter.clamp(0, widget.book.chapters.length - 1);
    var before = _chapterPrefix[c];
    final paras = widget.book.chapters[c].paragraphs;
    if (paras.isNotEmpty) {
      final p = _para.clamp(0, paras.length - 1);
      for (var i = 0; i < p; i++) {
        before += paras[i].display.length;
      }
    }
    return (before / _chapterPrefix.last).clamp(0.0, 1.0);
  }

  /// 章节 display 长度前缀和
  void _initLocate() {
    _chapterPrefix = [0];
    var acc = 0;
    for (final c in widget.book.chapters) {
      acc += c.displayLength;
      _chapterPrefix.add(acc);
    }
  }

  /// item 字符前缀和（句子级，用于按字符位置 O(log n) 定位）
  void _initCharPrefix() {
    _itemCharPrefix = [0];
    var acc = 0;
    for (final it in _items) {
      if (it.isTitle) {
        acc += it.title.length;
      } else {
        final para = widget.book.chapters[it.chapterIndex]
            .paragraphs[it.paragraphIndex];
        if (it.sentenceIndex < para.sentences.length) {
          acc += para.sentences[it.sentenceIndex].display.length;
        }
      }
      _itemCharPrefix.add(acc);
    }
  }

  /// 当前阅读位置对应的全局字符偏移（拖动基准）
  int get _currentCharPos {
    if (widget.book.chapters.isEmpty) return 0;
    final c = _chapter.clamp(0, widget.book.chapters.length - 1);
    var pos = _chapterPrefix[c];
    final paras = widget.book.chapters[c].paragraphs;
    if (paras.isEmpty) return pos;
    final p = _para.clamp(0, paras.length - 1);
    for (var i = 0; i < p; i++) {
      pos += paras[i].display.length;
    }
    // 加上当前句子的 display 偏移（_ttsSentence 为段内索引）
    if (_ttsSentence >= 0 && _ttsSentence < paras[p].sentences.length) {
      pos += paras[p].sentences[_ttsSentence].displayStart;
    }
    return pos;
  }

  /// 按全局字符偏移定位 → (章节, 段落, 章内句子索引, item索引)，句子级精度
  (int chapter, int para, int sentence, int itemIndex) _locateByChar(
      int charPos) {
    if (_itemCharPrefix.length <= 1 || widget.book.chapters.isEmpty) {
      return (0, 0, 0, 0);
    }
    final total = _itemCharPrefix.last;
    charPos = charPos.clamp(0, total);
    // 二分定位 item
    var lo = 0, hi = _items.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_itemCharPrefix[mid + 1] <= charPos) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final itemIdx = lo;
    final it = _items[itemIdx];
    if (it.isTitle) {
      // 落在标题上：定位到该章第一句
      final c = it.chapterIndex;
      final nextIdx = (itemIdx + 1 < _items.length) ? itemIdx + 1 : itemIdx;
      return (c, 0, 0, nextIdx);
    }
    final c = it.chapterIndex;
    final p = it.paragraphIndex;
    final sInPara = it.sentenceIndex;
    return (c, p, sInPara, itemIdx);
  }

  void _seekTo(double ratio) {
    final (c, p) = _locateByRatio(ratio);
    setState(() {
      _chapter = c;
      _para = p;
    });
    _jumpToItem(_itemIndexOf(c, p));
    _scheduleSave();
  }

  /// 按全局比例定位 (章节, 段落)：章节前缀二分 + 章内线性（O(log n + 章内段数)）
  (int, int) _locateByRatio(double ratio) {
    if (widget.book.chapters.isEmpty) return (0, 0);
    final total = _chapterPrefix.isEmpty ? 0 : _chapterPrefix.last;
    if (total <= 0) return (0, 0);
    var target = ratio.clamp(0.0, 1.0) * total;
    // 二分定位章节：找 _chapterPrefix[c] <= target < _chapterPrefix[c+1]
    var lo = 0, hi = widget.book.chapters.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_chapterPrefix[mid + 1] <= target) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final c = lo;
    var remain = target - _chapterPrefix[c];
    final paras = widget.book.chapters[c].paragraphs;
    if (paras.isEmpty) return (c, 0);
    for (var p = 0; p < paras.length; p++) {
      remain -= paras[p].display.length;
      if (remain <= 0) return (c, p);
    }
    return (c, paras.length - 1);
  }

  // ---------- 查找 ----------

  Future<void> _openSearch() async {
    final query = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final ctrl = TextEditingController(text: _searchQuery);
        return AlertDialog(
          title: const Text('查找'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(hintText: '输入要查找的文字'),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, null),
                child: const Text('取消')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
                child: const Text('查找')),
          ],
        );
      },
    );
    if (query == null || query.isEmpty) return;
    setState(() {
      _searchQuery = query;
    });
    final hits = <_SearchHit>[];
    for (var c = 0; c < widget.book.chapters.length; c++) {
      final ch = widget.book.chapters[c];
      for (var p = 0; p < ch.paragraphs.length; p++) {
        final text = ch.paragraphs[p].display;
        var idx = text.indexOf(query);
        while (idx >= 0 && hits.length < 200) {
          hits.add(_SearchHit(c, p, idx, query.length));
          idx = text.indexOf(query, idx + query.length);
        }
        if (hits.length >= 200) break;
      }
      if (hits.length >= 200) break;
    }
    setState(() {
      _searchHits = hits;
      _searchIndex = 0;
    });
    if (hits.isNotEmpty) {
      _gotoSearchHit(0);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未找到匹配内容')),
      );
    }
  }

  void _gotoSearchHit(int i) {
    if (i < 0 || i >= _searchHits.length) return;
    final h = _searchHits[i];
    setState(() {
      _chapter = h.chapter;
      _para = h.para;
      _searchIndex = i;
    });
    _jumpToItem(_itemIndexOf(h.chapter, h.para));
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    if (!_settingsLoaded) {
      return const Scaffold(
          body: Center(child: CircularProgressIndicator()));
    }
    return PopScope(
      canPop: !_fakeLock,
      child: Scaffold(
        backgroundColor: _theme.bg,
        body: Stack(
        children: [
          // 正文区（不分层）：整体下移「两行半空白 + 标题行」高度，
          // 章节标题 Positioned 固定在正文区顶部，正文列表在标题下方独立滚动
          Padding(
            padding: EdgeInsets.only(top: _chapterBarTop() + _chapterTopArea()),
            child: _buildBody(),
          ),
          // 固定章节标题：位于顶部两行半空白之后，正文滚动时保持不动
          Positioned(
            top: _chapterBarTop() + _fontSize * _lineHeight * 2.5,
            left: 0,
            right: 0,
            child: _buildChapterHeader(),
          ),
          // 三区点击层
          _buildTapZones(),
          // 拖动 seek 预览浮层
          if (_dragging) _buildDragPreview(),
          // 朗读模式底部控制面板（暂停时显示）
          if (_inReadingMode && _showReadingPanel) _buildReadingPanel(),
          // 顶部控制栏
          if (_showControls) _buildTopBar(),
          // 底部进度条
          if (_showControls) _buildBottomBar(),
          // 章节悬浮球
          if (_showControls) _buildFloatingChapter(),
          // 查找结果浮动条
          if (_showControls && _searchHits.isNotEmpty) _buildSearchBar(),
          // 音量键操作提示条（开始播放时短暂提示，2.5s 后淡出）
          if (_inReadingMode) _buildVolumeTip(),
          // TTS 加载中浮层（朗读模式点击恢复播放时显示）
          if (_inReadingMode && _ttsLoading) _buildTtsLoadingOverlay(),
            // 亮度遮罩
            _buildBrightnessOverlay(),
            // 假锁屏（最顶层，覆盖一切；长按 2 秒解锁）
            if (_fakeLock) _buildFakeLock(),
          ],
        ),
      ),
    );
  }

  /// TTS 加载中浮层：屏幕中央转圈 + 提示文字（点击播放/恢复后等待首句）
  Widget _buildTtsLoadingOverlay() {
    return Positioned.fill(
      child: IgnorePointer(
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.6, color: Color(0xFFE8C87A)),
                ),
                SizedBox(height: 12),
                Text('正在加载语音…',
                    style: TextStyle(color: Colors.white, fontSize: 14)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 音量键操作提示条：屏幕中下部半透明圆角胶囊，2.5s 后透明度淡出
  Widget _buildVolumeTip() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: MediaQuery.of(context).size.height * 0.22,
      child: IgnorePointer(
        child: Center(
          child: AnimatedOpacity(
            opacity: _volumeTipVisible ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeOut,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(24),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.volume_up, color: Colors.white70, size: 18),
                  SizedBox(width: 8),
                  Text(
                    '音量键：上=上一句  下=下一句',
                    style: TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 章节标题行文案：标题已含"第X章/Chapter"则原样，否则加章节序号
  String _chapterBarTitle(int c) {
    if (c < 0 || c >= widget.book.chapters.length) return '';
    final t = widget.book.chapters[c].title.trim();
    if (t.startsWith('第') ||
        t.toLowerCase().startsWith('chapter') ||
        t.startsWith('序') ||
        t.startsWith('楔')) {
      return t;
    }
    return '第${c + 1}章 $t';
  }

  /// 章节标题行距屏幕顶的偏移：UI模式在顶栏下方，全屏/朗读在屏幕顶
  double _chapterBarTop() {
    if (_showControls) {
      return MediaQuery.of(context).padding.top + 56;
    }
    return 0;
  }

  /// 正文区固定顶部高度：两行半空白 + 标题栏一行
  double _chapterTopArea() => _fontSize * _lineHeight * 3.5;

  /// 捕获当前视口状态：首可见 item 的 index + 其在视口内的像素偏移（相对视口顶）
  /// 用于模式切换后补偿滚动位置，保证正文文字屏幕位置不变
  (int, double)? _captureViewport() {
    final items = _itemPositionsListener.itemPositions.value.toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    if (items.isEmpty) return null;
    final first = items.firstWhere(
      (p) => p.itemLeadingEdge < 1.0 && p.itemTrailingEdge > 0.0,
      orElse: () => items.first,
    );
    final H = MediaQuery.of(context).size.height -
        _chapterBarTop() -
        _chapterTopArea();
    return (first.index, first.itemLeadingEdge * H);
  }

  /// 模式切换后补偿滚动位置：让首可见 item 的屏幕位置不变
  /// beforePx = 切换前 item 距视口顶的像素；delta = 顶栏偏移变化量(旧-新)
  void _compensateViewport(int index, double beforePx, double delta) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final H = MediaQuery.of(context).size.height -
          _chapterBarTop() -
          _chapterTopArea();
      if (H <= 0) return;
      final newPx = beforePx + delta;
      final align = (newPx / H).clamp(0.0, 1.0);
      _itemScrollController.jumpTo(index: index, alignment: align);
    });
  }

  /// 章节标题栏：固定在正文区顶部（正文区布局的一部分，非悬浮），
  /// 位于顶部两行半空白之后，一行高显示章节名，
  /// 滚动/朗读切换章节时实时跟随（_chapter 变化触发重建）
  Widget _buildChapterHeader() {
    return Container(
      height: _fontSize * _lineHeight,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: _theme.bg,
        border: Border(
          bottom: BorderSide(
            color: _theme.title.withValues(alpha: 0.18),
          ),
        ),
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          _chapterBarTitle(_chapter),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: _fontSize * 0.85,
            fontWeight: FontWeight.w600,
            color: _theme.title,
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    return ScrollablePositionedList.builder(
      itemScrollController: _itemScrollController,
      itemPositionsListener: _itemPositionsListener,
      // 全屏模式（隐藏UI）可滑动；UI模式禁滚，统一用点击三区翻页
      physics: _showControls
          ? const NeverScrollableScrollPhysics()
          : null,
      // 增大缓存区：跳转后能渲染更多 item，加速精确定位
      minCacheExtent: 1500,
      // 顶部留白由 Column 的标题栏承担；底部留 120 给进度条/朗读面板
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
      itemCount: _items.length,
      itemBuilder: (ctx, i) {
        final it = _items[i];
        final Widget child;
        if (it.isTitle) {
          child = Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              it.title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: _fontSize + 6,
                fontWeight: FontWeight.bold,
                color: _theme.title,
                height: _lineHeight,
              ),
            ),
          );
        } else {
          final para = widget.book.chapters[it.chapterIndex]
              .paragraphs[it.paragraphIndex];
          final isCurrent = it.chapterIndex == _chapter &&
              it.paragraphIndex == _para &&
              it.sentenceIndex == _ttsSentence;
          final sentenceText = (it.sentenceIndex < para.sentences.length)
              ? para.sentences[it.sentenceIndex].display
              : '';
          child = Padding(
            padding: EdgeInsets.only(
              top: it.isParaStart ? 10 : 2,
              bottom: 2,
            ),
            child: Text(
              sentenceText,
              style: TextStyle(
                fontSize: _fontSize,
                height: _lineHeight,
                color: _theme.text,
                backgroundColor:
                    isCurrent ? const Color(0x44FFC107) : null,
                fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          );
        }
        return _HeightReporter(
          onHeight: (h) => _recordHeight(i, h),
          child: child,
        );
      },
    );
  }

  /// 拖动 seek 时的位置预览浮层
  Widget _buildDragPreview() {
    final c = _chapter.clamp(0, widget.book.chapters.length - 1);
    final ch = widget.book.chapters[c];
    final sentenceNo = _ttsSentence >= 0 ? _ttsSentence + 1 : 1;
    final pct = (_percent * 100).toStringAsFixed(1);
    return Positioned(
      top: MediaQuery.of(context).size.height * 0.15,
      left: 40,
      right: 40,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: const Color(0xEE2B1D10),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                ch.title,
                style: const TextStyle(
                    color: Color(0xFFE8D5B7),
                    fontSize: 16,
                    fontWeight: FontWeight.w600),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              Text(
                '第 $sentenceNo 句 · $pct%',
                style:
                    const TextStyle(color: Color(0xFFC9A96E), fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- 朗读模式底部控制面板 ----------

  Widget _buildReadingPanel() {
    final rate = _settings.speechRate;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 14,
          bottom: MediaQuery.of(context).padding.bottom + 14,
        ),
        decoration: const BoxDecoration(
          color: Color(0xEE2B1D10),
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 音量调节行（音量键被 TTS 上下句占用，暂停时用滑条调节）
              Row(
                children: [
                  const Icon(Icons.volume_down, color: Color(0xFFC9A96E), size: 20),
                  Expanded(
                    child: Slider(
                      value: _mediaVolume.clamp(0.0, 1.0),
                      min: 0.0,
                      max: 1.0,
                      activeColor: const Color(0xFFC9A96E),
                      inactiveColor: const Color(0x44C9A96E),
                      onChanged: _setMediaVolume,
                    ),
                  ),
                  const Icon(Icons.volume_up, color: Color(0xFFC9A96E), size: 20),
                ],
              ),
              const SizedBox(height: 2),
              // 语速调节行
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline,
                        color: Color(0xFFC9A96E)),
                    onPressed: () => _adjustRate(-0.1),
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        Text(
                          '语速 ${rate.toStringAsFixed(1)}x',
                          style: const TextStyle(
                              color: Color(0xFFC9A96E), fontSize: 12),
                        ),
                        Slider(
                          value: rate.clamp(0.5, 3.0),
                          min: 0.5,
                          max: 3.0,
                          divisions: 25,
                          activeColor: const Color(0xFFC9A96E),
                          inactiveColor: const Color(0x44C9A96E),
                          onChanged: (v) => _setRate(v),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline,
                        color: Color(0xFFC9A96E)),
                    onPressed: () => _adjustRate(0.1),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              // 功能按钮行
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _panelButton(
                    icon: Icons.alarm,
                    label: _sleepMinutes > 0 ? '${_sleepMinutes}分' : '定时',
                    onTap: _openSleepTimer,
                    active: _sleepMinutes > 0,
                  ),
                  _panelButton(
                    icon: Icons.record_voice_over,
                    label: '音源',
                    onTap: _openVoiceSelector,
                  ),
                  _panelButton(
                    icon: Icons.lock_outline,
                    label: '锁屏',
                    onTap: _enterFakeLock,
                  ),
                  _panelButton(
                    icon: Icons.power_settings_new,
                    label: '退出',
                    onTap: _exitReadingMode,
                  ),
                ],
              ),
            ],
          ),
      ),
    );
  }

  Widget _panelButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool active = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon,
              color: active ? const Color(0xFFE8C87A) : const Color(0xFFC9A96E),
              size: 26),
          const SizedBox(height: 4),
          Text(label,
              style: TextStyle(
                  color: active
                      ? const Color(0xFFE8C87A)
                      : const Color(0xFFA89060),
                  fontSize: 11)),
        ],
      ),
    );
  }

  /// 读取当前系统媒体音量（0.0~1.0）
  Future<void> _loadMediaVolume() async {
    try {
      final v = await _volumeChannel.invokeMethod<double>('getMediaVolume');
      if (v != null && mounted) setState(() => _mediaVolume = v.clamp(0.0, 1.0));
    } catch (_) {}
  }

  /// 设置系统媒体音量（音量键被 TTS 逐句占用，暂停面板用滑条调音量）
  void _setMediaVolume(double v) {
    setState(() => _mediaVolume = v.clamp(0.0, 1.0));
    _volumeChannel.invokeMethod('setMediaVolume', _mediaVolume);
  }

  void _adjustRate(double delta) {
    _setRate((_settings.speechRate + delta).clamp(0.5, 3.0));
  }

  void _setRate(double rate) {
    _settings.speechRate = rate;
    _tts.setSpeechRate(rate);
    widget.storage.saveSettings(_settings.toJson());
    setState(() {});
  }

  /// 进入假锁屏：全黑 + 长按解锁；保持 app 前台使蓝牙耳机键可控，
  /// 屏幕常亮 + 亮度压到最低，防止系统真锁屏/灭屏抢走媒体键。
  Future<void> _enterFakeLock() async {
    if (_fakeLock) return;
    setState(() => _fakeLock = true);
    _volumeChannel.invokeMethod('setKeepScreenOn', true);
    _volumeChannel.invokeMethod('setScreenBrightness', 0.03);
  }

  /// 退出假锁屏：恢复亮度与屏幕常亮
  Future<void> _exitFakeLock() async {
    _lockTimer?.cancel();
    _lockTimer = null;
    if (mounted) {
      setState(() {
        _fakeLock = false;
        _lockPressing = false;
      });
    }
    _volumeChannel.invokeMethod('setKeepScreenOn', false);
    _volumeChannel.invokeMethod('resetScreenBrightness');
  }

  /// 假锁屏界面：全黑，仅中央一个锁图标 + 长按 2 秒解锁（防误触）
  Widget _buildFakeLock() {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) {
          setState(() => _lockPressing = true);
          _lockTimer?.cancel();
          _lockTimer = Timer(const Duration(seconds: 2), _exitFakeLock);
        },
        onTapUp: (_) {
          _lockTimer?.cancel();
          _lockTimer = null;
          setState(() => _lockPressing = false);
        },
        onTapCancel: () {
          _lockTimer?.cancel();
          _lockTimer = null;
          setState(() => _lockPressing = false);
        },
        child: Container(
          color: Colors.black,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.lock,
                  size: 44,
                  color: _lockPressing
                      ? const Color(0xFF555555)
                      : const Color(0xFF202020),
                ),
                const SizedBox(height: 14),
                Text(
                  _lockPressing ? '继续按住解锁' : '长按 2 秒解锁',
                  style: TextStyle(
                    color: _lockPressing
                        ? const Color(0xFF666666)
                        : const Color(0xFF282828),
                    fontSize: 13,
                    letterSpacing: 2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 定时播放：到时间自动暂停
  Future<void> _openSleepTimer() async {
    final options = [0, 15, 30, 60, 90];
    final selected = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('定时停止',
                  style:
                      TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
            const Divider(height: 1),
            ...options.map((m) => ListTile(
                  leading: Icon(
                    m == _sleepMinutes
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: const Color(0xFF8A5A2B),
                  ),
                  title: Text(m == 0 ? '不开启' : '$m 分钟后停止'),
                  onTap: () => Navigator.pop(ctx, m),
                )),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (selected == null) return;
    _setSleepTimer(selected);
  }

  void _setSleepTimer(int minutes) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepMinutes = minutes;
    if (minutes > 0) {
      _sleepTimer = Timer(Duration(minutes: minutes), () {
        if (mounted && _inReadingMode && _isPlaying) {
          _pauseReading();
        }
      });
    }
    setState(() {});
  }

  /// 切换书页背景主题
  Future<void> _openThemePanel() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _theme.bg,
      builder: (ctx) => SafeArea(
        child: StatefulBuilder(
          builder: (ctx, setSheetState) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('书页背景', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(16),
                child: GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.75,
                  ),
                  itemCount: _bookThemes.length,
                  itemBuilder: (ctx, i) {
                    final t = _bookThemes[i];
                    final selected = _settings.themeIndex == i;
                    return GestureDetector(
                      onTap: () {
                        setState(() => _settings.themeIndex = i);
                        setSheetState(() {});
                        widget.storage.saveSettings(_settings.toJson());
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          color: t.bg,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: selected ? const Color(0xFF8A5A2B) : Colors.transparent,
                            width: selected ? 2.5 : 0,
                          ),
                          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 4)],
                        ),
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(t.name, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.title)),
                            const SizedBox(height: 6),
                            Text('阅读文字示例预览', style: TextStyle(fontSize: 10, color: t.text, height: 1.4)),
                            const Spacer(),
                            if (selected) const Align(alignment: Alignment.bottomRight, child: Icon(Icons.check_circle, size: 18, color: Color(0xFF8A5A2B))),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  /// 切换朗读音源
  Future<void> _openVoiceSelector() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('朗读音源',
                  style:
                      TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: edgeVoices.length,
                itemBuilder: (ctx, i) {
                  final id = edgeVoices[i];
                  return ListTile(
                    leading: Icon(
                      id == _settings.voice
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                      color: const Color(0xFF8A5A2B),
                    ),
                    title: Text(_voiceLabel(id)),
                    onTap: () => Navigator.pop(ctx, id),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (selected == null) return;
    _settings.voice = selected;
    _tts.setVoice(selected);
    widget.storage.saveSettings(_settings.toJson());
    // 切换音源后从当前句重新开始（新音色需要重新合成）
    if (_inReadingMode) {
      _startTtsFrom(_chapter, _para, _ttsSentence >= 0 ? _ttsSentence : 0);
    }
    setState(() {});
  }

  Widget _buildTapZones() {
    // 朗读模式：点击切换播放/暂停，上下滑动快速跳进
    final inReading = _inReadingMode;
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapUp: inReading
            ? (_) {
                if (_ttsLoading) return; // 加载中忽略点击，防误触
                if (_isPlaying) {
                  _pauseReading();
                } else {
                  _resumeReading();
                }
              }
            : (details) {
                final h = MediaQuery.of(context).size.height;
                final y = details.globalPosition.dy;
                if (y < h / 3) {
                  _pageUp();
                } else if (y > h * 2 / 3) {
                  _pageDown();
                } else {
                  setState(() => _showControls = !_showControls);
                  _applySystemUi();
                }
              },
        onVerticalDragStart: inReading ? _onDragSeekStart : null,
        onVerticalDragUpdate: inReading ? _onDragSeekUpdate : null,
        onVerticalDragEnd: inReading ? (_) => _onDragSeekEnd() : null,
        onVerticalDragCancel: inReading ? () => _dragging = false : null,
      ),
    );
  }

  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xF2241F18),
          border: Border(
            bottom: BorderSide(color: Color(0x66C9A96E), width: 1.5),
          ),
        ),
        padding: EdgeInsets.only(
          top: MediaQuery.of(context).padding.top,
          left: 4,
          right: 4,
          bottom: 4,
        ),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () async {
                if (_inReadingMode) await _exitReadingMode();
                _scheduleSave();
                if (mounted) Navigator.of(context).pop();
              },
            ),
            const Spacer(),
            IconButton(
              icon: _ttsLoading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.2, color: Colors.white))
                  : Icon(
                      _inReadingMode
                          ? Icons.pause
                          : Icons.play_arrow,
                      color: Colors.white),
              tooltip: '朗读',
              onPressed: _ttsLoading ? null : _play,
            ),
            IconButton(
              icon: const Icon(Icons.checkroom, color: Colors.white),
              tooltip: '书页背景',
              onPressed: _openThemePanel,
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, color: Colors.white),
              onSelected: (v) {
                switch (v) {
                  case 'brightness':
                    _openSettingsPanel('brightness');
                    break;
                  case 'fontsize':
                    _openSettingsPanel('fontsize');
                    break;
                  case 'lineheight':
                    _openSettingsPanel('lineheight');
                    break;
                  case 'rate':
                    _openSettingsPanel('rate');
                    break;
                  case 'voice':
                    _openSettingsPanel('voice');
                    break;
                  case 'search':
                    _openSearch();
                    break;
                }
              },
              itemBuilder: (ctx) => const [
                PopupMenuItem(value: 'brightness', child: Text('亮度')),
                PopupMenuItem(value: 'fontsize', child: Text('字体大小')),
                PopupMenuItem(value: 'lineheight', child: Text('行距')),
                PopupMenuItem(value: 'rate', child: Text('变速')),
                PopupMenuItem(value: 'voice', child: Text('音源')),
                PopupMenuItem(value: 'search', child: Text('查找')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xF2241F18),
          border: Border(
            top: BorderSide(color: Color(0x66C9A96E), width: 1.5),
          ),
        ),
        padding: EdgeInsets.only(
          left: 12,
          right: 12,
          top: 6,
          bottom: MediaQuery.of(context).padding.bottom + 6,
        ),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.skip_previous,
                  size: 18, color: Colors.white),
              visualDensity: VisualDensity.compact,
              onPressed: _isPlaying ? _prevSentence : null,
              tooltip: '上一句',
            ),
            Text(
              '${(_percent * 100).toStringAsFixed(1)}%',
              style: const TextStyle(fontSize: 12, color: Color(0xFFD9C08A)),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Slider(
                value: _percent,
                activeColor: const Color(0xFFE8C87A),
                inactiveColor: const Color(0x55FFFFFF),
                onChanged: (v) => _seekTo(v),
              ),
            ),
            const SizedBox(width: 4),
            Text(
              '第 ${_chapter + 1}/${widget.book.chapters.length} 章',
              style: const TextStyle(fontSize: 11, color: Color(0xFFD9C08A)),
            ),
            IconButton(
              icon: const Icon(Icons.skip_next,
                  size: 18, color: Colors.white),
              visualDensity: VisualDensity.compact,
              onPressed: _isPlaying ? _nextSentence : null,
              tooltip: '下一句',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFloatingChapter() {
    return Positioned(
      left: 8,
      top: MediaQuery.of(context).size.height / 2 - 28,
      child: FloatingActionButton.small(
        heroTag: 'chapterFab',
        backgroundColor: const Color(0xCC8A5A2B),
        foregroundColor: Colors.white,
        onPressed: _openChapterList,
        child: const Icon(Icons.menu_book, size: 20),
      ),
    );
  }

  Future<void> _openChapterList() async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => _ChapterSheet(book: widget.book, current: _chapter),
    );
    if (selected == null) return;
    setState(() {
      _chapter = selected;
      _para = 0;
    });
    _jumpToItem(_itemIndexOf(selected, 0));
    _scheduleSave();
  }

  Widget _buildSearchBar() {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 52,
      left: 0,
      right: 0,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xE6FFFFFF),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 6,
            ),
          ],
        ),
        child: Row(
          children: [
            const Icon(Icons.search, size: 18),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '“$_searchQuery” 第 ${_searchIndex + 1}/${_searchHits.length} 处',
                style: const TextStyle(fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.chevron_left, size: 20),
              onPressed: () => _gotoSearchHit(_searchIndex - 1),
            ),
            IconButton(
              icon: const Icon(Icons.chevron_right, size: 20),
              onPressed: () => _gotoSearchHit(_searchIndex + 1),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => setState(() => _searchHits = []),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBrightnessOverlay() {
    if (_settings.brightness >= 1.0) return const SizedBox.shrink();
    final dark = (1 - _settings.brightness) * 0.7;
    return Positioned.fill(
      child: IgnorePointer(
        child: Container(color: Colors.black.withValues(alpha: dark)),
      ),
    );
  }

  // 设置面板（由右上角菜单触发）
  static String _voiceLabel(String id) {
    const friendly = {
      'zh-CN-XiaoxiaoNeural': '晓晓（女·温暖）',
      'zh-CN-YunxiNeural': '云希（男·阳光）',
      'zh-CN-YunyangNeural': '云扬（男·专业）',
      'zh-CN-XiaoyiNeural': '晓伊（女·活泼）',
      'zh-CN-liaoning-XiaobeiNeural': '小北（东北话）',
      'zh-CN-shaanxi-XiaoniNeural': '小妮（陕西话）',
    };
    return friendly[id] ?? id;
  }

  void _openSettingsPanel(String kind) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => _SettingsSheet(
        settings: _settings,
        onChanged: (s) {
          setState(() => _settings = s);
          _tts.setSpeechRate(s.speechRate);
          if (s.voice.isNotEmpty) _tts.setVoice(s.voice);
          widget.storage.saveSettings(s.toJson());
        },
        onVoiceLoad: () async => edgeVoices
            .map((v) => {'id': v, 'name': _voiceLabel(v)})
            .toList(),
      ),
    );
  }
}

/// 报告子组件实际渲染高度（用于精确计算滚动位置→段落映射）
class _HeightReporter extends SingleChildRenderObjectWidget {
  final ValueChanged<double> onHeight;
  const _HeightReporter({required this.onHeight, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _HeightReporterRender(onHeight);

  @override
  void updateRenderObject(
      BuildContext context, _HeightReporterRender renderObject) {
    renderObject.onHeight = onHeight;
  }
}

class _HeightReporterRender extends RenderProxyBox {
  ValueChanged<double> onHeight;
  double _last = -1;
  _HeightReporterRender(this.onHeight);

  @override
  void performLayout() {
    super.performLayout();
    final h = size.height;
    if ((h - _last).abs() > 0.01) {
      _last = h;
      onHeight(h);
    }
  }
}

class _SearchHit {
  final int chapter;
  final int para;
  final int start;
  final int length;
  const _SearchHit(this.chapter, this.para, this.start, this.length);
}

/// 章节选择底部弹层
class _ChapterSheet extends StatelessWidget {
  final Book book;
  final int current;
  const _ChapterSheet({required this.book, required this.current});

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (ctx, scrollController) {
        // 打开时滚动到当前章节
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (scrollController.hasClients) {
            final offset = (current * 56.0)
                .clamp(0.0, scrollController.position.maxScrollExtent);
            scrollController.jumpTo(offset);
          }
        });
        return Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('目录',
                  style:
                      TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                itemCount: book.chapters.length,
                itemBuilder: (ctx, i) => ListTile(
                  leading: Icon(
                    i == current
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: const Color(0xFF8A5A2B),
                    size: 20,
                  ),
                  title: Text(
                    book.chapters[i].title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  selected: i == current,
                  onTap: () => Navigator.pop(ctx, i),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 设置底部弹层
class _SettingsSheet extends StatefulWidget {
  final ReadingSettings settings;
  final ValueChanged<ReadingSettings> onChanged;
  final Future<List<dynamic>> Function() onVoiceLoad;
  const _SettingsSheet({
    required this.settings,
    required this.onChanged,
    required this.onVoiceLoad,
  });

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late ReadingSettings _s;
  List<dynamic> _voices = [];
  bool _voicesLoaded = false;

  @override
  void initState() {
    super.initState();
    _s = ReadingSettings.fromJson(widget.settings.toJson());
    _loadVoices();
  }

  Future<void> _loadVoices() async {
    final v = await widget.onVoiceLoad();
    if (mounted) {
      setState(() {
        _voices = v;
        _voicesLoaded = true;
      });
    }
  }

  void _update() {
    widget.onChanged(_s);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 亮度
              _row('亮度', Icons.brightness_6, Slider(
                value: _s.brightness,
                min: 0.3,
                max: 1.0,
                onChanged: (v) => setState(() {
                  _s.brightness = v;
                  _update();
                }),
              )),
              // 字体大小
              _row('字体大小', Icons.text_fields, Slider(
                value: _s.fontSize,
                min: 14,
                max: 32,
                divisions: 18,
                onChanged: (v) => setState(() {
                  _s.fontSize = v;
                  _update();
                }),
              )),
              // 行距
              _row('行距', Icons.format_line_spacing, Slider(
                value: _s.lineHeight,
                min: 1.2,
                max: 2.4,
                divisions: 12,
                onChanged: (v) => setState(() {
                  _s.lineHeight = v;
                  _update();
                }),
              )),
              // 变速
              _row('变速', Icons.speed, Slider(
                value: _s.speechRate,
                min: 0.5,
                max: 2.0,
                divisions: 15,
                label: '${_s.speechRate.toStringAsFixed(2)}x',
                onChanged: (v) => setState(() {
                  _s.speechRate = v;
                  _update();
                }),
              )),
              // 音源
              Row(
                children: [
                  const Icon(Icons.record_voice_over),
                  const SizedBox(width: 12),
                  const Text('音源'),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _voicesLoaded && _voices.isNotEmpty
                        ? DropdownButton<String>(
                            value: _s.voice.isEmpty ? null : _s.voice,
                            isExpanded: true,
                            hint: const Text('默认'),
                            items: _voices.map((v) {
                              final id = v is Map
                                  ? (v['id'] ?? v.toString())
                                  : v.toString();
                              final name = v is Map
                                  ? (v['name'] ?? id)
                                  : id;
                              return DropdownMenuItem(
                                  value: id.toString(), child: Text(name));
                            }).toList(),
                            onChanged: (val) => setState(() {
                              _s.voice = val ?? '';
                              _update();
                            }),
                          )
                        : const Text('加载中…'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(String label, IconData icon, Widget slider) {
    return Row(
      children: [
        Icon(icon, color: const Color(0xFF8A5A2B)),
        const SizedBox(width: 12),
        Text(label, style: const TextStyle(fontSize: 14)),
        const SizedBox(width: 8),
        Expanded(child: slider),
      ],
    );
  }
}
