import 'dart:async';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../i18n.dart';
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

class _ReaderScreenState extends State<ReaderScreen> {
  late final TtsReader _tts;
  late final List<_Item> _items;
  final ItemScrollController _itemScrollController = ItemScrollController();
  final ScrollOffsetController _pageScrollController = ScrollOffsetController();
  bool _paging = false;
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

  // 手势操作提示条（开始播放时短暂提示）
  Timer? _gestureTipTimer;
  bool _gestureTipVisible = false;

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

  // 系统媒体音量（音量键正常调节，暂停面板也提供滑条）
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
    _tts = TtsReader();
    _tts.onSentenceChanged = _onTtsSentenceChanged;
    _tts.onCompleted = _onTtsCompleted;
    _tts.onError = _onTtsError;
    _items = _flatten(widget.book);
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
    widget.storage.saveLastBookId(widget.book.id);
    // 读取系统媒体音量用于暂停面板滑条
    _loadMediaVolume();
    // 加载书签与划线
    _loadAnnotations();
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

  // ---------- 书签与划线 ----------

  Future<void> _loadAnnotations() async {
    final store = AnnotationStore();
    final bms = await store.loadBookmarks(widget.book.id);
    final hls = await store.loadHighlights(widget.book.id);
    if (!mounted) return;
    setState(() {
      _bookmarks = bms;
      _highlights = hls;
      _rebuildHlIndex();
    });
  }

  void _rebuildHlIndex() {
    _hlIndex = {};
    for (final h in _highlights) {
      _hlIndex.putIfAbsent(_hlKey(h.chapterIndex, h.paragraphIndex), () => [])
          .add(h);
    }
  }

