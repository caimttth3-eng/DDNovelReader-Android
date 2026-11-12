import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../i18n.dart';
import '../services/app_appearance.dart';
import '../services/reading_text.dart';
import '../services/reader_typography.dart';
import '../services/text_cleaner.dart';
import '../widgets/reader_icon.dart';
import '../widgets/reader_brightness_control.dart';
import '../widgets/reader_gestures.dart';
import '../models/annotation.dart';
import '../models/book.dart';
import '../models/progress.dart';
import '../services/annotation_store.dart';
import '../services/app_storage.dart';
import '../services/book_cache_task.dart';
import '../services/edge_tts.dart';
import '../services/font_manager.dart';
import '../services/tts_audio_handler.dart';
import '../services/tts_cache_store.dart';
import '../services/tts_reader.dart';
import '../services/system_tts.dart';

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
  @visibleForTesting
  final TtsReader? ttsReader;

  const ReaderScreen({
    super.key,
    required this.book,
    required this.storage,
    this.initialProgress,
    this.onProgressChanged,
    this.ttsReader,
  });

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

/// 扁平 item：章节标题 或 句子（段落拆为句子级，便于高亮跟随滚动）
/// 书页背景主题
class BookTheme {
  final String name;
  final String? labelKey; // i18n key（优先）；null 则用 name 原文
  final Color bg;
  final Color text;
  final Color title;
  const BookTheme({
    required this.name,
    this.labelKey,
    required this.bg,
    required this.text,
    required this.title,
  });
}

