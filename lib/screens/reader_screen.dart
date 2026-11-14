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
import '../services/reader_preparation.dart';
import '../services/reader_screen_awake.dart';
import '../services/book_parser.dart';
import '../services/reader_typography.dart';
import '../services/text_cleaner.dart';
import '../widgets/reader_icon.dart';
import '../widgets/reader_brightness_control.dart';
import '../widgets/reader_gestures.dart';
import '../widgets/speech_pause_editor.dart';
import '../services/media_speech_text.dart';
import '../models/annotation.dart';
import '../models/book.dart';
import '../models/progress.dart';
import '../services/annotation_store.dart';
import '../services/app_storage.dart';
import '../services/book_cache_task.dart';
import '../services/edge_tts.dart';
import '../services/font_manager.dart';
import '../services/tts_audio_handler.dart';
import '../services/playback_notifications.dart';
import '../services/network_connectivity.dart';
import '../services/display_cutout.dart';
import '../services/reader_header_layout.dart';
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
  final ReaderInitialData? initialData;
  final Future<void> Function(BookProgress p)? onProgressChanged;
  @visibleForTesting
  final TtsReader? ttsReader;

  const ReaderScreen({
    super.key,
    required this.book,
    required this.storage,
    this.initialProgress,
    this.initialData,
    this.onProgressChanged,
    this.ttsReader,
  });

  static Color backgroundFor(ReadingSettings settings) =>
    _bookThemes[settings.themeIndex.clamp(0, _bookThemes.length - 1)].bg;

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

class _PlaybackPermissionGate {
  final foreground = Completer<void>();
  bool cancelled = false;
  void resume() { if (!foreground.isCompleted) foreground.complete(); }
  void cancel() { cancelled = true; resume(); }
}

class _SentenceDragSession {
  final (int, int, int) origin;
  (int, int, int) target;
  final bool wasPlaying;
  final int generation, wordStart, wordEnd;
  late final Future<bool> paused;
  bool ending = false;
  int lastSteps = 0;
  _SentenceDragSession(this.origin, this.wasPlaying, this.generation, this.wordStart, this.wordEnd) : target = origin;
}

class _ReaderScreenState extends State<ReaderScreen> with TickerProviderStateMixin, WidgetsBindingObserver {
  late final TtsReader _tts;
  final ReaderScreenAwake _screenAwake = ReaderScreenAwake();
  StreamSubscription<bool>? _networkSubscription;
  final Map<(Size, double), DisplayCutoutGeometry> _cutoutGeometry = {};
  int _cutoutRevision = 0;
  late final Future<void> _viewportReady;
  bool _viewportPrepared = false;
  (Size, double)? _preparedViewportKey;
  bool _leavingReader = false;
  final Map<(Size, double), ReaderHeaderLayout> _stableHeaders = {};
  late List<_Item> _items;
  late Book _book;
  List<BookTocEntry> _toc = [];
  List<int> _tocAnchors = [];
  List<bool> _tocIsChapterTitle = [];
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
  _ReaderLineAnchor? _visibleLineAnchor;
  int? _lineBreakFor(int c, int p) => _flowChapter == c && _flowParagraph == p ? _flowOffset : null;
  int _renderOffset(int c, int p, int offset) => ReaderTypography.layoutOffset(
    _book.chapters[c].paragraphs[p].display, offset, lineBreakAt: _lineBreakFor(c, p));
  String _layoutSegment(_Item it, String text, int start) {
    final split = _lineBreakFor(it.chapterIndex, it.paragraphIndex);
    return ReaderTypography.layout(text, lineBreakAt: split != null && split >= start && split < start + text.length ? split - start : null);
  }
  BookProgress? _lastProgress;
  Size _viewportSize = Size.zero;
  double _headerReservedExtent = 24;
  double _bodyExtent = 1;
  String get _layoutSignature => 'typography4/$_textSignature/$_fontSize/$_lineHeight/$_fontFamily/$_viewportSize/$_headerReservedExtent/$_flowChapter/$_flowParagraph/$_flowOffset';
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
  bool _applyingSpeechPauses = false;
  bool? _pendingSpeechFallback;
  (int, int, int, int)? _speechPauseResumeCursor;

  // 控制 UI 显隐
  bool _showControls = true;
  bool _showQuickMenu = false;
  final Map<(Size, double), EdgeInsets> _stableInsets = {};
  EdgeInsets get _readerInsets => _stableInsets.putIfAbsent(
    (MediaQuery.sizeOf(context), MediaQuery.devicePixelRatioOf(context)), () => MediaQuery.viewPaddingOf(context));
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
  (int, int)? _pendingTtsSentence;
  (int, int)? _pendingTtsWord;
  String _wordMapKey = '';
  CleanedText? _wordMap;
  bool _followingWord = false;
  bool _isPlaying = false;
  int _playbackGeneration = 0;
  _SentenceDragSession? _sentenceDrag;
  final PlaybackNotifications _playbackNotifications = PlaybackNotifications();
  bool _notificationSettingsPending = false;
  _PlaybackPermissionGate? _permissionGate;
  // TTS 正在朗读的章节（与 _chapter 可能因滚动不同步）
  int _ttsChapter = 0;
  String? _mediaTocKey;
  String _mediaSpeechCursorKey = '';
  int? _mediaSpeechOffset;
  MediaSpeechText? _mediaSpeechText;
  // TTS 合成加载中（点击播放/恢复后等待首句出声；期间防误触）
  bool _ttsLoading = false;

