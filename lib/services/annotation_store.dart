import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/annotation.dart';

/// 标注持久化：书签 + 划线，按书籍分开存放（SharedPreferences JSON）。
/// 划线条数通常每本几十~几百条，JSON 数组足够承载，免去引入 sqlite。
class AnnotationStore {
  static const _bmPrefix = 'duoduo.bookmarks.';
  static const _hlPrefix = 'duoduo.highlights.';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _sp async {
    return _prefs ??= await SharedPreferences.getInstance();
  }

  // ---------- 书签 ----------
  Future<List<Bookmark>> loadBookmarks(String bookId) async {
    final sp = await _sp;
    final raw = sp.getString(_bmPrefix + bookId);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => Bookmark.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveBookmarks(String bookId, List<Bookmark> list) async {
    final sp = await _sp;
    await sp.setString(
        _bmPrefix + bookId, jsonEncode(list.map((b) => b.toJson()).toList()));
  }

  // ---------- 划线 ----------
  Future<List<Highlight>> loadHighlights(String bookId) async {
    final sp = await _sp;
    final raw = sp.getString(_hlPrefix + bookId);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => Highlight.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveHighlights(String bookId, List<Highlight> list) async {
    final sp = await _sp;
    await sp.setString(
        _hlPrefix + bookId, jsonEncode(list.map((h) => h.toJson()).toList()));
  }

  Future<void> removeBookAnnotations(String bookId) async {
    final sp = await _sp;
    await sp.remove(_bmPrefix + bookId);
    await sp.remove(_hlPrefix + bookId);
  }
}
