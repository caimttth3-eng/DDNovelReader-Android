// 来源：NayGnehz/DDNovelReader-Android 的 PR #2（commit 27b6a1e，部分代码，已修改适配本项目的缓存/同步架构）。
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/progress.dart';
import 'speech_breaks.dart';

/// 本地持久化：
///  - 书架书籍列表（BookMeta）
///  - 每本书的阅读进度（BookProgress）
///  - 阅读页设置（亮度/字号/行距/语速/音源）
class AppStorage {
  static const _booksKey = 'duoduo.books.v1';
  static const _bookSpeechKey = 'duoduo.bookSpeech.v1';
  static const _progressPrefix = 'duoduo.progress.';
  static const _settingsKey = 'duoduo.settings.v1';
  static const _lastBookKey = 'duoduo.lastBookId';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _sp async {
    return _prefs ??= await SharedPreferences.getInstance();
  }

  // ---------- 书籍列表 ----------
  Future<List<BookMeta>> loadBooks() async {
    final sp = await _sp;
    final raw = sp.getString(_booksKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      final books = list
          .map((e) => BookMeta.fromJson(e as Map<String, dynamic>))
          .toList();
      return await _repairBookPaths(books);
    } catch (_) {
      return [];
    }
  }

  /// 修复书籍文件路径：iOS 重装后容器 UUID 会变，历史记录里是旧绝对路径；
  /// 另外早期导入存的是系统选择器临时路径。这里按「bookId + 扩展名」或
  /// 文件名回落到当前 Documents/books 下，并写回书架。
  Future<List<BookMeta>> _repairBookPaths(List<BookMeta> books) async {
    if (books.isEmpty) return books;
    Directory? booksDir;
    try {
      final dir = await getApplicationDocumentsDirectory();
      booksDir = Directory('${dir.path}/books');
    } catch (_) {
      return books;
    }
    var changed = false;
    final out = <BookMeta>[];
    for (final b in books) {
      var path = b.filePath;
      bool exists(String p) {
        try {
          return p.isNotEmpty && File(p).existsSync();
        } catch (_) {
          return false;
        }
      }

      if (!exists(path)) {
        final ext = switch (b.format) {
          'epub' => '.epub',
          'pdf' => '.pdf',
          'docx' => '.docx',
          _ => '.txt',
        };
        final base = path.split(RegExp(r'[/\\]')).last;
        final candidates = <String>[
          '${booksDir.path}/${b.id}$ext',
          if (base.isNotEmpty) '${booksDir.path}/$base',
        ];
        for (final c in candidates) {
          if (exists(c)) {
            path = c;
            break;
          }
        }
      }
      if (path != b.filePath) {
        changed = true;
        out.add(b.copyWith(filePath: path));
      } else {
        out.add(b);
      }
    }
    if (changed) await saveBooks(out);
    return out;
  }