  // 系统媒体音量（音量键正常调节，暂停面板也提供滑条）
  double _mediaVolume = 1.0;
  Timer? _volumePollTimer;
  bool _volumeReadInFlight = false;
  bool _volumeDragging = false;
  bool _volumeForeground = true;
  int _volumeRevision = 0, _volumePollEpoch = 0, _volumeWrites = 0;
  bool get _volumePanelVisible => _inReadingMode && _showReadingPanel && _volumeForeground;

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
    SystemChrome.setPreferredOrientations(widget.initialData?.settings.followSystemRotation == true
      ? DeviceOrientation.values : [DeviceOrientation.portraitUp]);
    AppAppearance.nightMode.addListener(_onAppearanceChanged);
    if (widget.initialData case final initial?) {
      _applySystemUi();
      final view = WidgetsBinding.instance.platformDispatcher.implicitView;
      if (view != null) {
        final key = (view.physicalSize / view.devicePixelRatio, view.devicePixelRatio);
        _preparedViewportKey = key;
        final geometry = initial.geometry;
        if (geometry != null && initial.devicePixelRatio == view.devicePixelRatio && geometry.matches(key.$1)) {
          _cutoutGeometry[key] = geometry;
        }
      }
      _viewportPrepared = true; _viewportReady = Future<void>.value();
    } else {
      _viewportReady = _prepareReaderViewport();
    }
    _pageAnimation = AnimationController(vsync: this, duration: const Duration(milliseconds: 80));
    _autoClock = AnimationController(vsync: this, duration: const Duration(seconds: 20))
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed && _autoActive && !_autoPaused) _advanceAutoPage();
      });
    _tts = widget.ttsReader ?? TtsReader();
    _tts.onVoiceModeChanged = _onSpeechVoiceModeChanged;
    _networkSubscription = NetworkConnectivity().availability.listen(_tts.setNetworkAvailable);
    _tts.onSentenceChanged = _onTtsSentenceChanged;
    _tts.onWordChanged = _onTtsWordChanged;
    _tts.onCompleted = _onTtsCompleted;
    _tts.onError = _onTtsError;
    _tts.onStateChanged = _syncSpeechPlaybackState;
    _tts.onLoadingChanged = (loading) { if (mounted && _inReadingMode && _ttsLoading != loading) setState(() => _ttsLoading = loading); };
    _book = widget.book;
    _items = [];
    _itemPositionsListener.itemPositions.addListener(_onScroll);
    // 绑定全局 audio_service 回调（耳机播放键）
    globalAudioHandler?.onPlayRequested = _onHeadsetPlay;
    globalAudioHandler?.onPauseRequested = _onHeadsetPause;
    globalAudioHandler?.onStopRequested = _onHeadsetStop;
    globalAudioHandler?.onPreviousRequested = () async { _prevSentence(); };
    globalAudioHandler?.onNextRequested = () async { _nextSentence(); };
    _loadSettings();
    // 记录最后阅读的书籍，下次启动直接恢复
    widget.storage.saveLastBookId(_book.id);
    // 读取系统媒体音量用于暂停面板滑条
    _loadMediaVolume();
    // 加载书签与划线

  }

  static const _volumeChannel =
      MethodChannel('com.ddnovelreader/volume_keys');

  /// A MediaSession play request is idempotent; pause has its own callback.
  Future<void> _onHeadsetPlay() async {
    _cancelSentenceDrag();
    print('SCREEN onHeadsetPlay ttsState=${_tts.state} reading=$_inReadingMode loading=$_ttsLoading');
    _debugLog('SCREEN onHeadsetPlay state=${_tts.state} reading=$_inReadingMode');
    if (!mounted) return;
    if (!_inReadingMode) {
      await _play();
    } else if (_tts.state == TtsState.playing) {
      globalAudioHandler?.notifyPlaying();
    } else {
      // paused / stopped / idle 一律尝试恢复（_resumeReading 内部处理）
      await _resumeReading();
    }
  }

  Future<void> _onHeadsetPause() async {
    _cancelSentenceDrag();
    print('SCREEN onHeadsetPause ttsState=${_tts.state}');
    _debugLog('SCREEN onHeadsetPause state=${_tts.state}');
    if (!mounted) return;
    if (_tts.state == TtsState.playing || _ttsLoading) {
      await _pauseReading(force: true);
    } else if (_tts.state == TtsState.paused) {
      globalAudioHandler?.notifyPaused();
    } else {
      globalAudioHandler?.notifyStopped();
    }
  }

  Future<void> _onHeadsetStop() async {
    if (!mounted) return;
    await _exitReadingMode();
  }

  void _syncSpeechPlaybackState() {
    if (!mounted || !_inReadingMode) return;
    switch (_tts.state) {
      case TtsState.playing: globalAudioHandler?.notifyPlaying();
      case TtsState.paused: globalAudioHandler?.notifyPaused();
      case TtsState.stopped:
      case TtsState.idle:
        // Chapter completion briefly stops the old queue before starting the
        // next chapter. The completion/error/exit paths announce a final stop.
        if (!_isPlaying) globalAudioHandler?.notifyStopped();
    }
  }

  @override
  void dispose() {
    _sentenceDrag = null;
    AppAppearance.nightMode.removeListener(_onAppearanceChanged);
    _networkSubscription?.cancel();
    _permissionGate?.cancel(); _permissionGate = null;
    _volumePollTimer?.cancel(); _volumePollTimer = null; _volumePollEpoch++;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_screenAwake.dispose());
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
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _volumeChannel.invokeMethod('resetScreenBrightness');
    // 恢复系统默认系统栏样式（书架页浅色背景使用深色图标）
    _restoreSystemUiForExit();
    _gestureTipTimer?.cancel();
    _tts.dispose();
    _itemPositionsListener.itemPositions.removeListener(_onScroll);
    // 解绑耳机回调并停止 MediaSession（handler 实例保留供下次进入复用）
    globalAudioHandler?.onPlayRequested = null;
    globalAudioHandler?.onPauseRequested = null;
    globalAudioHandler?.onStopRequested = null;
    globalAudioHandler?.onPreviousRequested = null;
    globalAudioHandler?.onNextRequested = null;
    globalAudioHandler?.notifyStopped();
    super.dispose();
  }

  Future<void> _refreshDisplayCutout() async {
    final revision = ++_cutoutRevision;
    // This Android app has one implicit Flutter view. Reading its DPR here
    // avoids depending on inherited widgets while initState is still running.
    final dpr = WidgetsBinding.instance.platformDispatcher.implicitView?.devicePixelRatio ?? 1.0;
    final geometry = await DisplayCutoutService.read();
    if (!mounted || _leavingReader || revision != _cutoutRevision || geometry == null) return;
    if ((WidgetsBinding.instance.platformDispatcher.implicitView?.devicePixelRatio ?? 1.0) != dpr) return;
    setState(() => _cutoutGeometry[(geometry.viewport, dpr)] = geometry);
  }

  @override
  void didChangeMetrics() {
    if (!_viewportPrepared || _leavingReader) return;
    final playback = _playbackGeneration, navigation = _navigationGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || _leavingReader) return;
      await _refreshDisplayCutout();
      if (!mounted || _leavingReader || playback != _playbackGeneration || navigation != _navigationGeneration) return;
      _scheduleActiveSpeechAlignment();
    });
  }

  Future<void> _prepareReaderViewport() async {
    // Insets that ignore visibility can be read while immersive is applying.
    // Neither the immersive response nor route animation blocks the text frame.
    _applySystemUi();
    await _refreshDisplayCutout();
    if (mounted && !_leavingReader) {
      final view = WidgetsBinding.instance.platformDispatcher.implicitView;
      if (view != null) _preparedViewportKey = (view.physicalSize / view.devicePixelRatio, view.devicePixelRatio);
      _viewportPrepared = true;
    }
  }

  void _restoreSystemUiForExit() {
    if (_leavingReader) return;
    _leavingReader = true; _playbackGeneration++; _permissionGate?.cancel(); _sentenceDrag = null;
    _syncScreenAwake();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge).catchError((Object _) {});
    final dark = AppAppearance.nightMode.value;
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(statusBarColor: Colors.transparent,
      statusBarIconBrightness: dark ? Brightness.light : Brightness.dark, systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: dark ? Brightness.light : Brightness.dark));
  }

  ReaderHeaderLayout get _headerLayout {
    final viewport = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context), key = (viewport, MediaQuery.devicePixelRatioOf(context));
    final stable = _stableHeaders[key];
    if (stable != null) return stable;
    DisplayCutoutGeometry? native = _cutoutGeometry[key];
    if (native == null) {
      for (final entry in _cutoutGeometry.entries) {
        if (entry.key.$2 == dpr && entry.value.matches(viewport)) { native = entry.value; break; }
      }
    }
    final features = MediaQuery.of(context).displayFeatures
      .where((feature) => feature.type == ui.DisplayFeatureType.cutout).map((feature) => feature.bounds).toList();
    final cutouts = features.isNotEmpty ? features : native?.cutouts ?? const <Rect>[];
    final layout = ReaderHeaderLayout.compute(viewport: viewport,
      safeInsets: cutouts.isNotEmpty && native != null ? native.safeInsets : _readerInsets,
      cutouts: cutouts, topLeftRadius: native?.topLeftRadius ?? 0, topRightRadius: native?.topRightRadius ?? 0,
      // The reading layout stays immersive even while an OS bar is transiently
      // revealed. Its visibility must never move the text beneath overlays.
      statusBarVisible: false);
    if (_settingsLoaded && (native != null || features.isNotEmpty || key == _preparedViewportKey)) _stableHeaders[key] = layout;
    return layout;
  }

  void _onAppearanceChanged() {
    if (!mounted || !_settingsLoaded) return;
    setState(() => _settings = AppAppearance.applyCurrentMode(_settings));
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
      '${s.mergeNonSentenceBreaks}/${s.firstLineIndent}/${s.informationFilter}/${s.informationFilterLevel}/${s.effectiveSpeechPauses.cacheKey}';

  void _formatBook() {
    _textSignature = _formatSignature(_settings);
    final book = ReadingText.format(widget.book, merge: _settings.mergeNonSentenceBreaks,
      indent: _settings.firstLineIndent,
      pauseSettings: _settings.effectiveSpeechPauses,
      filter: _settings.informationFilter ? _settings.informationFilterLevel : 'none');
    _installFormattedBook(book, 'words1-${ReadingText.fingerprint(book)}');
    _rebuildToc();
  }

  void _installFormattedBook(Book book, String fingerprint) {
    _book = book; _cacheFingerprint = fingerprint;
    _visibleLineAnchor = null;
    _wordMapKey = ''; _wordMap = null; _wordStart = -1; _wordEnd = -1;
    _items = _flatten(_book);
    _paragraphKeys.clear();
    _titleKeys.clear(); _pageClipBottom = null; _pageEndKey = null;
    for (final recognizer in _sentenceRecognizers.values) { recognizer.dispose(); }
    _sentenceRecognizers.clear();
    _pendingScrollIndex = null;
    _initLocate(); _initCharPrefix();
  }

  void _rebuildToc() {
    final entries = BookParser.extractToc(widget.book, autoExtractToc: _settings.autoExtractToc);
    _tocAnchors = [for (final entry in entries)
      ReadingText.anchor(widget.book, entry.chapterIndex, entry.paragraphIndex, entry.displayOffset)];
    _tocIsChapterTitle = [for (final entry in entries) entry.paragraphIndex == 0 && entry.displayOffset == 0 &&
      entry.title == widget.book.chapters[entry.chapterIndex].title &&
      !widget.book.chapters[entry.chapterIndex].paragraphs.first.display.trimLeft().startsWith(entry.title)];
    _toc = [for (var i = 0; i < entries.length; i++) (() {
      final entry = entries[i], location = ReadingText.locate(_book, entries[i].chapterIndex, _tocAnchors[i]);
      return BookTocEntry(title: entry.title, chapterIndex: entry.chapterIndex,
        paragraphIndex: location.$1, displayOffset: location.$2);
    })()];
  }

  int get _currentTocIndex {
    if (_toc.isEmpty) return 0;
    var c = _chapter;
    var anchor = ReadingText.anchor(_book, c, _para, _wordStart >= 0 && _inReadingMode ? _wordStart :
      _ttsSentence >= 0 && _ttsSentence < _book.chapters[c].paragraphs[_para].sentences.length
        ? _book.chapters[c].paragraphs[_para].sentences[_ttsSentence].displayStart : 0);
    if (!_inReadingMode && _pendingScrollIndex == null) {
      // Rendering a new page can invalidate paragraph layout before this build.
      // Only read the source anchor measured after the preceding layout frame.
      final top = _visibleLineAnchor;
      if (top != null) { c = top.chapter; anchor = top.source; }
    }
    var result = 0;
    for (var i = 0; i < _toc.length; i++) {
      if (_toc[i].chapterIndex > c || _toc[i].chapterIndex == c && _tocAnchors[i] > anchor) break;
      result = i;
    }
    return result;
  }

  Future<void> _navigateToc(int index) async {
    if (_ttsLoading || _paging || index < 0 || index >= _toc.length) return;
    final entry = _toc[index], c = _toc[index].chapterIndex, p = _toc[index].paragraphIndex;
    final sentence = ReadingText.sentenceAt(_book.chapters[c].paragraphs[p], entry.displayOffset);
    setState(() { _showQuickMenu = false; _chapter = c; _para = p; _ttsSentence = sentence; _wordStart = -1; _wordEnd = -1; });
    _pageEndKey = null;
    if (_tocIsChapterTitle[index]) {
      _jumpToItem(_chapterItem(c), animate: false);
      if (_inReadingMode) _ttsFollowSeek(c, p, sentence, displayOffset: entry.displayOffset);
      _updateMediaChapter(c); _scheduleSave(); return;
    }
    final before = _navigationGeneration;
    await _positionViewport(_itemIndexOf(c, p), 0);
    if (!mounted || _navigationGeneration != before + 1) return;
    final glyph = _ttsGlyphRect(c, p, entry.displayOffset);
    if (glyph != null) await _pageScrollController.animateScroll(offset: glyph.top, duration: const Duration(milliseconds: 1));
    if (!mounted) return;
    if (_inReadingMode) _ttsFollowSeek(c, p, sentence, displayOffset: entry.displayOffset);
    _updateMediaChapter(c); _scheduleSave();
  }

  Future<void> _loadSettings() async {
    final initial = widget.initialData;
    if (initial != null) {
      _activatePrepared(initial.prepared, initial.settings, initial.progress);
      return;
    }
    final raw = await widget.storage.loadSettings();
    if (!mounted || _leavingReader) return;
    _settings = AppAppearance.applyCurrentMode(ReadingSettings.fromJson(raw));
    final prepared = await ReaderPreparation.prepare(ReaderPreparationRequest(widget.book,
      merge: _settings.mergeNonSentenceBreaks, indent: _settings.firstLineIndent,
      pauseSettings: _settings.effectiveSpeechPauses,
      filter: _settings.informationFilter ? _settings.informationFilterLevel : 'none',
      autoExtractToc: _settings.autoExtractToc));
    await _viewportReady;
    if (!mounted || _leavingReader) return;
    final progress = await widget.storage.loadProgress(widget.book.id) ?? widget.initialProgress;
    if (!mounted || _leavingReader) return;
    _activatePrepared(prepared, _settings, progress);
  }

  void _activatePrepared(PreparedReadingBook prepared, ReadingSettings settings, BookProgress? p) {
    _settings = AppAppearance.applyCurrentMode(ReadingSettings.fromJson(settings.toJson()));
    prepared.attachSourceMaps();
    _textSignature = _formatSignature(_settings);
    _installFormattedBook(prepared.book, prepared.fingerprint);
    _toc = prepared.toc; _tocAnchors = prepared.tocAnchors; _tocIsChapterTitle = prepared.chapterTitles;
    _applyReaderBrightness();
    if (_settings.automaticBrightness) _syncSystemBrightness();
    _applySystemUi();
    _tts.setSpeechRate(_settings.speechRate);
    _tts.setPrefetchSentences(_settings.prefetchSentences);
    _applyRotationPreference();
    final restoreFallback = _settings.systemFallbackActive;
    _tts.setVoice(_settings.voice.isEmpty ? TtsReader.defaultVoice : _settings.voice);
    _tts.restoreSystemFallback(restoreFallback);
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
    _restorePreparedPosition(p, atTitle, location);
  }

  Future<void> _restorePreparedPosition(BookProgress? p, bool atTitle, (int, int) location) async {
    await _loadAnnotations();
    if (!mounted || _leavingReader) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || _leavingReader) return;
      final exact = p != null && p.layoutSignature == _layoutSignature && p.viewportItem != null;
      final index = exact ? p.viewportItem!.clamp(0, _items.length - 1) :
        atTitle ? _chapterItem(_chapter) : _itemIndexOf(_chapter, _para);
      await _positionViewport(index, exact ? p.viewportAlignment : 0);
      if (mounted && !_leavingReader && !exact && p != null && !atTitle) {
        await _followSentence(_chapter, _para, max(0, _ttsSentence), character: location.$2);
      }
      if (mounted && !_leavingReader) { _restoringProgress = false; _scheduleSave(); }
    });
  }

  int _chapterItem(int chapter) => _items.indexWhere((it) => it.isTitle && it.chapterIndex == chapter);

  Future<void> _saveProgress() async {
    if (!_settingsLoaded || _restoringProgress) return;
    final visible = mounted ? _visibleItems() : <ItemPosition>[];
    final first = visible.isEmpty ? null : visible.first;
    final it = first == null ? null : _items[first.index];
    final c = _inReadingMode ? _chapter : it?.chapterIndex ?? _chapter;
    final paraIndex = _inReadingMode ? _para : it == null || it.isTitle ? 0 : it.paragraphIndex;
    final para = _book.chapters[c].paragraphs[paraIndex];
    final offset = _inReadingMode && _ttsSentence >= 0 && _ttsSentence < para.sentences.length
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
      if (_settings.wordHighlightEnabled && current && _wordStart >= 0 && _wordEnd > _wordStart) {
        points.add(_wordStart.clamp(start, end)); points.add(_wordEnd.clamp(start, end));
      }
      for (final h in marks) {
        if (h.charEnd > start && h.charStart < end) { points.add(h.charStart.clamp(start, end)); points.add(h.charEnd.clamp(start, end)); }
      }
      final sorted = points.toList()..sort();
      for (var j = 0; j + 1 < sorted.length; j++) {
        final left = sorted[j], right = sorted[j + 1];
        final marked = marks.where((h) => h.charStart < right && h.charEnd > left);
        final word = _settings.wordHighlightEnabled && current && _wordStart < right && _wordEnd > left && _wordStart >= 0;
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
    _visibleLineAnchor = null;
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
    _visibleLineAnchor = null;
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
    final oldEndKey = _pageEndKey, oldClipBottom = _pageClipBottom;
    if (!automatic && _autoActive) _autoClock.stop();
    _paging = true;
    _pendingScrollIndex = null;
    final navigation = ++_navigationGeneration;
    final boundary = _pageBoundary.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    try {
      if (_settings.pageTurnAnimation == 'slide' && boundary != null && !boundary.debugNeedsPaint) {
        _pageImage = boundary.toImageSync(pixelRatio: MediaQuery.devicePixelRatioOf(context).clamp(1.0, 2.0));
      }
    } catch (_) { /* A page turn still works if a frame cannot be captured. */ }
    if (!mounted) { _pageImage?.dispose(); _pageImage = null; return false; }
    setState(() {
      // Returning to the page dismisses overlay bars. In a cutout layout the
      // toolbar can extend below the fixed header and otherwise hide its first row.
      _showControls = false; _showQuickMenu = false;
      _pageDirection = direction; _pageReady = false;
      _outgoingPage = _pageImage == null ? null : RawImage(image: _pageImage, fit: BoxFit.fill);
    });
    _applySystemUi();
    var moved = false;
    try {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || navigation != _navigationGeneration) return false;
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
        if (candidates.isEmpty || retain && candidates.every((line) => line.key == first.key)) {
          target = await _preparePreviousPage(first, navigation, retain: retain);
          if (target == null) return false;
        } else {
          final end = candidates.last;
          final fitting = candidates.where((r) => end.bottom - r.top <= _bodyHeight + 0.5).toList();
          if (fitting.isEmpty) return false;
          target = fitting.first; _pageEndKey = end.key;
        }
      }
      // Move to an actual text-line boundary behind the frozen outgoing page.
      if (!await _alignPageLine(target, navigation)) return false;
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
      if (_settings.pageTurnAnimation == 'slide') {
        _pageAnimation.value = 0;
        setState(() => _pageReady = true);
        await _pageAnimation.forward().orCancel;
      }
      if (mounted && _inReadingMode) _ttsFollowSeek(_chapter, _para, max(0, _ttsSentence),
        displayOffset: _visibleDisplayOffset(_chapter, _para));
      return true;
    } on TickerCanceled {
      return false;
    } finally {
      if (mounted && !moved && navigation == _navigationGeneration) {
        _pageEndKey = oldEndKey;
        await _positionViewport(old.first.index, old.first.itemLeadingEdge);
        if (mounted) _pageClipBottom = oldClipBottom;
      }
      if (mounted) {
        final image = _pageImage; _pageImage = null;
        setState(() { _outgoingPage = null; _pageReady = false; _paging = false; });
        _flushPendingTtsUpdates();
        WidgetsBinding.instance.addPostFrameCallback((_) => image?.dispose());
        _scheduleSave();
        if (!automatic && _autoActive && !_autoPaused) _autoClock.forward(from: 0);
      }
    }
  }

  Future<_PageLine?> _preparePreviousPage(_PageLine first, int navigation, {bool retain = false}) async {
    if (first.itemIndex <= 0) return null;
    final previousItem = first.itemIndex - 1;
    // A distant TOC jump centres a new indexed list. Its preceding sliver can
    // have no laid-out text at all; visit the previous item before measuring it.
    _itemScrollController.jumpTo(index: previousItem, alignment: 1);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || navigation != _navigationGeneration) return null;
    final previous = _pageLines().where((line) => line.itemIndex == previousItem).toList();
    if (previous.isEmpty) return null;
    var endKey = previous.last.key;
    await _pageScrollController.animateScroll(offset: previous.last.bottom - _bodyHeight,
      duration: const Duration(milliseconds: 1));
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || navigation != _navigationGeneration) return null;
    var rows = _pageLines();
    if (retain) {
      final overlap = rows.where((line) => line.key == first.key);
      if (overlap.isNotEmpty) {
        endKey = first.key;
        await _pageScrollController.animateScroll(offset: overlap.first.bottom - _bodyHeight,
          duration: const Duration(milliseconds: 1));
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted || navigation != _navigationGeneration) return null;
        rows = _pageLines();
      }
    }
    final ends = rows.where((line) => line.key == endKey);
    if (ends.isEmpty) return null;
    final end = ends.first;
    final fitting = rows.where((line) => line.bottom <= end.bottom + 0.5 && end.bottom - line.top <= _bodyHeight + 0.5).toList();
    if (fitting.isEmpty) return null;
    _pageEndKey = end.key;
    return fitting.first;
  }

  Future<bool> _alignPageLine(_PageLine target, int navigation) async {
    var offset = target.top;
    for (var attempt = 0; attempt < 4; attempt++) {
      if (!mounted || navigation != _navigationGeneration) return false;
      if (offset.abs() > 0.25) {
        await _pageScrollController.animateScroll(offset: offset, duration: const Duration(milliseconds: 1));
      }
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || navigation != _navigationGeneration) return false;
      final matches = _pageLines().where((line) => line.key == target.key);
      if (matches.isEmpty) return false;
      offset = matches.first.top;
      if (offset.abs() <= 0.25) return true;
    }
    return false;
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
        result.add(_PageLine('${entry.key}/$start', top + rect.top, top + rect.bottom, entry.key));
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
      if (mounted) {
        final anchor = _captureLineAnchor(), previous = _visibleLineAnchor;
        _visibleLineAnchor = anchor;
        if (anchor?.chapter != previous?.chapter || anchor?.source != previous?.source || anchor?.title != previous?.title) {
          setState(() {});
        }
        _updatePageGeometry();
      }
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
    if (!_settingsLoaded) return;
    _cancelSentenceDrag();
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
    if (_pendingScrollIndex != null || _suppressScrollTrack || _paging || _inReadingMode) return;
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

  int _visibleDisplayOffset(int c, int p) {
    final positions = _visibleItems().where((position) => position.index == _itemIndexOf(c, p));
    return positions.isEmpty ? 0 : _visibleOffset(positions.first);
  }

  int _sentenceTtsOffset(int c, int p, int s, int? displayOffset) {
    if (!_tts.usesSystemVoice || displayOffset == null) return 0;
    final sentence = _book.chapters[c].paragraphs[p].sentences[s];
    final relative = max(0, displayOffset - sentence.displayStart);
    final map = const TextCleaner().clean(sentence.display);
    var offset = 0;
    while (offset < map.tts.length && map.displayOffsetOfTts(offset) < relative) { offset++; }
    return offset.clamp(0, max(0, sentence.tts.length - 1));
  }

  int _sentenceDisplayOffset(int c, int p, int s, int ttsOffset) {
    final sentence = _book.chapters[c].paragraphs[p].sentences[s];
    return sentence.displayStart + const TextCleaner().clean(sentence.display).displayOffsetOfTts(ttsOffset);
  }

  void _startTtsLoading() { if (mounted) setState(() => _ttsLoading = true); }
  void _stopTtsLoading() { if (mounted && _ttsLoading) setState(() => _ttsLoading = false); }

  /// 进入朗读模式：全屏隐藏UI，开始TTS播放
  Future<void> _play({bool requestNotificationPermission = false}) async {
    if (!_settingsLoaded) return;
    if (_inReadingMode) return;
    if (requestNotificationPermission && !_volumeForeground) return;
    final generation = ++_playbackGeneration;
    if (requestNotificationPermission) {
      final gate = _PlaybackPermissionGate();
      _permissionGate?.cancel(); _permissionGate = gate;
      try {
        final result = await _checkPlaybackNotificationPermission();
        if (!mounted || generation != _playbackGeneration || gate.cancelled) return;
        if (_volumeForeground) gate.resume();
        // Android may deliver the permission result before window focus and
        // resumed. Wait for that event, but never revive a click after Home,
        // actual screen-off, leaving this reader, or an explicit stop.
        await gate.foreground.future;
        if (!mounted || generation != _playbackGeneration || gate.cancelled || !_volumeForeground) return;
        if (result.requested) _showNotificationStatus(result.status);
      } finally {
        if (identical(_permissionGate, gate)) _permissionGate = null;
      }
    }
    if (_autoActive) _stopAutoPage();
    _clearTtsPageBoundary();
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
    await _startTtsFrom(startC, startP, startS, displayOffset: _visibleDisplayOffset(startC, startP));
    if (!mounted || generation != _playbackGeneration || !_inReadingMode) return;
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
  Future<void> _pauseReading({bool force = false}) async {
    _cancelSentenceDrag();
    if (_ttsLoading && !force) return; // Screen taps still ignore loading.
    if (!_inReadingMode || (!force && _tts.state != TtsState.playing)) return;
    if (force) {
      _playbackGeneration++;
      setState(() => _ttsLoading = false);
    }
    final generation = _playbackGeneration;
    if (force && _tts.state != TtsState.playing) {
      await _tts.stop();
    } else {
      await _tts.pause();
    }
    if (!mounted || generation != _playbackGeneration || !_inReadingMode) return;
    globalAudioHandler?.notifyPaused();
    setState(() {
      _isPlaying = false;
      _showReadingPanel = true;
    });
    // A background/OEM volume query must not hold the media pause command and
    // prevent a subsequent notification play from reaching the engine.
    unawaited(_loadMediaVolume());
    _scheduleSave();
  }

  /// 从暂停恢复播放，隐藏底部面板
  /// - 暂停中滑动跨章：重新加载目标章，从当前句开始播放
  /// - 同章恢复：TtsReader 恢复暂停处；彻底失败时 onError 已触发退出
  Future<void> _resumeReading() async {
    print('SCREEN resumeReading state=${_tts.state} loading=$_ttsLoading');
    _debugLog('SCREEN resumeReading state=${_tts.state}');
    if (_ttsLoading) return; // 加载中忽略恢复，防误触
    final generation = _playbackGeneration;
    if (_tts.state != TtsState.paused) {
      // 状态丢失（stopped/idle，如章节播完/曾失败）：从当前阅读位置重新加载
      if (_tts.state == TtsState.stopped || _tts.state == TtsState.idle) {
        _startTtsLoading();
        await _startTtsFrom(
            _chapter, _para, _ttsSentence >= 0 ? _ttsSentence : 0);
        if (!mounted || generation != _playbackGeneration || !_inReadingMode) return;
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
    // Protect the speech cursor before resume can synchronously emit sentence,
    // word or scroll callbacks, including resume through the in-app lock.
    setState(() { _isPlaying = true; _showReadingPanel = false; });
    if (_ttsChapter != _chapter) {
      // 暂停期间滑到了其他章节：TtsReader 内部仍是旧章句子，需重新加载
      final cursor = _speechPauseResumeCursor;
      await _startTtsFrom(
          _chapter, _para, _ttsSentence >= 0 ? _ttsSentence : 0,
          displayOffset: cursor != null && cursor.$1 == _chapter && cursor.$2 == _para && cursor.$3 == _ttsSentence ? cursor.$4 : null);
      if (!mounted || generation != _playbackGeneration || !_inReadingMode) return;
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
    if (!mounted || generation != _playbackGeneration || !_inReadingMode) return;
    _stopTtsLoading();
    if (!ok || !mounted) {
      // 失败且未触发退出：同步 MediaSession 为停止，避免假 playing 状态
      globalAudioHandler?.notifyStopped();
      if (mounted && _inReadingMode) setState(() { _isPlaying = false; _showReadingPanel = true; });
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
    _sentenceDrag = null;
    final generation = ++_playbackGeneration;
    _permissionGate?.cancel();
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepMinutes = 0;
    _gestureTipTimer?.cancel();
    _gestureTipTimer = null;
    _gestureTipVisible = false;
    _ttsLoading = false;
    _saveDebounce?.cancel(); _saveProgress();
    if (mounted) setState(() {
      _inReadingMode = false;
      _showControls = true;
      _isPlaying = false;
      _showReadingPanel = false;
    });
    globalAudioHandler?.notifyStopped();
    _exitFullscreen();
    await _tts.stop();
    if (!mounted || generation != _playbackGeneration) return;
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
  Future<void> _applySystemUi() async {
    if (_leavingReader) return;
    final applying = SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemStatusBarContrastEnforced: false,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.light,
      systemNavigationBarContrastEnforced: false,
    ));
    try { await applying; } on PlatformException { /* Preserve a usable reader on older hosts. */ }
    on MissingPluginException { /* Non-Android hosts can still read. */ }
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
    if (state != AppLifecycleState.resumed) _cancelSentenceDrag();
    _volumeForeground = state == AppLifecycleState.resumed;
    _syncScreenAwake();
    _syncMediaVolumePolling();
    if (state == AppLifecycleState.resumed) _permissionGate?.resume();
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      _permissionGate?.cancel();
    }
    if (state == AppLifecycleState.resumed) {
      final afterSettings = _notificationSettingsPending;
      _notificationSettingsPending = false;
      if (afterSettings) _refreshPlaybackNotifications(afterSettings: true);
    }
    if (state != AppLifecycleState.resumed) {
      _saveDebounce?.cancel(); _saveProgress();
      if (_autoActive && !_autoPaused) _pauseAutoPage();
    } else if (_inReadingMode && _tts.state == TtsState.playing) {
      // Audio keeps playing in the background. Only refresh its cursor; never
      // restart audio or restore the viewport's older reading position.
      setState(() { _isPlaying = true; _showReadingPanel = false; _showControls = false; });
      _applySystemUi();
      _scheduleActiveSpeechAlignment();
    }
  }

  void _scheduleActiveSpeechAlignment() {
    final playback = _playbackGeneration, navigation = _navigationGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _leavingReader || !_volumeForeground || !_inReadingMode || _sentenceDrag != null ||
        _tts.state != TtsState.playing || playback != _playbackGeneration || navigation != _navigationGeneration) return;
      _onTtsSentenceChanged(_tts.currentIndex, follow: false);
      final offset = _wordStart >= 0 ? _wordStart : _sentenceDisplayOffset(_chapter, _para, max(0, _ttsSentence), _tts.currentTtsOffset);
      _followSentence(_chapter, _para, max(0, _ttsSentence), character: offset, alignToTop: true);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<PlaybackNotificationCheck> _checkPlaybackNotificationPermission() async {
    final result = await _playbackNotifications.checkForPlayback(foregroundUserAction: true);
    return result;
  }

  void _showNotificationStatus(PlaybackNotificationStatus status) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text(T(!status.supported ? 'playbackNotificationsUnavailable' : status.enabled
        ? 'playbackNotificationsEnabled' : 'playbackNotificationsDisabled')),
      action: status.supported && !status.enabled
        ? SnackBarAction(label: T('notificationSettings'), onPressed: _openNotificationSettings) : null));
  }

  Future<void> _refreshPlaybackNotifications({bool afterSettings = false}) async {
    final status = await _playbackNotifications.getStatus();
    if (!mounted) return;
    if (afterSettings) _showNotificationStatus(status);
  }

  Future<void> _openNotificationSettings() async {
    _notificationSettingsPending = true;
    final opened = await _playbackNotifications.openSettings();
    if (!opened) {
      _notificationSettingsPending = false;
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(T('notificationSettingsFailed'))));
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
    _syncScreenAwake();
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
    if (mounted) setState(() { _autoPaused = true; _showAutoPanel = true; });
    _syncScreenAwake();
  }

  void _resumeAutoPage() {
    setState(() { _autoPaused = false; _showAutoPanel = false; _showControls = false; });
    _syncScreenAwake();
    if (_autoClock.value >= 1) { _autoClock.forward(from: 0); } else { _autoClock.forward(); }
  }

  void _stopAutoPage() {
    _autoClock.stop(); _autoClock.value = 0;
    if (mounted) setState(() { _autoActive = false; _autoPaused = false; _showAutoPanel = false; _showControls = true; });
    _syncScreenAwake();
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
      _settings.themeMode = index == 2 ? 'dark' : 'light';
      if (index != 2) _settings.dayThemeIndex = index;
    });
    AppAppearance.setThemeMode(_settings.themeMode);
    widget.storage.saveSettings(_settings.toJson());
  }

  void _toggleNight() => _setTheme(_isNight
      ? (_settings.dayThemeIndex == 2 ? 0 : _settings.dayThemeIndex.clamp(0, _bookThemes.length - 1)) : 2);

  void _toggleOrientation() {
    _settings.followSystemRotation = false;
    widget.storage.saveSettings(_settings.toJson());
    final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    SystemChrome.setPreferredOrientations(landscape
        ? [DeviceOrientation.portraitUp]
        : [DeviceOrientation.landscapeLeft]);
  }

  void _applyRotationPreference() => SystemChrome.setPreferredOrientations(_settings.followSystemRotation
    ? DeviceOrientation.values : [DeviceOrientation.portraitUp]);

  void _changeChapter(int direction) {
    _navigateToc(_currentTocIndex + direction);
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
  void _ttsFollowSeek(int c, int p, int s, {int? displayOffset}) {
    if (c < 0 || c >= _book.chapters.length) return;
    _updateMediaChapter(c);
    final offset = _sentenceTtsOffset(c, p, s, displayOffset);
    if (_tts.state == TtsState.paused || !_isPlaying) {
      if (c == _ttsChapter) {
        _tts.jumpTo(_chapterSentenceStart(c, p) + s, ttsOffset: offset);
      }
      return;
    }
    if (c != _ttsChapter) {
      _startTtsFrom(c, p, s, displayOffset: displayOffset);
    } else {
      _tts.jumpTo(_chapterSentenceStart(c, p) + s, ttsOffset: offset);
    }
  }

  Future<void> _startTtsFrom(int c, int p, int s, {int? displayOffset}) async {
    _speechPauseResumeCursor = null;
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
    final offset = _sentenceTtsOffset(c, p, s, displayOffset ??
      (c == _chapter && p == _para && s == _ttsSentence && _wordStart >= 0 ? _wordStart : null));
    _ttsChapter = c;
    // 保证播放位置有效
    final from = startIdx.clamp(0, sentences.length - 1);
    setState(() {
      _chapter = c;
      _para = p;
      _ttsSentence = s;
      // Every restart (including a voice change from the paused panel) starts
      // playback. Keep scroll tracking and the visible controls in that state
      // before follow/tts callbacks can produce a scroll notification.
      if (_inReadingMode) {
        _isPlaying = true;
        _showReadingPanel = false;
      }
    });
    _updateMediaChapter(c);
    if (_inReadingMode) globalAudioHandler?.notifyPlaying();
    _followSentence(c, p, s, character: offset > 0 ? _sentenceDisplayOffset(c, p, s, offset) : null);
    _scheduleSave();
    _refreshTtsCache();
    await _tts.start(
      sentences,
      offsets: chapterTtsSentenceOffsets(_book.chapters[c]),
      pauseAfterMilliseconds: [for (final para in _book.chapters[c].paragraphs)
        for (final sentence in para.sentences) sentence.pauseAfterMilliseconds],
      chapterIndex: c,
      from: from,
      initialTtsOffset: offset,
    );
  }

  void _updateMediaChapter(int chapter) {
    if (chapter < 0 || chapter >= _book.chapters.length) return;
    final toc = _toc.isEmpty ? null : _toc[_currentTocIndex];
    final title = toc?.title ?? _book.chapters[chapter].title;
    String? spokenText;
    if (_settings.showSystemMediaText && _inReadingMode && _chapter == chapter &&
        _para >= 0 && _para < _book.chapters[chapter].paragraphs.length) {
      final sentences = _book.chapters[chapter].paragraphs[_para].sentences;
      if (_ttsSentence >= 0 && _ttsSentence < sentences.length) {
        final sentence = sentences[_ttsSentence];
        final cursorKey = '$_textSignature/$_chapter/$_para/$_ttsSentence';
        if (_mediaSpeechCursorKey != cursorKey) {
          _mediaSpeechCursorKey = cursorKey; _mediaSpeechOffset = null;
        }
        if (_mediaSpeechText?.text != sentence.display) _mediaSpeechText = MediaSpeechText(sentence.display);
        spokenText = _mediaSpeechText!.textAt(_mediaSpeechOffset);
      }
    }
    final key = '$chapter/${toc?.paragraphIndex}/${toc?.displayOffset}/$title/'
      '${_settings.showSystemMediaText}/$_para/$_ttsSentence/$spokenText';
    if (_mediaTocKey == key && globalAudioHandler?.mediaItem.value?.displaySubtitle == spokenText) return;
    _mediaTocKey = key;
    globalAudioHandler?.updateBookChapter(bookId: _book.id, bookTitle: _book.title,
      chapterTitle: title, chapterIndex: chapter, spokenText: spokenText);
  }

  void _onTtsSentenceChanged(int idx, {bool follow = true}) {
    if (!mounted || !_inReadingMode || _sentenceDrag != null) return;
    if (idx < 0) return;
    if (_paging) {
      _pendingTtsSentence = (_ttsChapter, idx);
      _pendingTtsWord = null;
      return;
    }
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
      _scheduleSave();
    }
    _updateMediaChapter(c);
    // A replay after a page animation may already have the right sentence but
    // still need to bring it back inside the newly laid out viewport.
    if (follow && _volumeForeground && _itemScrollController.isAttached) _followSentence(c, p, s, character: _tts.currentTtsOffset > 0
      ? _sentenceDisplayOffset(c, p, s, _tts.currentTtsOffset) : null);
  }

  void _onTtsWordChanged(int start, int end) {
    if (!mounted || !_inReadingMode || _sentenceDrag != null) return;
    if (_paging) {
      // Word offsets belong to the queued sentence, never the old screen one.
      if (_pendingTtsSentence != null) _pendingTtsWord = (start, end);
      return;
    }
    if (start < 0 || end <= start) {
      if (_wordStart >= 0) setState(() { _wordStart = -1; _wordEnd = -1; });
      return;
    }
    final para = _book.chapters[_chapter].paragraphs[_para];
    if (_ttsSentence < 0 || _ttsSentence >= para.sentences.length) return;
    final sentence = para.sentences[_ttsSentence];
    final key = '$_textSignature/$_chapter/$_para/$_ttsSentence';
    if (_wordMapKey != key) { _wordMapKey = key; _wordMap = const TextCleaner().clean(sentence.display); }
    // Speech-only separators (such as a silent dash) are absent from the
    // paragraph TTS offsets. Map inside this displayed segment instead.
    final base = sentence.displayStart;
    var left = (base + _wordMap!.displayOffsetOfTts(start)).clamp(base, sentence.displayEnd);
    final right = (base + _wordMap!.displayOffsetOfTts(end)).clamp(left, sentence.displayEnd);
    while (left < right && para.display[left].trim().isEmpty) { left++; }
    _mediaSpeechCursorKey = key;
    _mediaSpeechOffset = left - base;
    setState(() { _wordStart = left; _wordEnd = right; });
    _updateMediaChapter(_chapter);
    _ensureWordVisible(left);
  }

  void _flushPendingTtsUpdates() {
    final sentence = _pendingTtsSentence, word = _pendingTtsWord;
    _pendingTtsSentence = null; _pendingTtsWord = null;
    if (!mounted || !_inReadingMode || sentence == null || sentence.$1 != _ttsChapter) return;
    _onTtsSentenceChanged(sentence.$2);
    if (word != null) _onTtsWordChanged(word.$1, word.$2);
  }

  void _clearTtsPageBoundary() {
    if (_pageEndKey == null) return;
    _pageEndKey = null;
    _pageClipBottom = null;
    _schedulePageGeometry();
  }

  RenderBox? get _ttsBodyBox {
    final render = _pageBoundary.currentContext?.findRenderObject();
    return render is RenderBox && render.hasSize ? render : null;
  }

  double get _ttsBodyHeight => _ttsBodyBox?.size.height ?? _bodyExtent;
  double get _ttsVisibleBottom => min(_ttsBodyHeight,
    _settings.pageTurnMode == 'scroll' ? _ttsBodyHeight : (_pageClipBottom ?? _ttsBodyHeight));

  Rect? _ttsGlyphRect(int c, int p, int offset) {
    final body = _ttsBodyBox;
    final render = _paragraphKeys[_itemIndexOf(c, p)]?.currentContext?.findRenderObject();
    if (body == null || render is! RenderParagraph || !render.hasSize) return null;
    final paragraph = _book.chapters[c].paragraphs[p];
    final boxes = render.getBoxesForSelection(TextSelection(baseOffset: _renderOffset(c, p, offset),
      extentOffset: _renderOffset(c, p, min(offset + 1, paragraph.display.length))),
      boxHeightStyle: ui.BoxHeightStyle.includeLineSpacingMiddle);
    if (boxes.isEmpty) return null;
    return boxes.first.toRect().shift(render.localToGlobal(Offset.zero, ancestor: body));
  }

  bool _ttsGlyphVisible(Rect glyph) => glyph.top >= -0.25 && glyph.bottom <= _ttsVisibleBottom + 0.25;

  Future<void> _ensureWordVisible(int offset) async {
    if (!_volumeForeground || _paging || _followingWord || _pendingScrollIndex != null || !_itemScrollController.isAttached) return;
    _clearTtsPageBoundary();
    final glyph = _ttsGlyphRect(_chapter, _para, offset);
    if (glyph == null) {
      _followSentence(_chapter, _para, max(0, _ttsSentence), character: offset);
      return;
    }
    if (_ttsGlyphVisible(glyph)) return;
    _followingWord = true;
    try {
      await _pageScrollController.animateScroll(offset: glyph.top - _ttsBodyHeight * 0.2,
        duration: const Duration(milliseconds: 1));
    } finally { _followingWord = false; }
    if (mounted) _scheduleSave();
  }

  Future<void> _followSentence(int c, int p, int sentence, {int? character, bool alignToTop = false}) async {
    _clearTtsPageBoundary();
    final index = _itemIndexOf(c, p);
    final paragraph = _book.chapters[c].paragraphs[p];
    if (paragraph.sentences.isEmpty) return;
    final offset = character ?? paragraph.sentences[sentence.clamp(0, paragraph.sentences.length - 1)].displayStart;
    final painter = TextPainter(text: _paragraphSpan(_items[index], paragraph, gestures: false),
      textAlign: TextAlign.justify, textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context));
    if (ReaderTypography.leadingLength(paragraph.display) > 0) painter.setPlaceholderDimensions([
      PlaceholderDimensions(size: Size(_indentWidth(paragraph), 1), alignment: ui.PlaceholderAlignment.middle)]);
    painter.layout(maxWidth: (_ttsBodyBox?.size.width ?? MediaQuery.sizeOf(context).width) - 32);
    final boxes = painter.getBoxesForSelection(TextSelection(baseOffset: _renderOffset(c, p, offset),
      extentOffset: _renderOffset(c, p, min(offset + 1, paragraph.display.length))));
    final top = boxes.isEmpty ? 0.0 : boxes.first.top + 10;
    painter.dispose();
    final glyph = _ttsGlyphRect(c, p, offset);
    if (!alignToTop && glyph != null && _ttsGlyphVisible(glyph)) return;
    final before = _navigationGeneration;
    final playback = _playbackGeneration;
    await _positionViewport(index, 0);
    if (!mounted || _paging || _navigationGeneration != before + 1 || alignToTop && playback != _playbackGeneration) return;
    _pendingScrollIndex = null;
    final generation = _navigationGeneration;
    final positionedGlyph = _ttsGlyphRect(c, p, offset);
    final contextSpace = _inReadingMode && !alignToTop ? _ttsBodyHeight * 0.2 : 0.0;
    await _pageScrollController.animateScroll(offset: max(0.0, (positionedGlyph?.top ?? top) - contextSpace),
      duration: const Duration(milliseconds: 1));
    if (generation == _navigationGeneration) _scheduleSave();
  }

  void _onTtsCompleted() {
    if (!mounted || !_inReadingMode || _sentenceDrag != null) return;
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
    if (!mounted || !_inReadingMode) return;
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

  (int, int, int) _sentenceDragTarget((int, int, int) origin, int steps) {
    int count(int chapter) => _book.chapters[chapter].paragraphs.fold(0, (sum, p) => sum + p.sentences.length);
    var c = origin.$1, index = _chapterSentenceStart(origin.$1, origin.$2) + origin.$3 + steps;
    while (c > 0 && index < 0) { c--; index += count(c); }
    while (c < _book.chapters.length - 1 && index >= count(c)) { index -= count(c); c++; }
    while (c > 0 && count(c) == 0) { c--; index = count(c) - 1; }
    index = index.clamp(0, max(0, count(c) - 1));
    for (var p = 0; p < _book.chapters[c].paragraphs.length; p++) {
      final n = _book.chapters[c].paragraphs[p].sentences.length;
      if (index < n) return (c, p, index);
      index -= n;
    }
    return origin;
  }

  void _startSentenceDrag() {
    if (!_inReadingMode || _paging || _sentenceDrag != null) return;
    final wasLoading = _ttsLoading;
    final session = _SentenceDragSession((_chapter, _para, max(0, _ttsSentence)), _isPlaying,
      ++_playbackGeneration, _wordStart, _wordEnd);
    _sentenceDrag = session;
    setState(() { _isPlaying = false; _ttsLoading = false; _showReadingPanel = false; });
    final pause = _tts.state == TtsState.playing ? _tts.pause() : wasLoading ? _tts.stop() : Future<void>.value();
    session.paused = pause.then((_) => true, onError: (Object _) => false);
    globalAudioHandler?.notifyPaused();
  }

  void _previewSentenceDrag(int steps) {
    final session = _sentenceDrag;
    if (session == null || session.ending) return;
    final delta = steps - session.lastSteps;
    session.lastSteps = steps;
    final target = _sentenceDragTarget(session.target, delta);
    if (session.target == target) return;
    session.target = target; _navigationGeneration++;
    setState(() { _chapter = target.$1; _para = target.$2; _ttsSentence = target.$3; _wordStart = -1; _wordEnd = -1; });
    _followSentence(target.$1, target.$2, target.$3);
  }

  void _cancelSentenceDrag() {
    final session = _sentenceDrag;
    if (session == null) return;
    _sentenceDrag = null; _navigationGeneration++;
    if (!mounted || !_inReadingMode) return;
    setState(() { _chapter = session.origin.$1; _para = session.origin.$2; _ttsSentence = session.origin.$3;
      _wordStart = session.wordStart; _wordEnd = session.wordEnd; _isPlaying = false; _showReadingPanel = true; });
    _followSentence(_chapter, _para, _ttsSentence, character: _wordStart >= 0 ? _wordStart : null);
    globalAudioHandler?.notifyPaused(); _scheduleSave();
  }

  Future<void> _finishSentenceDrag(bool cancelled) async {
    if (cancelled) { _cancelSentenceDrag(); return; }
    final session = _sentenceDrag;
    if (session == null || session.ending) return;
    session.ending = true;
    final paused = await session.paused;
    if (!mounted || !_inReadingMode || !identical(_sentenceDrag, session) || session.generation != _playbackGeneration) return;
    if (!paused) { _cancelSentenceDrag(); return; }
    _sentenceDrag = null;
    final target = session.target;
    if (session.wasPlaying) {
      if (target == session.origin) {
        setState(() { _wordStart = session.wordStart; _wordEnd = session.wordEnd; });
        await _resumeReading();
      } else {
        await _startTtsFrom(target.$1, target.$2, target.$3);
      }
    } else {
      setState(() { _isPlaying = false; _showReadingPanel = true; });
      if (target == session.origin) {
        setState(() { _wordStart = session.wordStart; _wordEnd = session.wordEnd; });
      } else {
        _ttsFollowSeek(target.$1, target.$2, target.$3);
      }
      _scheduleSave();
    }
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
    _syncScreenAwake();
    if (!_settingsLoaded) {
      return PopScope(onPopInvokedWithResult: (didPop, result) { if (didPop) _restoreSystemUiForExit(); },
        child: const Scaffold(body: Center(child: CircularProgressIndicator())));
    }
    _viewportSize = MediaQuery.sizeOf(context);
    _headerReservedExtent = _chapterTopArea();
    _bodyExtent = _bodyHeight;
    final header = _headerLayout.chapterTitle(_chapterBarTitle(_chapter));
    return PopScope(
      onPopInvokedWithResult: (didPop, result) { if (didPop) _restoreSystemUiForExit(); },
      child: Listener(onPointerDown: (_) => _screenAwake.interaction(), onPointerMove: (_) => _screenAwake.interaction(), child: Scaffold(
        backgroundColor: _theme.bg,
        body: Stack(
        children: [
          // 正文区（不分层）：整体下移「两行半空白 + 标题行」高度，
          // 章节标题 Positioned 固定在正文区顶部，正文列表在标题下方独立滚动
          Padding(
            padding: EdgeInsets.only(
              top: _chapterTopArea(),
              bottom: _readerInsets.bottom + 32,
            ),
            child: _buildPageCanvas(),
          ),
          // 固定章节标题：位于顶部两行半空白之后，正文滚动时保持不动
          Positioned.fromRect(
            rect: header.nameRect,
            child: _buildChapterHeader(header.chapterName),
          ),
          if (header.chapterNumber != null && header.numberRect != null)
            Positioned.fromRect(rect: header.numberRect!, child: Center(child: Text(header.chapterNumber!,
              key: const ValueKey('reader-chapter-number'), maxLines: 1, overflow: TextOverflow.ellipsis,
              textScaler: TextScaler.noScaling, style: TextStyle(fontSize: 12, color: _theme.title)))),
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
          ],
        ),
      )),
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
          if (_inReadingMode && !_showReadingPanel && _tts.usingSystemFallback)
            Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Text(T('offlineSystemVoice'),
              maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
              style: TextStyle(fontSize: 10, color: _theme.title)))),
          Text('${(_percent * 100).toStringAsFixed(1)}%', style: TextStyle(fontSize: 12, color: _theme.title)),
        ],
      )),
    );
  }

  /// 章节标题行文案：标题已含"第X章/Chapter"则原样，否则加章节序号
  String _chapterBarTitle(int c) {
    if (_toc.isNotEmpty) return _toc[_currentTocIndex].title;
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

  double _chapterTopArea() => _headerLayout.topArea;

  /// A fixed-size chapter title occupies the safe top slot. Body font changes
  /// and toolbar overlays never change this reserved height.
  Widget _buildChapterHeader(String name) {
    return Container(
      key: const ValueKey('reader-chapter-header'),
      padding: const EdgeInsets.symmetric(horizontal: 4),
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
          name,
          maxLines: 1,
          textScaler: TextScaler.noScaling,
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
        key: const ValueKey('reading-panel'),
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height - _readerInsets.top),
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
          child: SingleChildScrollView(child: Column(
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
              if (_tts.usingSystemFallback) Padding(key: const ValueKey('tts-offline-fallback'),
                padding: const EdgeInsets.only(bottom: 4), child: Text(T('offlineSystemVoice'),
                  style: const TextStyle(color: Color(0xFF9BC5DD), fontSize: 12))),
              // 功能按钮行
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _panelButton(
                    icon: Icons.alarm,
                    label: _sleepMinutes > 0
                        ? T('minutes', {'m': '$_sleepMinutes'})
                        : T('timer'),
                    key: const ValueKey('reading-sleep'), onTap: _openSleepTimer,
                    active: _sleepMinutes > 0,
                  ),
                  _panelButton(
                    key: const ValueKey('reading-voice'),
                    icon: Icons.record_voice_over,
                    label: T('voiceWithName', {'name': _shortVoiceLabel(_effectiveVoice)}), singleLine: true,
                    onTap: _openVoiceSelector,
                  ),
                  _panelButton(
                    key: const ValueKey('playback-settings'), icon: Icons.settings_outlined,
                    label: T('playbackSettings'), onTap: _openPlaybackSettings),
                  _panelButton(
                    icon: Icons.power_settings_new,
                    label: T('exit'),
                    onTap: _exitReadingMode,
                  ),
                ].map((button) => Expanded(child: button)).toList(),
              ),
            ],
          )),
      ),
    );
  }

  Widget _panelButton({
    Key? key,
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    String? detail,
    bool singleLine = false,
    bool active = false,
  }) {
    return GestureDetector(
      key: key,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon,
              color: onTap == null ? Colors.grey : const Color(0xFF9BC5DD),
              size: 26),
          const SizedBox(height: 4),
          Text(label, textAlign: TextAlign.center, maxLines: singleLine ? 1 : 2, overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: active
                      ? const Color(0xFF9BC5DD)
                      : const Color(0xFFA89060),
                  fontSize: 11)),
          if (detail != null) Text(detail, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Color(0xFFA89060), fontSize: 10)),
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
    rate = (rate.clamp(0.5, 3.0) * 10).round() / 10;
    _settings.speechRate = rate;
    _tts.setSpeechRate(rate);
    _refreshTtsCache();
    widget.storage.saveSettings(_settings.toJson());
    setState(() {});
  }

  Future<void> _openPrefetchSettings() async {
    final count = await showDialog<int>(context: context, builder: (_) => _IntegerInputDialog(
      title: T('prefetchTitle'), help: T('prefetchDescription'), value: _settings.prefetchSentences,
      minimum: 0, maximum: 100, inputKey: const ValueKey('prefetch-number')));
    if (count == null || !mounted) return;
    _settings.prefetchSentences = count;
    _tts.setPrefetchSentences(count);
    widget.storage.saveSettings(_settings.toJson());
    setState(() {});
  }

  Future<void> _openPlaybackSettings() async {
    if (_applyingSpeechPauses) return;
    final pauseVoice = _settings.speechPauseVoice;
    final selected = await showModalBottomSheet<SpeechPauseSelection>(context: context, isScrollControlled: true,
      builder: (context) => StatefulBuilder(builder: (ctx, update) => SafeArea(child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.85),
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(16), children: [
          Text(T('playbackSettings'), style: Theme.of(ctx).textTheme.titleMedium),
          SwitchListTile(key: const ValueKey('word-highlight'), title: Text(T('wordHighlight')),
            value: _settings.wordHighlightEnabled, onChanged: (value) {
              setState(() => _settings.wordHighlightEnabled = value); update(() {}); widget.storage.saveSettings(_settings.toJson());
            }),
          SwitchListTile(key: const ValueKey('show-system-media-text'), title: Text(T('showSystemMediaText')),
            value: _settings.showSystemMediaText, onChanged: (value) {
              setState(() => _settings.showSystemMediaText = value); update(() {}); widget.storage.saveSettings(_settings.toJson());
              _updateMediaChapter(_chapter);
            }),
          ListTile(key: const ValueKey('reading-prefetch'), title: Text(T('prefetchSentences', {'n': '${_settings.prefetchSentences}'})),
            subtitle: Text(T('prefetchDescription')), trailing: const Icon(Icons.tune),
            onTap: () async { await _openPrefetchSettings(); if (ctx.mounted) update(() {}); }),
          ListTile(title: Text(T('sentenceDragDelay', {'n': _settings.sentenceDragDelay.toStringAsFixed(1)}))),
          Slider(key: const ValueKey('sentence-drag-delay'), value: _settings.sentenceDragDelay,
            min: 0, max: 0.5, divisions: 5, onChanged: (value) {
              setState(() => _settings.sentenceDragDelay = (value * 10).round() / 10); update(() {}); widget.storage.saveSettings(_settings.toJson());
            }),
          ListTile(key: const ValueKey('screen-awake'), title: Text(T('screenAwake')),
            subtitle: Text('${T('voiceScreenAwakeDescription')}\n${T('screenTimeoutDescription')}'), trailing: DropdownButton<int>(
            value: [0, 15, 30, 60, 90].contains(_settings.keepScreenMinutes) ? _settings.keepScreenMinutes : -1,
            items: [for (final minutes in [0, 15, 30, 60, 90, -1]) DropdownMenuItem(value: minutes,
              child: Text(minutes == 0 ? T('systemScreenAwake') : minutes == -1 ? T('customScreenAwake') : T('minutes', {'m': '$minutes'})))],
            onChanged: (value) async {
              if (value == null) return;
              final chosen = value == -1 ? await showDialog<int>(context: ctx, builder: (_) => _IntegerInputDialog(
                title: T('screenAwake'), value: _settings.keepScreenMinutes > 0 ? _settings.keepScreenMinutes : 15,
                minimum: 1, maximum: 120, inputKey: const ValueKey('awake-custom-minutes'))) : value;
              if (chosen != null && mounted && ctx.mounted) { setState(() => _settings.keepScreenMinutes = chosen); update(() {});
                widget.storage.saveSettings(_settings.toJson()); _syncScreenAwake(); }
            })),
          SpeechPauseEditor(voiceId: pauseVoice,
            initialPauses: _settings.speechPausesForVoice(pauseVoice), globalPauses: _settings.speechPauses,
            onApply: (selection) => Navigator.pop(ctx, selection)),
        ])))));
    if (selected != null && mounted) await _applySpeechPauseSelection(selected);
  }

  void _syncScreenAwake() {
    final speaking = _inReadingMode && (_isPlaying || _ttsLoading);
    final seconds = _inReadingMode ? speaking ? _settings.keepScreenMinutes * 60 : 0 : _settings.readingScreenSeconds;
    _screenAwake.configure(timeout: seconds > 0 ? Duration(seconds: seconds) : null,
      active: _settingsLoaded && !_leavingReader && (!_inReadingMode || speaking), foreground: _volumeForeground,
      scope: _inReadingMode ? 'voice' : 'reading');
  }

  Future<void> _openVoiceSpeechPauses(String voice) async {
    if (_applyingSpeechPauses) return;
    final selected = await showModalBottomSheet<SpeechPauseSelection>(context: context, isScrollControlled: true,
      builder: (ctx) => SafeArea(child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.85),
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(16), children: [
          Text(T('voicePauseTitle', {'name': _shortVoiceLabel(voice)}), style: Theme.of(ctx).textTheme.titleMedium),
          SpeechPauseEditor(voiceId: voice, initialPauses: _settings.speechPausesForVoice(voice),
            globalPauses: _settings.speechPauses, initiallyExpanded: true,
            onApply: (selection) => Navigator.pop(ctx, selection)),
        ]))));
    if (selected != null && mounted) await _applySpeechPauseSelection(selected);
  }

  Future<void> _applySpeechPauseSelection(SpeechPauseSelection selection) async {
    final desired = ReadingSettings.fromJson(_settings.toJson());
    switch (selection.action) {
      case SpeechPauseAction.currentVoice: desired.setVoiceSpeechPauses(selection.voiceId, selection.pauses);
      case SpeechPauseAction.global: desired.applyGlobalSpeechPauses(selection.pauses);
      case SpeechPauseAction.resetGlobal: desired.resetGlobalSpeechPauses();
    }
    await _applySpeechConfiguration(desired);
  }

  void _commitPauseConfiguration(ReadingSettings desired, {required bool updateVoice}) {
    _settings.speechPauses = desired.speechPauses;
    _settings.perVoiceSpeechPauses..clear()..addAll(desired.perVoiceSpeechPauses);
    if (updateVoice) {
      _settings.voice = desired.voice;
      _settings.systemFallbackActive = desired.systemFallbackActive;
    }
  }

  void _onSpeechVoiceModeChanged(bool fallback) {
    if (!mounted) return;
    if (!_settingsLoaded || _settings.systemFallbackActive == fallback) { setState(() {}); return; }
    final desired = ReadingSettings.fromJson(_settings.toJson())..systemFallbackActive = fallback;
    if (_applyingSpeechPauses) {
      _pendingSpeechFallback = fallback;
      if (fallback && _inReadingMode && _isPlaying && _formatSignature(desired) != _textSignature) {
        unawaited(_tts.pause());
      }
      return;
    }
    if (fallback && !_applyingSpeechPauses && _inReadingMode && _isPlaying &&
        _formatSignature(desired) != _textSignature) {
      // pause() invalidates the pending fallback synchronously. The old queue
      // cannot start system speech with the online voice's split boundaries.
      unawaited(_applySpeechConfiguration(desired, updateVoice: true,
        setEngineVoice: false, resumeAfter: true));
    } else {
      setState(() => _settings.systemFallbackActive = fallback);
      widget.storage.saveSettings(_settings.toJson());
    }
  }

  /// Commit pause/voice changes only after their effective split is prepared.
  /// Raw source anchors preserve the displayed line and the paused word.
  Future<bool> _applySpeechConfiguration(ReadingSettings desired, {bool updateVoice = false,
    bool setEngineVoice = true, bool? resumeAfter}) async {
    if (_applyingSpeechPauses || _book.chapters.isEmpty) return false;
    final needsPreparation = _textSignature != _formatSignature(desired);
    if (!needsPreparation && !updateVoice) {
      setState(() => _commitPauseConfiguration(desired, updateVoice: false));
      await widget.storage.saveSettings(_settings.toJson());
      return true;
    }
    final previous = _book, line = _captureLineAnchor(), c = _chapter.clamp(0, _book.chapters.length - 1);
    if (previous.chapters[c].paragraphs.isEmpty) return false;
    _applyingSpeechPauses = true;
    final p = _para.clamp(0, previous.chapters[c].paragraphs.length - 1);
    final paragraph = previous.chapters[c].paragraphs[p];
    final at = _wordStart >= 0 ? _wordStart : paragraph.sentences.isEmpty ? 0 :
      paragraph.sentences[_ttsSentence.clamp(0, paragraph.sentences.length - 1)].displayStart;
    final anchor = ReadingText.anchor(previous, c, p, at), wasPlaying = resumeAfter ?? _isPlaying;
    final signature = _formatSignature(_settings);
    final generation = ++_playbackGeneration;
    try {
      if (_inReadingMode) {
        await _tts.pause();
        if (!mounted || _leavingReader || generation != _playbackGeneration) return false;
        setState(() { _isPlaying = false; _ttsLoading = false; });
        globalAudioHandler?.notifyPaused();
      }
      if (!mounted || _leavingReader || generation != _playbackGeneration) return false;
      final prepared = needsPreparation ? await ReaderPreparation.prepare(ReaderPreparationRequest(widget.book,
        merge: desired.mergeNonSentenceBreaks, indent: desired.firstLineIndent, pauseSettings: desired.effectiveSpeechPauses,
        filter: desired.informationFilter ? desired.informationFilterLevel : 'none', autoExtractToc: desired.autoExtractToc)) : null;
      if (!mounted || _leavingReader || generation != _playbackGeneration || signature != _formatSignature(_settings)) return false;
      prepared?.attachSourceMaps();
      setState(() {
        _commitPauseConfiguration(desired, updateVoice: updateVoice);
        _textSignature = _formatSignature(_settings);
        if (prepared != null) {
          _installFormattedBook(prepared.book, prepared.fingerprint);
          _toc = prepared.toc; _tocAnchors = prepared.tocAnchors; _tocIsChapterTitle = prepared.chapterTitles;
          _flowChapter = null; _flowParagraph = null; _flowOffset = null;
        }
        final location = ReadingText.locate(_book, c, anchor);
        _chapter = c; _para = location.$1;
        _ttsSentence = ReadingText.sentenceAt(_book.chapters[c].paragraphs[_para], location.$2);
        _wordStart = location.$2; _wordEnd = location.$2; _ttsChapter = -1;
        _speechPauseResumeCursor = (_chapter, _para, _ttsSentence, location.$2);
      });
      if (updateVoice && setEngineVoice) _tts.setVoice(_settings.voice.isEmpty ? TtsReader.defaultVoice : _settings.voice);
      if (prepared != null) _remapAnnotations(previous);
      _refreshTtsCache(); _updateMediaChapter(_chapter);
      await widget.storage.saveSettings(_settings.toJson());
      if (prepared != null) await _restoreLineAnchor(line);
      if (mounted && !_leavingReader && generation == _playbackGeneration && wasPlaying && _inReadingMode) {
        await _startTtsFrom(_chapter, _para, _ttsSentence, displayOffset: _wordStart);
      }
      return true;
    } catch (error) {
      if (mounted && !_leavingReader && generation == _playbackGeneration) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(T('parseFail', {'err': '$error'}))));
        if (wasPlaying && _inReadingMode) await _resumeReading();
      }
      return false;
    } finally {
      _applyingSpeechPauses = false;
      final pendingFallback = _pendingSpeechFallback;
      _pendingSpeechFallback = null;
      if (pendingFallback != null && mounted && !_leavingReader) {
        _onSpeechVoiceModeChanged(_tts.usingSystemFallback);
      }
    }
  }

  /// 定时播放：到时间自动暂停
  Future<void> _openSleepTimer() async {
    final options = [0, 15, 30, 60, 90];
    final selected = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(child: Column(
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
                  key: ValueKey('sleep-preset-$m'),
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
            ListTile(key: const ValueKey('sleep-custom'), leading: const Icon(Icons.edit_outlined),
              title: Text(T('customSleepTimer')), subtitle: Text(T('numberRange', {'n': '1', 'total': '120'})),
              onTap: () => Navigator.pop(ctx, -1)),
            const SizedBox(height: 8),
          ],
        )),
      ),
    );
    if (selected == null) return;
    if (selected == -1) {
      if (!mounted) return;
      final minutes = await showDialog<int>(context: context, builder: (_) => _IntegerInputDialog(
        title: T('customSleepTimer'), value: _sleepMinutes > 0 ? _sleepMinutes : 30,
        minimum: 1, maximum: 120, inputKey: const ValueKey('sleep-custom-minutes')));
      if (minutes != null && mounted) _setSleepTimer(minutes);
    } else {
      _setSleepTimer(selected);
    }
  }

  void _setSleepTimer(int minutes) {
    minutes = minutes.clamp(0, 120);
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepMinutes = minutes;
    if (minutes > 0) {
      _sleepTimer = Timer(Duration(minutes: minutes), () {
        if (!mounted) return;
        _cancelSentenceDrag();
        setState(() { _sleepMinutes = 0; _sleepTimer = null; });
        if (mounted && _inReadingMode && _isPlaying) {
          _pauseReading(force: true);
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

  Widget _voicePauseButton(String voice, StateSetter update, BuildContext sheet) => IconButton(
    key: ValueKey('pause-voice-$voice'), tooltip: T('voicePauseTitle', {'name': _shortVoiceLabel(voice)}),
    icon: Stack(clipBehavior: Clip.none, children: [
      const Icon(Icons.hourglass_empty),
      if (_settings.hasVoiceSpeechPauses(voice)) Positioned(right: -1, top: -1,
        child: Semantics(label: T('voicePauseCustomized'), child: Container(key: ValueKey('pause-customized-$voice'),
          width: 6, height: 6, decoration: const BoxDecoration(color: Color(0xFF6498B5), shape: BoxShape.circle)))),
    ]), onPressed: () async {
      await _openVoiceSpeechPauses(voice);
      if (sheet.mounted) update(() {});
    });

  /// Voice settings and cache actions stay attached to stable voice IDs.
  Future<void> _openVoiceSelector() async {
    if (_applyingSpeechPauses) return;
    final selected = await showModalBottomSheet<String>(context: context,
      builder: (ctx) => StatefulBuilder(builder: (sheet, update) {
        final voices = sortedEdgeVoices();
        final active = _settings.speechPauseVoice;
        final items = <Widget>[ListTile(
          leading: Icon(active == TtsReader.systemVoice ? Icons.radio_button_checked : Icons.radio_button_off),
          title: Text(T('systemTts')),
          trailing: _voicePauseButton(TtsReader.systemVoice, update, sheet),
          onTap: () => Navigator.pop(ctx, TtsReader.systemVoice)), const Divider()];
        String? lastLang;
        for (final v in voices) {
          if (v.langCode != lastLang) {
            lastLang = v.langCode;
            items.add(Padding(padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
              child: Text(_groupLabel(v.langCode), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                color: Theme.of(sheet).colorScheme.onSurfaceVariant))));
          }
          items.add(ListTile(dense: true,
            leading: Icon(v.id == active ? Icons.radio_button_checked : Icons.radio_button_off,
              color: const Color(0xFF6498B5)), title: Text(_voiceLabel(v.id)),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              _voicePauseButton(v.id, update, sheet),
              IconButton(key: ValueKey('cache-voice-${v.id}'), tooltip: T('cacheBook'),
                icon: const Icon(Icons.download_outlined), onPressed: () => _openBookCache(cacheVoice: v.id)),
            ]), onTap: () => Navigator.pop(ctx, v.id)));
        }
        return SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(padding: const EdgeInsets.all(16), child: Text(T('voiceTitle'),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
          const Divider(height: 1), Flexible(child: ListView(shrinkWrap: true, children: items)),
        ]));
      }));
    if (selected == null || !mounted) return;
    final desired = ReadingSettings.fromJson(_settings.toJson())..voice = selected..systemFallbackActive = false;
    await _applySpeechConfiguration(desired, updateVoice: true, resumeAfter: _inReadingMode);
  }

  /// 全书语音缓存管理：任务控制（开始/暂停/继续/取消）+ 缓存占用 + 清除
  Future<void> _openBookCache({String? cacheVoice}) async {
    if (_applyingSpeechPauses) return;
    final voice = cacheVoice ?? _effectiveVoice;
    if (voice == TtsReader.systemVoice) { _showToast(T('cacheOnlineOnly')); return; }
    // Keep every operation bound to the selected online voice/rate, even if a
    // temporary offline fallback or another settings change occurs later.
    final rate = _settings.speechRate;
    final targetSettings = ReadingSettings.fromJson(_settings.toJson())..voice = voice..systemFallbackActive = false;
    final prepared = _formatSignature(targetSettings) != _textSignature
      ? await ReaderPreparation.prepare(ReaderPreparationRequest(widget.book,
          merge: targetSettings.mergeNonSentenceBreaks, indent: targetSettings.firstLineIndent,
          pauseSettings: targetSettings.effectiveSpeechPauses,
          filter: targetSettings.informationFilter ? targetSettings.informationFilterLevel : 'none',
          autoExtractToc: targetSettings.autoExtractToc)) : null;
    if (!mounted || _leavingReader) return;
    prepared?.attachSourceMaps();
    final cacheBook = prepared?.book ?? _book, fingerprint = prepared?.fingerprint ?? _cacheFingerprint;
    final cacheKey = '${cacheBook.id}/$fingerprint/$voice/${rate.toStringAsFixed(2)}';
    final store = TtsCacheStore(cacheBook.id, voice, rate, textFingerprint: fingerprint);
    final task = activeBookCaches[cacheKey] ??
        (activeBookCaches[cacheKey] = BookCacheTask(
              book: cacheBook,
              bookId: cacheBook.id,
              store: store,
            ));
    // 重进页面/进程重启后任务实例为空：先从磁盘恢复已有缓存，避免"整本缓存为 0"
    if (task.status.state == 'idle') {
      await task.restoreFromDisk();
    }
    if (!mounted) return;
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
                  child: SingleChildScrollView(child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.file_download_outlined,
                              color: Color(0xFF6498B5)),
                          const SizedBox(width: 10),
                          Text(T('cacheBook'),
                              style: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.bold)),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text('${T('voice')}: ${_voiceLabel(voice)} · ${T('rateLabel', {'rate': rate.toStringAsFixed(1)})}',
                        key: const ValueKey('cache-binding'), style: const TextStyle(fontSize: 13)),
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
                      Wrap(
                        alignment: WrapAlignment.end, spacing: 8, runSpacing: 4,
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
                                FilledButton(
                                  onPressed: () =>
                                      task.start(resume: !st.isDone),
                                  child: Text(st.isDone
                                      ? T('cacheRestart')
                                      : T('cacheStart')),
                                ),
                                OutlinedButton(
                                  onPressed: () async {
                                    final ok = await showDialog<bool>(
                                      context: ctx,
                                      builder: (dctx) => AlertDialog(
                                        title: Text(T('cacheClear')),
                                        content: Text('${T('cacheClearSelectedConfirm')}\n${_voiceLabel(voice)} · ${T('rateLabel', {'rate': rate.toStringAsFixed(1)})}'),
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
                                    activeBookCaches.remove(cacheKey);
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
                            if (!st.isDone)
                              TextButton(
                                  onPressed: () =>
                                      _startCacheFromCurrent(task),
                                  child: Text(T('cacheFromHere')),
                              ),
                          ],
                        ],
                      ),
                    ],
                  )),
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
    if (_book.chapters.isEmpty || task.book.chapters.isEmpty) return;
    final c = _chapter.clamp(0, min(_book.chapters.length, task.book.chapters.length) - 1);
    final p = _para.clamp(0, _book.chapters[c].paragraphs.length - 1);
    final paragraph = _book.chapters[c].paragraphs[p];
    final at = _wordStart >= 0 ? _wordStart : _ttsSentence >= 0 && _ttsSentence < paragraph.sentences.length
      ? paragraph.sentences[_ttsSentence].displayStart : 0;
    final anchor = ReadingText.anchor(_book, c, p, at);
    final target = ReadingText.locate(task.book, c, anchor);
    final targetParagraph = task.book.chapters[c].paragraphs[target.$1];
    final sentence = ReadingText.sentenceAt(targetParagraph, target.$2);
    var global = sentence;
    for (var pi = 0; pi < target.$1; pi++) { global += task.book.chapters[c].paragraphs[pi].sentences.length; }
    final offsets = chapterTtsSentenceOffsets(task.book.chapters[c]);
    task.start(resume: false, fromChapter: c, fromOffset: global >= 0 && global < offsets.length ? offsets[global] : 0);
  }

  Widget _buildTapZones({required Widget child}) {
    // 朗读模式点击播放/暂停，滑动切句或翻页；普通阅读保留原操作。
    final inReading = _inReadingMode;
    return ReaderGestures(
        enabled: inReading || _settings.pageTurnMode == 'swipe',
        sentenceSwipesEnabled: inReading,
        sentenceDragDelay: Duration(milliseconds: (_settings.sentenceDragDelay * 1000).round()),
        onSentenceDragStart: inReading ? _startSentenceDrag : null,
        onSentenceDragChange: inReading ? _previewSentenceDrag : null,
        onSentenceDragEnd: inReading ? _finishSentenceDrag : null,
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
                if (mounted && ModalRoute.of(context)?.isCurrent == true) {
                  _restoreSystemUiForExit(); Navigator.of(context).pop();
                }
              }),
            const Spacer(),
            IconButton(tooltip: T('read'), icon: const ReaderIcon(ReaderSymbol.headphones, color: Colors.white70),
              onPressed: _ttsLoading ? null : () => _play(requestNotificationPermission: true)),
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
              onPressed: _currentTocIndex > 0 ? () => _changeChapter(-1) : null,
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
                  {'c': '${_currentTocIndex + 1}', 'total': '${_toc.length}'}),
              style: const TextStyle(fontSize: 11, color: Color(0xFFD6D6D6)),
            ),
            IconButton(
              icon: const ReaderIcon(ReaderSymbol.nextChapter, size: 18, color: Colors.white70),
              visualDensity: VisualDensity.compact,
              key: const ValueKey('next-chapter'),
              onPressed: _currentTocIndex < _toc.length - 1 ? () => _changeChapter(1) : null,
              tooltip: T('nextChapter'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFloatingChapter() => Positioned(
    left: 0, top: MediaQuery.sizeOf(context).height / 2 - 32,
    child: GestureDetector(key: const ValueKey('contents-touch'), behavior: HitTestBehavior.translucent, onTap: _openChapterList,
      child: SizedBox(width: 48, height: 64, child: Align(alignment: Alignment.centerLeft,
        child: Material(key: const ValueKey('contents-handle'), color: const Color(0xDD333333),
          borderRadius: const BorderRadius.horizontal(right: Radius.circular(14)),
          child: Tooltip(message: T('toc'), child: const SizedBox(width: 16, height: 64,
            child: Center(child: ReaderIcon(ReaderSymbol.contents, size: 14, color: Colors.white70)))))))),
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
              child: SafeArea(child: _ChapterSheet(entries: _toc, current: _currentTocIndex)))),
        ),
      ),
    );
    if (selected == -1) { _openBookmarks(); return; }
    if (selected == null) return;
    await _navigateToc(selected);
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

  static String _shortVoiceLabel(String id) => id == TtsReader.systemVoice ? T('shortSystemVoice')
    : _voiceLabel(id).split(RegExp(r'[（(]')).first.trim();

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
        onChanged: (s) {
          final rotationChanged = s.followSystemRotation != _settings.followSystemRotation;
          final tocChanged = s.autoExtractToc != _settings.autoExtractToc;
          AppAppearance.setThemeMode(s.themeMode);
          final current = AppAppearance.applyCurrentMode(s);
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
            _settings = current;
            if (tocChanged && !textChanged) _rebuildToc();
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
          if (voiceChanged) _tts.setVoice(s.voice.isEmpty ? TtsReader.defaultVoice : s.voice);
          if (voiceChanged && _inReadingMode) _startTtsFrom(_chapter, _para, max(0, _ttsSentence));
          // 变速/切音色后缓存坐标（voice/rate 段）变化，重建朗读侧缓存
          _refreshTtsCache();
          _applyReaderBrightness();
          _pageEndKey = null; _schedulePageGeometry();
          widget.storage.saveSettings(_settings.toJson());
          if (rotationChanged) _applyRotationPreference();
          if (tocChanged) _updateMediaChapter(_chapter);
        },
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
  final List<BookTocEntry> entries;
  final int current;
  const _ChapterSheet({required this.entries, required this.current});
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
      Expanded(child: TextButton(key: const ValueKey('contents-tab'), onPressed: () {},
        style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.primary),
        child: Text(T('toc'), style: const TextStyle(fontWeight: FontWeight.bold)))),
      Expanded(child: TextButton(key: const ValueKey('bookmarks-tab'), onPressed: () => Navigator.pop(context, -1),
        style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant), child: Text(T('bookmark')))),
    ]),
    const Divider(height: 1),
    Expanded(child: ListView.builder(
      controller: _controller,
      itemExtent: 56,
      itemCount: widget.entries.length,
      itemBuilder: (context, i) => ListTile(
        key: ValueKey('toc-entry-$i'),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        title: Text(widget.entries[i].title, maxLines: 1, overflow: TextOverflow.ellipsis),
        selected: i == widget.current,
        selectedTileColor: const Color(0x226498B5),
        selectedColor: const Color(0xFF9BC5DD),
        onTap: () => Navigator.pop(context, i),
      ),
    )),
  ]);
}

