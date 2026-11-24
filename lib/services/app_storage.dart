// 来源：NayGnehz/DDNovelReader-Android 的 PR #2（commit 27b6a1e，部分代码，已修改适配本项目的缓存/同步架构）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/progress.dart';
import 'annotation_store.dart';
import 'speech_breaks.dart';
import 'system_tts.dart';

enum BookStorageChangeKind { progress, removed, annotations }

@immutable
class BookStorageChange {
  final String bookId;
  final BookStorageChangeKind kind;
  final BookProgress? progress;
  final bool remote;

  const BookStorageChange({required this.bookId, required this.kind,
    this.progress, this.remote = false});
}

/// 本地持久化：
///  - 书架书籍列表（BookMeta）
///  - 每本书的阅读进度（BookProgress）
///  - 阅读页设置（亮度/字号/行距/语速/音源）
class AppStorage {
  static final _changes = StreamController<BookStorageChange>.broadcast(sync: true);
  static Stream<BookStorageChange> get bookChanges => _changes.stream;
  static void publishBookChange(BookStorageChange change) => _changes.add(change);

  static Future<void>? _bookWrites;
  static Future<void>? _settingsWrites;

  // One shelf transaction also fences progress writes through old duplicate IDs.
  Future<T> _bookWrite<T>(Future<T> Function() action) {
    final result = (_bookWrites ?? Future<void>.value()).then((_) => action());
    late final Future<void> settled;
    void clear() { if (identical(_bookWrites, settled)) _bookWrites = null; }
    settled = result.then<void>((_) => clear(), onError: (Object _, StackTrace __) => clear());
    _bookWrites = settled;
    return result;
  }
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
  Future<List<BookMeta>> loadBooks() => _loadBooks(repairPaths: true);

  /// Exact persisted metadata for previews; never repairs or saves iOS paths.
  Future<List<BookMeta>> loadBooksSnapshot() => _loadBooks(repairPaths: false);

  Future<List<BookMeta>> _loadBooks({required bool repairPaths}) async {
    final sp = await _sp;
    final raw = sp.getString(_booksKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      final books = list
          .map((e) => BookMeta.fromJson(e as Map<String, dynamic>))
          .toList();
      return repairPaths ? await _repairBookPaths(books) : books;
    } catch (_) {
      return [];
    }
  }

  /// 修复书籍文件路径：iOS 重装后容器 UUID 会变，历史记录里是旧绝对路径；
  /// 另外早期导入存的是系统选择器临时路径。这里按「bookId + 扩展名」或
  /// 文件名回落到当前 Documents/books 下，并写回书架。
  Future<List<BookMeta>> _repairBookPaths(List<BookMeta> books) async {
    if (books.isEmpty || !Platform.isIOS) return books;
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
    if (changed) await _saveBooks(out);
    return out;
  }

  /// 按书记忆音色/语速（v1.3.1）。
  Future<Map<String, dynamic>?> loadBookSpeech(String bookId) async {
    await _speechWrites;
    final sp = await _sp;
    final raw = sp.getString(_bookSpeechKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final item = map[bookId];
      return item is Map ? item.cast<String, dynamic>() : null;
    } catch (error) {
      debugPrint('Loading book speech preferences failed: $error');
      return null;
    }
  }

  static Future<void>? _speechWrites;

  Future<void> saveBookSpeech(String bookId, {String? voice, double? rate}) {
    final write = (_speechWrites ?? Future<void>.value()).then((_) => _saveBookSpeech(bookId, voice: voice, rate: rate));
    final settled = write.then<void>((_) {}, onError: (Object error, StackTrace stack) {
      debugPrint('Saving book speech preferences failed: $error');
    });
    _speechWrites = settled;
    unawaited(settled.then((_) {
      if (identical(_speechWrites, settled)) _speechWrites = null;
    }));
    return write;
  }

  Future<void> _saveBookSpeech(String bookId, {String? voice, double? rate}) async {
    final sp = await _sp;
    Map<String, dynamic> map = {};
    try {
      final raw = sp.getString(_bookSpeechKey);
      if (raw != null && raw.isNotEmpty) {
        map = (jsonDecode(raw) as Map).cast<String, dynamic>();
      }
    } catch (error) {
      debugPrint('Reading saved book speech preferences failed: $error');
    }
    final item = (map[bookId] as Map?)?.cast<String, dynamic>() ?? {};
    if (voice != null) item['voice'] = voice;
    if (rate != null) item['rate'] = rate;
    map.remove(bookId);
    map[bookId] = item;
    // 只保留最近 200 本，避免无限增长。
    if (map.length > 200) {
      final keys = map.keys.take(map.length - 200).toList();
      for (final k in keys) {
        map.remove(k);
      }
    }
    if (!await sp.setString(_bookSpeechKey, jsonEncode(map))) {
      throw StateError('Book speech preferences could not be saved.');
    }
  }

