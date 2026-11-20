import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/annotation.dart';
import 'app_storage.dart';

/// 标注持久化：书签 + 划线，按书籍分开存放（SharedPreferences JSON）。
/// 划线条数通常每本几十~几百条，JSON 数组足够承载，免去引入 sqlite。
class AnnotationStore {
  static const _bmPrefix = 'duoduo.bookmarks.';
  static const _hlPrefix = 'duoduo.highlights.';
  static const _deletedPrefix = 'duoduo.bookmarkDeletions.';
  static const _clockPrefix = 'duoduo.bookmarksAt.';
  static Future<void>? _writes;

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _sp async {
    return _prefs ??= await SharedPreferences.getInstance();
  }

  Future<T> _write<T>(Future<T> Function() action) {
    final result = (_writes ?? Future<void>.value()).then((_) => action());
    late final Future<void> settled;
    void clear() { if (identical(_writes, settled)) _writes = null; }
    settled = result.then<void>((_) => clear(), onError: (Object _, StackTrace __) => clear());
    _writes = settled;
    return result;
  }

  /// Shelf deletion checks and annotation writes share the same ordering.
  Future<void> duringBookRemoval(Future<void> Function() action) => _write(action);

  Future<bool> _removed(String id) async {
    final storage = AppStorage();
    if ((await storage.loadBooks()).any((book) => book.id == id || book.aliases.contains(id))) return false;
    return (await storage.loadDeletions()).entries.any((entry) {
      final value = entry.value;
      return value is Map && (entry.key == id || value['id_key'] == id ||
          value['id_keys'] is List && (value['id_keys'] as List).contains(id));
    });
  }

  static double bookmarkVersion(Map<String, dynamic> bm) {
    double number(Object? v) => v is num && v.isFinite ? v.toDouble() : 0;
    final created = number(bm['created_at']);
    final iso = bm['createdAt'];
    var version = created > 0 ? created : iso is String
        ? (DateTime.tryParse(iso)?.millisecondsSinceEpoch ?? 0) / 1000.0 : 0.0;
    final modified = number(bm['modified_at']);
    if (modified > version) version = modified;
    return version;
  }

  static Map<String, double> deletionVersions(Object? raw) {
    final out = <String, double>{};
    if (raw is Map) {
      for (final entry in raw.entries) {
        final v = entry.value is Map ? (entry.value as Map)['deleted_at'] : entry.value;
        if (v is num && v.isFinite && v >= 0) out[entry.key.toString()] = v.toDouble();
      }
    }
    return out;
  }

  static String _bookmarkValue(Map<String, dynamic> bm) {
    final keys = bm.keys.where((key) => key != 'bookId').toList()..sort();
    return jsonEncode({for (final key in keys) key: bm[key]});
  }

  Future<Map<String, double>> _loadDeletions(String id) async {
    final raw = (await _sp).getString(_deletedPrefix + id);
    if (raw == null) return {};
    return deletionVersions(jsonDecode(raw));
  }

  Future<Map<String, double>> loadBookmarkDeletions(String bookId) async =>
      _loadDeletions(await AppStorage().resolveBookId(bookId));

  Future<double> loadBookmarksAt(String bookId) async =>
      (await _sp).getDouble(_clockPrefix + await AppStorage().resolveBookId(bookId)) ?? 0;

  static List<Map<String, dynamic>> mergeRawBookmarks(
      List<Map<String, dynamic>> local, List<Map<String, dynamic>> remote,
      Map<String, double> deletions) {
    final merged = <String, Map<String, dynamic>>{};
    for (final bm in [...local, ...remote]) {
      final id = (bm['id'] ?? '').toString();
      if (id.isEmpty) continue;
      final version = bookmarkVersion(bm);
      if (deletions.containsKey(id) && deletions[id]! >= version) continue;
      final previous = merged[id];
      if (previous == null || version > bookmarkVersion(previous) ||
          (version == bookmarkVersion(previous) && _bookmarkValue(bm).compareTo(_bookmarkValue(previous)) > 0)) {
        merged[id] = Map<String, dynamic>.from(bm);
      }

    }
    return merged.values.toList()..sort((a, b) {
      final version = bookmarkVersion(a).compareTo(bookmarkVersion(b));
      return version != 0 ? version : a['id'].toString().compareTo(b['id'].toString());
    });
  }