/// 设置底部弹层
class _IntegerInputDialog extends StatefulWidget {
  final String title;
  final String? help;
  final int value, minimum, maximum;
  final Key inputKey;
  const _IntegerInputDialog({required this.title, this.help, required this.value, required this.minimum,
    required this.maximum, required this.inputKey});
  @override
  State<_IntegerInputDialog> createState() => _IntegerInputDialogState();
}

class _IntegerInputDialogState extends State<_IntegerInputDialog> {
  final _form = GlobalKey<FormState>();
  late final _controller = TextEditingController(text: '${widget.value}');
  @override
  void dispose() { _controller.dispose(); super.dispose(); }
  void _submit() {
    if (_form.currentState!.validate()) Navigator.pop(context, int.parse(_controller.text));
  }
  @override
  Widget build(BuildContext context) => AlertDialog(title: Text(widget.title),
    content: Form(key: _form, child: Column(mainAxisSize: MainAxisSize.min, children: [
      if (widget.help != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(widget.help!)),
      TextFormField(key: widget.inputKey, controller: _controller, autofocus: true,
        keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(helperText: T('numberRange', {'n': '${widget.minimum}', 'total': '${widget.maximum}'})),
        validator: (text) {
          final value = int.tryParse(text ?? '');
          return value == null || value < widget.minimum || value > widget.maximum
            ? T('numberRange', {'n': '${widget.minimum}', 'total': '${widget.maximum}'}) : null;
        }, onFieldSubmitted: (_) => _submit()),
    ])), actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(T('cancel'))),
      FilledButton(onPressed: _submit, child: Text(T('ok')))]);
}