  Future<ReadingSettings> loadReadingSettings(String bookId) async {
    final settings = ReadingSettings.fromJson(await loadSettings());
    final saved = await loadBookSpeech(bookId);
    if (saved?['voice'] case final String voice) {
      final selected = voice.isEmpty ? ReadingSettings.defaultPauseVoice : voice;
      final previous = settings.voice.isEmpty ? ReadingSettings.defaultPauseVoice : settings.voice;
      if (selected != previous || SystemTtsClient.isSystemVoiceId(selected)) settings.systemFallbackActive = false;
      settings.voice = selected;
    }
    if (saved?['rate'] case final num rate when rate.isFinite) settings.speechRate = rate.toDouble();
    settings.speechRate = ReadingSettings.normalizeSpeechRate(settings.speechRate,
      ReadingSettings.maxSpeechRateFor(settings.speechPauseVoice));
    return settings;
  }

  Future<void> _saveBooks(List<BookMeta> books) async {
    final sp = await _sp;
    final data = books.map((b) => b.toJson()).toList();
    if (!await sp.setString(_booksKey, jsonEncode(data))) throw StateError('Books could not be saved.');
  }

  /// Metadata backfill/deserialization does not manufacture user activity.
  Future<void> saveBooks(List<BookMeta> books) {
    final snapshot = List<BookMeta>.of(books);
    return _bookWrite(() => _saveBooks(snapshot));
  }

  Future<String> resolveBookId(String bookId) async {
    for (final book in await loadBooks()) {
      if (book.id == bookId || book.aliases.contains(bookId)) return book.id;
    }
    return bookId;
  }

  Future<void> addBook(BookMeta meta, {bool remote = false, double? activityAt,
      double? remoteVersion}) => _bookWrite(() async {
    final books = await loadBooks();
    final key = meta.contentKey.trim().isEmpty ? meta.id : meta.contentKey.trim();
    var activity = activityAt ?? (remote ? meta.activityAt : DateTime.now().millisecondsSinceEpoch / 1000.0);
    final deletions = await loadDeletions();
    final tomb = deletions[key];
    final deletedAt = tomb is Map ? (tomb['deleted_at'] as num?)?.toDouble() ?? 0.0 : 0.0;
    if (remote && deletedAt >= (remoteVersion ?? activity) && deletedAt > 0) return;
    if (!remote && activity <= deletedAt) activity = deletedAt + 0.001;
    if (!remote) {
      for (final book in books) {
        if ((book.id == meta.id || key == book.contentKey.trim()) && book.activityAt >= activity) {
          activity = book.activityAt + 0.001;
        }
      }
    }
    final index = books.indexWhere((book) => book.id == meta.id || book.filePath == meta.filePath && meta.filePath.isNotEmpty);
    if (index < 0) {
      books.add(meta.copyWith(activityAt: activity));
    } else {
      final old = books[index];
      books[index] = old.copyWith(
        title: meta.title,
        contentKey: meta.contentKey.isEmpty ? old.contentKey : meta.contentKey,
        totalChars: meta.totalChars == 0 ? old.totalChars : meta.totalChars,
        chapterCount: meta.chapterCount == 0 ? old.chapterCount : meta.chapterCount,
        activityAt: activity > old.activityAt ? activity : old.activityAt,
        aliases: {...old.aliases, ...meta.aliases, if (meta.id != old.id) meta.id}.toList(),
        sourcePaths: {...old.sourcePaths, ...meta.sourcePaths, meta.filePath}.where((p) => p.isNotEmpty).toList());
    }
    await _consolidateBooks(books);
    if ((!remote || (remoteVersion ?? activity) > deletedAt) && deletions.remove(key) != null) {
      await _saveDeletions(deletions);
    }
  });

  Future<void> consolidateBooks() => _bookWrite(() async => _consolidateBooks(await loadBooks()));

  Future<bool> applyBookActivity(String bookId, double activityAt) => _bookWrite(() async {
    if (!activityAt.isFinite || activityAt <= 0) return false;
    final id = await resolveBookId(bookId);
    final books = await loadBooks();
    final index = books.indexWhere((book) => book.id == id);
    if (index < 0 || books[index].activityAt >= activityAt) return false;
    books[index] = books[index].copyWith(activityAt: activityAt);
    await _saveBooks(books);
    return true;
  });