  Future<bool> _persist(String id, List<Map<String, dynamic>> incoming,
      {Map<String, double> deletions = const {}, double updatedAt = 0, bool remote = false,
      Set<String> removed = const {}, bool notify = true}) async {
    if (await _removed(id)) return false;
    final sp = await _sp;
    final old = await _loadRaw(id);
    final oldDeletions = await _loadDeletions(id);
    final mergedDeletions = {...oldDeletions};
    for (final entry in deletions.entries) {
      if (entry.value > (mergedDeletions[entry.key] ?? -1)) mergedDeletions[entry.key] = entry.value;
    }
    var clock = sp.getDouble(_clockPrefix + id) ?? 0.0;
    if (updatedAt > clock) clock = updatedAt;
    for (final bm in [...old, ...incoming]) {
      final version = bookmarkVersion(bm);
      if (version > clock) clock = version;
    }
    for (final bookmarkId in removed) {
      final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
      clock = (now > clock ? now : clock) + 0.001;
      mergedDeletions[bookmarkId] = clock;
    }
    for (final version in mergedDeletions.values) {
      if (version > clock) clock = version;
    }
    final merged = mergeRawBookmarks(old, incoming, mergedDeletions)
        .map((bm) => {...bm, 'bookId': id}).toList();
    final changed = jsonEncode(old) != jsonEncode(merged) ||
        jsonEncode(oldDeletions) != jsonEncode(mergedDeletions) ||
        clock != (sp.getDouble(_clockPrefix + id) ?? 0);
    if (!changed) return false;
    // Persist deletes first: an interrupted write must not revive removed items.
    if (!await sp.setString(_deletedPrefix + id, jsonEncode(mergedDeletions)) ||
        !await sp.setString(_bmPrefix + id, jsonEncode(merged)) ||
        !await sp.setDouble(_clockPrefix + id, clock)) {
      throw StateError('Bookmarks could not be saved.');
    }
    if (notify) await _notify(id, remote: remote);
    return true;
  }

  Future<void> _notify(String id, {bool remote = false}) async {
    final matching = (await AppStorage().loadBooks()).where((book) => book.id == id);
    final aliases = matching.isEmpty ? const <String>[] : matching.first.aliases;
    for (final eventId in {id, ...aliases}) {
      AppStorage.publishBookChange(BookStorageChange(bookId: eventId,
          kind: BookStorageChangeKind.annotations, remote: remote));
    }
  }

  // ---------- 原始 JSON（WebDAV 同步用） ----------
  // 同步要按 id 做并集，且不能丢掉 PC 端写入的原生字段（chapter_idx/offset/
  // offset_end/text/created_at），所以这里直接读写未解析的 Map 列表。
  Future<List<Map<String, dynamic>>> loadRawBookmarks(String bookId) async {
    final id = await AppStorage().resolveBookId(bookId);
    return mergeRawBookmarks(await _loadRaw(id), [], await _loadDeletions(id));
  }