class _SettingsSheet extends StatefulWidget {
  final ReadingSettings settings;
  final ValueChanged<ReadingSettings> onChanged;
  const _SettingsSheet({
    required this.settings,
    required this.onChanged,
  });

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late ReadingSettings _s;

  @override
  void initState() {
    super.initState();
    _s = ReadingSettings.fromJson(widget.settings.toJson());
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
              _group(context, 'settingsAppearance'),
              ListTile(title: Text(T('themeColor')), trailing: DropdownButton<String>(
                key: const ValueKey('theme-mode'), value: _s.themeMode,
                items: ['system', 'dark', 'light'].map((mode) => DropdownMenuItem(value: mode,
                  child: Text(T(mode == 'system' ? 'followSystemTheme' : mode == 'dark' ? 'darkTheme' : 'lightTheme')))).toList(),
                onChanged: (mode) { if (mode != null) setState(() { _s.themeMode = mode; _update(); }); })),
              ListTile(key: const ValueKey('reader-font-family'), title: Text(T('fontReplace')),
                trailing: SizedBox(width: 120, child: Row(children: [Expanded(child: Text(
                  _s.fontFamily.isEmpty ? T('default') : FontManager.familyOf(_s.fontFamily),
                  maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.end)),
                  const Icon(Icons.chevron_right, size: 18)])), onTap: _openFontPicker),
              ListTile(title: Text(T('lineHeight')), subtitle: Slider(key: const ValueKey('reader-line-height'),
                padding: EdgeInsets.zero, value: _s.lineHeight, min: 1.2, max: 2.4, divisions: 12,
                onChanged: (value) => setState(() { _s.lineHeight = value; _update(); }))),
              const Divider(),
              _group(context, 'settingsPageTurning'),
              ListTile(title: const Text('翻页方式'), trailing: DropdownButton<String>(
                key: const ValueKey('page-turn-mode'), value: _s.pageTurnMode,
                items: const [DropdownMenuItem(value: 'tap', child: Text('点击左右侧')),
                  DropdownMenuItem(value: 'swipe', child: Text('左右滑动')),
                  DropdownMenuItem(value: 'scroll', child: Text('上下滚动'))],
                onChanged: (value) { if (value != null) setState(() { _s.pageTurnMode = value; _update(); }); })),
              ListTile(title: Text(T('pageTurnAnimation')), trailing: DropdownButton<String>(
                key: const ValueKey('page-turn-animation'), value: _s.pageTurnAnimation,
                items: ['off', 'slide'].map((value) => DropdownMenuItem(value: value,
                  child: Text(T(value == 'off' ? 'animationOff' : 'animationSlide')))).toList(),
                onChanged: (value) { if (value != null) setState(() { _s.pageTurnAnimation = value; _update(); }); })),
              SwitchListTile(key: const ValueKey('retain-page-line'), title: const Text('翻页后保留首行'),
                subtitle: Text(_s.pageTurnMode == 'scroll' ? '上下滚动时不可用' : '下一页首行重复上一页最后一整行'),
                value: _s.retainPageLine, onChanged: _s.pageTurnMode == 'scroll' ? null : (value) {
                  setState(() { _s.retainPageLine = value; _update(); });
                }),
              const Divider(),
              _group(context, 'settingsScreen'),
              SwitchListTile(key: const ValueKey('follow-system-rotation'), title: Text(T('followSystemRotation')),
                value: _s.followSystemRotation, onChanged: (value) => setState(() { _s.followSystemRotation = value; _update(); })),
              ListTile(title: Text(T('readingScreenAwake')), subtitle: Text(T('screenTimeoutDescription')),
                trailing: DropdownButton<int>(key: const ValueKey('reading-screen-seconds'),
                value: _s.readingScreenSeconds,
                items: [for (final seconds in [0, 60, 120, 300, 600, 1800]) DropdownMenuItem(value: seconds,
                  child: Text(seconds == 0 ? T('systemScreenAwake') : T('minutes', {'m': '${seconds ~/ 60}'})))],
                onChanged: (value) { if (value != null) setState(() { _s.readingScreenSeconds = value; _update(); }); })),
              const Divider(),
              _group(context, 'settingsTextProcessing'),
              SwitchListTile(key: const ValueKey('auto-extract-toc'), title: Text(T('autoExtractToc')),
                value: _s.autoExtractToc, onChanged: (value) => setState(() { _s.autoExtractToc = value; _update(); })),
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
            ],
          ),
        ),
      ),
    );
  }

  Widget _group(BuildContext context, String key) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Align(alignment: Alignment.centerLeft, child: Text(T(key),
      style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary))),
  );

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
  final int itemIndex;
  const _PageLine(this.key, this.top, this.bottom, this.itemIndex);
}

class _ReaderPageClipper extends CustomClipper<Rect> {
  final double? bottom;
  const _ReaderPageClipper(this.bottom);
  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, size.width, (bottom ?? size.height).clamp(0.0, size.height));
  @override
  bool shouldReclip(_ReaderPageClipper oldClipper) => bottom != oldClipper.bottom;
}
