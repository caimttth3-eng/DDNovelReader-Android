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
  }

  Future<void> removeBook(String bookId) async {
    final books = await loadBooks();
    books.removeWhere((b) => b.id == bookId);
    await saveBooks(books);
    final sp = await _sp;
    await sp.remove(_progressPrefix + bookId);
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

  Map<String, dynamic> toJson() => {
        'brightness': brightness,
        'fontSize': fontSize,
        'lineHeight': lineHeight,
        'speechRate': speechRate,
        'voice': voice,
        'themeIndex': themeIndex,
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
    return s;
  }
}