  Future<List<Map<String, dynamic>>> _loadRaw(String bookId) async {
    final sp = await _sp;
    final raw = sp.getString(_bmPrefix + bookId);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveRawBookmarks(
      String bookId, List<Map<String, dynamic>> list, {bool remote = false,
      Map<String, double> deletions = const {}, double updatedAt = 0}) async {
    await mergeBookmarks(bookId, list, deletions: deletions, updatedAt: updatedAt, remote: remote);
  }

  Future<bool> mergeBookmarks(String bookId, List<Map<String, dynamic>> list,
      {Map<String, double> deletions = const {}, double updatedAt = 0, bool remote = true}) => _write(() async {
    final id = await AppStorage().resolveBookId(bookId);
    return _persist(id, list, deletions: deletions, updatedAt: updatedAt, remote: remote);
  });

  Future<void> deleteBookmark(String bookId, String bookmarkId) => _write(() async {
    final id = await AppStorage().resolveBookId(bookId);
    await _persist(id, [], removed: {bookmarkId});
  });

  // ---------- 书签 ----------
  Future<List<Bookmark>> loadBookmarks(String bookId) async {
    return (await loadRawBookmarks(bookId)).map(Bookmark.fromJson).toList();
  }

  /// Upsert a UI snapshot; absence is not deletion (it may predate a remote union).
  /// User deletion must use deleteBookmark so it has its own durable version.
  Future<void> saveBookmarks(String bookId, List<Bookmark> list) => _write(() async {
    final id = await AppStorage().resolveBookId(bookId);
    final old = await _loadRaw(id);
    final incoming = <Map<String, dynamic>>[for (final bm in list) {
      for (final previous in old.where((raw) => raw['id'] == bm.id)) ...previous,
      ...bm.toJson(),
    }];
    await _persist(id, incoming);
  });

  // ---------- 划线 ----------
  Future<List<Highlight>> loadHighlights(String bookId) async {
    bookId = await AppStorage().resolveBookId(bookId);
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

  Future<void> saveHighlights(String bookId, List<Highlight> list) => _write(() async {
    bookId = await AppStorage().resolveBookId(bookId);
    if (await _removed(bookId)) return;
    final sp = await _sp;
    final data = jsonEncode(list.map((h) => {...h.toJson(), 'bookId': bookId}).toList());
    if (sp.getString(_hlPrefix + bookId) == data) return;
    if (!await sp.setString(_hlPrefix + bookId, data)) {
      throw StateError('Highlights could not be saved.');
    }
    await _notify(bookId);
  });

  /// Called before shelf aliases are collapsed. Source files are never touched.
  Future<bool> mergeBooks(String survivorId, Iterable<String> ids, {bool notify = true}) => _write(() async {
    final sp = await _sp;
    final all = <Map<String, dynamic>>[];
    final deletions = <String, double>{};
    final highlights = <String, Map<String, dynamic>>{};
    var clock = 0.0;
    for (final id in {survivorId, ...ids}) {
      all.addAll(await _loadRaw(id));
      for (final entry in (await _loadDeletions(id)).entries) {
        if (entry.value > (deletions[entry.key] ?? -1)) deletions[entry.key] = entry.value;
      }
      final t = sp.getDouble(_clockPrefix + id) ?? 0.0;
      if (t > clock) clock = t;
      final raw = sp.getString(_hlPrefix + id);
      if (raw == null) continue;
      for (final value in (jsonDecode(raw) as List).whereType<Map>()) {
        final item = Map<String, dynamic>.from(value)..['bookId'] = survivorId;
        final base = (item['id'] ?? '').toString();
        var key = base;
        var suffix = 0;
        while (highlights.containsKey(key)) {
          item['id'] = key;
          if (jsonEncode(highlights[key]) == jsonEncode(item)) break;
          suffix++;
          key = '$base@$id${suffix == 1 ? '' : '#$suffix'}';
        }
        item['id'] = key;
        highlights[key] = item;
      }
    }
    final bookmarksChanged = await _persist(survivorId, all,
        deletions: deletions, updatedAt: clock, notify: false);
    final data = jsonEncode(highlights.values.toList());
    final highlightsChanged = sp.getString(_hlPrefix + survivorId) != data;
    if (highlightsChanged && !await sp.setString(_hlPrefix + survivorId, data)) {
      throw StateError('Merged highlights could not be saved.');
    }
    final changed = bookmarksChanged || highlightsChanged;
    if (changed && notify) await _notify(survivorId);
    return changed;
  });

  Future<void> removeBookAnnotations(String bookId) => _write(() async {
    bookId = await AppStorage().resolveBookId(bookId);
    final sp = await _sp;
    await sp.remove(_bmPrefix + bookId);
    await sp.remove(_hlPrefix + bookId);
    // Keep deletion versions across reimports; old clients may still send items.
  });
}