  /// 写回存储（书签+划线），保持内存与磁盘同步
  Future<void> _persistAnnotations() async {
    final store = AnnotationStore();
    await store.saveBookmarks(widget.book.id, _bookmarks);
    await store.saveHighlights(widget.book.id, _highlights);
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
  bool _hasBookmarkAt(int c, int p, int s) =>
      _bookmarks.any((b) =>
          b.chapterIndex == c && b.paragraphIndex == p && b.sentenceIndex == s);

  Future<void> _addBookmarkAt(_Item it) async {
    if (_hasBookmarkAt(it.chapterIndex, it.paragraphIndex, it.sentenceIndex)) {
      return;
    }
    final para = widget.book.chapters[it.chapterIndex].paragraphs[it.paragraphIndex];
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
        bookId: widget.book.id,
        chapterIndex: it.chapterIndex,
        paragraphIndex: it.paragraphIndex,
        sentenceIndex: it.sentenceIndex,
        chapterTitle: widget.book.chapters[it.chapterIndex].title,
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
        bookId: widget.book.id,
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
    final s = para.sentences[it.sentenceIndex];
    setState(() {
      _highlights.removeWhere((h) =>
          h.chapterIndex == it.chapterIndex &&
          h.paragraphIndex == it.paragraphIndex &&
          h.charEnd > s.displayStart &&
          h.charStart < s.displayEnd);
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

  /// 渲染句子文本：按划线区间切 TextSpan；朗读高亮走 style 层
  Widget _buildSentenceText(
      _Item it, Paragraph para, String sentenceText, bool isCurrent) {
    final base = TextStyle(
      fontSize: _fontSize,
      height: _lineHeight,
      color: _theme.text,
      fontFamily: _fontFamily.isEmpty ? null : _fontFamily,
      backgroundColor: isCurrent ? const Color(0x44FFC107) : null,
      fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal,
    );
    final seg = _hlIndex[_hlKey(it.chapterIndex, it.paragraphIndex)];
    if (seg == null || seg.isEmpty) return Text(sentenceText, style: base);
    if (it.sentenceIndex >= para.sentences.length) {
      return Text(sentenceText, style: base);
    }
    final s = para.sentences[it.sentenceIndex];
    final sStart = s.displayStart;
    final sEnd = s.displayEnd;
    final spans = <TextSpan>[];
    var cursor = 0;
    final len = sentenceText.length;
    for (final h in seg) {
      final cs = max(h.charStart, sStart);
      final ce = min(h.charEnd, sEnd);
      if (ce <= cs) continue;
      final relS = cs - sStart;
      final relE = ce - sStart;
      if (relS > cursor) {
        spans.add(TextSpan(
            text: sentenceText.substring(cursor, min(relS, len))));
      }
      if (relE <= len && relS < len) {
        spans.add(TextSpan(
          text: sentenceText.substring(relS, relE),
          style: TextStyle(backgroundColor: Color(h.color)),
        ));
      }
      cursor = max(relE, cursor);
    }
    if (cursor < len) {
      spans.add(TextSpan(text: sentenceText.substring(cursor)));
    }
    if (spans.isEmpty) return Text(sentenceText, style: base);
    return Text.rich(TextSpan(children: spans), style: base);
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
    });
    _jumpToItem(_itemIndexOf(selected.chapterIndex, selected.paragraphIndex,
        selected.sentenceIndex));
    _scheduleSave();
  }

  Future<void> _openHighlights() async {
    final selected = await showModalBottomSheet<_Item>(
      context: context,
      builder: (ctx) => _HighlightSheet(
        book: widget.book,
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
    });
    _jumpToItem(_itemIndexOf(selected.chapterIndex, selected.paragraphIndex,
        selected.sentenceIndex));
    _scheduleSave();
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

  void _pageUp() => _turnPage(-1);

  void _pageDown() => _turnPage(1);

  Future<void> _turnPage(int direction) async {
    if (_ttsLoading || _paging || _items.isEmpty) return;
    if (!_inReadingMode) {
      final target = (_itemIndexOf(_chapter, _para) + direction * 5).clamp(0, _items.length - 1);
      _jumpToItem(target);
      _updatePositionFromItem(target);
      return;
    }
    if (!_itemScrollController.isAttached) return;
    _paging = true;
    _pendingScrollIndex = null;
    try {
      // Move a viewport, including within sentences taller than the screen.
      final height = MediaQuery.of(context).size.height - _chapterTopArea();
      await _pageScrollController.animateScroll(
        offset: direction * max(1.0, height - _fontSize * _lineHeight),
        duration: const Duration(milliseconds: 180), curve: Curves.easeOut,
      );
      if (!mounted) return;
      final visible = _itemPositionsListener.itemPositions.value
        .where((p) => p.itemTrailingEdge > 0 && p.itemLeadingEdge < 1)
        .toList()
      ..sort((a, b) => a.index.compareTo(b.index));
      if (visible.isEmpty) return;
      var target = visible.first.index;
      while (target < _items.length - 1 && _items[target].isTitle) { target++; }
      _updatePositionFromItem(target);
      _ttsFollowSeek(_chapter, _para, max(0, _ttsSentence));
    } finally {
      _paging = false;
    }
  }

  // Skip chapter headings and empty sentences, including at chapter boundaries.
  void _moveSentence(int direction) {
    if (_ttsLoading || _paging || _items.isEmpty) return;
    var index = _itemIndexOf(_chapter, _para, max(0, _ttsSentence)) + direction;
    while (index >= 0 && index < _items.length) {
      final it = _items[index];
      if (!it.isTitle) {
        final sentences = widget.book.chapters[it.chapterIndex]
            .paragraphs[it.paragraphIndex].sentences;
        if (it.sentenceIndex < sentences.length &&
            sentences[it.sentenceIndex].display.trim().isNotEmpty) {
          _navigateToItem(index);
          return;
        }
      }
      index += direction;
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
    if (_suppressScrollTrack || _paging || _isPlaying) return;
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
    if (c < 0 || c >= widget.book.chapters.length) return out;
    for (final p in widget.book.chapters[c].paragraphs) {
      for (final s in p.sentences) {
        out.add(s.tts);
      }
    }
    return out;
  }

  /// 当前朗读音色（空=默认），与缓存目录的 voice 段保持一致
  String get _effectiveVoice =>
      _settings.voice.isEmpty ? 'zh-CN-XiaoxiaoNeural' : _settings.voice;

  /// 当前书/音色/语速对应的缓存（朗读与全书缓存共用同一坐标）
  TtsCacheStore _currentCacheStore() =>
      TtsCacheStore(widget.book.id, _effectiveVoice, _settings.speechRate);

  /// 按当前书/音色/语速重建朗读侧磁盘缓存（切书/切音色/变速后调用）
  void _refreshTtsCache() {
    _tts.setCache(_currentCacheStore());
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
          SnackBar(content: Text(T('voiceTimeout'))),
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
    _showGestureTip();
    if (vp != null) _compensateViewport(vp.$1, vp.$2, delta);
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
    final vp = _captureViewport();
    final delta = -_chapterBarTop(); // 退出朗读后顶栏偏移恢复
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepMinutes = 0;
    _gestureTipTimer?.cancel();
    _gestureTipTimer = null;
    _gestureTipVisible = false;
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
        statusBarColor: Color(0xFF333333),
        statusBarIconBrightness: Brightness.light,
        systemStatusBarContrastEnforced: false,
        systemNavigationBarColor: Color(0xFF333333),
        systemNavigationBarIconBrightness: Brightness.light,
        systemNavigationBarContrastEnforced: false,
        systemNavigationBarDividerColor: Colors.transparent,
      ));
    }
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
    _refreshTtsCache();
    await _tts.start(
      sentences,
      offsets: chapterTtsSentenceOffsets(widget.book.chapters[c]),
      chapterIndex: c,
      from: from,
    );
  }

  void _onTtsSentenceChanged(int idx) {
    if (!mounted || _paging) return;
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
      if (_itemScrollController.isAttached) {
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
      SnackBar(content: Text(T('speakFail'))),
    );
  }

  // 上一句 / 下一句
  void _prevSentence() => _moveSentence(-1);

  void _nextSentence() => _moveSentence(1);

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
            child: _buildTapZones(child: _buildBody()),
          ),
          // 固定章节标题：位于顶部两行半空白之后，正文滚动时保持不动
          Positioned(
            top: MediaQuery.of(context).viewPadding.top + 12,
            left: 0,
            right: 0,
            child: _buildChapterHeader(),
          ),
          // 三区点击层
          _buildReadingStatus(),
          // 拖动 seek 预览浮层
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
          // 手势操作提示条（开始播放时短暂提示，2.5s 后淡出）
          if (_inReadingMode) _buildGestureTip(),
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
      bottom: MediaQuery.of(context).padding.bottom + 100,
      child: IgnorePointer(child: AnimatedOpacity(
        opacity: _gestureTipVisible ? 1 : 0,
        duration: const Duration(milliseconds: 500),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: const Color(0xEE333333), borderRadius: BorderRadius.circular(8)),
          child: Text(T('volHint'), textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 13)),
        ),
      )),
    );
  }

  Widget _buildReadingStatus() {
    return Positioned(left: 16, right: 16, bottom: MediaQuery.of(context).padding.bottom + 8,
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

  /// 章节标题行距屏幕顶的偏移：恒为 0。
  /// 正文区（空两行半→章节标题→正文）位置固定紧凑，不随顶栏显隐变化；
  /// 顶栏是 Positioned 悬浮覆盖层，悬浮在正文区上方，不占位、不影响正文区。
  double _chapterBarTop() => 0;

  /// Compact header space remains stable when controls appear.
  double _chapterTopArea() => MediaQuery.of(context).viewPadding.top + 20 + _fontSize * _lineHeight;

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
    return ScrollablePositionedList.builder(
      itemScrollController: _itemScrollController,
      scrollOffsetController: _pageScrollController,
      itemPositionsListener: _itemPositionsListener,
      // Only reading mode replaces free scrolling with sentence/page gestures.
      physics: (_inReadingMode || _showControls)
          ? const NeverScrollableScrollPhysics()
          : null,
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
          final para = widget.book.chapters[it.chapterIndex]
              .paragraphs[it.paragraphIndex];
          final isCurrent = _inReadingMode && it.chapterIndex == _chapter &&
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
            child: GestureDetector(
              onLongPress: () => _onSentenceLongPress(it, para),
              child: _buildSentenceText(it, para, sentenceText, isCurrent),
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
          color: Color(0xEE333333),
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 音量调节行（保留暂停面板的音量滑条）
              Row(
                children: [
                  const Icon(Icons.volume_down, color: Color(0xFF9BC5DD), size: 20),
                  Expanded(
                    child: Slider(
                      value: _mediaVolume.clamp(0.0, 1.0),
                      min: 0.0,
                      max: 1.0,
                      activeColor: const Color(0xFF9BC5DD),
                      inactiveColor: const Color(0x44C9A96E),
                      onChanged: _setMediaVolume,
                    ),
                  ),
                  const Icon(Icons.volume_up, color: Color(0xFF9BC5DD), size: 20),
                ],
              ),
              const SizedBox(height: 2),
              // 语速调节行
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline,
                        color: Color(0xFF9BC5DD)),
                    onPressed: () => _adjustRate(-0.1),
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        Text(
                          T('rateLabel', {'rate': rate.toStringAsFixed(1)}),
                          style: const TextStyle(
                              color: Color(0xFF9BC5DD), fontSize: 12),
                        ),
                        Slider(
                          value: rate.clamp(0.5, 3.0),
                          min: 0.5,
                          max: 3.0,
                          divisions: 25,
                          activeColor: const Color(0xFF9BC5DD),
                          inactiveColor: const Color(0x44C9A96E),
                          onChanged: (v) => _setRate(v),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline,
                        color: Color(0xFF9BC5DD)),
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
                        setState(() => _settings.themeIndex = i);
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
    final items = <Widget>[];
    String? lastLang;
    for (final v in voices) {
      if (v.langCode != lastLang) {
        lastLang = v.langCode;
        items.add(Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
          child: Text(
            _groupLabel(v.langCode),
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.black45,
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
    final store = _currentCacheStore();
    final task = activeBookCaches[widget.book.id] ??
        (activeBookCaches[widget.book.id] = BookCacheTask(
              book: widget.book,
              bookId: widget.book.id,
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
                                  : Colors.black45,
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
                        style: const TextStyle(
                            fontSize: 13, color: Colors.black54),
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
                                    activeBookCaches.remove(widget.book.id);
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
    if (_ttsChapter >= 0 && _ttsChapter < widget.book.chapters.length) {
      final offs =
          chapterTtsSentenceOffsets(widget.book.chapters[_ttsChapter]);
      // _ttsSentence 是段内句子序号，累加段前句子数得到章内全局序号
      var global = _ttsSentence;
      for (var pi = 0; pi < _para; pi++) {
        global += widget.book.chapters[_ttsChapter]
            .paragraphs[pi]
            .sentences
            .length;
      }
      if (global >= 0 && global < offs.length) {
        fromChapter = _ttsChapter;
        fromOffset = offs[global];
      }
    }
    fromChapter ??= _chapter.clamp(0, widget.book.chapters.length - 1);
    fromOffset ??= 0;
    task.start(resume: false, fromChapter: fromChapter, fromOffset: fromOffset);
  }

  Widget _buildTapZones({required Widget child}) {
    // 朗读模式点击播放/暂停，滑动切句或翻页；普通阅读保留原操作。
    final inReading = _inReadingMode;
    return ReaderGestures(
        enabled: inReading,
        onPreviousSentence: _prevSentence,
        onNextSentence: _nextSentence,
        onPreviousPage: _pageUp,
        onNextPage: _pageDown,
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
        child: child,
    );
  }

  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xF2333333),
          border: Border(
            bottom: BorderSide(color: Color(0x33777777), width: 1.5),
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
              tooltip: T('read'),
              onPressed: _ttsLoading ? null : _play,
            ),
            IconButton(
              icon: const Icon(Icons.checkroom, color: Colors.white),
              tooltip: T('pageTheme'),
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
                  case 'bookmarks':
                    _openBookmarks();
                    break;
                  case 'highlights':
                    _openHighlights();
                    break;
                  case 'cachebook':
                    _openBookCache();
                    break;
                }
              },
              itemBuilder: (ctx) => [
                PopupMenuItem(value: 'brightness', child: Text(T('brightness'))),
                PopupMenuItem(value: 'fontsize', child: Text(T('fontSize'))),
                PopupMenuItem(value: 'lineheight', child: Text(T('lineHeight'))),
                PopupMenuItem(value: 'rate', child: Text(T('speed'))),
                PopupMenuItem(value: 'voice', child: Text(T('voice'))),
                PopupMenuItem(value: 'search', child: Text(T('searchTitle'))),
                PopupMenuItem(value: 'bookmarks', child: Text(T('bookmark'))),
                PopupMenuItem(value: 'highlights', child: Text(T('highlight'))),
                PopupMenuItem(value: 'cachebook', child: Text(T('cacheBook'))),
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
          color: Color(0xF2333333),
          border: Border(
            top: BorderSide(color: Color(0x33777777), width: 1.5),
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
              tooltip: T('prev'),
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
                  {'c': '${_chapter + 1}', 'total': '${widget.book.chapters.length}'}),
              style: const TextStyle(fontSize: 11, color: Color(0xFFD6D6D6)),
            ),
            IconButton(
              icon: const Icon(Icons.skip_next,
                  size: 18, color: Colors.white),
              visualDensity: VisualDensity.compact,
              onPressed: _isPlaying ? _nextSentence : null,
              tooltip: T('next'),
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
        backgroundColor: const Color(0xDD333333),
        foregroundColor: Colors.white,
        onPressed: _openChapterList,
        child: const Icon(Icons.menu_book, size: 20),
      ),
    );
  }

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
              child: SafeArea(child: _ChapterSheet(book: widget.book, current: _chapter)))),
        ),
      ),
    );
    if (selected == -1) { _openBookmarks(); return; }
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
  /// 音色显示名：中文界面显示中文友好名，其他界面显示英文名
  static String _voiceLabel(String id) {
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

  void _openSettingsPanel(String kind) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => _SettingsSheet(
        settings: _settings,
        onChanged: (s) {
          setState(() => _settings = s);
          _tts.setSpeechRate(s.speechRate);
          if (s.voice.isNotEmpty) _tts.setVoice(s.voice);
          // 变速/切音色后缓存坐标（voice/rate 段）变化，重建朗读侧缓存
          _refreshTtsCache();
          widget.storage.saveSettings(s.toJson());
        },
        onVoiceLoad: () async => sortedEdgeVoices()
            .map((v) => {'id': v.id, 'name': _voiceLabel(v.id)})
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
              // 亮度
              _row(T('brightness'), Icons.brightness_6, Slider(
                value: _s.brightness,
                min: 0.3,
                max: 1.0,
                onChanged: (v) => setState(() {
                  _s.brightness = v;
                  _update();
                }),
              )),
              // 字体大小
              _row(T('fontSize'), Icons.text_fields, Slider(
                value: _s.fontSize,
                min: 14,
                max: 32,
                divisions: 18,
                onChanged: (v) => setState(() {
                  _s.fontSize = v;
                  _update();
                }),
              )),
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
                  Text(T('voice')),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _voicesLoaded && _voices.isNotEmpty
                        ? DropdownButton<String>(
                            value: _s.voice.isEmpty ? null : _s.voice,
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