  /// 按书记忆音色/语速（v1.3.1）。
  Future<Map<String, dynamic>?> loadBookSpeech(String bookId) async {
    final sp = await _sp;
    final raw = sp.getString(_bookSpeechKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final item = map[bookId];
      return item is Map ? item.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveBookSpeech(String bookId,
      {String? voice, double? rate}) async {
    final sp = await _sp;
    Map<String, dynamic> map = {};
    try {
      final raw = sp.getString(_bookSpeechKey);
      if (raw != null && raw.isNotEmpty) {
        map = (jsonDecode(raw) as Map).cast<String, dynamic>();
      }
    } catch (_) {}
    final item = (map[bookId] as Map?)?.cast<String, dynamic>() ?? {};
    if (voice != null) item['voice'] = voice;
    if (rate != null) item['rate'] = rate;
    map[bookId] = item;
    // 只保留最近 200 本，避免无限增长。
    if (map.length > 200) {
      final keys = map.keys.take(map.length - 200).toList();
      for (final k in keys) {
        map.remove(k);
      }
    }
    await sp.setString(_bookSpeechKey, jsonEncode(map));
  }

  Future<void> saveBooks(List<BookMeta> books) async {
    final sp = await _sp;
    final data = books.map((b) => b.toJson()).toList();
    await sp.setString(_booksKey, jsonEncode(data));
  }

  Future<void> addBook(BookMeta meta) async {
    final books = await loadBooks();
    // 去重：同一文件路径不重复添加
    if (books.any((b) => b.filePath == meta.filePath)) return;
    books.add(meta);
    await saveBooks(books);
    // 重新导入同一本书 = 撤销它的删除墓碑，否则同步会把它再删一次
    if (meta.contentKey.trim().isNotEmpty) {
      await clearDeletion(meta.contentKey.trim());
    }
  }

  /// 从书架删除一本书，并留下删除墓碑（WebDAV 同步用它把删除传到其它设备）。
  /// [deletedAt] 不传取当前时间；应用远端删除时必须传远端时间，
  /// 否则本机时间会把对端的删除事件"变新"，导致两端反复拉锯。
  Future<void> removeBook(String bookId, {double? deletedAt}) async {
    final books = await loadBooks();
    String key = '';
    String title = '';
    for (final b in books) {
      if (b.id == bookId) {
        key = b.contentKey.trim();
        title = b.title;
        break;
      }
    }
    books.removeWhere((b) => b.id == bookId);
    await saveBooks(books);
    final sp = await _sp;
    await sp.remove(_progressPrefix + bookId);
    if (key.isNotEmpty) {
      await markDeleted(key, title, deletedAt: deletedAt, idKey: bookId);
    } else {
      // 老书还没回填 ck2：上传时用 book id 兜底，删除也必须用同一个 key
      await markDeleted(bookId, title, deletedAt: deletedAt);
    }
  }

  // ---------- 删除墓碑 ----------
  static const _deletionsKey = 'duoduo.deletions.v1';

  /// {content_key: {"deleted_at": 秒, "title": 书名}}
  Future<Map<String, dynamic>> loadDeletions() async {
    final sp = await _sp;
    final raw = sp.getString(_deletionsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final m = jsonDecode(raw);
      if (m is Map) return m.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {}
    return {};
  }

  Future<void> saveDeletions(Map<String, dynamic> deletions) async {
    final sp = await _sp;
    await sp.setString(_deletionsKey, jsonEncode(deletions));
  }

  Future<void> markDeleted(String contentKey, String title,
      {double? deletedAt, String? idKey}) async {
    final key = contentKey.trim();
    if (key.isEmpty) return;
    final deletions = await loadDeletions();
    final t = deletedAt ?? DateTime.now().millisecondsSinceEpoch / 1000.0;
    final old = deletions[key];
    final oldT = old is Map ? (old['deleted_at'] as num?)?.toDouble() ?? 0.0 : 0.0;
    // 只保留最新一次删除事件
    if (t >= oldT) {
      deletions[key] = {
        'deleted_at': t,
        'title': title,
        if (idKey != null && idKey.trim().isNotEmpty) 'id_key': idKey.trim(),
      };
      await saveDeletions(deletions);
    }
  }

  Future<void> clearDeletion(String contentKey) async {
    final key = contentKey.trim();
    if (key.isEmpty) return;
    final deletions = await loadDeletions();
    if (deletions.remove(key) != null) await saveDeletions(deletions);
  }

  // ---------- 进度 ----------
  Future<BookProgress?> loadProgress(String bookId) async {
    final sp = await _sp;
    final raw = sp.getString(_progressPrefix + bookId);
    if (raw == null || raw.isEmpty) return null;
    try {
      return BookProgress.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveProgress(BookProgress p) async {
    final sp = await _sp;
    await sp.setString(_progressPrefix + p.bookId, jsonEncode(p.toJson()));
  }

  // ---------- 阅读设置 ----------
  Map<String, dynamic> _settings = {};

  Future<Map<String, dynamic>> loadSettings() async {
    final sp = await _sp;
    final raw = sp.getString(_settingsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        _settings = jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {}
    }
    return _settings;
  }

  /// 合并写入：阅读设置与同步配置共用同一份 map，
  /// 任何一方保存时都不能把另一方的 key 冲掉（重启丢同步配置的根因）。
  Future<void> saveSettings(Map<String, dynamic> s) async {
    final sp = await _sp;
    var current = _settings;
    final raw = sp.getString(_settingsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        current = (jsonDecode(raw) as Map).cast<String, dynamic>();
      } catch (_) {}
    }
    _settings = {...current, ...s};
    await sp.setString(_settingsKey, jsonEncode(_settings));
  }

  // ---------- 书架打开顺序（最近打开的排最前） ----------
  static const _openOrderKey = 'duoduo.openOrder.v1';

  Future<List<String>> loadOpenOrder() async {
    final sp = await _sp;
    return sp.getStringList(_openOrderKey) ?? const [];
  }

  Future<void> touchOpened(String bookId) async {
    final sp = await _sp;
    final order = <String>[...(sp.getStringList(_openOrderKey) ?? const <String>[])];
    order.remove(bookId);
    order.insert(0, bookId);
    if (order.length > 200) order.removeRange(200, order.length);
    await sp.setStringList(_openOrderKey, order);
  }

  // ---------- 最后阅读的书籍（启动时自动恢复） ----------
  Future<String?> loadLastBookId() async {
    final sp = await _sp;
    return sp.getString(_lastBookKey);
  }

  Future<void> saveLastBookId(String bookId) async {
    final sp = await _sp;
    await sp.setString(_lastBookKey, bookId);
  }
}

/// 阅读偏好（含默认值）
class ReadingSettings {
  static const speechRateStep = 0.02;
  static const speechRateDivisions = 125;
  static double normalizeSpeechRate(double rate, [double max = 3.0]) =>
      (rate.clamp(0.5, max) * 50).round() / 50;
  static const defaultPrefetchSentences = 8;
  static const minPrefetchSentences = 0;
  static const maxPrefetchSentences = 100;
  double brightness = 0.25;
  bool automaticBrightness = true;
  int autoPageSeconds = 20;
  String pageTurnMode = 'scroll';
  String pageTurnAnimation = 'off';
  bool followSystemRotation = false;
  double sentenceDragDelay = 0.2;
  int keepScreenMinutes = 0;
  int readingScreenSeconds = 0;
  SpeechPauseSettings speechPauses = const SpeechPauseSettings();
  final Map<String, SpeechPauseSettings> perVoiceSpeechPauses = {};
  bool retainPageLine = false;
  bool mergeNonSentenceBreaks = true;
  bool firstLineIndent = true;
  bool autoExtractToc = true;
  bool wordHighlightEnabled = false;
  bool showSystemMediaText = false;
  bool informationFilter = true;
  String informationFilterLevel = 'links';
  double fontSize = 20.0;
  double lineHeight = 1.6;
  double speechRate = 1.0; // edge-tts 语速倍数：1.0=正常, 0.5=慢速, 2.0=快速
  int prefetchSentences = defaultPrefetchSentences;
  bool systemFallbackActive = false;
  String voice = '';
  String themeMode = 'system';
  int themeIndex = 0; // 书页背景主题索引
  int dayThemeIndex = 0;
  String fontFamily = ''; // 用户自选字体 family 名，空=系统默认

  // Keep stable voice IDs rather than translated/display names. An unset
  // online selection is the same Xiaoxiao voice used by the reader.
  static const defaultPauseVoice = 'zh-CN-XiaoxiaoNeural';
  static const systemPauseVoice = '__system_tts__';
  static String _pauseVoiceKey(String value) =>
    value.trim().isEmpty ? defaultPauseVoice : value.trim();
  String get speechPauseVoice => systemFallbackActive ? systemPauseVoice : _pauseVoiceKey(voice);
  SpeechPauseSettings get effectiveSpeechPauses => speechPausesForVoice(speechPauseVoice);
  SpeechPauseSettings speechPausesForVoice(String voiceId) =>
    _pauseVoiceKey(voiceId) == systemPauseVoice
      ? perVoiceSpeechPauses[systemPauseVoice] ?? speechPauses
      : const SpeechPauseSettings();
  bool hasVoiceSpeechPauses(String voiceId) => _pauseVoiceKey(voiceId) == systemPauseVoice &&
    perVoiceSpeechPauses.containsKey(systemPauseVoice);
  void setVoiceSpeechPauses(String voiceId, SpeechPauseSettings pauses) =>
    perVoiceSpeechPauses[_pauseVoiceKey(voiceId)] = pauses;
  void clearVoiceSpeechPauses(String voiceId) => perVoiceSpeechPauses.remove(_pauseVoiceKey(voiceId));

  // Legacy global and online overrides remain serialized for compatibility.
  // Only the system voice may consume customized pauses. Its explicit profile
  // wins over the older, pre-profile setting so upgrades never discard it.

  Map<String, dynamic> toJson() => {
        'brightness': brightness,
        'brightnessControlVersion': 2,
        'automaticBrightness': automaticBrightness,
        'autoPageSeconds': autoPageSeconds,
        'pageTurnMode': pageTurnMode,
        'pageTurnAnimation': pageTurnAnimation,
        'followSystemRotation': followSystemRotation,
        'sentenceDragDelay': sentenceDragDelay,
        'keepScreenMinutes': keepScreenMinutes,
        'readingScreenSeconds': readingScreenSeconds,
        'speechPauses': speechPauses.toJson(),
        'perVoiceSpeechPauses': {for (final entry in perVoiceSpeechPauses.entries) entry.key: entry.value.toJson()},
        'retainPageLine': retainPageLine,
        'textCorrection': mergeNonSentenceBreaks,
        'firstLineIndent': firstLineIndent,
        'autoExtractToc': autoExtractToc,
        'wordHighlightEnabled': wordHighlightEnabled,
        'showSystemMediaText': showSystemMediaText,
        'informationFilter': informationFilter,
        'informationFilterLevel': informationFilterLevel,
        'fontSize': fontSize,
        'lineHeight': lineHeight,
        'speechRate': speechRate,
        'prefetchSentences': prefetchSentences,
        'systemFallbackActive': systemFallbackActive,
        'voice': voice,
        'themeMode': themeMode,
        'themeIndex': themeIndex,
        'dayThemeIndex': dayThemeIndex,
        'fontFamily': fontFamily,
      };

  static ReadingSettings fromJson(Map<String, dynamic>? json) {
    final s = ReadingSettings();
    if (json == null) return s;
    // Old versions defaulted to full brightness. Migrate them to system control.
    if (json['brightnessControlVersion'] == 2) {
      s.brightness = ((json['brightness'] as num?)?.toDouble() ?? 0.25).clamp(0, 1);
      s.automaticBrightness = json['automaticBrightness'] as bool? ?? true;
    }
    s.autoPageSeconds = ((json['autoPageSeconds'] as num?)?.toInt() ?? 20).clamp(1, 120);
    final mode = json['pageTurnMode'];
    s.pageTurnAnimation = json['pageTurnAnimation'] == 'slide' ? 'slide' : 'off';
    s.followSystemRotation = json['followSystemRotation'] as bool? ?? false;
    s.sentenceDragDelay = ((((json['sentenceDragDelay'] as num?)?.toDouble() ?? 0.2).clamp(0, 0.5) * 10).round() / 10);
    s.keepScreenMinutes = ((json['keepScreenMinutes'] as num?)?.toInt() ?? 0).clamp(0, 120);
    final readingSeconds = (json['readingScreenSeconds'] as num?)?.toInt();
    s.readingScreenSeconds = [0, 60, 120, 300, 600, 1800].contains(readingSeconds) ? readingSeconds! : 0;
    s.speechPauses = SpeechPauseSettings.fromJson(json['speechPauses']);
    final voicePauses = json['perVoiceSpeechPauses'];
    if (voicePauses is Map) {
      for (final entry in voicePauses.entries) {
        final value = entry.value;
        if (entry.key is! String || value is! Map || (value['version'] != null && value['version'] != 1)) continue;
        if (!SpeechPauseKind.values.any((kind) => value[kind.name] is num && (value[kind.name] as num).isFinite)) continue;
        s.setVoiceSpeechPauses(entry.key as String, SpeechPauseSettings.fromJson(value));
      }
    }
    s.pageTurnMode = ['tap', 'swipe', 'scroll'].contains(mode) ? mode as String : 'scroll';
    s.retainPageLine = json['retainPageLine'] as bool? ?? false;
    s.mergeNonSentenceBreaks = json['textCorrection'] as bool? ?? json['mergeNonSentenceBreaks'] as bool? ?? true;
    s.firstLineIndent = json['firstLineIndent'] as bool? ?? true;
    s.autoExtractToc = json['autoExtractToc'] is bool ? json['autoExtractToc'] as bool : true;
    s.wordHighlightEnabled = json['wordHighlightEnabled'] is bool ? json['wordHighlightEnabled'] as bool : false;
    s.showSystemMediaText = json['showSystemMediaText'] is bool ? json['showSystemMediaText'] as bool : false;
    final level = json['informationFilterLevel'];
    // Older releases persisted false+none for their default. Once migrated,
    // turning filtering off stores false+links and remains an explicit choice.
    final legacyDefault = json['informationFilter'] == false && (level == null || level == 'none');
    s.informationFilter = legacyDefault || (json['informationFilter'] as bool? ?? true);
    s.informationFilterLevel = ['links', 'ads', 'extra'].contains(level) ? level as String : 'links';
    s.fontSize = ((json['fontSize'] as num?)?.toDouble() ?? s.fontSize).clamp(14, 64);
    s.lineHeight = (json['lineHeight'] as num?)?.toDouble() ?? s.lineHeight;
    s.speechRate = normalizeSpeechRate((json['speechRate'] as num?)?.toDouble() ?? s.speechRate);
    s.prefetchSentences = ((json['prefetchSentences'] as num?)?.toInt() ?? defaultPrefetchSentences)
      .clamp(minPrefetchSentences, maxPrefetchSentences);
    s.voice = json['voice'] as String? ?? '';
    s.systemFallbackActive = json['systemFallbackActive'] as bool? ?? false;
    final themeMode = json['themeMode'];
    s.themeMode = ['system', 'dark', 'light'].contains(themeMode) ? themeMode as String : 'system';
    s.themeIndex = (json['themeIndex'] as num?)?.toInt() ?? 0;
    s.dayThemeIndex = (json['dayThemeIndex'] as num?)?.toInt() ?? 0;
    s.fontFamily = json['fontFamily'] as String? ?? '';
    return s;
  }
}