const List<BookTheme> _bookThemes = [
  BookTheme(name: '羊皮纸', labelKey: 'themeParchment', bg: Color(0xFFB5AB92), text: Color(0xFF25231D), title: Color(0xFF454137)),
  BookTheme(name: '护眼绿', labelKey: 'themeGreen', bg: Color(0xFFC7EDCC), text: Color(0xFF1F3A1F), title: Color(0xFF2D5A2D)),
  BookTheme(name: '夜间黑', labelKey: 'themeNight', bg: Color(0xFF1A1A1A), text: Color(0xFFBBBBBB), title: Color(0xFFDDDDDD)),
  BookTheme(name: '纯白', labelKey: 'themeWhite', bg: Color(0xFFFFFFFF), text: Color(0xFF333333), title: Color(0xFF555555)),
  BookTheme(name: '浅灰', labelKey: 'themeGray', bg: Color(0xFFEDEDED), text: Color(0xFF333333), title: Color(0xFF555555)),
  BookTheme(name: '复古棕', labelKey: 'themeBrown', bg: Color(0xFFE8D5B7), text: Color(0xFF4A3728), title: Color(0xFF6B4A2A)),
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

class _ReaderScreenState extends State<ReaderScreen> with TickerProviderStateMixin, WidgetsBindingObserver {
  late final TtsReader _tts;
  late List<_Item> _items;
  late Book _book;
  String _textSignature = '';
  String _cacheFingerprint = '';
  final GlobalKey _pageBoundary = GlobalKey();
  ui.Image? _pageImage;
  final Map<int, GlobalKey> _paragraphKeys = {};
  final Map<int, GlobalKey> _titleKeys = {};
  double? _pageClipBottom;
  bool _pageGeometryScheduled = false;
  String? _pageEndKey;
  final Map<String, LongPressGestureRecognizer> _sentenceRecognizers = {};
  int _navigationGeneration = 0;
  bool _restoringProgress = true;
  bool _restoringViewport = false;
  int? _flowChapter, _flowParagraph, _flowOffset;
  int _viewRevision = 0;
  ui.Image? _viewSnapshot;
  _ReaderLineAnchor? _reformatAnchor;
  int? _lineBreakFor(int c, int p) => _flowChapter == c && _flowParagraph == p ? _flowOffset : null;
  int _renderOffset(int c, int p, int offset) => ReaderTypography.layoutOffset(
    _book.chapters[c].paragraphs[p].display, offset, lineBreakAt: _lineBreakFor(c, p));
  String _layoutSegment(_Item it, String text, int start) {
    final split = _lineBreakFor(it.chapterIndex, it.paragraphIndex);
    return ReaderTypography.layout(text, lineBreakAt: split != null && split >= start && split < start + text.length ? split - start : null);
  }
  BookProgress? _lastProgress;
  Size _viewportSize = Size.zero;
  double _bodyExtent = 1;
  String get _layoutSignature => 'typography3/$_textSignature/$_fontSize/$_lineHeight/$_fontFamily/$_viewportSize/$_flowChapter/$_flowParagraph/$_flowOffset';
  final ItemScrollController _itemScrollController = ItemScrollController();
  final ScrollOffsetController _pageScrollController = ScrollOffsetController();
  bool _paging = false;
  late final AnimationController _pageAnimation;
  late final AnimationController _autoClock;
  Widget? _outgoingPage;
  bool _pageReady = false;
  int _pageDirection = 1;
  bool _autoActive = false;
  bool _autoPaused = false;
  bool _showAutoPanel = false;
  final ItemPositionsListener _itemPositionsListener =
      ItemPositionsListener.create();

  ReadingSettings _settings = ReadingSettings();
  bool _settingsLoaded = false;

  // 控制 UI 显隐
  bool _showControls = true;
  bool _showQuickMenu = false;
  final Map<Orientation, EdgeInsets> _stableInsets = {};
  EdgeInsets get _readerInsets => _stableInsets.putIfAbsent(
    MediaQuery.orientationOf(context), () => MediaQuery.viewPaddingOf(context));
  bool get _isNight => _settings.themeIndex == 2;
  Color get _menuColor => _isNight ? const Color(0xFF181818) : const Color(0xF2333333);

  // 朗读模式（全屏播放/暂停，顶栏隐藏，暂停时底部弹控制面板）
  bool _inReadingMode = false;
  bool _showReadingPanel = false;

  // 定时播放
  Timer? _sleepTimer;
  int _sleepMinutes = 0; // 0=未设置

  // 手势操作提示条（开始播放时短暂提示）
  Timer? _gestureTipTimer;
  bool _gestureTipVisible = false;

  // 当前阅读位置（章节/段落）
  int _chapter = 0;
  int _para = 0;
  // 当前 TTS 句子索引（-1 表示未在朗读）
  int _ttsSentence = -1;
  int _wordStart = -1, _wordEnd = -1;
  String _wordMapKey = '';
  CleanedText? _wordMap;
  bool _followingWord = false;
  bool _isPlaying = false;
  // TTS 正在朗读的章节（与 _chapter 可能因滚动不同步）
  int _ttsChapter = 0;
  // TTS 合成加载中（点击播放/恢复后等待首句出声；期间防误触）
  bool _ttsLoading = false;

  // 系统媒体音量（音量键正常调节，暂停面板也提供滑条）
  double _mediaVolume = 1.0;
  Timer? _volumePollTimer;
  bool _volumeReadInFlight = false;
  bool _volumeDragging = false;
  bool _volumeForeground = true;
  int _volumeRevision = 0, _volumePollEpoch = 0, _volumeWrites = 0;
  bool get _volumePanelVisible => _inReadingMode && _showReadingPanel && !_fakeLock && _volumeForeground;

  // 假锁屏（保持 app 前台，蓝牙耳机键可控；长按 2 秒解锁）
  bool _fakeLock = false;
  Timer? _lockTimer;
  bool _lockPressing = false;

  // 跳转逼近计数（防震荡死循环）
  int _approaches = 0;
  bool _suppressScrollTrack = false;
  bool _scrollThrottle = false;
  int? _pendingScrollIndex; // 待跳转 item，渲染出真实高度后校正视口
  bool _heightCorrectionScheduled = false;

  List<int> _itemCharPrefix = [0]; // 每个 item 的 display 字符前缀和（用于 O(log n) 按字定位）

  // 章节 display 长度前缀和（用于 O(log n) 定位进度，避免每次全扫全书）
  List<int> _chapterPrefix = [0];

  // 查找结果
  List<_SearchHit> _searchHits = [];
  int _searchIndex = 0;
  String _searchQuery = '';

  // 书签与划线（标注）
  List<Bookmark> _bookmarks = [];
  List<Highlight> _highlights = [];
  Map<String, List<Highlight>> _hlIndex = {}; // '$c-$p' -> 该段划线
  static const List<int> _hlColors = [0x3385B5FF, 0x33FFC107, 0x338FE388]; // 蓝/黄/绿
  static String _hlKey(int c, int p) => '$c-$p';

  Timer? _saveDebounce;

  double get _fontSize => _settings.fontSize;
  double get _lineHeight => _settings.lineHeight;
  String get _fontFamily => _settings.fontFamily;
  BookTheme get _theme => _bookThemes[_settings.themeIndex.clamp(0, _bookThemes.length - 1)];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pageAnimation = AnimationController(vsync: this, duration: const Duration(milliseconds: 80));
    _autoClock = AnimationController(vsync: this, duration: const Duration(seconds: 20))
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed && _autoActive && !_autoPaused) _advanceAutoPage();
      });
    _tts = widget.ttsReader ?? TtsReader();
    _tts.onSentenceChanged = _onTtsSentenceChanged;
    _tts.onWordChanged = _onTtsWordChanged;
    _tts.onCompleted = _onTtsCompleted;
    _tts.onError = _onTtsError;
    _tts.onLoadingChanged = (loading) { if (mounted && _inReadingMode && _ttsLoading != loading) setState(() => _ttsLoading = loading); };
    _book = widget.book;
    _items = _flatten(_book);
    _initLocate();
    _initCharPrefix();
    _itemPositionsListener.itemPositions.addListener(_onScroll);
    // 绑定全局 audio_service 回调（耳机播放键）
    globalAudioHandler?.onPlayRequested = _onHeadsetPlay;
    globalAudioHandler?.onPauseRequested = _onHeadsetPause;
    globalAudioHandler?.onStopRequested = _onHeadsetStop;
    globalAudioHandler?.onCustomResumeRequested = _onCustomResume;
    _loadSettings();
    // 记录最后阅读的书籍，下次启动直接恢复
    widget.storage.saveLastBookId(_book.id);
    // 读取系统媒体音量用于暂停面板滑条
    _loadMediaVolume();
    // 加载书签与划线

  }

  static const _volumeChannel =
      MethodChannel('com.ddnovelreader/volume_keys');

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
    _volumePollTimer?.cancel(); _volumePollTimer = null; _volumePollEpoch++;
    WidgetsBinding.instance.removeObserver(this);
    if (_autoActive) _volumeChannel.invokeMethod('setKeepScreenOn', false);
    for (final recognizer in _sentenceRecognizers.values) { recognizer.dispose(); }
    _pageAnimation.dispose(); _autoClock.dispose();
    final image = _pageImage; _pageImage = null;
    WidgetsBinding.instance.addPostFrameCallback((_) => image?.dispose());
    final snapshot = _viewSnapshot; _viewSnapshot = null;
    WidgetsBinding.instance.addPostFrameCallback((_) => snapshot?.dispose());
    _saveDebounce?.cancel();
    // 退出前确保最后一次进度写入（防抖可能未触发）
    _saveProgress();
    _sleepTimer?.cancel();
    _lockTimer?.cancel();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    _volumeChannel.invokeMethod('resetScreenBrightness');
    // 恢复系统默认系统栏样式（书架页浅色背景使用深色图标）
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: _isNight ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: _isNight ? Brightness.light : Brightness.dark,
    ));
    _gestureTipTimer?.cancel();
    _tts.dispose();
    _itemPositionsListener.itemPositions.removeListener(_onScroll);
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
        list.add(_Item.sentence(c, p, 0, isParaStart: true));
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

  String _formatSignature(ReadingSettings s) =>
      '${s.mergeNonSentenceBreaks}/${s.firstLineIndent}/${s.informationFilter}/${s.informationFilterLevel}';

  void _formatBook() {
    _textSignature = _formatSignature(_settings);
    _book = ReadingText.format(widget.book, merge: _settings.mergeNonSentenceBreaks,
      indent: _settings.firstLineIndent,
      filter: _settings.informationFilter ? _settings.informationFilterLevel : 'none');
    _cacheFingerprint = 'words1-${ReadingText.fingerprint(_book)}';
    _wordMapKey = ''; _wordMap = null; _wordStart = -1; _wordEnd = -1;
    _items = _flatten(_book);
    _paragraphKeys.clear();
    _titleKeys.clear(); _pageClipBottom = null; _pageEndKey = null;
    for (final recognizer in _sentenceRecognizers.values) { recognizer.dispose(); }
    _sentenceRecognizers.clear();
    _pendingScrollIndex = null;
    _initLocate(); _initCharPrefix();
  }

  Future<void> _loadSettings() async {
    final raw = await widget.storage.loadSettings();
    if (!mounted) return;
    _settings = ReadingSettings.fromJson(raw);
    _formatBook();
    AppAppearance.nightMode.value = _isNight;
    _applyReaderBrightness();
    if (_settings.automaticBrightness) _syncSystemBrightness();
    _applySystemUi();
    await _tts.setSpeechRate(_settings.speechRate);
    if (_settings.voice.isNotEmpty) _tts.setVoice(_settings.voice);
    final p = await widget.storage.loadProgress(_book.id) ?? widget.initialProgress;
    if (!mounted) return;
    final atTitle = p == null || p.atChapterTitle ||
      (p.layoutSignature.isEmpty && p.paragraphIndex == 0 && p.offsetInParagraph == 0);
    _lastProgress = p;
    if (p != null && p.flowChapter != null && p.flowAnchor != null && p.flowChapter! < _book.chapters.length) {
      final location = ReadingText.locate(_book, p.flowChapter!, p.flowAnchor!);
      _setFlowBreak(p.flowChapter!, location.$1, location.$2);
    }
    _chapter = (p?.chapterIndex ?? 0).clamp(0, max(0, _book.chapters.length - 1));
    final location = p == null ? (0, 0) : ReadingText.locate(_book, _chapter,
      p.chapterAnchor ?? ReadingText.anchor(widget.book, _chapter, p.paragraphIndex, p.offsetInParagraph));
    _para = location.$1;
    _ttsSentence = ReadingText.sentenceAt(_book.chapters[_chapter].paragraphs[_para], location.$2);
    setState(() => _settingsLoaded = true);
    await _loadAnnotations();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final exact = p != null && p.layoutSignature == _layoutSignature && p.viewportItem != null;
      final index = exact ? p.viewportItem!.clamp(0, _items.length - 1) :
        atTitle ? _chapterItem(_chapter) : _itemIndexOf(_chapter, _para);
      await _positionViewport(index, exact ? p.viewportAlignment : 0);
      if (mounted && !exact && p != null && !atTitle) {
        await _followSentence(_chapter, _para, max(0, _ttsSentence));
      }
      if (mounted) { _restoringProgress = false; _scheduleSave(); }
    });
  }

  int _chapterItem(int chapter) => _items.indexWhere((it) => it.isTitle && it.chapterIndex == chapter);

  Future<void> _saveProgress() async {
    if (!_settingsLoaded || _restoringProgress) return;
    final visible = mounted ? _visibleItems() : <ItemPosition>[];
    final first = visible.isEmpty ? null : visible.first;
    final it = first == null ? null : _items[first.index];
    final c = _isPlaying ? _chapter : it?.chapterIndex ?? _chapter;
    final paraIndex = _isPlaying ? _para : it == null || it.isTitle ? 0 : it.paragraphIndex;
    final para = _book.chapters[c].paragraphs[paraIndex];
    final offset = _isPlaying && _ttsSentence >= 0 && _ttsSentence < para.sentences.length
      ? para.sentences[_ttsSentence].displayStart : first != null && !(it?.isTitle ?? true)
        ? _visibleOffset(first) : 0;
    final p = BookProgress(bookId: _book.id, chapterIndex: c, paragraphIndex: paraIndex,
      offsetInParagraph: offset, chapterAnchor: ReadingText.anchor(_book, c, paraIndex, offset),
      percent: _percent, viewportItem: first?.index ?? _lastProgress?.viewportItem,
      viewportAlignment: first?.itemLeadingEdge ?? _lastProgress?.viewportAlignment ?? 0,
      layoutSignature: _layoutSignature,
      atChapterTitle: it?.isTitle ?? false,
      flowChapter: _flowChapter, flowAnchor: _flowChapter != null && _flowParagraph != null && _flowOffset != null
        ? ReadingText.anchor(_book, _flowChapter!, _flowParagraph!, _flowOffset!) : null);
    _lastProgress = p;
    await widget.storage.saveProgress(p);
    await widget.onProgressChanged?.call(p);
  }

  // ---------- 书签与划线 ----------

  Future<void> _loadAnnotations() async {
    final store = AnnotationStore();
    final bms = await store.loadBookmarks(_book.id);
    final hls = await store.loadHighlights(_book.id);
    if (!mounted) return;
    setState(() {
      _bookmarks = bms;
      _highlights = hls;
      _remapAnnotations(widget.book, legacy: true);
    });
  }

  void _remapAnnotations(Book previous, {bool legacy = false}) {
    _bookmarks = _bookmarks.map((b) {
      final c = b.chapterIndex.clamp(0, _book.chapters.length - 1);
      final oldParas = previous.chapters[c].paragraphs;
      final oldPara = oldParas[b.paragraphIndex.clamp(0, oldParas.length - 1)];
      final oldOffset = oldPara.sentences.isEmpty ? 0 : oldPara.sentences[b.sentenceIndex.clamp(0, oldPara.sentences.length - 1)].displayStart;
      final anchor = b.chapterAnchor ?? (legacy ? ReadingText.legacySentenceAnchor(previous, c, b.sentenceIndex)
        : ReadingText.anchor(previous, c, b.paragraphIndex, oldOffset));
      final location = ReadingText.locate(_book, c, anchor);
      return Bookmark.fromJson({...b.toJson(), 'chapterIndex': c, 'paragraphIndex': location.$1,
        'sentenceIndex': ReadingText.sentenceAt(_book.chapters[c].paragraphs[location.$1], location.$2),
        'chapterAnchor': anchor});
    }).toList();
    _highlights = _highlights.map((h) {
      final c = h.chapterIndex.clamp(0, _book.chapters.length - 1);
      final start = h.anchorStart ?? (legacy ? ReadingText.legacyAnchor(previous, c, h.charStart)
        : ReadingText.anchor(previous, c, h.paragraphIndex, h.charStart));
      final end = h.anchorEnd ?? (legacy ? ReadingText.legacyAnchor(previous, c, h.charEnd)
        : ReadingText.anchor(previous, c, h.paragraphIndex, h.charEnd));
      final location = ReadingText.locate(_book, c, start);
      final ending = ReadingText.locate(_book, c, max(start, end - 1));
      return Highlight.fromJson({...h.toJson(), 'chapterIndex': c, 'paragraphIndex': location.$1,
        'charStart': location.$2, 'charEnd': ending.$1 == location.$1 ? ending.$2 + 1 : _book.chapters[c].paragraphs[location.$1].display.length,
        'anchorStart': start, 'anchorEnd': end});
    }).toList();
    _rebuildHlIndex();
  }

  void _rebuildHlIndex() {
    _hlIndex = {};
    for (final h in _highlights) {
      final start = h.anchorStart ?? ReadingText.anchor(_book, h.chapterIndex, h.paragraphIndex, h.charStart);
      final end = h.anchorEnd ?? ReadingText.anchor(_book, h.chapterIndex, h.paragraphIndex, h.charEnd);
      final last = ReadingText.locate(_book, h.chapterIndex, max(start, end - 1));
      for (var p = h.paragraphIndex; p <= last.$1; p++) {
        _hlIndex.putIfAbsent(_hlKey(h.chapterIndex, p), () => []).add(Highlight.fromJson({...h.toJson(),
          'paragraphIndex': p, 'charStart': p == h.paragraphIndex ? h.charStart : 0,
          'charEnd': p == last.$1 ? last.$2 + 1 : _book.chapters[h.chapterIndex].paragraphs[p].display.length}));
      }
    }
  }

  /// 写回存储（书签+划线），保持内存与磁盘同步
  Future<void> _persistAnnotations() async {
    _remapAnnotations(_book);
    final store = AnnotationStore();
    await store.saveBookmarks(_book.id, _bookmarks);
    await store.saveHighlights(_book.id, _highlights);
  }

  /// 轻提示（复制/划线/书签成功反馈）
  void _showToast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ));
  }

  // 判断 (c,p,s) 是否已有书签
  Future<void> _addCurrentBookmark() async {
    final position = _inReadingMode ? (_chapter, _para, max(0, _ttsSentence)) : _viewportPosition() ?? (_chapter, _para, 0);
    await _addBookmarkAt(_Item.sentence(position.$1, position.$2, position.$3));
  }

  bool _hasBookmarkAt(int c, int p, int s) =>
      _bookmarks.any((b) =>
          b.chapterIndex == c && b.paragraphIndex == p && b.sentenceIndex == s);

  Future<void> _addBookmarkAt(_Item it) async {
    if (_hasBookmarkAt(it.chapterIndex, it.paragraphIndex, it.sentenceIndex)) {
      return;
    }
    final para = _book.chapters[it.chapterIndex].paragraphs[it.paragraphIndex];
    String snippet = '';
    if (it.sentenceIndex < para.sentences.length) {
      snippet = para.sentences[it.sentenceIndex].display.trim();
    } else {
      snippet = para.display.trim();
    }
    if (snippet.length > 40) snippet = snippet.substring(0, 40);
    setState(() {
      _bookmarks.add(Bookmark(
        id: 'b${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
        bookId: _book.id,
        chapterIndex: it.chapterIndex,
        paragraphIndex: it.paragraphIndex,
        sentenceIndex: it.sentenceIndex,
        chapterTitle: _book.chapters[it.chapterIndex].title,
        snippet: snippet,
        createdAt: DateTime.now(),
      ));
    });
    await _persistAnnotations();
    if (!mounted) return;
    _showToast(T('bookmarkAdded'));
  }

  // 判断该句是否已被划线（返回命中的高亮）
  List<Highlight> _highlightOf(_Item it, Paragraph para) {
    if (it.sentenceIndex >= para.sentences.length) return const [];
    final seg = _hlIndex[_hlKey(it.chapterIndex, it.paragraphIndex)];
    if (seg == null) return const [];
    final s = para.sentences[it.sentenceIndex];
    return seg.where((h) => h.hits(it.chapterIndex, it.paragraphIndex,
            s.displayStart, s.displayEnd))
        .toList();
  }

  Future<void> _addHighlightAt(_Item it, Paragraph para, int color) async {
    if (it.sentenceIndex >= para.sentences.length) return;
    final s = para.sentences[it.sentenceIndex];
    if (s.displayStart >= s.displayEnd) return;
    // 去重：该句已有任何颜色划线则跳过
    final existing = _hlIndex[_hlKey(it.chapterIndex, it.paragraphIndex)];
    if (existing != null &&
        existing.any((h) => h.hits(
            it.chapterIndex, it.paragraphIndex, s.displayStart, s.displayEnd))) {
      return;
    }
    setState(() {
      _highlights.add(Highlight(
        id: 'h${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
        bookId: _book.id,
        chapterIndex: it.chapterIndex,
        paragraphIndex: it.paragraphIndex,
        charStart: s.displayStart,
        charEnd: s.displayEnd,
        color: color,
        note: '',
        createdAt: DateTime.now(),
      ));
      _rebuildHlIndex();
    });
    await _persistAnnotations();
    _showToast(T('highlightAdded'));
  }

  Future<void> _removeHighlightOf(_Item it, Paragraph para) async {
    if (it.sentenceIndex >= para.sentences.length) return;
    final ids = _highlightOf(it, para).map((h) => h.id).toSet();
    setState(() {
      _highlights.removeWhere((h) => ids.contains(h.id));
      _rebuildHlIndex();
    });
    await _persistAnnotations();
  }

  Future<void> _setHighlightNote(Highlight h) async {
    final ctrl = TextEditingController(text: h.note);
    final note = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(T('note')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 4,
          decoration: InputDecoration(hintText: T('noteHint')),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: Text(T('cancel'))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: Text(T('ok'))),
        ],
      ),
    );
    if (note == null) return;
    setState(() {
      final i = _highlights.indexWhere((x) => x.id == h.id);
      if (i >= 0) _highlights[i] = _highlights[i].copyWith(note: note);
    });
    await _persistAnnotations();
  }

  /// 长按句子：划线/换色/笔记/取消划线/书签/复制
  Future<void> _onSentenceLongPress(_Item it, Paragraph para) async {
    final hits = _highlightOf(it, para);
    final hasHl = hits.isNotEmpty;
    if (it.isTitle) return;
    if (!hasHl) {
      // 选择划线颜色 → 或直接书签/复制
      final action = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(T('highlight'),
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.bold)),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final color in _hlColors)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: GestureDetector(
                        onTap: () => Navigator.pop(ctx, 'color:$color'),
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: Color(color),
                            shape: BoxShape.circle,
                            border: Border.all(color: const Color(0x44000000)),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              ListTile(
                leading: const Icon(Icons.bookmark_add_outlined),
                title: Text(T('addBookmark')),
                onTap: () => Navigator.pop(ctx, 'bookmark'),
              ),
              ListTile(
                leading: const Icon(Icons.copy),
                title: Text(T('copy')),
                onTap: () {
                  Navigator.pop(ctx, 'copy');
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
      if (action == null) return;
      if (action == 'bookmark') {
        await _addBookmarkAt(it);
      } else if (action == 'copy') {
        await _copySentence(it, para);
      } else if (action.startsWith('color:')) {
        await _addHighlightAt(it, para, int.parse(action.split(':')[1]));
      }
      return;
    }
    // 已划线：换色/笔记/取消划线/复制
    final hl = hits.first;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(T('highlight'),
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.bold)),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final color in _hlColors)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: GestureDetector(
                      onTap: () => Navigator.pop(ctx, 'color:$color'),
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: Color(color),
                          shape: BoxShape.circle,
                          border: Border.all(color: const Color(0x44000000)),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            ListTile(
              leading: const Icon(Icons.edit_note),
              title: Text(T('note')),
              subtitle: hl.note.isEmpty ? null : Text(hl.note),
              onTap: () {
                Navigator.pop(ctx, 'note');
              },
            ),
            ListTile(
              leading: const Icon(Icons.highlight_off),
              title: Text(T('removeHighlight')),
              onTap: () => Navigator.pop(ctx, 'remove'),
            ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: Text(T('copy')),
              onTap: () => Navigator.pop(ctx, 'copy'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action == null) return;
    if (action == 'note') {
      await _setHighlightNote(hl);
    } else if (action == 'remove') {
      await _removeHighlightOf(it, para);
    } else if (action == 'copy') {
      await _copySentence(it, para);
    } else if (action.startsWith('color:')) {
      final color = int.parse(action.split(':')[1]);
      setState(() {
        final i = _highlights.indexWhere((x) => x.id == hl.id);
        if (i >= 0) _highlights[i] = _highlights[i].copyWith(color: color);
      });
      await _persistAnnotations();
    }
  }

  String _sentenceText(_Item it, Paragraph para) {
    if (it.sentenceIndex < para.sentences.length) {
      return para.sentences[it.sentenceIndex].display;
    }
    return para.display;
  }

  /// 复制句子并提示（提示文案截断）
  Future<void> _copySentence(_Item it, Paragraph para) async {
    var text = _sentenceText(it, para).trim();
    await Clipboard.setData(ClipboardData(text: text));
    var preview = text.replaceAll('\n', '');
    if (preview.length > 15) preview = preview.substring(0, 15);
    _showToast(T('copied', {'text': preview}));
  }

  TextSpan _paragraphSpan(_Item it, Paragraph para, {bool gestures = true}) {
    final spans = <InlineSpan>[];
    final leading = ReaderTypography.leadingLength(para.display);
    if (leading > 0) spans.add(WidgetSpan(alignment: ui.PlaceholderAlignment.middle,
      child: SizedBox(width: _indentWidth(para), height: 1)));
    var cursor = leading;
    for (var i = 0; i < para.sentences.length; i++) {
      final sentence = para.sentences[i];
      final start = sentence.displayStart.clamp(cursor, para.display.length);
      final end = sentence.displayEnd.clamp(start, para.display.length);
      if (start > cursor) spans.add(TextSpan(text: _layoutSegment(it, para.display.substring(cursor, start), cursor)));
      final current = _inReadingMode && it.chapterIndex == _chapter && it.paragraphIndex == _para && i == _ttsSentence;
      final recognizer = gestures ? _sentenceRecognizers.putIfAbsent('${it.chapterIndex}/${it.paragraphIndex}/$i', () => LongPressGestureRecognizer()) : null;
      if (recognizer != null) recognizer.onLongPress = () => _onSentenceLongPress(_Item.sentence(it.chapterIndex, it.paragraphIndex, i), para);
      final marks = _hlIndex[_hlKey(it.chapterIndex, it.paragraphIndex)] ?? [];
      final points = <int>{start, end};
      if (current && _wordStart >= 0 && _wordEnd > _wordStart) {
        points.add(_wordStart.clamp(start, end)); points.add(_wordEnd.clamp(start, end));
      }
      for (final h in marks) {
        if (h.charEnd > start && h.charStart < end) { points.add(h.charStart.clamp(start, end)); points.add(h.charEnd.clamp(start, end)); }
      }
      final sorted = points.toList()..sort();
      for (var j = 0; j + 1 < sorted.length; j++) {
        final left = sorted[j], right = sorted[j + 1];
        final marked = marks.where((h) => h.charStart < right && h.charEnd > left);
        final word = current && _wordStart < right && _wordEnd > left && _wordStart >= 0;
        spans.add(TextSpan(text: _layoutSegment(it, para.display.substring(left, right), left), recognizer: recognizer,
          style: TextStyle(color: word ? const Color(0xFF102A3A) : null,
            backgroundColor: word ? const Color(0xFF9BC5DD) : current ? const Color(0x44FFC107) : marked.isEmpty ? null : Color(marked.last.color),
            fontWeight: FontWeight.normal)));
      }
      cursor = end;
    }
    if (cursor < para.display.length) spans.add(TextSpan(text: _layoutSegment(it, para.display.substring(cursor), cursor)));
    return TextSpan(style: TextStyle(fontSize: _fontSize, height: _lineHeight, color: _theme.text,
      fontFamily: _fontFamily.isEmpty ? null : _fontFamily), children: spans);
  }

  double _indentWidth(Paragraph paragraph) {
    var units = 0.0;
    final leading = ReaderTypography.leadingLength(paragraph.display);
    for (var i = 0; i < leading; i++) {
      units += paragraph.display[i] == '　' ? 1 : paragraph.display[i] == '\t' ? 2 : 0.5;
    }
    return MediaQuery.textScalerOf(context).scale(_fontSize) * units;
  }

  static String _fmtTime(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  Future<void> _openBookmarks() async {
    final selected = await showModalBottomSheet<_Item>(
      context: context,
      builder: (ctx) => _BookmarkSheet(
        initial: List.of(_bookmarks),
        onDelete: (b) {
          setState(() {
            _bookmarks.removeWhere((x) => x.id == b.id);
          });
          _persistAnnotations();
          _showToast(T('bookmarkDeleted'));
        },
      ),
    );
    if (selected == null) return;
    setState(() {
      _chapter = selected.chapterIndex;
      _para = selected.paragraphIndex;
      _ttsSentence = selected.sentenceIndex;
    });
    _followSentence(selected.chapterIndex, selected.paragraphIndex, selected.sentenceIndex);
    if (_inReadingMode) _ttsFollowSeek(_chapter, _para, max(0, _ttsSentence));
    _scheduleSave();
  }

  Future<void> _openHighlights() async {
    final selected = await showModalBottomSheet<_Item>(
      context: context,
      builder: (ctx) => _HighlightSheet(
        book: _book,
        initial: List.of(_highlights),
        onDelete: (h) {
          setState(() {
            _highlights.removeWhere((x) => x.id == h.id);
            _rebuildHlIndex();
          });
          _persistAnnotations();
          _showToast(T('highlightDeleted'));
        },
      ),
    );
    if (selected == null) return;
    setState(() {
      _chapter = selected.chapterIndex;
      _para = selected.paragraphIndex;
      _ttsSentence = selected.sentenceIndex;
    });
    _followSentence(selected.chapterIndex, selected.paragraphIndex, selected.sentenceIndex);
    if (_inReadingMode) _ttsFollowSeek(_chapter, _para, max(0, _ttsSentence));
    _scheduleSave();
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 400), _saveProgress);
  }

  // ---------- 滚动/翻页 ----------

  void _jumpToItem(int index, {bool animate = true}) {
    _pageEndKey = null;
    if (!mounted || index < 0 || index >= _items.length) return;
    if (!_itemScrollController.isAttached) {
      WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _jumpToItem(index, animate: false); });
      return;
    }
    _navigationGeneration++;
    _pendingScrollIndex = index;
    _approaches = 0;
    _itemScrollController.jumpTo(index: index, alignment: 0);
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _maybeCorrectScroll(); });
  }

  Future<void> _positionViewport(int index, double alignment) async {
    if (!_itemScrollController.isAttached || !mounted) return;
    final generation = ++_navigationGeneration;
    _pendingScrollIndex = null;
    // The underlying viewport requires an anchor in [0,1]. A negative saved
    // leading edge is restored as a pixel offset after laying out that item.
    _itemScrollController.jumpTo(index: index, alignment: alignment.clamp(0.0, 1.0));
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || generation != _navigationGeneration) return;
    if (alignment < 0) {
      final height = _bodyHeight;
      await _pageScrollController.animateScroll(offset: -alignment * height, duration: const Duration(milliseconds: 1));
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  double get _bodyHeight => max(1.0, MediaQuery.sizeOf(context).height - _chapterTopArea() - _readerInsets.bottom - 32);

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

  void _pageUp() => _turnPage(-1);

  void _pageDown() => _turnPage(1);

  Future<bool> _turnPage(int direction, {bool automatic = false}) async {
    if (_ttsLoading || _paging || _items.isEmpty || !_itemScrollController.isAttached) return false;
    final old = _visibleItems();
    if (old.isEmpty) return false;
    if (!automatic && _autoActive) _autoClock.stop();
    _paging = true;
    _pendingScrollIndex = null;
    _navigationGeneration++;
    final boundary = _pageBoundary.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    try {
      if (boundary != null && !boundary.debugNeedsPaint) {
        _pageImage = boundary.toImageSync(pixelRatio: MediaQuery.devicePixelRatioOf(context).clamp(1.0, 2.0));
      }
    } catch (_) { /* A page turn still works if a frame cannot be captured. */ }
    if (!mounted) { _pageImage?.dispose(); _pageImage = null; return false; }
    setState(() {
      _pageDirection = direction; _pageReady = false;
      _outgoingPage = _pageImage == null ? null : RawImage(image: _pageImage, fit: BoxFit.fill);
    });
    var moved = false;
    try {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return false;
      final rows = _pageLines();
      final clip = _pageClipBottom ?? _bodyHeight;
      final complete = rows.where((r) => r.top >= -0.5 && r.bottom <= clip + 0.5).toList();
      if (complete.isEmpty) return false;
      final retain = _settings.pageTurnMode != 'scroll' && _settings.retainPageLine && complete.length > 1;
      _PageLine? target;
      if (direction > 0) {
        final last = complete.last;
        final candidates = rows.where((r) => r.top >= last.bottom - 0.5 && r.key != last.key).toList();
        if (candidates.isEmpty) return false;
        target = retain ? last : candidates.first;
        _pageEndKey = null;
      } else {
        final first = complete.first;
        final candidates = rows.where((r) => retain ? r.top <= first.top + 0.5 : r.bottom <= first.top + 0.5).toList();
        if (candidates.isEmpty) return false;
        final end = candidates.last;
        final fitting = candidates.where((r) => end.bottom - r.top <= _bodyHeight + 0.5).toList();
        if (fitting.isEmpty) return false;
        target = fitting.first; _pageEndKey = end.key;
      }
      if (target.top.abs() < 0.5) return false;
      // Move to an actual text-line boundary behind the frozen outgoing page.
      await _pageScrollController.animateScroll(
        offset: target.top,
        duration: const Duration(milliseconds: 1),
      );
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return false;
      _updatePageGeometry();
      final visible = _visibleItems();
      if (visible.isEmpty) {
        await _positionViewport(old.first.index, old.first.itemLeadingEdge);
        return false;
      }
      moved = visible.first.index != old.first.index ||
          (visible.first.itemLeadingEdge - old.first.itemLeadingEdge).abs() > 0.002;
      if (!moved) return false;
      var targetItem = visible.first.index;
      while (targetItem < _items.length - 1 && _items[targetItem].isTitle) { targetItem++; }
      _updatePositionFromItem(targetItem);
      _pageAnimation.value = 0;
      setState(() => _pageReady = true);
      await _pageAnimation.forward().orCancel;
      if (mounted && _inReadingMode) _ttsFollowSeek(_chapter, _para, max(0, _ttsSentence));
      return true;
    } on TickerCanceled {
      return false;
    } finally {
      if (mounted) {
        final image = _pageImage; _pageImage = null;
        setState(() { _outgoingPage = null; _pageReady = false; _paging = false; });
        WidgetsBinding.instance.addPostFrameCallback((_) => image?.dispose());
        _scheduleSave();
        if (!automatic && _autoActive && !_autoPaused) _autoClock.forward(from: 0);
      }
    }
  }

  List<ItemPosition> _visibleItems() => _itemPositionsListener.itemPositions.value
      .where((p) => p.itemTrailingEdge > 0 && p.itemLeadingEdge < 1).toList()
        ..sort((a,b) => a.index.compareTo(b.index));

  Widget _buildPageCanvas() => AnimatedBuilder(animation: _pageAnimation,
    child: _buildTapZones(child: RepaintBoundary(key: _pageBoundary, child: _buildBody())),
    builder: (context, child) {
      final v = _pageReady ? Curves.easeInOut.transform(_pageAnimation.value) : 0.0;
      return ClipRect(child: IgnorePointer(ignoring: _paging, child: Stack(fit: StackFit.expand, children: [
        FractionalTranslation(key: const ValueKey('page-incoming-transform'),
          translation: Offset(_pageReady ? _pageDirection * (1-v) : 0, 0), child: child),
        if (_viewSnapshot != null) RawImage(image: _viewSnapshot, fit: BoxFit.fill),
        if (_outgoingPage != null) FractionalTranslation(key: const ValueKey('page-outgoing-transform'),
          translation: Offset(-_pageDirection * v, 0),
          child: ColoredBox(color: _theme.bg, child: _outgoingPage!)),
      ])));
    });

  List<_PageLine> _pageLines() {
    final boundary = _pageBoundary.currentContext?.findRenderObject();
    if (boundary is! RenderBox || !boundary.hasSize) return [];
    final origin = boundary.localToGlobal(Offset.zero).dy;
    final result = <_PageLine>[];
    for (final entry in {..._titleKeys, ..._paragraphKeys}.entries) {
      final render = entry.value.currentContext?.findRenderObject();
      if (render is! RenderParagraph || !render.hasSize) continue;
      final top = render.localToGlobal(Offset.zero).dy - origin;
      if (top > _bodyExtent * 2 || top + render.size.height < -_bodyExtent) continue;
      final text = render.text.toPlainText();
      final boxes = render.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: text.length),
        boxHeightStyle: ui.BoxHeightStyle.includeLineSpacingMiddle);
      final lines = <Rect>[];
      for (final box in boxes) {
        final rect = box.toRect();
        if (rect.width < 0.01 || rect.height < 2) continue;
        final row = lines.indexWhere((r) => (r.top - rect.top).abs() < 0.5);
        if (row < 0) lines.add(rect); else lines[row] = lines[row].expandToInclude(rect);
      }
      for (final rect in lines) {
        final start = render.getPositionForOffset(Offset(-10000, rect.center.dy)).offset;
        result.add(_PageLine('${entry.key}/$start', top + rect.top, top + rect.bottom));
      }
    }
    result.sort((a,b) => a.top.compareTo(b.top));
    return result;
  }

  void _schedulePageGeometry() {
    if (_pageGeometryScheduled || !mounted) return;
    _pageGeometryScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pageGeometryScheduled = false;
      if (mounted) _updatePageGeometry();
    });
  }

  void _updatePageGeometry() {
    if (_settings.pageTurnMode == 'scroll') {
      if (_pageClipBottom != null) setState(() => _pageClipBottom = null);
      return;
    }
    final rows = _pageLines();
    var limit = _bodyExtent;
    if (_pageEndKey != null) {
      final ends = rows.where((r) => r.key == _pageEndKey);
      if (ends.isNotEmpty) limit = min(limit, ends.first.bottom);
    }
    final full = rows.where((r) => r.bottom <= limit + 0.25 && r.top >= -0.25).toList();
    final bottom = full.isEmpty ? _bodyExtent : min(_bodyExtent, full.last.bottom);
    if (_pageClipBottom == null || (_pageClipBottom! - bottom).abs() > 0.25) setState(() => _pageClipBottom = bottom);
  }

  // Skip chapter headings and empty sentences, including at chapter boundaries.
  void _moveSentence(int direction) {
    if (_ttsLoading || _paging || _items.isEmpty) return;
    var c = _chapter, p = _para, sentence = max(0, _ttsSentence) + direction;
    while (c >= 0 && c < _book.chapters.length) {
      final paragraphs = _book.chapters[c].paragraphs;
      if (p >= paragraphs.length) { c++; p = 0; sentence = 0; continue; }
      if (p < 0) { c--; if (c < 0) return; p = _book.chapters[c].paragraphs.length - 1;
        sentence = _book.chapters[c].paragraphs[p].sentences.length - 1; continue; }
      final sentences = paragraphs[p].sentences;
      if (sentence >= sentences.length) { p++; sentence = 0; continue; }
      if (sentence < 0) { p--; if (p >= 0) sentence = paragraphs[p].sentences.length - 1; continue; }
      setState(() { _chapter = c; _para = p; _ttsSentence = sentence; });
      _followSentence(c, p, sentence);
      if (_inReadingMode) _ttsFollowSeek(c, p, sentence);
      _scheduleSave(); return;
    }
  }

  void _navigateToItem(int index) {
    // A page may land on a heading; start from its first actual sentence.
    while (index < _items.length - 1 && _items[index].isTitle) {
      index++;
    }
    _updatePositionFromItem(index);
    _jumpToItem(index);
    if (_inReadingMode) {
      _ttsFollowSeek(_chapter, _para, max(0, _ttsSentence));
    }
  }

  void _updatePositionFromItem(int index) {
    final it = _items[index];
    if (it.isTitle) return;
    final visible = _visibleItems().where((p) => p.index == index);
    final offset = visible.isEmpty ? 0 : _visibleOffset(visible.first);
    final sentence = ReadingText.sentenceAt(_book.chapters[it.chapterIndex].paragraphs[it.paragraphIndex], offset);
    if (it.chapterIndex != _chapter ||
        it.paragraphIndex != _para ||
        sentence != _ttsSentence) {
      setState(() {
        _chapter = it.chapterIndex;
        _para = it.paragraphIndex;
        _ttsSentence = sentence;
      });
      _scheduleSave();
    }
  }

  void _onScroll() {
    _schedulePageGeometry();
    // 程序化跳转（章节/进度条/TTS 高亮）期间不覆盖正确位置；
    // 拖动 seek 期间由拖动逻辑控制位置。
    // TTS 朗读期间位置由 TTS 句子主导（_onTtsSentenceChanged），
    // 禁止 onScroll 覆盖，否则高亮会错位到视口顶部 item。
    if (_pendingScrollIndex != null || _suppressScrollTrack || _paging || _isPlaying) return;
    if (_restoringProgress || _restoringViewport) return;
    _scheduleSave();
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
    final sentence = ReadingText.sentenceAt(_book.chapters[it.chapterIndex].paragraphs[it.paragraphIndex], _visibleOffset(top));
    if (it.chapterIndex != _chapter ||
        it.paragraphIndex != _para ||
        sentence != _ttsSentence) {
      setState(() {
        _chapter = it.chapterIndex;
        _para = it.paragraphIndex;
        _ttsSentence = sentence;
      });
      _scheduleSave();
    }
  }

  /// 报告 item 实际渲染高度。scrollable_positioned_list 自管 item 定位，
  /// 这里仅用渲染回调驱动跳转后校正（itemPositions 二次收敛）。
  void _recordHeight(int index, double height) {
    _schedulePageGeometry();
    if (_heightCorrectionScheduled) return;
    _heightCorrectionScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _heightCorrectionScheduled = false;
      if (mounted) _maybeCorrectScroll();
    });
  }

  // ---------- TTS ----------

  /// 当前章节全部句子的 tts 文本（用于 TtsReader 整章朗读）
  List<String> _chapterTtsSentences(int c) {
    final out = <String>[];
    if (c < 0 || c >= _book.chapters.length) return out;
    for (final p in _book.chapters[c].paragraphs) {
      for (final s in p.sentences) {
        out.add(s.tts);
      }
    }
    return out;
  }

  /// 当前朗读音色（空=默认），与缓存目录的 voice 段保持一致
  String get _effectiveVoice =>
      _settings.voice.isEmpty ? TtsReader.defaultVoice : _settings.voice;

  /// 当前书/音色/语速对应的缓存（朗读与全书缓存共用同一坐标）
  TtsCacheStore _currentCacheStore() =>
      TtsCacheStore(_book.id, _effectiveVoice, _settings.speechRate, textFingerprint: _cacheFingerprint);

  String get _cacheTaskKey => '${_book.id}/$_cacheFingerprint/$_effectiveVoice/${_settings.speechRate.toStringAsFixed(2)}';

  /// 按当前书/音色/语速重建朗读侧磁盘缓存（切书/切音色/变速后调用）
  void _refreshTtsCache() {
    _tts.setCache(_currentCacheStore());
  }

  /// 章节内段落 p 之前的句子总数（TtsReader 的起始索引）
  int _chapterSentenceStart(int c, int p) {
    if (c < 0 || c >= _book.chapters.length) return 0;
    var n = 0;
    for (var i = 0; i < p && i < _book.chapters[c].paragraphs.length; i++) {
      n += _book.chapters[c].paragraphs[i].sentences.length;
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
    final paragraph = _book.chapters[it.chapterIndex].paragraphs[it.paragraphIndex];
    return (it.chapterIndex, it.paragraphIndex, ReadingText.sentenceAt(paragraph, _visibleOffset(first)));
  }

  int _visibleOffset(ItemPosition position) {
    final render = _paragraphKeys[position.index]?.currentContext?.findRenderObject();
    if (render is! RenderParagraph) return 0;
    final y = max(0.0, -position.itemLeadingEdge * _bodyExtent - 10);
    final it = _items[position.index];
    if (it.isTitle) return 0;
    return ReaderTypography.sourceOffset(_book.chapters[it.chapterIndex].paragraphs[it.paragraphIndex].display,
      render.getPositionForOffset(Offset(0, y)).offset, lineBreakAt: _lineBreakFor(it.chapterIndex, it.paragraphIndex));
  }

  void _startTtsLoading() { if (mounted) setState(() => _ttsLoading = true); }
  void _stopTtsLoading() { if (mounted && _ttsLoading) setState(() => _ttsLoading = false); }

  /// 进入朗读模式：全屏隐藏UI，开始TTS播放
  Future<void> _play() async {
    if (_inReadingMode) return;
    if (_autoActive) _stopAutoPage();
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
    _showGestureTip();
    // 从视口当前句子开始朗读（合成首句期间显示 loading）
    _startTtsLoading();
    await _startTtsFrom(startC, startP, startS);
    _stopTtsLoading();
  }

  /// 显示手势操作提示：立即显现，2.5s 后透明度 500ms 淡出
  void _showGestureTip() {
    _gestureTipTimer?.cancel();
    setState(() => _gestureTipVisible = true);
    _gestureTipTimer = Timer(const Duration(milliseconds: 2500), () {
      if (!mounted) return;
      setState(() => _gestureTipVisible = false);
    });
  }

  /// 朗读模式中暂停：保留全屏，弹出底部控制面板
  Future<void> _pauseReading() async {
    if (_ttsLoading) return; // 加载中忽略暂停，防误触
    if (_tts.state != TtsState.playing) return;
    await _tts.pause();
    await _loadMediaVolume();
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
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepMinutes = 0;
    _gestureTipTimer?.cancel();
    _gestureTipTimer = null;
    _gestureTipVisible = false;
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
    _scheduleSave();
  }

  /// 根据当前 UI 状态应用系统栏样式：
  /// - 朗读/全屏模式：immersiveSticky 彻底隐藏状态栏与导航条
  /// - UI 模式：edgeToEdge + 状态栏/导航条与 UI 栏同色(深暖黑)+白色图标，
  ///   系统栏与顶栏/底栏视觉融为一体，无突兀白条
  void _applySystemUi() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemStatusBarContrastEnforced: false,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.light,
      systemNavigationBarContrastEnforced: false,
    ));
  }

  void _applyReaderBrightness() {
    if (_settings.automaticBrightness) {
      _volumeChannel.invokeMethod('resetScreenBrightness');
    } else {
      final value = ((_settings.brightness - ReaderBrightnessControl.split) /
          (1 - ReaderBrightnessControl.split)).clamp(0.0, 1.0);
      _volumeChannel.invokeMethod('setScreenBrightness', max(0.01, value));
    }
  }

  Future<void> _syncSystemBrightness() async {
    try {
      final value = await _volumeChannel.invokeMethod<double>('getSystemBrightness');
      if (!mounted || !_settings.automaticBrightness) return;
      if (value != null) setState(() => _settings.brightness = ReaderBrightnessControl.split +
          value.clamp(0.0, 1.0) * (1 - ReaderBrightnessControl.split));
      await widget.storage.saveSettings(_settings.toJson());
    } catch (_) {}
  }

  void _setBrightness(double value) {
    setState(() { _settings.brightness = value; _settings.automaticBrightness = false; });
    _applyReaderBrightness(); widget.storage.saveSettings(_settings.toJson());
  }

  void _resetBrightness() {
    setState(() => _settings.automaticBrightness = true);
    _applyReaderBrightness(); widget.storage.saveSettings(_settings.toJson());
    _syncSystemBrightness();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _volumeForeground = state == AppLifecycleState.resumed;
    _syncMediaVolumePolling();
    if (state != AppLifecycleState.resumed) {
      _saveDebounce?.cancel(); _saveProgress();
      if (_autoActive && !_autoPaused) _pauseAutoPage();
    }
  }

  Future<void> _openAutoPage() async {
    if (_autoActive) {
      setState(() => _showAutoPanel = true);
      return;
    }
    if (_inReadingMode) await _exitReadingMode();
    if (!mounted) return;
    var seconds = _settings.autoPageSeconds;
    final selected = await showDialog<int>(context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, update) => AlertDialog(
        title: Text(T('autoPage')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(T('autoPageInterval', {'n': '$seconds'})),
          Slider(key: const ValueKey('auto-page-interval'), value: seconds.toDouble(),
            min: 1, max: 120, divisions: 119,
            onChanged: (value) => update(() => seconds = value.round())),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(T('cancel'))),
          FilledButton(key: const ValueKey('auto-page-start'), onPressed: () => Navigator.pop(ctx, seconds),
            child: Text(T('autoPageStart'))),
        ],
      )));
    if (selected == null || !mounted) return;
    setState(() {
      _settings.autoPageSeconds = selected;
      _autoActive = true; _autoPaused = false; _showAutoPanel = false;
      _showControls = false; _showQuickMenu = false;
    });
    widget.storage.saveSettings(_settings.toJson());
    _autoClock.duration = Duration(seconds: selected);
    _volumeChannel.invokeMethod('setKeepScreenOn', true);
    _autoClock.forward(from: 0);
  }

  Future<void> _advanceAutoPage() async {
    final moved = await _turnPage(1, automatic: true);
    if (!mounted || !_autoActive) return;
    if (!moved) { _stopAutoPage(); return; }
    if (!_autoPaused) _autoClock.forward(from: 0);
  }

  void _pauseAutoPage() {
    _autoClock.stop();
    _volumeChannel.invokeMethod('setKeepScreenOn', false);
    if (mounted) setState(() { _autoPaused = true; _showAutoPanel = true; });
  }

  void _resumeAutoPage() {
    _volumeChannel.invokeMethod('setKeepScreenOn', true);
    setState(() { _autoPaused = false; _showAutoPanel = false; _showControls = false; });
    if (_autoClock.value >= 1) { _autoClock.forward(from: 0); } else { _autoClock.forward(); }
  }

  void _stopAutoPage() {
    _autoClock.stop(); _autoClock.value = 0;
    _volumeChannel.invokeMethod('setKeepScreenOn', false);
    if (mounted) setState(() { _autoActive = false; _autoPaused = false; _showAutoPanel = false; _showControls = true; });
  }

  Widget _buildAutoGuide() => AnimatedBuilder(animation: _autoClock, builder: (context, child) {
    final top = _chapterTopArea();
    final height = max(1.0, MediaQuery.sizeOf(context).height - top - _readerInsets.bottom - 32);
    return Positioned(left: 16, right: 16, top: top + (height - 2) * _autoClock.value,
      child: IgnorePointer(child: Container(key: const ValueKey('auto-reading-guide'), height: 1.5,
        color: _isNight ? const Color(0xCC9BC5DD) : const Color(0xCC377C9F))));
  });

  Widget _buildAutoPanel() => Positioned(left: 0, right: 0, bottom: 0,
    child: Material(color: _menuColor, child: Padding(
      padding: EdgeInsets.fromLTRB(12, 8, 12, _readerInsets.bottom + 8),
      child: Wrap(alignment: WrapAlignment.center, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text(T('autoPageInterval', {'n': '${_settings.autoPageSeconds}'}), style: const TextStyle(color: Colors.white70)),
        TextButton(key: const ValueKey('auto-page-pause'), onPressed: _autoPaused ? _resumeAutoPage : _pauseAutoPage,
          style: TextButton.styleFrom(foregroundColor: const Color(0xFF9BC5DD)),
          child: Text(T(_autoPaused ? 'autoPageResume' : 'autoPagePause'))),
        TextButton(key: const ValueKey('auto-page-stop'), onPressed: _stopAutoPage,
          style: TextButton.styleFrom(foregroundColor: const Color(0xFF9BC5DD)), child: Text(T('autoPageStop'))),
      ]),
    )),
  );

  Widget _buildDimMask() {
    final value = _settings.brightness;
    if (_settings.automaticBrightness || value >= ReaderBrightnessControl.split) return const SizedBox.shrink();
    return Positioned.fill(child: IgnorePointer(child: ColoredBox(key: const ValueKey('reader-dim-mask'),
      color: Colors.black.withValues(alpha: (1 - value / ReaderBrightnessControl.split) * 0.85))));
  }

  Future<void> _openFontFineTune() async {
    await showModalBottomSheet<void>(context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, update) => SafeArea(child: Padding(
        padding: const EdgeInsets.all(16), child: Row(children: [
          IconButton(key: const ValueKey('font-decrease'), tooltip: T('fontDecrease'),
            icon: const Icon(Icons.remove), onPressed: () { setState(() => _settings.fontSize = max(14, _fontSize - 1));
              update(() {}); widget.storage.saveSettings(_settings.toJson()); }),
          Expanded(child: Text('${T('fontSize')} ${_fontSize.toStringAsFixed(0)}', textAlign: TextAlign.center)),
          IconButton(key: const ValueKey('font-increase'), tooltip: T('fontIncrease'),
            icon: const Icon(Icons.add), onPressed: () { setState(() => _settings.fontSize = min(64, _fontSize + 1));
              update(() {}); widget.storage.saveSettings(_settings.toJson()); }),
        ]),
      ))));
  }

  void _setTheme(int index) {
    setState(() {
      _settings.themeIndex = index;
      if (index != 2) _settings.dayThemeIndex = index;
    });
    AppAppearance.nightMode.value = _isNight;
    widget.storage.saveSettings(_settings.toJson());
  }

  void _toggleNight() => _setTheme(_isNight
      ? (_settings.dayThemeIndex == 2 ? 0 : _settings.dayThemeIndex.clamp(0, _bookThemes.length - 1)) : 2);

  void _toggleOrientation() {
    final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    SystemChrome.setPreferredOrientations(landscape
        ? [DeviceOrientation.portraitUp]
        : [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  }

  void _changeChapter(int direction) {
    if (_ttsLoading || _paging) return;
    final chapter = _chapter + direction;
    if (chapter < 0 || chapter >= _book.chapters.length) return;
    setState(() { _showQuickMenu = false; _chapter = chapter; _para = 0; _ttsSentence = 0; });
    _jumpToItem(_chapterItem(chapter), animate: false);
    if (_inReadingMode) _ttsFollowSeek(chapter, 0, 0);
    _scheduleSave();
  }

  void _enterFullscreen() {
    _applySystemUi();
  }

  void _exitFullscreen() {
    _applySystemUi();
  }

  /// 让语音跟随到 (c, p, 段内句子s)
  /// 播放中：跨章重新加载整章，同章 jumpTo 当前句
  /// 暂停/未播放：只更新阅读位置，不触发播放；跨章时保持 _ttsChapter
  /// 不变，恢复播放时由 _resumeReading 检测到不一致而重新加载
  void _ttsFollowSeek(int c, int p, int s) {
    if (c < 0 || c >= _book.chapters.length) return;
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
    if (c >= _book.chapters.length) {
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
      if (c + 1 < _book.chapters.length) {
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
      _ttsSentence = s;
    });
    _followSentence(c, p, s);
    _scheduleSave();
    _refreshTtsCache();
    await _tts.start(
      sentences,
      offsets: chapterTtsSentenceOffsets(_book.chapters[c]),
      chapterIndex: c,
      from: from,
    );
  }

  void _onTtsSentenceChanged(int idx) {
    if (!mounted || _paging) return;
    if (idx < 0) return;
    // 把 TtsReader 的句子索引映射回 (chapter, para, sIndex)
    final c = _ttsChapter;
    if (c < 0 || c >= _book.chapters.length) return;
    var remain = idx;
    int p = 0;
    int s = 0;
    var found = false;
    for (var pi = 0; pi < _book.chapters[c].paragraphs.length; pi++) {
      final n = _book.chapters[c].paragraphs[pi].sentences.length;
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
        _wordStart = -1; _wordEnd = -1;
      });
      // 高亮跟随：每次句子变化都滚动到该句子 item，保持在视口 25% 位置
      if (_itemScrollController.isAttached) {
        _followSentence(c, p, s);
      }
      _scheduleSave();
    }
  }

  void _onTtsWordChanged(int start, int end) {
    if (!mounted || !_inReadingMode) return;
    if (start < 0 || end <= start) {
      if (_wordStart >= 0) setState(() { _wordStart = -1; _wordEnd = -1; });
      return;
    }
    final para = _book.chapters[_chapter].paragraphs[_para];
    if (_ttsSentence < 0 || _ttsSentence >= para.sentenceStartTts.length) return;
    final key = '$_textSignature/$_chapter/$_para';
    if (_wordMapKey != key) { _wordMapKey = key; _wordMap = const TextCleaner().clean(para.display); }
    final base = para.sentenceStartTts[_ttsSentence];
    var left = _wordMap!.displayOffsetOfTts(base + start).clamp(0, para.display.length);
    final right = _wordMap!.displayOffsetOfTts(base + end).clamp(left, para.display.length);
    while (left < right && para.display[left].trim().isEmpty) { left++; }
    setState(() { _wordStart = left; _wordEnd = right; });
    _ensureWordVisible(left);
  }

  Future<void> _ensureWordVisible(int offset) async {
    if (_paging || _followingWord || _pendingScrollIndex != null || !_itemScrollController.isAttached) return;
    final index = _itemIndexOf(_chapter, _para);
    final paragraph = _book.chapters[_chapter].paragraphs[_para];
    final render = _paragraphKeys[index]?.currentContext?.findRenderObject();
    final positions = _visibleItems().where((p) => p.index == index);
    if (render is! RenderParagraph || positions.isEmpty) {
      _followSentence(_chapter, _para, max(0, _ttsSentence), character: offset);
      return;
    }
    final boxes = render.getBoxesForSelection(TextSelection(
      baseOffset: _renderOffset(_chapter, _para, offset),
      extentOffset: _renderOffset(_chapter, _para, min(offset + 1, paragraph.display.length))));
    if (boxes.isEmpty) return;
    final y = positions.first.itemLeadingEdge * _bodyHeight + 10 + boxes.first.top;
    if (y >= 0 && y < _bodyHeight - _fontSize * _lineHeight) return;
    _followingWord = true;
    try {
      await _pageScrollController.animateScroll(offset: y - _bodyHeight * 0.2,
        duration: const Duration(milliseconds: 1));
    } finally { _followingWord = false; }
    if (mounted) _scheduleSave();
  }

  Future<void> _followSentence(int c, int p, int sentence, {int? character}) async {
    final index = _itemIndexOf(c, p);
    final paragraph = _book.chapters[c].paragraphs[p];
    if (paragraph.sentences.isEmpty) return;
    final offset = character ?? paragraph.sentences[sentence.clamp(0, paragraph.sentences.length - 1)].displayStart;
    final painter = TextPainter(text: _paragraphSpan(_items[index], paragraph, gestures: false),
      textAlign: TextAlign.justify, textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context));
    if (ReaderTypography.leadingLength(paragraph.display) > 0) painter.setPlaceholderDimensions([
      PlaceholderDimensions(size: Size(_indentWidth(paragraph), 1), alignment: ui.PlaceholderAlignment.middle)]);
    painter.layout(maxWidth: MediaQuery.sizeOf(context).width - 32);
    final boxes = painter.getBoxesForSelection(TextSelection(baseOffset: _renderOffset(c, p, offset),
      extentOffset: _renderOffset(c, p, min(offset + 1, paragraph.display.length))));
    final top = boxes.isEmpty ? 0.0 : boxes.first.top + 10;
    painter.dispose();
    final position = _visibleItems().where((pos) => pos.index == index);
    if (position.isNotEmpty) {
      final y = position.first.itemLeadingEdge * _bodyHeight + top;
      if (y >= 0 && y < _bodyHeight - _fontSize * _lineHeight) return;
    }
    final before = _navigationGeneration;
    await _positionViewport(index, 0);
    if (!mounted || _paging || _navigationGeneration != before + 1) return;
    _pendingScrollIndex = null;
    final generation = _navigationGeneration;
    await _pageScrollController.animateScroll(offset: max(0.0, top - _bodyHeight * 0.2),
      duration: const Duration(milliseconds: 1));
    if (generation == _navigationGeneration) _scheduleSave();
  }

  void _onTtsCompleted() {
    if (!mounted) return;
    // 本章读完：自动进入下一章继续朗读
    final next = _ttsChapter + 1;
    if (next < _book.chapters.length) {
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
    final failure = _tts.lastFailure;
    final message = failure is PlatformException ? T(_tts.usesSystemVoice ? 'systemTtsUnavailable' : 'voicePlaybackFailed')
      : failure is TimeoutException || failure is EdgeTtsException && failure.kind == 'timeout'
        ? T(_tts.usesSystemVoice ? 'systemTtsTimeout' : 'onlineTtsTimeout')
      : failure is EdgeTtsException ? (failure.status != null ? T('onlineTtsRejected', {'err': '${failure.status}'}) : T('onlineTtsUnavailable'))
      : T('voicePlaybackFailed');
    _exitReadingMode();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  // 上一句 / 下一句
  void _prevSentence() => _moveSentence(-1);

  void _nextSentence() => _moveSentence(1);

  // ---------- 进度条 ----------

  /// 用章节前缀和快速算百分比（O(log n + 章内段数)，避免每次全扫全书）
  double get _percent {
    if (_chapterPrefix.isEmpty || _chapterPrefix.last == 0) return 0;
    if (_book.chapters.isEmpty) return 0;
    final c = _chapter.clamp(0, _book.chapters.length - 1);
    var before = _chapterPrefix[c];
    final paras = _book.chapters[c].paragraphs;
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
    for (final c in _book.chapters) {
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
        final para = _book.chapters[it.chapterIndex]
            .paragraphs[it.paragraphIndex];
        if (it.sentenceIndex < para.sentences.length) {
          acc += para.display.length;
        }
      }
      _itemCharPrefix.add(acc);
    }
  }

  /// 当前阅读位置对应的全局字符偏移（拖动基准）
  int get _currentCharPos {
    if (_book.chapters.isEmpty) return 0;
    final c = _chapter.clamp(0, _book.chapters.length - 1);
    var pos = _chapterPrefix[c];
    final paras = _book.chapters[c].paragraphs;
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
    if (_itemCharPrefix.length <= 1 || _book.chapters.isEmpty) {
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
    final para = _book.chapters[c].paragraphs[p];
    final sInPara = ReadingText.sentenceAt(para, charPos - _itemCharPrefix[itemIdx]);
    return (c, p, sInPara, itemIdx);
  }

  void _seekTo(double ratio) {
    final (c, p) = _locateByRatio(ratio);
    setState(() {
      _showQuickMenu = false;
      _chapter = c;
      _para = p;
      _ttsSentence = 0;
    });
    _jumpToItem(ratio <= 0 ? 0 : _itemIndexOf(c, p), animate: false);
    if (_inReadingMode) _ttsFollowSeek(c, p, 0);
    _scheduleSave();
  }

  /// 按全局比例定位 (章节, 段落)：章节前缀二分 + 章内线性（O(log n + 章内段数)）
  (int, int) _locateByRatio(double ratio) {
    if (_book.chapters.isEmpty) return (0, 0);
    final total = _chapterPrefix.isEmpty ? 0 : _chapterPrefix.last;
    if (total <= 0) return (0, 0);
    var target = ratio.clamp(0.0, 1.0) * total;
    // 二分定位章节：找 _chapterPrefix[c] <= target < _chapterPrefix[c+1]
    var lo = 0, hi = _book.chapters.length - 1;
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
    final paras = _book.chapters[c].paragraphs;
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
          title: Text(T('searchTitle')),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: InputDecoration(hintText: T('searchHint')),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, null),
                child: Text(T('cancel'))),
            TextButton(
                onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
                child: Text(T('searchTitle'))),
          ],
        );
      },
    );
    if (query == null || query.isEmpty) return;
    setState(() {
      _searchQuery = query;
    });
    final hits = <_SearchHit>[];
    for (var c = 0; c < _book.chapters.length; c++) {
      final ch = _book.chapters[c];
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
        SnackBar(content: Text(T('noMatch'))),
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
    _syncMediaVolumePolling();
    _viewportSize = MediaQuery.sizeOf(context);
    _bodyExtent = _bodyHeight;
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
            padding: EdgeInsets.only(
              top: _chapterBarTop() + _chapterTopArea(),
              bottom: _readerInsets.bottom + 32,
            ),
            child: _buildPageCanvas(),
          ),
          // 固定章节标题：位于顶部两行半空白之后，正文滚动时保持不动
          Positioned(
            top: max(24.0, _readerInsets.top) + 12,
            left: 0,
            right: 0,
            child: _buildChapterHeader(),
          ),
          // 三区点击层
          _buildReadingStatus(),
          // 拖动 seek 预览浮层
          // 朗读模式底部控制面板（暂停时显示）
          if (_inReadingMode && _showReadingPanel) _buildReadingPanel(),
          if (_showControls && _showQuickMenu) _buildQuickMenu(),
          // 顶部控制栏
          if (_showControls) _buildTopBar(),
          // 底部进度条
          if (_showControls) _buildBottomBar(),
          // 章节悬浮球
          if (_showControls) _buildFloatingChapter(),
          // 查找结果浮动条
          if (_showControls && _searchHits.isNotEmpty) _buildSearchBar(),
          // 手势操作提示条（开始播放时短暂提示，2.5s 后淡出）
          if (_inReadingMode) _buildGestureTip(),
          // TTS 加载中浮层（朗读模式点击恢复播放时显示）
          if (_inReadingMode && _ttsLoading) _buildTtsLoadingOverlay(),
            // 亮度遮罩
            if (_autoActive) _buildAutoGuide(),
            if (_autoActive && _showAutoPanel) _buildAutoPanel(),
            _buildDimMask(),
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.6, color: Color(0xFF9BC5DD)),
                ),
                const SizedBox(height: 12),
                Text(T('loadingVoice'),
                    style: const TextStyle(color: Colors.white, fontSize: 14)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 手势操作提示条：屏幕中下部半透明圆角胶囊，2.5s 后透明度淡出
  Widget _buildGestureTip() {
    return Positioned(
      left: 24, right: 24,
      bottom: _readerInsets.bottom + 100,
      child: IgnorePointer(child: AnimatedOpacity(
        opacity: _gestureTipVisible ? 1 : 0,
        duration: const Duration(milliseconds: 500),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: const Color(0xEE333333), borderRadius: BorderRadius.circular(8)),
          child: Text(T(_settings.pageTurnMode == 'tap' ? 'readTapHint' :
            _settings.pageTurnMode == 'swipe' ? 'volHint' : 'readSentenceHint'), textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 13)),
        ),
      )),
    );
  }

  Widget _buildReadingStatus() {
    return Positioned(left: 16, right: 16, bottom: _readerInsets.bottom + 8,
      child: IgnorePointer(child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          StreamBuilder<int>(stream: Stream.periodic(const Duration(minutes: 1), (i) => i),
            builder: (context, snapshot) {
              final now = DateTime.now();
              return Text('${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
                style: TextStyle(fontSize: 12, color: _theme.title));
            }),
          Text('${(_percent * 100).toStringAsFixed(1)}%', style: TextStyle(fontSize: 12, color: _theme.title)),
        ],
      )),
    );
  }

  /// 章节标题行文案：标题已含"第X章/Chapter"则原样，否则加章节序号
  String _chapterBarTitle(int c) {
    if (c < 0 || c >= _book.chapters.length) return '';
    final t = _book.chapters[c].title.trim();
    if (t.startsWith('第') ||
        t.toLowerCase().startsWith('chapter') ||
        t.startsWith('序') ||
        t.startsWith('楔')) {
      return t;
    }
    return '第${c + 1}章 $t';
  }

  /// 章节标题行距屏幕顶的偏移：恒为 0。
  /// 正文区（空两行半→章节标题→正文）位置固定紧凑，不随顶栏显隐变化；
  /// 顶栏是 Positioned 悬浮覆盖层，悬浮在正文区上方，不占位、不影响正文区。
  double _chapterBarTop() => 0;

  /// Compact header space remains stable when controls appear.
  double _chapterTopArea() => max(24.0, _readerInsets.top) + 20 + _fontSize * _lineHeight;

  /// 章节标题栏：固定在正文区顶部（正文区布局的一部分，非悬浮），
  /// 位于顶部两行半空白之后，一行高显示章节名，
  /// 滚动/朗读切换章节时实时跟随（_chapter 变化触发重建）
  Widget _buildChapterHeader() {
    return Container(
      height: _fontSize * _lineHeight,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: _theme.bg,
        border: Border(
          bottom: BorderSide(
            color: _theme.title.withValues(alpha: 0.18),
          ),
        ),
      ),
      child: Align(
        alignment: Alignment.center,
        child: Text(
          _chapterBarTitle(_chapter),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.normal,
            color: _theme.title,
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    return ClipRect(key: const ValueKey('reader-page-clip'), clipper: _ReaderPageClipper(
      _settings.pageTurnMode == 'scroll' ? null : _pageClipBottom),
      child: KeyedSubtree(key: ValueKey(_textSignature), child: ScrollablePositionedList.builder(
      key: const ValueKey('reader-body'),
      itemScrollController: _itemScrollController,
      scrollOffsetController: _pageScrollController,
      itemPositionsListener: _itemPositionsListener,
      initialScrollIndex: 0,
      initialAlignment: 0,
      // Only reading mode replaces free scrolling with sentence/page gestures.
      physics: _inReadingMode || _settings.pageTurnMode != 'scroll' ? const NeverScrollableScrollPhysics() : const ClampingScrollPhysics(),
      // 增大缓存区：跳转后能渲染更多 item，加速精确定位
      minCacheExtent: 1500,
      // 顶部留白由 Column 的标题栏承担；底部留 120 给进度条/朗读面板
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
      itemCount: _items.length,
      itemBuilder: (ctx, i) {
        final it = _items[i];
        final Widget child;
        if (it.isTitle) {
          child = Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              it.title,
              key: _titleKeys.putIfAbsent(i, () => GlobalKey()),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: _fontSize + 6,
                fontWeight: FontWeight.bold,
                color: _theme.title,
                height: _lineHeight,
                fontFamily: _fontFamily.isEmpty ? null : _fontFamily,
              ),
            ),
          );
        } else {
          final para = _book.chapters[it.chapterIndex]
              .paragraphs[it.paragraphIndex];
          child = Padding(padding: const EdgeInsets.only(top: 10, bottom: 2),
            child: Text.rich(_paragraphSpan(it, para),
              key: _paragraphKeys.putIfAbsent(i, () => GlobalKey()),
              textAlign: TextAlign.justify));
        }

        return _HeightReporter(
          onHeight: (h) => _recordHeight(i, h),
          child: child,
        );
      },
    )));
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
          bottom: _readerInsets.bottom + 14,
        ),
        decoration: BoxDecoration(
          color: _menuColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                const SizedBox(width: 44, height: 44, child: Icon(Icons.volume_down, color: Color(0xFF9BC5DD), size: 20)),
                Expanded(child: Slider(key: const ValueKey('reading-volume-slider'),
                  padding: const EdgeInsets.symmetric(horizontal: 12), value: _mediaVolume.clamp(0.0, 1.0),
                  min: 0, max: 1, activeColor: const Color(0xFF9BC5DD), inactiveColor: const Color(0x44C9A96E),
                  onChangeStart: (_) { _volumeDragging = true; _volumeRevision++; },
                  onChangeEnd: (_) { _volumeDragging = false; _volumeRevision++; },
                  onChanged: _setMediaVolume)),
                const SizedBox(width: 44, height: 44, child: Icon(Icons.volume_up, color: Color(0xFF9BC5DD), size: 20)),
              ]),
              Text(T('rateLabel', {'rate': rate.toStringAsFixed(1)}),
                style: const TextStyle(color: Color(0xFF9BC5DD), fontSize: 12)),
              Row(children: [
                SizedBox(width: 44, height: 44, child: IconButton(key: const ValueKey('reading-rate-minus'),
                  padding: EdgeInsets.zero, icon: const Icon(Icons.remove_circle_outline, color: Color(0xFF9BC5DD)),
                  onPressed: () => _adjustRate(-0.1))),
                Expanded(child: Slider(key: const ValueKey('reading-rate-slider'),
                  padding: const EdgeInsets.symmetric(horizontal: 12), value: rate.clamp(0.5, 3.0),
                  min: 0.5, max: 3, divisions: 25, activeColor: const Color(0xFF9BC5DD), inactiveColor: const Color(0x44C9A96E),
                  onChanged: _setRate)),
                SizedBox(width: 44, height: 44, child: IconButton(key: const ValueKey('reading-rate-plus'),
                  padding: EdgeInsets.zero, icon: const Icon(Icons.add_circle_outline, color: Color(0xFF9BC5DD)),
                  onPressed: () => _adjustRate(0.1))),
              ]),
              const SizedBox(height: 4),
              // 功能按钮行
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _panelButton(
                    icon: Icons.alarm,
                    label: _sleepMinutes > 0
                        ? T('minutes', {'m': '$_sleepMinutes'})
                        : T('timer'),
                    onTap: _openSleepTimer,
                    active: _sleepMinutes > 0,
                  ),
                  _panelButton(
                    icon: Icons.record_voice_over,
                    label: T('voice'),
                    onTap: _openVoiceSelector,
                  ),
                  _panelButton(
                    icon: Icons.lock_outline,
                    label: T('lock'),
                    onTap: _enterFakeLock,
                  ),
                  _panelButton(
                    icon: Icons.power_settings_new,
                    label: T('exit'),
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
              color: active ? const Color(0xFF9BC5DD) : const Color(0xFF9BC5DD),
              size: 26),
          const SizedBox(height: 4),
          Text(label,
              style: TextStyle(
                  color: active
                      ? const Color(0xFF9BC5DD)
                      : const Color(0xFFA89060),
                  fontSize: 11)),
        ],
      ),
    );
  }

  /// 读取当前系统媒体音量（0.0~1.0）
  Future<void> _loadMediaVolume({bool panelPoll = false}) async {
    if (_volumeReadInFlight || _volumeDragging || _volumeWrites > 0 || (panelPoll && !_volumePanelVisible)) return;
    _volumeReadInFlight = true;
    final revision = _volumeRevision, epoch = _volumePollEpoch;
    try {
      final v = await _volumeChannel.invokeMethod<double>('getMediaVolume');
      if (v != null && mounted && revision == _volumeRevision && epoch == _volumePollEpoch &&
          !_volumeDragging && (!panelPoll || _volumePanelVisible)) {
        final value = v.clamp(0.0, 1.0);
        if ((value - _mediaVolume).abs() > 0.0001) setState(() => _mediaVolume = value);
      }
    } catch (_) {} finally { _volumeReadInFlight = false; }
  }

  void _syncMediaVolumePolling() {
    if (_volumePanelVisible) {
      _volumePollTimer ??= Timer.periodic(const Duration(milliseconds: 250), (_) => _loadMediaVolume(panelPoll: true));
    } else if (_volumePollTimer != null) {
      _volumePollTimer!.cancel(); _volumePollTimer = null; _volumePollEpoch++;
    }
  }

  /// Optimistic slider updates win over older reads until the system write completes.
  void _setMediaVolume(double v) {
    _volumeRevision++; _volumeWrites++;
    setState(() => _mediaVolume = v.clamp(0.0, 1.0));
    unawaited(_volumeChannel.invokeMethod<void>('setMediaVolume', _mediaVolume)
      .catchError((Object _) {}).whenComplete(() => _volumeWrites--));
  }

  void _adjustRate(double delta) {
    _setRate((_settings.speechRate + delta).clamp(0.5, 3.0));
  }

  void _setRate(double rate) {
    _settings.speechRate = rate;
    _tts.setSpeechRate(rate);
    _refreshTtsCache();
    widget.storage.saveSettings(_settings.toJson());
    setState(() {});
  }

  /// 进入假锁屏：全黑 + 长按解锁；保持 app 前台使蓝牙耳机键可控，
  /// 屏幕常亮 + 亮度压到最低，防止系统真锁屏/灭屏抢走媒体键。
  /// 锁屏即听书：进入时若未在播放，自动恢复朗读。
  Future<void> _enterFakeLock() async {
    if (_fakeLock) return;
    setState(() => _fakeLock = true);
    _volumeChannel.invokeMethod('setKeepScreenOn', true);
    _volumeChannel.invokeMethod('setScreenBrightness', 0.03);
    if (_tts.state != TtsState.playing) {
      _resumeReading();
    }
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
    _applyReaderBrightness();
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
                      ? const Color(0xFF8A8A8A)
                      : const Color(0xFF4E4E4E),
                ),
                const SizedBox(height: 14),
                Text(
                  _lockPressing ? T('keepHolding') : T('holdToUnlock'),
                  style: TextStyle(
                    color: _lockPressing
                        ? const Color(0xFF9A9A9A)
                        : const Color(0xFF5C5C5C),
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
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(T('timerStop'),
                  style:
                      const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
            const Divider(height: 1),
            ...options.map((m) => ListTile(
                  leading: Icon(
                    m == _sleepMinutes
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: const Color(0xFF6498B5),
                  ),
                  title: Text(m == 0
                      ? T('timerOff')
                      : T('timerAfter', {'m': '$m'})),
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
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(T('pageTheme'),
                    style:
                        const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
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
                        _setTheme(i);
                        setSheetState(() {});
                        widget.storage.saveSettings(_settings.toJson());
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          color: t.bg,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: selected ? const Color(0xFF6498B5) : Colors.transparent,
                            width: selected ? 2.5 : 0,
                          ),
                          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 4)],
                        ),
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(t.labelKey == null ? t.name : T(t.labelKey!),
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.title)),
                            const SizedBox(height: 6),
                            Text(T('previewText'), style: TextStyle(fontSize: 10, color: t.text, height: 1.4)),
                            const Spacer(),
                            if (selected) const Align(alignment: Alignment.bottomRight, child: Icon(Icons.check_circle, size: 18, color: Color(0xFF6498B5))),
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

  /// 切换朗读音源：默认语言组置顶，其余语言按组分列
  Future<void> _openVoiceSelector() async {
    final voices = sortedEdgeVoices();
    final items = <Widget>[ListTile(
      leading: Icon(_settings.voice == TtsReader.systemVoice ? Icons.radio_button_checked : Icons.radio_button_off),
      title: Text(T('systemTts')), subtitle: Text(T('systemTtsDescription')),
      onTap: () => Navigator.pop(context, TtsReader.systemVoice)), const Divider()];
    String? lastLang;
    for (final v in voices) {
      if (v.langCode != lastLang) {
        lastLang = v.langCode;
        items.add(Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
          child: Text(
            _groupLabel(v.langCode),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ));
      }
      items.add(ListTile(
        dense: true,
        leading: Icon(
          v.id == _settings.voice
              ? Icons.radio_button_checked
              : Icons.radio_button_off,
          color: const Color(0xFF6498B5),
        ),
        title: Text(_voiceLabel(v.id)),
        onTap: () => Navigator.pop(context, v.id),
      ));
    }
    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(T('voiceTitle'),
                  style:
                      const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
            const Divider(height: 1),
            Flexible(child: ListView(shrinkWrap: true, children: items)),
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

  /// 全书语音缓存管理：任务控制（开始/暂停/继续/取消）+ 缓存占用 + 清除
  Future<void> _openBookCache() async {
    if (_settings.voice == TtsReader.systemVoice) { _showToast(T('cacheOnlineOnly')); return; }
    final store = _currentCacheStore();
    final task = activeBookCaches[_cacheTaskKey] ??
        (activeBookCaches[_cacheTaskKey] = BookCacheTask(
              book: _book,
              bookId: _book.id,
              store: store,
            ));
    // 重进页面/进程重启后任务实例为空：先从磁盘恢复已有缓存，避免"整本缓存为 0"
    if (task.status.state == 'idle') {
      await task.restoreFromDisk();
    }
    var sizeBytes = 0;
    var sizeLoaded = false;

    String fmtSize(int bytes) {
      if (bytes <= 0) return '0 B';
      if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }

    String stateText(String state, int done, int total) {
      switch (state) {
        case 'building':
          return T('cacheScanning');
        case 'caching':
          return T('cacheProgress', {'done': '$done', 'total': '$total'});
        case 'paused':
          return T('cachePaused', {'done': '$done', 'total': '$total'});
        case 'done':
          return T('cacheDone', {'done': '$done', 'total': '$total'});
        case 'cancelled':
          return T('cacheCancelled');
        default:
          return T('cacheIdle');
      }
    }

    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          // 弹层内嵌状态：缓存大小只异步刷新一次（防 rebuild 循环）
          if (!sizeLoaded) {
            sizeLoaded = true;
            store.sizeBytes().then((s) {
              if (ctx.mounted) setSheetState(() => sizeBytes = s);
            });
          }
          return SafeArea(
            child: ValueListenableBuilder<BookCacheStatus>(
              valueListenable: task.statusNotifier,
              builder: (ctx, st, _) {
                final active = st.isActive;
                return Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.file_download_outlined,
                              color: Color(0xFF6498B5)),
                          const SizedBox(width: 10),
                          Text(T('voiceCacheTitle'),
                              style: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.bold)),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          if (active)
                            const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Color(0xFF6498B5)),
                            )
                          else
                            Icon(
                              st.isDone
                                  ? Icons.check_circle_outline
                                  : Icons.info_outline,
                              size: 18,
                              color: st.isDone
                                  ? const Color(0xFF4C8C4A)
                                  : Theme.of(ctx).colorScheme.onSurfaceVariant,
                            ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              stateText(st.state, st.done, st.total),
                              style: const TextStyle(fontSize: 14),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        T('cacheSize', {'size': fmtSize(sizeBytes)}),
                        style: TextStyle(
                            fontSize: 13, color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (active) ...[
                            TextButton(
                              onPressed: st.state == 'caching'
                                  ? () => task.pause()
                                  : null,
                              child: Text(T('cachePause')),
                            ),
                            TextButton(
                              onPressed: () => task.cancel(),
                              child: Text(T('cacheCancel')),
                            ),
                          ] else if (st.isPaused) ...[
                            TextButton(
                              onPressed: () => task.resume(),
                              child: Text(T('cacheResume')),
                            ),
                            TextButton(
                              onPressed: () => task.cancel(),
                              child: Text(T('cacheCancel')),
                            ),
                          ] else ...[
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                FilledButton(
                                  onPressed: () =>
                                      task.start(resume: !st.isDone),
                                  child: Text(st.isDone
                                      ? T('cacheRestart')
                                      : T('cacheStart')),
                                ),
                                const SizedBox(width: 8),
                                OutlinedButton(
                                  onPressed: () async {
                                    final ok = await showDialog<bool>(
                                      context: ctx,
                                      builder: (dctx) => AlertDialog(
                                        title: Text(T('cacheClear')),
                                        content: Text(T('cacheClearConfirm')),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(dctx, false),
                                            child: Text(T('cancel')),
                                          ),
                                          FilledButton(
                                            onPressed: () =>
                                                Navigator.pop(dctx, true),
                                            child: Text(T('ok')),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (ok != true) return;
                                    task.cancel();
                                    activeBookCaches.remove(_cacheTaskKey);
                                    await store.clear();
                                    if (ctx.mounted) {
                                      setSheetState(() => sizeBytes = 0);
                                      ScaffoldMessenger.of(ctx).showSnackBar(
                                        SnackBar(
                                            content: Text(T('cacheCleared'))),
                                      );
                                    }
                                  },
                                  child: Text(T('cacheClear')),
                                ),
                              ],
                            ),
                            if (!st.isDone)
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton(
                                  onPressed: () =>
                                      _startCacheFromCurrent(task),
                                  child: Text(T('cacheFromHere')),
                                ),
                              ),
                          ],
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }

  /// 从"目前进度"开始缓存：以当前朗读位置（或当前阅读章节）为起点，
  /// 只缓存该句/该章之后的句子。
  void _startCacheFromCurrent(BookCacheTask task) {
    int? fromChapter;
    int? fromOffset;
    if (_ttsChapter >= 0 && _ttsChapter < _book.chapters.length) {
      final offs =
          chapterTtsSentenceOffsets(_book.chapters[_ttsChapter]);
      // _ttsSentence 是段内句子序号，累加段前句子数得到章内全局序号
      var global = _ttsSentence;
      for (var pi = 0; pi < _para; pi++) {
        global += _book.chapters[_ttsChapter]
            .paragraphs[pi]
            .sentences
            .length;
      }
      if (global >= 0 && global < offs.length) {
        fromChapter = _ttsChapter;
        fromOffset = offs[global];
      }
    }
    fromChapter ??= _chapter.clamp(0, _book.chapters.length - 1);
    fromOffset ??= 0;
    task.start(resume: false, fromChapter: fromChapter, fromOffset: fromOffset);
  }

  Widget _buildTapZones({required Widget child}) {
    // 朗读模式点击播放/暂停，滑动切句或翻页；普通阅读保留原操作。
    final inReading = _inReadingMode;
    return ReaderGestures(
        enabled: inReading || _settings.pageTurnMode == 'swipe',
        sentenceSwipesEnabled: inReading,
        onPreviousSentence: _prevSentence,
        onNextSentence: _nextSentence,
        onPreviousPage: () { if (_settings.pageTurnMode == 'swipe') _pageUp(); },
        onNextPage: () { if (_settings.pageTurnMode == 'swipe') _pageDown(); },
        onTapUp: _autoActive
            ? (_) => setState(() { _showAutoPanel = !_showAutoPanel; _showControls = _showAutoPanel; })
            : inReading
            ? (details) {
                if (_tapPage(details)) return;
                if (_ttsLoading) return; // 加载中忽略点击，防误触
                if (_isPlaying) {
                  _pauseReading();
                } else {
                  _resumeReading();
                }
              }
            : (details) {
                if (_tapPage(details)) return;
                setState(() { _showControls = !_showControls; _showQuickMenu = false; });
                _applySystemUi();
              },
        child: child,
    );
  }

  bool _tapPage(TapUpDetails details) {
    if (_settings.pageTurnMode != 'tap') return false;
    final width = MediaQuery.sizeOf(context).width;
    if (details.globalPosition.dx < width / 3) { _pageUp(); return true; }
    if (details.globalPosition.dx > width * 2 / 3) { _pageDown(); return true; }
    return false;
  }

  Widget _buildTopBar() {
    return Positioned(top: 0, left: 0, right: 0,
      child: Material(color: _menuColor,
        child: Padding(padding: EdgeInsets.only(top: _readerInsets.top, left: 4, right: 4, bottom: 4),
          child: Row(children: [
            IconButton(tooltip: T('back'), icon: const ReaderIcon(ReaderSymbol.back, color: Colors.white70),
              onPressed: () async {
                if (_inReadingMode) await _exitReadingMode();
                _scheduleSave();
                if (mounted) Navigator.of(context).pop();
              }),
            const Spacer(),
            IconButton(tooltip: T('read'), icon: const ReaderIcon(ReaderSymbol.headphones, color: Colors.white70),
              onPressed: _ttsLoading ? null : _play),
            IconButton(key: const ValueKey('night-mode'), tooltip: T(_isNight ? 'dayMode' : 'nightMode'),
              icon: ReaderIcon(_isNight ? ReaderSymbol.sun : ReaderSymbol.moon, color: Colors.white70), onPressed: _toggleNight),
            IconButton(key: const ValueKey('reader-menu'), tooltip: T('readerMenu'),
              icon: ReaderIcon(ReaderSymbol.more, color: _showQuickMenu ? const Color(0xFF9BC5DD) : Colors.white70),
              onPressed: () => setState(() => _showQuickMenu = !_showQuickMenu)),
          ]),
        ),
      ),
    );
  }

  Widget _quickAction(ReaderSymbol symbol, String label, VoidCallback action) => Expanded(
    child: IconButton(tooltip: label, iconSize: 28,
      icon: ReaderIcon(symbol, size: 28, color: Colors.white70),
      onPressed: () { setState(() => _showQuickMenu = false); action(); }),
  );

  Widget _buildQuickMenu() {
    final width = min(312.0, MediaQuery.sizeOf(context).width - 16);
    final maxHeight = MediaQuery.sizeOf(context).height - _readerInsets.top - 72;
    return Positioned.fill(child: Stack(children: [
      GestureDetector(behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _showQuickMenu = false)),
      Positioned(top: _readerInsets.top + 56, right: 8, width: width,
        child: SliderTheme(data: SliderTheme.of(context).copyWith(
          trackHeight: 1,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 4),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
          tickMarkShape: SliderTickMarkShape.noTickMark,
          activeTrackColor: Colors.white54, inactiveTrackColor: Colors.white24, thumbColor: Colors.white70,
        ), child: Material(color: _menuColor, borderRadius: BorderRadius.circular(3),
          child: ConstrainedBox(constraints: BoxConstraints(maxHeight: maxHeight),
            child: SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(8),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                ReaderBrightnessControl(value: _settings.brightness, automatic: _settings.automaticBrightness,
                  foregroundColor: Colors.white70,
                  sliderKey: const ValueKey('quick-brightness'), onChanged: _setBrightness, onAutomatic: _resetBrightness),
                Row(children: [
                  Expanded(child: Slider(padding: const EdgeInsets.symmetric(horizontal: 12), value: _settings.fontSize.clamp(14, 64), min: 14, max: 64, divisions: 50,
                    onChanged: (value) {
                      setState(() => _settings.fontSize = value); widget.storage.saveSettings(_settings.toJson());
                    })),
                  SizedBox(width: 44, height: 44, child: TextButton(key: const ValueKey('font-fine-tune'), onPressed: () {
                    setState(() => _showQuickMenu = false); _openFontFineTune();
                  }, style: TextButton.styleFrom(minimumSize: const Size(44, 44), padding: EdgeInsets.zero),
                    child: const Text('T±', style: TextStyle(fontSize: 20, color: Colors.white70)))),
                ]),
                Row(children: [
                  _quickAction(ReaderSymbol.note, T('highlight'), _openHighlights),
                  _quickAction(ReaderSymbol.search, T('searchTitle'), _openSearch),
                  _quickAction(ReaderSymbol.theme, T('pageTheme'), _openThemePanel),
                  _quickAction(ReaderSymbol.play, T('autoPage'), _openAutoPage),
                ]),
                Row(children: [
                  const Expanded(child: SizedBox()),
                  _quickAction(ReaderSymbol.bookmark, T('addBookmark'), _addCurrentBookmark),
                  _quickAction(ReaderSymbol.rotate, T('rotateScreen'), _toggleOrientation),
                  _quickAction(ReaderSymbol.settings, T('readerSettings'), () => _openSettingsPanel('all')),
                ]),
              ]),
            )),
          ),
        )),
      ),
    ]));
  }

  Widget _buildBottomBar() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        decoration: BoxDecoration(
          color: _menuColor,
          border: const Border(
            top: BorderSide(color: Color(0x33777777), width: 1.5),
          ),
        ),
        padding: EdgeInsets.only(
          left: 12,
          right: 12,
          top: 6,
          bottom: _readerInsets.bottom + 6,
        ),
        child: Row(
          children: [
            IconButton(
              icon: const ReaderIcon(ReaderSymbol.previousChapter, size: 18, color: Colors.white70),
              visualDensity: VisualDensity.compact,
              key: const ValueKey('previous-chapter'),
              onPressed: _chapter > 0 ? () => _changeChapter(-1) : null,
              tooltip: T('previousChapter'),
            ),
            Text(
              '${(_percent * 100).toStringAsFixed(1)}%',
              style: const TextStyle(fontSize: 12, color: Color(0xFFD6D6D6)),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Slider(
                value: _percent,
                activeColor: const Color(0xFF9BC5DD),
                inactiveColor: const Color(0x55FFFFFF),
                onChanged: (v) => _seekTo(v),
              ),
            ),
            const SizedBox(width: 4),
            Text(
              T('chapterIndicator',
                  {'c': '${_chapter + 1}', 'total': '${_book.chapters.length}'}),
              style: const TextStyle(fontSize: 11, color: Color(0xFFD6D6D6)),
            ),
            IconButton(
              icon: const ReaderIcon(ReaderSymbol.nextChapter, size: 18, color: Colors.white70),
              visualDensity: VisualDensity.compact,
              key: const ValueKey('next-chapter'),
              onPressed: _chapter < _book.chapters.length - 1 ? () => _changeChapter(1) : null,
              tooltip: T('nextChapter'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFloatingChapter() => Positioned(
    left: 0, top: MediaQuery.sizeOf(context).height / 2 - 24,
    child: Material(color: const Color(0xDD333333),
      borderRadius: const BorderRadius.horizontal(right: Radius.circular(14)),
      child: InkWell(key: const ValueKey('contents-handle'), onTap: _openChapterList,
        borderRadius: const BorderRadius.horizontal(right: Radius.circular(14)),
        child: Tooltip(message: T('toc'), child: const SizedBox(width: 16, height: 48,
          child: Center(child: ReaderIcon(ReaderSymbol.contents, size: 12, color: Colors.white70)))),
      ),
    ),
  );

  Future<void> _openChapterList() async {
    final selected = await showGeneralDialog<int>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black38,
      transitionDuration: const Duration(milliseconds: 220),
      transitionBuilder: (ctx, animation, secondary, child) => SlideTransition(
        position: Tween(begin: const Offset(-1, 0), end: Offset.zero).animate(animation), child: child),
      pageBuilder: (ctx, animation, secondary) => Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(width: MediaQuery.of(ctx).size.width * 0.72,
          height: double.infinity,
          child: Theme(data: ThemeData.dark(useMaterial3: true).copyWith(
            colorScheme: const ColorScheme.dark(primary: Color(0xFF9BC5DD), surface: Color(0xFF2D3032))),
            child: Material(color: const Color(0xFF2D3032),
              child: SafeArea(child: _ChapterSheet(book: _book, current: _chapter)))),
        ),
      ),
    );
    if (selected == -1) { _openBookmarks(); return; }
    if (selected == null) return;
    setState(() {
      _chapter = selected;
      _para = 0;
    });
    _jumpToItem(_chapterItem(selected), animate: false);
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
          color: _isNight ? const Color(0xFF222222) : const Color(0xE6FFFFFF),
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
                T('searchHit', {
                  'q': _searchQuery,
                  'idx': '${_searchIndex + 1}',
                  'total': '${_searchHits.length}',
                }),
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

  // 设置面板（由右上角菜单触发）
  /// 音色显示名：中文界面显示中文友好名，其他界面显示英文名
  static String _voiceLabel(String id) {
    if (id == TtsReader.systemVoice) return T('systemTts');
    for (final v in edgeVoices) {
      if (v.id == id) {
        return (AppI18n.current == AppLang.zhHans ||
                AppI18n.current == AppLang.zhHant)
            ? v.zhName
            : v.enName;
      }
    }
    return id;
  }

  /// 音色组标题（语言自称，各界面语言下通用）
  static String _groupLabel(String langCode) => switch (langCode) {
        'zh-CN' => AppLang.zhHans.nativeName,
        'zh-TW' => AppLang.zhHant.nativeName,
        'en' => AppLang.en.nativeName,
        'ja-JP' => AppLang.ja.nativeName,
        'ko-KR' => AppLang.ko.nativeName,
        _ => langCode,
      };

  void _setFlowBreak(int chapter, int paragraph, int offset) {
    final text = _book.chapters[chapter].paragraphs[paragraph].display;
    if (offset <= ReaderTypography.leadingLength(text) || offset >= text.length) return;
    _flowChapter = chapter; _flowParagraph = paragraph; _flowOffset = offset;
  }

  _ReaderLineAnchor? _captureLineAnchor() {
    final positions = _visibleItems();
    if (positions.isEmpty) return null;
    final position = positions.first;
    final it = _items[position.index];
    if (it.isTitle) return _ReaderLineAnchor(it.chapterIndex, 0, position.itemLeadingEdge * _bodyExtent, title: true);
    final render = _paragraphKeys[position.index]?.currentContext?.findRenderObject();
    if (render is! RenderParagraph) return null;
    final y = max(0.0, -position.itemLeadingEdge * _bodyExtent - 10);
    final lineStart = render.getPositionForOffset(Offset(-10000, y)).offset;
    final text = _book.chapters[it.chapterIndex].paragraphs[it.paragraphIndex].display;
    var sourceOffset = ReaderTypography.sourceOffset(text, lineStart, lineBreakAt: _lineBreakFor(it.chapterIndex, it.paragraphIndex));
    while (sourceOffset < text.length && text[sourceOffset].trim().isEmpty) { sourceOffset++; }
    final start = _renderOffset(it.chapterIndex, it.paragraphIndex, sourceOffset);
    final end = _renderOffset(it.chapterIndex, it.paragraphIndex, min(sourceOffset + 1, text.length));
    final boxes = render.getBoxesForSelection(TextSelection(baseOffset: start, extentOffset: end));
    final top = position.itemLeadingEdge * _bodyExtent + 10 + (boxes.isEmpty ? 0 : boxes.first.top);
    return _ReaderLineAnchor(it.chapterIndex, ReadingText.anchor(_book, it.chapterIndex, it.paragraphIndex, sourceOffset), top);
  }

  Future<void> _restoreLineAnchor(_ReaderLineAnchor? anchor) async {
    final revision = ++_viewRevision;
    try {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || revision != _viewRevision) return;
      if (anchor == null) { _jumpToItem(_itemIndexOf(_chapter, _para), animate: false); return; }
      if (anchor.title) { await _positionViewport(_chapterItem(anchor.chapter), anchor.top / _bodyExtent); return; }
      final location = ReadingText.locate(_book, anchor.chapter, anchor.source);
      final index = _itemIndexOf(anchor.chapter, location.$1);
      await _positionViewport(index, 0);
      if (!mounted || revision != _viewRevision) return;
      final render = _paragraphKeys[index]?.currentContext?.findRenderObject();
      if (render is! RenderParagraph) return;
      final text = _book.chapters[anchor.chapter].paragraphs[location.$1].display;
      final boxes = render.getBoxesForSelection(TextSelection(
        baseOffset: _renderOffset(anchor.chapter, location.$1, location.$2),
        extentOffset: _renderOffset(anchor.chapter, location.$1, min(location.$2 + 1, text.length))));
      final offset = 10 + (boxes.isEmpty ? 0.0 : boxes.first.top) - anchor.top;
      await _pageScrollController.animateScroll(offset: offset, duration: const Duration(milliseconds: 1));
      await WidgetsBinding.instance.endOfFrame;
    } finally {
      if (mounted && revision == _viewRevision) {
        final image = _viewSnapshot;
        setState(() { _restoringViewport = false; _viewSnapshot = null; _reformatAnchor = null; });
        WidgetsBinding.instance.addPostFrameCallback((_) => image?.dispose());
        _scheduleSave();
      }
    }
  }

  void _openSettingsPanel(String kind) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => _SettingsSheet(
        settings: _settings,
        onCache: _openBookCache,
        onFontTune: _openFontFineTune,
        onChanged: (s) {
          final textChanged = _textSignature != _formatSignature(s);
          final voiceChanged = (s.voice.isEmpty ? TtsReader.defaultVoice : s.voice) != _tts.voice;
          final previous = _book;
          final anchor = textChanged ? _reformatAnchor ?? _captureLineAnchor() : null;
          if (textChanged) {
            _saveDebounce?.cancel(); _restoringViewport = true; _reformatAnchor = anchor;
            final boundary = _pageBoundary.currentContext?.findRenderObject();
            if (_viewSnapshot == null && boundary is RenderRepaintBoundary && !boundary.debugNeedsPaint) {
              _viewSnapshot = boundary.toImageSync(pixelRatio: MediaQuery.devicePixelRatioOf(context).clamp(1.0, 2.0));
            }
          }
          setState(() {
            _settings = s;
            if (textChanged) {
              _formatBook(); _flowChapter = null; _flowParagraph = null; _flowOffset = null;
              if (anchor != null && !anchor.title) {
                final location = ReadingText.locate(_book, anchor.chapter, anchor.source);
                _setFlowBreak(anchor.chapter, location.$1, location.$2);
                _chapter = anchor.chapter; _para = location.$1;
                _ttsSentence = ReadingText.sentenceAt(_book.chapters[_chapter].paragraphs[_para], location.$2);
              }
              _remapAnnotations(previous);
            }
          });
          if (textChanged) {
            _searchHits.clear(); _searchQuery = '';
            _restoreLineAnchor(anchor);
          }
          _tts.setSpeechRate(s.speechRate);
          _tts.setVoice(s.voice.isEmpty ? TtsReader.defaultVoice : s.voice);
          if (voiceChanged && _inReadingMode) _startTtsFrom(_chapter, _para, max(0, _ttsSentence));
          // 变速/切音色后缓存坐标（voice/rate 段）变化，重建朗读侧缓存
          _refreshTtsCache();
          _applyReaderBrightness();
          _pageEndKey = null; _schedulePageGeometry();
          widget.storage.saveSettings(s.toJson());
        },
        onVoiceLoad: () async => [
          {'id': TtsReader.systemVoice, 'name': T('systemTts')},
          ...sortedEdgeVoices().map((v) => {'id': v.id, 'name': _voiceLabel(v.id)}),
        ],
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

/// Side contents panel, positioned at the current chapter.
class _ChapterSheet extends StatefulWidget {
  final Book book;
  final int current;
  const _ChapterSheet({required this.book, required this.current});
  @override
  State<_ChapterSheet> createState() => _ChapterSheetState();
}

class _ChapterSheetState extends State<_ChapterSheet> {
  late final ScrollController _controller;
  @override
  void initState() {
    super.initState();
    _controller = ScrollController(initialScrollOffset: max(0, widget.current - 3) * 56.0);
  }
  @override
  void dispose() { _controller.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => Column(children: [
    Row(children: [
      Expanded(child: Padding(padding: const EdgeInsets.all(16), child: Text(T('toc'), textAlign: TextAlign.center))),
      Expanded(child: TextButton(onPressed: () => Navigator.pop(context, -1), child: Text(T('bookmark')))),
    ]),
    const Divider(height: 1),
    Expanded(child: ListView.builder(
      controller: _controller,
      itemExtent: 56,
      itemCount: widget.book.chapters.length,
      itemBuilder: (context, i) => ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        title: Text(widget.book.chapters[i].title, maxLines: 1, overflow: TextOverflow.ellipsis),
        selected: i == widget.current,
        selectedTileColor: const Color(0x226498B5),
        selectedColor: const Color(0xFF9BC5DD),
        onTap: () => Navigator.pop(context, i),
      ),
    )),
  ]);
}

/// 设置底部弹层
class _SettingsSheet extends StatefulWidget {
  final ReadingSettings settings;
  final VoidCallback onCache;
  final VoidCallback onFontTune;
  final ValueChanged<ReadingSettings> onChanged;
  final Future<List<dynamic>> Function() onVoiceLoad;
  const _SettingsSheet({
    required this.settings,
    required this.onCache,
    required this.onFontTune,
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

  /// 字体更换弹层：教程 + 导入 + 已导入列表（可删除）+ 恢复默认。
  Future<void> _openFontPicker() async {
    final fonts = await FontManager.listImported();
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(T('fontReplace'),
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text(T('fontTutorial'),
                      style: const TextStyle(fontSize: 13, height: 1.5)),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      icon: const Icon(Icons.file_download_outlined, size: 18),
                      label: Text(T('importFont')),
                      onPressed: () async {
                        // ignore: deprecated_member_use
                        final result = await FilePicker.pickFiles(
                          type: FileType.custom,
                          allowedExtensions: ['ttf', 'otf'],
                        );
                        if (result.isEmpty) return;
                        final path = result.first.path;
                        if (path == null) return;
                        final family = await FontManager.importFont(path);
                        if (!ctx.mounted) return;
                        if (family == null) {
                          ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                            content: Text(T('importFail')),
                          ));
                          return;
                        }
                        setState(() {
                          _s.fontFamily = family;
                          _update();
                        });
                        Navigator.pop(ctx);
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(T('importedFonts'),
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  if (fonts.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(T('default'),
                          style: const TextStyle(
                              fontSize: 13, color: Colors.grey)),
                    )
                  else
                    ...fonts.map((f) => ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            FontManager.familyOf(f),
                            style: const TextStyle(fontSize: 14),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, size: 20),
                            tooltip: T('deleteFont'),
                            onPressed: () async {
                              await FontManager.removeFont(f);
                              if (_s.fontFamily == FontManager.familyOf(f)) {
                                setState(() {
                                  _s.fontFamily = '';
                                  _update();
                                });
                              }
                              setSheetState(() {});
                            },
                          ),
                        )),
                  const SizedBox(height: 4),
                  Center(
                    child: TextButton.icon(
                      icon: const Icon(Icons.restart_alt, size: 18),
                      label: Text(T('restoreDefault')),
                      onPressed: () {
                        setState(() {
                          _s.fontFamily = '';
                          _update();
                        });
                        Navigator.pop(ctx);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
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
              ListTile(leading: const Icon(Icons.storage_outlined), title: Text(T('cacheBook')),
                onTap: () { Navigator.pop(context); widget.onCache(); }),
              // 亮度
              ReaderBrightnessControl(value: _s.brightness, automatic: _s.automaticBrightness,
                onChanged: (value) => setState(() { _s.brightness = value; _s.automaticBrightness = false; _update(); }),
                onAutomatic: () async {
                  setState(() => _s.automaticBrightness = true); _update();
                  final value = await _ReaderScreenState._volumeChannel.invokeMethod<double>('getSystemBrightness');
                  if (mounted && _s.automaticBrightness && value != null) {
                    setState(() => _s.brightness = ReaderBrightnessControl.split + value.clamp(0.0, 1.0) * (1 - ReaderBrightnessControl.split));
                    _update();
                  }
                }),
              // 字体大小
              Row(children: [
                Expanded(child: Slider(padding: const EdgeInsets.symmetric(horizontal: 12), value: _s.fontSize.clamp(14, 64), min: 14, max: 64, divisions: 50,
                  onChanged: (value) => setState(() { _s.fontSize = value; _update(); }))),
                SizedBox(width: 44, height: 44, child: TextButton(
                  style: TextButton.styleFrom(minimumSize: const Size(44, 44), padding: EdgeInsets.zero),
                  onPressed: () { Navigator.pop(context); widget.onFontTune(); },
                  child: const Text('T±', style: TextStyle(fontSize: 20)))),
              ]),
              ListTile(title: const Text('翻页方式'), trailing: DropdownButton<String>(
                key: const ValueKey('page-turn-mode'), value: _s.pageTurnMode,
                items: const [DropdownMenuItem(value: 'tap', child: Text('点击左右侧')),
                  DropdownMenuItem(value: 'swipe', child: Text('左右滑动')),
                  DropdownMenuItem(value: 'scroll', child: Text('上下滚动'))],
                onChanged: (value) { if (value != null) setState(() { _s.pageTurnMode = value; _update(); }); })),
              SwitchListTile(key: const ValueKey('retain-page-line'), title: const Text('翻页后保留首行'),
                subtitle: Text(_s.pageTurnMode == 'scroll' ? '上下滚动时不可用' : '下一页首行重复上一页最后一整行'),
                value: _s.retainPageLine, onChanged: _s.pageTurnMode == 'scroll' ? null : (value) {
                  setState(() { _s.retainPageLine = value; _update(); });
                }),
              SwitchListTile(key: const ValueKey('text-correction'), title: const Text('文本修正'),
                subtitle: const Text('合并非句换行、修复换行错位闭引号、清理不可见字符，同时调整朗读分句'),
                value: _s.mergeNonSentenceBreaks,
                onChanged: (v) => setState(() { _s.mergeNonSentenceBreaks = v; _update(); })),
              SwitchListTile(key: const ValueKey('first-line-indent'), title: const Text('首行缩进'),
                subtitle: const Text('不足两个空格的段首缩进两个字符'), value: _s.firstLineIndent,
                onChanged: (v) => setState(() { _s.firstLineIndent = v; _update(); })),
              SwitchListTile(key: const ValueKey('information-filter'), title: const Text('无关信息过滤'),
                subtitle: const Text('开启后请选择过滤级别；原始文件保留'), value: _s.informationFilter,
                onChanged: (v) => setState(() { _s.informationFilter = v; _update(); })),
              if (_s.informationFilter) ...[
                for (final level in const [('links', '一级：网址和邮箱'),
                  ('ads', '二级：再过滤明确广告行'), ('extra', '三级：再过滤求票、求收藏及作者说明行')])
                  RadioListTile<String>(title: Text(level.$2), value: level.$1,
                    groupValue: _s.informationFilterLevel,
                    onChanged: (v) => setState(() { _s.informationFilterLevel = v!; _update(); })),
              ],
              // 字体更换
              InkWell(
                onTap: _openFontPicker,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      const Icon(Icons.font_download_outlined,
                          color: Color(0xFF6498B5)),
                      const SizedBox(width: 12),
                      Text(T('fontReplace'),
                          style: const TextStyle(fontSize: 14)),
                      const Spacer(),
                      Text(
                        _s.fontFamily.isEmpty
                            ? T('default')
                            : FontManager.familyOf(_s.fontFamily),
                        style: const TextStyle(
                            fontSize: 13, color: Color(0xFF6498B5)),
                      ),
                      const Icon(Icons.chevron_right,
                          size: 18, color: Color(0xFF6498B5)),
                    ],
                  ),
                ),
              ),
              // 行距
              _row(T('lineHeight'), Icons.format_line_spacing, Slider(
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
              _row(T('speed'), Icons.speed, Slider(
                value: _s.speechRate.clamp(0.5, 3.0),
                min: 0.5,
                max: 3.0,
                divisions: 25,
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
                  Text(T('voice')),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _voicesLoaded && _voices.isNotEmpty
                        ? DropdownButton<String>(
                            value: _s.voice.isEmpty ? TtsReader.defaultVoice : _s.voice,
                            isExpanded: true,
                            hint: Text(T('default')),
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
                        : Text(T('loading')),
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
        Icon(icon, color: const Color(0xFF6498B5)),
        const SizedBox(width: 12),
        Text(label, style: const TextStyle(fontSize: 14)),
        const SizedBox(width: 8),
        Expanded(child: slider),
      ],
    );
  }
}

/// 书签列表底部弹层（删除带动画、即时刷新）
class _BookmarkSheet extends StatefulWidget {
  final List<Bookmark> initial;
  final void Function(Bookmark) onDelete;
  const _BookmarkSheet({required this.initial, required this.onDelete});

  @override
  State<_BookmarkSheet> createState() => _BookmarkSheetState();
}

class _BookmarkSheetState extends State<_BookmarkSheet> {
  late final List<Bookmark> _items = List.of(widget.initial);
  final GlobalKey<AnimatedListState> _listKey = GlobalKey<AnimatedListState>();
  String? _toastMsg;
  Timer? _toastTimer;

  void _showToast(String msg) {
    _toastTimer?.cancel();
    setState(() => _toastMsg = msg);
    _toastTimer = Timer(const Duration(milliseconds: 1300), () {
      if (mounted) setState(() => _toastMsg = null);
    });
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    super.dispose();
  }

  void _delete(Bookmark b) {
    final idx = _items.indexWhere((x) => x.id == b.id);
    if (idx < 0) return;
    widget.onDelete(b); // 持久化 + 父状态同步
    _items.removeAt(idx);
    _listKey.currentState?.removeItem(
      idx,
      (ctx, anim) => SizeTransition(
        sizeFactor: anim,
        child: _buildTile(b),
      ),
      duration: const Duration(milliseconds: 600),
    );
    Future.delayed(const Duration(milliseconds: 620), () {
      if (mounted && _items.isEmpty) setState(() {});
    });
    _showToast(T('bookmarkDeleted'));
  }

  Widget _buildTile(Bookmark b) {
    return ListTile(
      leading:
          const Icon(Icons.bookmark, color: Color(0xFF6498B5), size: 20),
      title:
          Text(b.chapterTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(b.snippet,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12)),
          Text(_ReaderScreenState._fmtTime(b.createdAt),
              style: const TextStyle(fontSize: 11)),
        ],
      ),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline, size: 20),
        onPressed: () => _delete(b),
      ),
      onTap: () => Navigator.pop(
          context,
          _Item.sentence(
              b.chapterIndex, b.paragraphIndex, b.sentenceIndex)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          maxChildSize: 0.9,
          builder: (ctx, scrollController) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(T('bookmark'),
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold)),
              ),
              const Divider(height: 1),
              Expanded(
                child: Stack(
                  children: [
                    AnimatedList(
                      key: _listKey,
                      controller: scrollController,
                      initialItemCount: _items.length,
                      itemBuilder: (ctx, i, anim) => SizeTransition(
                        sizeFactor: anim,
                        child: _buildTile(_items[i]),
                      ),
                    ),
                    if (_items.isEmpty)
                      Center(
                        child: Text(T('noBookmark'),
                            style: const TextStyle(color: Colors.grey)),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 20,
          child: IgnorePointer(
            child: Center(
              child: AnimatedOpacity(
                opacity: _toastMsg == null ? 0 : 1,
                duration: const Duration(milliseconds: 220),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 9),
                  decoration: BoxDecoration(
                    color: const Color(0xE6323232),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(_toastMsg ?? '',
                      style: const TextStyle(color: Colors.white)),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 划线列表底部弹层（删除带动画、即时刷新）
class _HighlightSheet extends StatefulWidget {
  final Book book;
  final List<Highlight> initial;
  final void Function(Highlight) onDelete;
  const _HighlightSheet(
      {required this.book,
      required this.initial,
      required this.onDelete});

  @override
  State<_HighlightSheet> createState() => _HighlightSheetState();
}

class _HighlightSheetState extends State<_HighlightSheet> {
  late final List<Highlight> _items = List.of(widget.initial);
  final GlobalKey<AnimatedListState> _listKey = GlobalKey<AnimatedListState>();
  String? _toastMsg;
  Timer? _toastTimer;

  void _showToast(String msg) {
    _toastTimer?.cancel();
    setState(() => _toastMsg = msg);
    _toastTimer = Timer(const Duration(milliseconds: 1300), () {
      if (mounted) setState(() => _toastMsg = null);
    });
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    super.dispose();
  }

  void _delete(Highlight h) {
    final idx = _items.indexWhere((x) => x.id == h.id);
    if (idx < 0) return;
    widget.onDelete(h); // 持久化 + 父状态同步
    _items.removeAt(idx);
    _listKey.currentState?.removeItem(
      idx,
      (ctx, anim) => SizeTransition(
        sizeFactor: anim,
        child: _buildTile(h),
      ),
      duration: const Duration(milliseconds: 600),
    );
    Future.delayed(const Duration(milliseconds: 620), () {
      if (mounted && _items.isEmpty) setState(() {});
    });
    _showToast(T('highlightDeleted'));
  }

  Widget _buildTile(Highlight h) {
    final book = widget.book;
    final ch = h.chapterIndex.clamp(0, book.chapters.length - 1);
    final chapterTitle = book.chapters.isEmpty ? '' : book.chapters[ch].title;
    String snippet = '';
    if (book.chapters.isNotEmpty &&
        h.paragraphIndex < book.chapters[ch].paragraphs.length) {
      final para = book.chapters[ch].paragraphs[h.paragraphIndex];
      if (h.charStart < para.display.length) {
        snippet = para.display
            .substring(h.charStart, min(h.charEnd, para.display.length));
        if (snippet.length > 40) {
          snippet = snippet.substring(0, 40);
        }
      }
    }
    return ListTile(
      leading: Container(
        width: 16,
        height: 16,
        decoration: BoxDecoration(
          color: Color(h.color),
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0x44000000)),
        ),
      ),
      title: Text(chapterTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(snippet,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12)),
          if (h.note.isNotEmpty)
            Text('${T('note')}: ${h.note}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11)),
          Text(_ReaderScreenState._fmtTime(h.createdAt),
              style: const TextStyle(fontSize: 11)),
        ],
      ),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline, size: 20),
        onPressed: () => _delete(h),
      ),
      onTap: () {
        final chIdx = h.chapterIndex;
        final para = book.chapters[chIdx].paragraphs[h.paragraphIndex];
        var sIdx = 0;
        for (var s = 0; s < para.sentences.length; s++) {
          if (para.sentences[s].displayStart <= h.charStart) {
            sIdx = s;
          } else {
            break;
          }
        }
        Navigator.pop(context, _Item.sentence(chIdx, h.paragraphIndex, sIdx));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          maxChildSize: 0.9,
          builder: (ctx, scrollController) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(T('highlight'),
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold)),
              ),
              const Divider(height: 1),
              Expanded(
                child: Stack(
                  children: [
                    AnimatedList(
                      key: _listKey,
                      controller: scrollController,
                      initialItemCount: _items.length,
                      itemBuilder: (ctx, i, anim) => SizeTransition(
                        sizeFactor: anim,
                        child: _buildTile(_items[i]),
                      ),
                    ),
                    if (_items.isEmpty)
                      Center(
                        child: Text(T('noHighlight'),
                            style: const TextStyle(color: Colors.grey)),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 20,
          child: IgnorePointer(
            child: Center(
              child: AnimatedOpacity(
                opacity: _toastMsg == null ? 0 : 1,
                duration: const Duration(milliseconds: 220),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 9),
                  decoration: BoxDecoration(
                    color: const Color(0xE6323232),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(_toastMsg ?? '',
                      style: const TextStyle(color: Colors.white)),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ReaderLineAnchor {
  final int chapter, source;
  final double top;
  final bool title;
  const _ReaderLineAnchor(this.chapter, this.source, this.top, {this.title = false});
}

class _PageLine {
  final String key;
  final double top, bottom;
  const _PageLine(this.key, this.top, this.bottom);
}

class _ReaderPageClipper extends CustomClipper<Rect> {
  final double? bottom;
  const _ReaderPageClipper(this.bottom);
  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, size.width, (bottom ?? size.height).clamp(0.0, size.height));
  @override
  bool shouldReclip(_ReaderPageClipper oldClipper) => bottom != oldClipper.bottom;
}