  Future<void> _consolidateBooks(List<BookMeta> books) async {
    final groups = <String, List<BookMeta>>{};
    for (final book in books) {
      final key = book.contentKey.trim().isEmpty ? 'id:${book.id}' : 'ck:${book.contentKey.trim()}';
      groups.putIfAbsent(key, () => []).add(book);
    }
    final out = <BookMeta>[];
    final redirects = <String, String>{};
    final consolidatedChanges = <BookStorageChange>[];
    final sp = await _sp;
    for (final group in groups.values) {
      var survivor = group.first;
      final ids = {for (final book in group) ...[book.id, ...book.aliases]};
      for (final id in ids) { redirects[id] = survivor.id; }
      if (group.length > 1) {
        BookProgress? newest;
        final previousProgress = <String, BookProgress?>{};
        var activity = survivor.activityAt;
        var source = survivor;
        var totalChars = survivor.totalChars;
        var chapterCount = survivor.chapterCount;
        bool exists(String path) { try { return path.isNotEmpty && File(path).existsSync(); } catch (_) { return false; } }
        for (final book in group) {
          if (book.activityAt > activity) activity = book.activityAt;
          if (!exists(source.filePath) && exists(book.filePath)) source = book;
          if (book.totalChars > totalChars) totalChars = book.totalChars;
          if (book.chapterCount > chapterCount) chapterCount = book.chapterCount;
        }
        for (final id in ids) {
          final progress = await _loadProgress(id);
          previousProgress[id] = progress;
          if (progress != null && (newest == null || progress.updatedAt > newest.updatedAt)) newest = progress;
        }
        final annotationsChanged = await AnnotationStore().mergeBooks(survivor.id, ids, notify: false);
        if (newest != null && !await sp.setString(_progressPrefix + survivor.id,
            jsonEncode(newest.copyWith(bookId: survivor.id).toJson()))) {
          throw StateError('Merged progress could not be saved.');
        }
        for (final id in ids) {
          if (annotationsChanged) {
            consolidatedChanges.add(BookStorageChange(bookId: id,
                kind: BookStorageChangeKind.annotations, remote: true));
          }
          if (newest != null && (previousProgress[id] == null ||
              previousProgress[id]!.updatedAt < newest.updatedAt)) {
            consolidatedChanges.add(BookStorageChange(bookId: id,
                kind: BookStorageChangeKind.progress,
                progress: newest.copyWith(bookId: id), remote: true));
          }
        }
        survivor = survivor.copyWith(activityAt: activity,
          filePath: source.filePath, format: source.format, parseOk: source.parseOk,
          totalChars: totalChars, chapterCount: chapterCount,
          aliases: ids.where((id) => id != survivor.id).toList(),
          sourcePaths: {for (final book in group) ...[book.filePath, ...book.sourcePaths]}
              .where((path) => path.isNotEmpty).toList());
      }
      out.add(survivor);
    }
    await _saveBooks(out);
    final last = sp.getString(_lastBookKey);
    if (last != null && redirects.containsKey(last) &&
        !await sp.setString(_lastBookKey, redirects[last]!)) throw StateError('Last book could not be migrated.');
    final order = sp.getStringList(_openOrderKey) ?? const <String>[];
    if (!await sp.setStringList(_openOrderKey, {for (final id in order) redirects[id] ?? id}.toList())) {
      throw StateError('Book open order could not be migrated.');
    }
    for (final change in consolidatedChanges) { publishBookChange(change); }
  }

