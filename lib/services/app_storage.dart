import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/progress.dart';

/// 本地持久化：
///  - 书架书籍列表（BookMeta）
///  - 每本书的阅读进度（BookProgress）
///  - 阅读页设置（亮度/字号/行距/语速/音源）
class AppStorage {
  static const _booksKey = 'duoduo.books.v1';
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
      return list
          .map((e) => BookMeta.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
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
  ///
  /// 墓碑 key 必须与"当初上传时用的 key"一致：
  /// contentKey 有值时用 contentKey；没有值时（老书还没回填 ck2，上传时用 book id 兜底）
  /// 就必须用 book id，否则远端那条记录永远收不到删除。
  /// 同时把 book id 记进墓碑条目的 id_key，同步时顺手把远端遗留的 id_key 孤儿记录也清掉。
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
      await markDeleted(bookId, title, deletedAt: deletedAt);
    }
  }

  // ---------- 删除墓碑 ----------
  static const _deletionsKey = 'duoduo.deletions.v1';

  /// {content_key: {"deleted_at": 秒, "title": 书名, "id_key": 当初兜底上传用的 book id}}
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

  Future<void> saveSettings(Map<String, dynamic> s) async {
    _settings = s;
    final sp = await _sp;
    await sp.setString(_settingsKey, jsonEncode(s));
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
  double brightness = 1.0;
  double fontSize = 20.0;
  double lineHeight = 1.6;
  double speechRate = 1.0; // edge-tts 语速倍数：1.0=正常, 0.5=慢速, 2.0=快速
  String voice = '';
  int themeIndex = 0; // 书页背景主题索引
  String fontFamily = ''; // 用户自选字体 family 名，空=系统默认

  Map<String, dynamic> toJson() => {
        'brightness': brightness,
        'fontSize': fontSize,
        'lineHeight': lineHeight,
        'speechRate': speechRate,
        'voice': voice,
        'themeIndex': themeIndex,
        'fontFamily': fontFamily,
      };

  static ReadingSettings fromJson(Map<String, dynamic>? json) {
    final s = ReadingSettings();
    if (json == null) return s;
    s.brightness = (json['brightness'] as num?)?.toDouble() ?? s.brightness;
    s.fontSize = (json['fontSize'] as num?)?.toDouble() ?? s.fontSize;
    s.lineHeight = (json['lineHeight'] as num?)?.toDouble() ?? s.lineHeight;
    s.speechRate = (json['speechRate'] as num?)?.toDouble() ?? s.speechRate;
    s.voice = json['voice'] as String? ?? '';
    s.themeIndex = (json['themeIndex'] as num?)?.toInt() ?? 0;
    s.fontFamily = json['fontFamily'] as String? ?? '';
    return s;
  }
}