  /// 从书架删除一本书，并留下删除墓碑（WebDAV 同步用它把删除传到其它设备）。
  /// [deletedAt] 不传取当前时间；应用远端删除时必须传远端时间，
  /// 否则本机时间会把对端的删除事件"变新"，导致两端反复拉锯。
  Future<void> removeBook(String bookId, {double? deletedAt, bool remote = false}) =>
      _bookWrite(() => AnnotationStore().duringBookRemoval(() async {
    final books = await loadBooks();
    bookId = await resolveBookId(bookId);
    String key = '';
    String title = '';
    final ids = <String>{bookId};
    for (final b in books) {
      if (b.id == bookId) {
        key = b.contentKey.trim();
        title = b.title;
        ids.addAll(b.aliases);
      }
    }
    for (final book in books) {
      if (key.isNotEmpty && book.contentKey.trim() == key) ids.addAll([book.id, ...book.aliases]);
    }
    if (remote && deletedAt != null) {
      var activity = 0.0;
      for (final book in books.where((book) => ids.contains(book.id))) {
        if (book.activityAt > activity) activity = book.activityAt;
        final progress = await _loadProgress(book.id);
        if ((progress?.updatedAt ?? 0) > activity) activity = progress!.updatedAt;
        final annotationClock = await AnnotationStore().loadBookmarksAt(book.id);
        if (annotationClock > activity) activity = annotationClock;
        for (final bm in await AnnotationStore().loadRawBookmarks(book.id)) {
          final version = AnnotationStore.bookmarkVersion(bm);
          if (version > activity) activity = version;
        }
      }
      if (activity > deletedAt) return;
    }
    if (key.isNotEmpty) {
      await _markDeleted(key, title, deletedAt: deletedAt, idKey: bookId, idKeys: ids);
    } else {
      // 老书还没回填 ck2：上传时用 book id 兜底，删除也必须用同一个 key
      await _markDeleted(bookId, title, deletedAt: deletedAt, idKeys: ids);
    }
    books.removeWhere((b) => ids.contains(b.id));
    await _saveBooks(books);
    final sp = await _sp;
    for (final id in ids) {
      if (sp.containsKey(_progressPrefix + id) && !await sp.remove(_progressPrefix + id)) {
        throw StateError('Removed book progress could not be cleared.');
      }
    }
    if (ids.contains(sp.getString(_lastBookKey)) && !await sp.remove(_lastBookKey)) {
      throw StateError('Last book could not be cleared.');
    }
    if (!await sp.setStringList(_openOrderKey,
        (sp.getStringList(_openOrderKey) ?? []).where((id) => !ids.contains(id)).toList())) {
      throw StateError('Removed book open order could not be cleared.');
    }
    for (final id in ids) {
      publishBookChange(BookStorageChange(bookId: id, kind: BookStorageChangeKind.removed, remote: remote));
    }
  }));

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
    await _bookWrite(() => _saveDeletions(deletions));
  }

  Future<void> _saveDeletions(Map<String, dynamic> deletions) async {
    final sp = await _sp;
    if (!await sp.setString(_deletionsKey, jsonEncode(deletions))) throw StateError('Deletions could not be saved.');
  }

  Future<void> markDeleted(String contentKey, String title,
      {double? deletedAt, String? idKey, Iterable<String> idKeys = const []}) =>
      _bookWrite(() => _markDeleted(contentKey, title, deletedAt: deletedAt, idKey: idKey, idKeys: idKeys));

  Future<void> _markDeleted(String contentKey, String title,
      {double? deletedAt, String? idKey, Iterable<String> idKeys = const []}) async {
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
        if (idKey == null && old is Map && old['id_key'] is String) 'id_key': old['id_key'],
        'id_keys': {if (old is Map) ...((old['id_keys'] as List?)?.whereType<String>() ?? const <String>[]),
          if (old is Map && old['id_key'] is String) old['id_key'] as String,
          if (idKey != null) idKey, ...idKeys}.toList(),
      };
      await _saveDeletions(deletions);
    }
  }

  Future<void> clearDeletion(String contentKey) => _bookWrite(() async {
    final key = contentKey.trim();
    if (key.isEmpty) return;
    final deletions = await loadDeletions();
    if (deletions.remove(key) != null) await _saveDeletions(deletions);
  });

  // ---------- 进度 ----------
  Future<BookProgress?> loadProgress(String bookId) async {
    return _loadProgress(await resolveBookId(bookId));
  }

  /// Read this exact stored ID without alias resolution or shelf repair.
  Future<BookProgress?> loadProgressSnapshot(String bookId) => _loadProgress(bookId);

  Future<BookProgress?> _loadProgress(String bookId) async {
    final sp = await _sp;
    final raw = sp.getString(_progressPrefix + bookId);
    if (raw == null || raw.isEmpty) return null;
    try {
      return BookProgress.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<bool> trySaveProgress(BookProgress p, {bool remote = false}) {
    final snapshot = BookProgress.fromJson(p.toJson());
    return _bookWrite(() async {
      final id = await resolveBookId(snapshot.bookId);
      final books = await loadBooks();
      final matching = books.where((book) => book.id == id);
      final meta = matching.isEmpty ? null : matching.first;
      final deletions = await loadDeletions();
      final blocked = deletions.entries.any((entry) {
        final value = entry.value;
        return value is Map && (entry.key == id || entry.key == meta?.contentKey ||
          value['id_key'] == id || (value['id_keys'] is List && (value['id_keys'] as List).contains(id))) &&
          (meta == null || meta.activityAt <= ((value['deleted_at'] as num?)?.toDouble() ?? 0));
      });
      final previous = await _loadProgress(id);
      if (blocked || !snapshot.updatedAt.isFinite || snapshot.updatedAt < 0 ||
          (previous != null && snapshot.updatedAt <= previous.updatedAt)) {
        debugPrint('Rejected stale or deleted-book progress write.');
        return false;
      }
      final saved = snapshot.copyWith(bookId: id);
      final sp = await _sp;
      if (!await sp.setString(_progressPrefix + id, jsonEncode(saved.toJson()))) {
        throw StateError('Progress could not be saved.');
      }
      for (final eventId in {id, ...?meta?.aliases}) {
        publishBookChange(BookStorageChange(bookId: eventId, kind: BookStorageChangeKind.progress,
            progress: saved.copyWith(bookId: eventId), remote: remote));
      }
      return true;
    });
  }

  Future<void> saveProgress(BookProgress p, {bool remote = false}) async {
    await trySaveProgress(p, remote: remote);
  }

  // ---------- 阅读设置 ----------
  Map<String, dynamic> _settings = {};

  Future<Map<String, dynamic>> loadSettings() async {
    final sp = await _sp;
    _settings = {};
    final raw = sp.getString(_settingsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        _settings = jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {}
    }
    return Map<String, dynamic>.from(_settings);
  }

  /// 合并写入：阅读设置与同步配置共用同一份 map，
  /// 任何一方保存时都不能把另一方的 key 冲掉（重启丢同步配置的根因）。
  Future<void> saveSettings(Map<String, dynamic> s) async {
    final patch = Map<String, dynamic>.from(s);
    await updateSettings((_) => patch);
  }

  /// The callback returns only owned keys and runs against the latest persisted map.
  Future<Map<String, dynamic>> updateSettings(
      Map<String, dynamic> Function(Map<String, dynamic>) patch) {
    final write = (_settingsWrites ?? Future<void>.value()).then((_) async {
      final sp = await _sp;
      var current = <String, dynamic>{};
      final raw = sp.getString(_settingsKey);
      if (raw != null && raw.isNotEmpty) {
        try {
          current = (jsonDecode(raw) as Map).cast<String, dynamic>();
        } catch (_) {}
      }
      _settings = {...current, ...patch(Map<String, dynamic>.from(current))};
      if (!await sp.setString(_settingsKey, jsonEncode(_settings))) throw StateError('Settings could not be saved.');
      return Map<String, dynamic>.from(_settings);
    });
    late final Future<void> settled;
    void clear() { if (identical(_settingsWrites, settled)) _settingsWrites = null; }
    settled = write.then<void>((_) => clear(), onError: (Object _, StackTrace __) => clear());
    _settingsWrites = settled;
    return write;
  }

  // ---------- 书架打开顺序（最近打开的排最前） ----------
  static const _openOrderKey = 'duoduo.openOrder.v1';

  Future<List<String>> loadOpenOrder() async {
    final sp = await _sp;
    return sp.getStringList(_openOrderKey) ?? const [];
  }

  Future<void> touchOpened(String bookId) => _bookWrite(() async {
    bookId = await resolveBookId(bookId);
    final sp = await _sp;
    final order = <String>[...(sp.getStringList(_openOrderKey) ?? const <String>[])];
    order.remove(bookId);
    order.insert(0, bookId);
    if (order.length > 200) order.removeRange(200, order.length);
    await sp.setStringList(_openOrderKey, order);
  });

  // ---------- 最后阅读的书籍（启动时自动恢复） ----------
  Future<String?> loadLastBookId() async {
    final sp = await _sp;
    return sp.getString(_lastBookKey);
  }

  Future<void> saveLastBookId(String bookId) => _bookWrite(() async {
    bookId = await resolveBookId(bookId);
    final sp = await _sp;
    await sp.setString(_lastBookKey, bookId);
  });
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
  static const paragraphSpacingLevels = <int>[0, 1, 2, 3];
  static int normalizeParagraphSpacingLevel(Object? value) => value is int && value >= 0 && value <= 3 ? value : 0;
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
  int paragraphSpacingLevel = 0;
  double speechRate = 1.0; // edge-tts 语速倍数：1.0=正常, 0.5=慢速, 2.0=快速
  int prefetchSentences = defaultPrefetchSentences;
  bool systemFallbackEnabled = false;
  bool systemFallbackActive = false;
  bool systemVoiceEnhancedOnly = true;
  String voice = '';
  String themeMode = 'system';
  int themeIndex = 0; // 书页背景主题索引
  int dayThemeIndex = 0;
  String fontFamily = ''; // 用户自选字体 family 名，空=系统默认

  // Keep stable voice IDs rather than translated/display names. An unset
  // online selection is the same Xiaoxiao voice used by the reader.
  static const defaultPauseVoice = 'zh-CN-XiaoxiaoNeural';
  static const systemPauseVoice = '__system_tts__';
  static double maxSpeechRateFor(String voice) =>
    SystemTtsClient.isSystemVoiceId(voice) ? (Platform.isIOS ? 2.0 : 3.0) : 2.0;
  static String _pauseVoiceKey(String value) =>
    value.trim().isEmpty ? defaultPauseVoice : value.trim();
  String get speechPauseVoice => systemFallbackActive ? systemPauseVoice : _pauseVoiceKey(voice);
  SpeechPauseSettings get effectiveSpeechPauses => speechPausesForVoice(speechPauseVoice);
  SpeechPauseSettings speechPausesForVoice(String voiceId) =>
    SystemTtsClient.isSystemVoiceId(_pauseVoiceKey(voiceId))
      ? perVoiceSpeechPauses[systemPauseVoice] ?? speechPauses
      : const SpeechPauseSettings();
  bool hasVoiceSpeechPauses(String voiceId) => SystemTtsClient.isSystemVoiceId(_pauseVoiceKey(voiceId)) &&
    perVoiceSpeechPauses.containsKey(systemPauseVoice);
  void setVoiceSpeechPauses(String voiceId, SpeechPauseSettings pauses) =>
    perVoiceSpeechPauses[SystemTtsClient.isSystemVoiceId(voiceId) ? systemPauseVoice : _pauseVoiceKey(voiceId)] = pauses;
  void clearVoiceSpeechPauses(String voiceId) =>
    perVoiceSpeechPauses.remove(SystemTtsClient.isSystemVoiceId(voiceId) ? systemPauseVoice : _pauseVoiceKey(voiceId));

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
        'paragraphSpacingModel': 'fixed',
        'paragraphSpacingLevel': normalizeParagraphSpacingLevel(paragraphSpacingLevel),
        'speechRate': speechRate,
        'prefetchSentences': prefetchSentences,
        'systemFallbackEnabled': systemFallbackEnabled,
        'systemFallbackActive': systemFallbackActive,
        'systemVoiceEnhancedOnly': systemVoiceEnhancedOnly,
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
    if (json['paragraphSpacingModel'] == 'fixed') {
      s.paragraphSpacingLevel = normalizeParagraphSpacingLevel(json['paragraphSpacingLevel']);
    } else {
      // Previous levels described a tiny geometry-dependent spacing budget,
      // including a persisted default of 2. They do not express consent to
      // the new visible fixed gaps. Migrate once to no extra gap; toJson's
      // model marker preserves subsequent explicit choices in the new UI.
      s.paragraphSpacingLevel = 0;
    }
    s.speechRate = normalizeSpeechRate((json['speechRate'] as num?)?.toDouble() ?? s.speechRate);
    s.prefetchSentences = ((json['prefetchSentences'] as num?)?.toInt() ?? defaultPrefetchSentences)
      .clamp(minPrefetchSentences, maxPrefetchSentences);
    s.voice = json['voice'] as String? ?? '';
    s.systemFallbackEnabled = json['systemFallbackEnabled'] as bool? ?? false;
    s.systemFallbackActive = s.systemFallbackEnabled && (json['systemFallbackActive'] as bool? ?? false);
    s.systemVoiceEnhancedOnly = json['systemVoiceEnhancedOnly'] is bool ? json['systemVoiceEnhancedOnly'] as bool : true;
    final themeMode = json['themeMode'];
    s.themeMode = ['system', 'dark', 'light'].contains(themeMode) ? themeMode as String : 'system';
    s.themeIndex = (json['themeIndex'] as num?)?.toInt() ?? 0;
    s.dayThemeIndex = (json['dayThemeIndex'] as num?)?.toInt() ?? 0;
    s.fontFamily = json['fontFamily'] as String? ?? '';
    return s;
  }
}
