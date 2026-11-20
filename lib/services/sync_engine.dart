import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../models/book.dart';
import '../models/progress.dart';
import 'annotation_store.dart';
import 'app_storage.dart';
import 'book_parser.dart';
import 'content_key.dart';
import 'webdav_client.dart';

/// 同步结果
class SyncReport {
  bool ok = false;
  int pushed = 0;
  int pulled = 0;
  int skipped = 0;
  /// 从远端源文件下载并入书架的本数（桌面独有的书）
  int imported = 0;
  /// 按远端的删除墓碑从本机书架移除的本数
  int removed = 0;
  /// 上传到远端的删除事件（本机删除的书）
  int deleted = 0;
  /// 被移除的本地 book id（界面据此关掉正在读的书）
  final List<String> removedIds = [];
  /// 补传到 v1/sources 的源文件个数
  int sourceUploaded = 0;
  int ambiguousProgress = 0;
  final List<String> remoteOnly = [];
  final List<String> lines = [];
  String error = '';

  String get summary {
    if (!ok) return error;
    final b = StringBuffer('同步完成：上传 $pushed 本，拉取 $pulled 本，跳过 $skipped 本');
    if (imported > 0) b.write('，新增 $imported 本');
    if (removed > 0) b.write('，删除 $removed 本');
    if (deleted > 0) b.write('，上传删除事件 $deleted 个');
    if (sourceUploaded > 0) b.write('，补传书源 $sourceUploaded 个');
    if (remoteOnly.isNotEmpty) {
      b.write('；远端有 ${remoteOnly.length} 本本机未导入（无源文件）');
    }
    if (ambiguousProgress > 0) b.write('；$ambiguousProgress 本旧版进度百分比单位未知，保留原值并按字符位置恢复');
    return b.toString();
  }
}

/// WebDAV 同步：与 PC 端 novelreader/sync_engine.py 协议同构。
///
/// 远端布局（与 PC 完全一致，两端可互相读写）：
///   <远端目录>/v1/books/<content_key>.json
///   <远端目录>/v1/sources/<content_key><ext>   书源文件（桌面独有的书靠它落地）
///   <远端目录>/v1/devices/<device_id>.json
///   <远端目录>/v1/meta.json
///
/// 同步的数据：书名/作者/格式/字数/章数、阅读进度、书签、书源文件。
/// 音频缓存不上传（靠相同的 content_key 目录名复用，见 tts_cache_store.dart）。
///
/// 冲突策略（与 PC sync_engine.py 逐条一致）：
///   - 进度：比 `progress_at`，新者胜（差值 > 0.5 秒才算更新；只看谁最后改，不看章节前后）
///   - 书签：按 id/version 并集，bookmark_deletions 过滤旧版本；旧桌面端可能不应用删除
///   - 删除：墓碑记录（deleted / deleted_at），对端删除时间更新则本机也删；
///     删除之后本机又重新导入/读过 → 视为复活，不会被对端墓碑再删一次
class SyncEngine {
  static const schemaVersion = 2;
  static const remoteDirDefault = WebDavClient.defaultRemoteDir;

  /// 时间比较容差（秒），与 PC TIME_TOL 相同
  static const timeTol = 0.5;

  /// 删除墓碑保留时长：过期后不再向远端推删除事件
  static const tombstoneTtl = 120 * 86400;

  /// 与 PC sync_engine 的 CFG_KEYS 同名同义（都存在阅读设置里）
  static const cfgServer = 'sync_server';
  static const cfgUser = 'sync_user';
  static const cfgPass = 'sync_pass';
  static const cfgDir = 'sync_dir';
  static const cfgDeviceId = 'sync_device_id';
  static const cfgDeviceName = 'sync_device_name';
  static const cfgAuto = 'sync_auto';
  static const cfgVerifyTls = 'sync_verify_tls';
  static const cfgLastTime = 'sync_last_time';

  final AppStorage storage;
  final AnnotationStore annotations;

  /// 书源落地目录；生产走应用私有目录，测试可注入临时目录
  final String? sourceDirOverride;

  static Object? _coordinator;

  SyncEngine({
    required this.storage,
    required this.annotations,
    this.sourceDirOverride,
  });

  // ---------------------------------------------------------------- 配置

  Future<Map<String, dynamic>> settings() => storage.loadSettings();

  Future<void> saveSettings(Map<String, dynamic> s) => storage.saveSettings({
    for (final key in [cfgServer, cfgUser, cfgPass, cfgDir, cfgDeviceId, cfgDeviceName,
      cfgAuto, cfgVerifyTls, cfgLastTime]) if (s.containsKey(key)) key: s[key],
  });

  /// 确保本机有稳定的 device_id / device_name，返回 (id, name)。
  Future<(String, String)> ensureDevice(Map<String, dynamic> s) async {
    final saved = await storage.updateSettings((current) {
      final name = (current[cfgDeviceName] as String? ?? '').trim();
      final id = (current[cfgDeviceId] as String? ?? '').trim();
      return {
        if (id.isEmpty) cfgDeviceId: _newDeviceId(name.isEmpty ? _platformName() : name),
        if (name.isEmpty) cfgDeviceName: _platformName(),
      };
    });
    return (saved[cfgDeviceId] as String, saved[cfgDeviceName] as String);
  }

  static String _configIdentity(Map<String, dynamic> s) => jsonEncode([
    s[cfgServer], s[cfgUser], s[cfgPass], s[cfgDir], s[cfgVerifyTls],
  ]);

  Future<void> _checkConfig(Map<String, dynamic> s) async {
    if (_configIdentity(await settings()) != _configIdentity(s)) {
      throw WebDavException('同步配置已更改，请重新同步');
    }
  }

  static String _platformName() => 'Android';

  static String _newDeviceId(String name) {
    final raw = 'android|$name|${DateTime.now().millisecondsSinceEpoch}';
    return sha1.convert(utf8.encode(raw)).toString().substring(0, 12);
  }

  bool configured(Map<String, dynamic> s) =>
      (s[cfgServer] as String? ?? '').trim().isNotEmpty;

  WebDavClient client(Map<String, dynamic> s) => WebDavClient(
        server: s[cfgServer] as String? ?? '',
        username: s[cfgUser] as String? ?? '',
        password: s[cfgPass] as String? ?? '',
        remoteDir: (s[cfgDir] as String? ?? '').trim().isEmpty
            ? remoteDirDefault
            : s[cfgDir] as String?,
        verifyTls: (s[cfgVerifyTls] as bool?) ?? true,
      );

  // ---------------------------------------------------------------- 本地记录

  /// 每本书一条记录；与 PC `_record()` 的字段名逐一对齐。
  Future<Map<String, MapEntry<String, Map<String, dynamic>>>> localRecords(
    Map<String, dynamic> s,
    String deviceName,
  ) async {
    await storage.consolidateBooks();
    final books = await storage.loadBooks();
    final out = <String, MapEntry<String, Map<String, dynamic>>>{};
    for (final meta in books) {
      final key = meta.contentKey.trim().isNotEmpty ? meta.contentKey.trim() : meta.id;
      final progress = await storage.loadProgress(meta.id);
      final bms = await annotations.loadRawBookmarks(meta.id);
      final bmDeletions = await annotations.loadBookmarkDeletions(meta.id);
      // 进度与书签各带自己的版本时间：只改书签不会把进度"变新"，
      // 只改进度也不会让对端误判书签更新。
      final pAt = progress?.updatedAt ?? 0.0;
      var bAt = await annotations.loadBookmarksAt(meta.id);
      for (final bm in bms) {
        final t = _createdAt(bm);
        if (t > bAt) bAt = t;
      }
      for (final version in bmDeletions.values) { if (version > bAt) bAt = version; }
      final activity = meta.activityAt;
      final upd = [pAt, bAt, activity].reduce((a, b) => a > b ? a : b);
      out[key] = MapEntry(meta.id, {
        'schema': schemaVersion,
        'content_key': key,
        'content_key_version': ckVersion,
        'legacy_key': '',
        'title': meta.title,
        'author': '',
        'format': meta.format,
        'total_chars': meta.totalChars,
        'chapter_count': meta.chapterCount,
        if (_sourceMeta(meta) != null) 'source': _sourceMeta(meta),
        'progress': progress == null
            ? <String, dynamic>{}
            : {
                ...progress.toPcJson(),
                // 远端（与 PC 同口径）的 percent 是 0~100，本机是 0~1，出站要换算
                'percent': progress.ambiguousPercent ?? _percentToRemote(progress.percent),
                'percent_unit': progress.ambiguousPercent == null ? 'percent' : 'unknown',
              },
        'progress_at': _round(pAt),
        'bookmarks': bms,
        'bookmark_deletions': bmDeletions,
        'bookmarks_at': _round(bAt),
        'metadata_at': _round(activity),
        'updated_at': _round(upd),
        'device': deviceName,
        'synced_at': _round(DateTime.now().millisecondsSinceEpoch / 1000.0),
      });
    }
    return out;
  }

  /// 删除墓碑记录：与普通记录同目录同 key，多一个 deleted 标记（PC 端同构）
  static Map<String, dynamic> tombstoneRecord(
    String key,
    Map<String, dynamic> entry,
    String deviceName,
  ) {
    final t = _num(entry['deleted_at']) ?? 0.0;
    return {
      'schema': schemaVersion,
      'content_key': key,
      'content_key_version': ckVersion,
      'legacy_key': '',
      'title': (entry['title'] as String?) ?? '',
      'author': '',
      'format': '',
      'total_chars': 0,
      'chapter_count': 0,
      'progress': <String, dynamic>{},
      'progress_at': 0,
      'bookmarks': <Map<String, dynamic>>[],
      'bookmark_deletions': <String, double>{},
      'bookmarks_at': 0,
      'deleted': true,
      'deleted_at': _round(t),
      'updated_at': _round(t),
      'device': deviceName,
      'synced_at': _round(DateTime.now().millisecondsSinceEpoch / 1000.0),
    };
  }

  static double? _num(dynamic v) {
    if (v is num && v.isFinite) return v.toDouble();
    if (v is String) { final d = double.tryParse(v); return d != null && d.isFinite ? d : null; }
    return null;
  }

  /// 本机 percent(0~1) → 远端 percent(0~100)
  static double _percentToRemote(double v) => v.clamp(0.0, 1.0) * 100.0;

  /// Schema 2 uses percent, never a value-based ratio heuristic.
  static double percentFromRemote(dynamic v, {String unit = 'percent'}) {
    final d = _num(v) ?? 0.0;
    if (unit != 'percent' && unit != 'ratio') throw FormatException('Ambiguous progress percent unit');
    return (unit == 'ratio' ? d : d / 100.0).clamp(0.0, 1.0);
  }

  static BookProgress _remoteProgress(String id, Map<String, dynamic> rec, {double fallbackPercent = 0}) {
    final raw = Map<String, dynamic>.from(rec['progress'] as Map);
    final parsed = BookProgress.fromPcJson(id, raw);
    final unit = raw['percent_unit'] ?? rec['percent_unit'] ??
        (rec['schema'] == schemaVersion ? 'percent' : null);
    final ambiguous = unit != 'percent' && unit != 'ratio' || raw['percent_ambiguous'] == true;
    return BookProgress.fromJson({
      ...parsed.toJson(),
      'updatedAt': _num(rec['progress_at']) ?? _num(rec['updated_at']) ?? 0.0,
      'percent': ambiguous ? fallbackPercent : percentFromRemote(raw['percent'], unit: unit as String),
      if (ambiguous) 'ambiguousPercent': _num(raw['percent']) ?? 0.0,
    });
  }

  /// 一本书在本地最后一次"内容变化"的时间（进度 / 书签 / 加入书架）
  static double bookActivity(BookMeta meta, BookProgress? progress, List<Map<String, dynamic>> bms) {
    var t = progress?.updatedAt ?? 0.0;
    if (meta.activityAt > t) t = meta.activityAt;
    for (final bm in bms) {
      final c = _createdAt(bm);
      if (c > t) t = c;
    }
    return t;
  }

  static double _round(double v) => (v * 1000).round() / 1000.0;

  // ---------------------------------------------------------------- 远端

  static const _booksDir = 'v1/books';
  static const _sourcesDir = 'v1/sources';
  static const _devicesDir = 'v1/devices';

  /// 书源文件上限，与桌面端一致
  static const maxSourceBytes = 512 * 1024 * 1024;

  static String _bookPath(String key) => '$_booksDir/$key.json';

  /// 本地源文件落地目录（应用私有目录，SAF/content:// 的源副本都在这）
  static const _docsBooksSub = 'books';

  static String _extOf(String format) {
    switch (format.toLowerCase()) {
      case 'epub':
        return '.epub';
      case 'pdf':
        return '.pdf';
      case 'docx':
        return '.docx';
      default:
        return '.txt';
    }
  }

  static int _fileSize(String path) {
    try {
      return File(path).lengthSync();
    } catch (_) {
      return 0;
    }
  }

  static String _baseName(String path) {
    final segs = path.split(Platform.pathSeparator);
    return segs.isEmpty ? path : segs.last;
  }

  /// 记录里的 source 段：{"ext":".txt","size":n,"name":"某本书.txt"}
  /// 源文件不存在则不写（宁可缺，也不要写个下载不下来的指针）。
  static Map<String, dynamic>? _sourceMeta(BookMeta meta) {
    if (meta.filePath.isEmpty) return null;
    final size = _fileSize(meta.filePath);
    if (size <= 0) return null;
    return {'ext': _extOf(meta.format), 'size': size, 'name': _baseName(meta.filePath)};
  }

  Future<List<int>?> _readSourceFile(String path) async {
    try {
      final f = File(path);
      if (!await f.exists()) return null;
      final len = await f.length();
      if (len <= 0 || len > maxSourceBytes) return null;
      return await f.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  Future<void> prepareRemote(WebDavClient cli) async {
    await cli.mkdirs(_booksDir);
    await cli.mkdirs(_sourcesDir);
    await cli.mkdirs(_devicesDir);
    try {
      await cli.put(
        'v1/meta.json',
        utf8.encode(jsonEncode({
          'schema': schemaVersion,
          'app': 'DDNovelReader',
          'updated_at': _round(DateTime.now().millisecondsSinceEpoch / 1000.0),
        })),
      );
    } on WebDavException {
      // meta 写失败不影响同步主流程
    }
  }

  Future<Map<String, Map<String, dynamic>>> readRemoteBooks(WebDavClient cli) async {
    final out = <String, Map<String, dynamic>>{};
    final entries = await cli.propfind(_booksDir);
    for (final e in entries) {
      if (e.isDir || !e.name.toLowerCase().endsWith('.json')) continue;
      final key = e.name.substring(0, e.name.length - 5);
      final raw = await cli.get(e.rel.isEmpty ? _bookPath(key) : e.rel);
      if (raw == null || raw.isEmpty) throw WebDavException('远端书籍记录无法读取，已停止同步');
      Map<String, dynamic> rec;
      try {
        rec = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
      } catch (_) {
        throw WebDavException('远端书籍记录无效，已停止同步');
      }
      final ck = (rec['content_key'] as String? ?? '').trim();
      if (ck.isEmpty || ck != key || ck.contains(RegExp(r'[/\\]')) || ck == '.' || ck == '..' ||
          out.containsKey(ck)) throw WebDavException('远端书籍标识无效或重复，已停止同步');
      out[ck] = rec;
    }
    return out;
  }

  // ---------------------------------------------------------------- 合并

  /// 书签按 id 取并集；同 id 取 created_at 较新的一份。返回 (并集, 是否变化)
  static (List<Map<String, dynamic>>, bool) mergeBookmarks(
    List<Map<String, dynamic>> local,
    List<Map<String, dynamic>> remote, {
    Map<String, double> deletions = const {},
  }) {
    final list = AnnotationStore.mergeRawBookmarks(local, remote, deletions);
    final original = AnnotationStore.mergeRawBookmarks(local, [], const {});
    return (list, jsonEncode(list) != jsonEncode(original));
  }

  static double _createdAt(Map<String, dynamic> bm) {
    return AnnotationStore.bookmarkVersion(bm);
  }

  static String _stableJson(Object? value) {
    Object? ordered(Object? item) {
      if (item is Map) {
        final keys = item.keys.map((key) => key.toString()).toList()..sort();
        return {for (final key in keys) key: ordered(item[key])};
      }
      if (item is List) return item.map(ordered).toList();
      return item;
    }
    return jsonEncode(ordered(value));
  }

  static bool _sameBookmarkState(Map<String, dynamic> a, Map<String, dynamic> b) {
    Object normalized(Map<String, dynamic> rec) {
      final list = (rec['bookmarks'] as List? ?? const []).whereType<Map>()
          .map((bm) => Map<String, dynamic>.from(bm)..remove('bookId')).toList()
        ..sort((a, b) => a['id'].toString().compareTo(b['id'].toString()));
      return [list, AnnotationStore.deletionVersions(rec['bookmark_deletions'])];
    }
    return _stableJson(normalized(a)) == _stableJson(normalized(b));
  }

  /// 把远端记录合到本地书（进度/书签各按自己的时间新者胜），返回是否改动。
  Future<bool> applyRemote(String bookId, Map<String, dynamic> rec) async {
    final progressData = rec['progress'];
    final metadataVersion = _num(rec['metadata_at']) ??
        (progressData is! Map || progressData.isEmpty ? _num(rec['updated_at']) ?? 0.0 : 0.0);
    var changed = await storage.applyBookActivity(bookId, metadataVersion);
    final local = await storage.loadProgress(bookId);
    final localUpd = local?.updatedAt ?? 0.0;
    // schema 1 老记录没有 progress_at，用整体 updated_at 兜底
    final remoteUpd = _num(rec['progress_at']) ?? _num(rec['updated_at']) ?? 0.0;
    final rp = rec['progress'];
    if (rp is Map && rp.isNotEmpty && remoteUpd > localUpd + timeTol) {
      final accepted = await storage.trySaveProgress(
        _remoteProgress(bookId, rec, fallbackPercent: local?.percent ?? 0), remote: true);
      changed = changed || accepted;
    }
    final remoteBms = <Map<String, dynamic>>[];
    final rb = rec['bookmarks'];
    if (rb is List) {
      for (final x in rb) {
        if (x is Map) remoteBms.add(x.cast<String, dynamic>());
      }
    }
    final bmChanged = await annotations.mergeBookmarks(bookId, remoteBms,
      deletions: AnnotationStore.deletionVersions(rec['bookmark_deletions']),
      updatedAt: _num(rec['bookmarks_at']) ?? 0, remote: true);
    changed = bmChanged || changed;
    return changed;
  }

  // ---------------------------------------------------------------- 主流程

  Future<SyncReport> sync() async {
    final report = SyncReport();
    if (_coordinator != null) {
      report.error = '已有同步任务在进行';
      return report;
    }
    final operation = Object();
    _coordinator = operation;
    try {
      final s = await settings();
      if (!configured(s)) {
        report.error = '未配置 WebDAV 服务器地址';
        return report;
      }
      final cli = client(s);
      await prepareRemote(cli);
      final (deviceId, deviceName) = await ensureDevice(s);
      var local = await localRecords(s, deviceName);
      final remote = await readRemoteBooks(cli);
      await _checkConfig(s);
      final metaById = {for (final m in await storage.loadBooks()) m.id: m};
      final keyByAlias = <String, String>{
        for (final m in metaById.values)
          for (final id in [m.id, ...m.aliases]) id: m.contentKey.trim().isEmpty ? m.id : m.contentKey.trim(),
      };
      var deletions = await storage.loadDeletions();
      // 删除过的所有 key（含老书兜底用的 book id），用于挡住"删掉的旧记录被当远端独有书导回"
      final deadKeys = <String, double>{};
      for (final e in deletions.entries) {
        final v = e.value is Map ? (e.value as Map) : const {};
        final t = _num(v['deleted_at']) ?? 0.0;
        if (t <= 0) continue;
        deadKeys[e.key] = t;
        final idk = (v['id_key'] as String? ?? '').trim();
        if (idk.isNotEmpty) deadKeys[idk] = t;
        for (final id in (v['id_keys'] as List?)?.whereType<String>() ?? const <String>[]) {
          deadKeys[id] = t;
        }
      }

      // Read all known live aliases before deciding any logical-book deletion.
      // PROPFIND order must not let an old alias tombstone erase a newer event.
      final pulledKeys = <String>{};
      final remoteLiveActivity = <String, double>{};
      for (final entry in remote.entries) {
        final key = keyByAlias[entry.key] ?? entry.key;
        final item = local[key];
        final rec = entry.value;
        if (item == null || rec['deleted'] == true) continue;
        await _checkConfig(s);
        final activity = <double>[_num(rec['updated_at']) ?? 0.0, _num(rec['progress_at']) ?? 0.0,
          _num(rec['bookmarks_at']) ?? 0.0, _num(rec['metadata_at']) ?? 0.0]
            .reduce((a, b) => a > b ? a : b);
        if (activity > (remoteLiveActivity[key] ?? 0)) remoteLiveActivity[key] = activity;
        if (await applyRemote(item.key, rec)) pulledKeys.add(key);
      }

      // 1) 远端更新 → 拉到本地；远端删除 → 本机也删；远端独有的书尝试下载书源并入书架
      for (final entry in remote.entries) {
        await _checkConfig(s);
        final key = keyByAlias[entry.key] ?? entry.key;
        final rec = entry.value;

        if (rec['deleted'] != true && rec['progress'] is Map && (rec['progress'] as Map).isNotEmpty &&
            _remoteProgress(key, rec).ambiguousPercent != null) report.ambiguousProgress++;

        if (rec['deleted'] == true) {
          final tomb = _num(rec['deleted_at']) ?? _num(rec['updated_at']) ?? 0.0;
          final item = local[key];
          if (item != null) {
            final meta = metaById[item.key];
            final prog = await storage.loadProgress(item.key);
            final lBms = await annotations.loadRawBookmarks(item.key);
            var activity = meta == null
                ? (prog?.updatedAt ?? 0.0)
                : [bookActivity(meta, prog, lBms), await annotations.loadBookmarksAt(item.key)]
                    .reduce((a, b) => a > b ? a : b);
            if ((remoteLiveActivity[key] ?? 0) > activity) activity = remoteLiveActivity[key]!;
            // 本地这本书在删除之后又被读过/加了书签/重新导入 = 用户又用起来了，复活。
            // Imported/display addedAt never counts as a new user event.
            if (activity > tomb) {
              report.skipped++;
              continue;
            }
            await storage.removeBook(item.key, deletedAt: tomb, remote: true);
            if ((await storage.loadBooks()).any((book) => book.id == item.key)) continue;
            report.removed++;
            report.removedIds.add(item.key);
            local.remove(key);
            report.lines.add('✕ 已删除 ${item.value['title'] ?? rec['title'] ?? key}（对端删除）');
          }
          // 远端已删且本机也没有：记下墓碑，避免以后又把这本书拉回来
          await storage.markDeleted(key, (rec['title'] as String?) ?? '', deletedAt: tomb);
          deletions[key] = {'deleted_at': tomb, 'title': rec['title'] ?? ''};
          await _dropRemoteSource(cli, entry.key, rec);
          continue;
        }

        // 本机删过、且删除比远端记录更新 → 让本机的删除生效（下面会推墓碑）
        final dent = deletions[key];
        if (dent is Map &&
            ((_num(dent['deleted_at']) ?? 0.0) >= (_num(rec['updated_at']) ?? 0.0))) {
          continue;
        }
        // 本机删过这本书的「旧 key」（当初用 book id 上传的孤儿记录）→ 不能当远端独有书导入回来
        if (deadKeys[key] != null &&
            deadKeys[key]! >= (_num(rec['updated_at']) ?? 0.0)) {
          continue;
        }

        final item = local[key];
        if (item == null) {
          final title = (rec['title'] as String? ?? '').trim();
          if (await _importRemote(cli, key, rec, checkConfig: () => _checkConfig(s))) {
            report.imported++;
            report.lines.add('↓ 新增 ${title.isEmpty ? key : title}');
          } else {
            report.remoteOnly.add(title.isEmpty ? key : title);
          }
          continue;
        }

        // Union every ID/deletion before any replacement upload. An aggregate
        // clock cannot prove the other device has no distinct older bookmarks.
        if (pulledKeys.remove(key) || await applyRemote(item.key, rec)) {
            report.pulled++;
            report.lines.add('↓ ${item.value['title'] ?? key}（远端更新）');
        } else {
          report.skipped++;
        }
      }

      local = await localRecords(s, deviceName);
      deletions = await storage.loadDeletions();

      // 2) 本地更新 → 推到远端（进度/书签任一字段更新就推整条）
      for (final entry in local.entries) {
        await _checkConfig(s);
        final key = entry.key;
        var rec = entry.value.value;
        final rrec = remote[key];
        if (rrec != null && rrec['deleted'] != true) {
          final lPat = _num(rec['progress_at']) ?? 0.0;
          final rPat = _num(rrec['progress_at']) ?? _num(rrec['updated_at']) ?? 0.0;
          final lBat = _num(rec['bookmarks_at']) ?? 0.0;
          final rBat = _num(rrec['bookmarks_at']) ?? _num(rrec['updated_at']) ?? 0.0;
          final metadataChanged = (_num(rec['metadata_at']) ?? 0) > (_num(rrec['metadata_at']) ?? 0);
          final bookmarksChanged = !_sameBookmarkState(rec, rrec);
          if (lPat <= rPat + timeTol && lBat <= rBat && !metadataChanged && !bookmarksChanged) continue;
          // Bookmark/metadata uploads must not replace more authoritative progress.
          if (rPat > lPat) {
            rec = {...rec, 'progress': rrec['progress'], 'progress_at': rPat,
              'updated_at': [rPat, _num(rec['updated_at']) ?? 0].reduce((a, b) => a > b ? a : b)};
          }
        }
        rec = {...?rrec, ...rec}..remove('deleted')..remove('deleted_at');
        await cli.put(_bookPath(key), utf8.encode(jsonEncode(rec)));
        remote[key] = rec;
        report.pushed++;
        report.lines.add('↑ ${rec['title'] ?? key}');
      }

      // 2.2) 本地删除 → 远端墓碑
      final nowS = DateTime.now().millisecondsSinceEpoch / 1000.0;
      for (final e in deletions.entries.toList()) {
        await _checkConfig(s);
        final key = e.key;
        final dent = e.value is Map ? (e.value as Map).cast<String, dynamic>() : <String, dynamic>{};
        if (local.containsKey(key)) {
          // 书还在本地（刚重新导入）= 撤销墓碑，不再推删除
          await storage.clearDeletion(key);
          continue;
        }
        final dT = _num(dent['deleted_at']) ?? 0.0;
        if (dT <= 0) continue;
        if (nowS - dT > tombstoneTtl) {
          await storage.clearDeletion(key);
          continue;
        }
        final aliases = <String>{key,
          if (dent['id_key'] is String) dent['id_key'] as String,
          ...((dent['id_keys'] as List?)?.whereType<String>() ?? const <String>[]),
        }..remove('');
        for (final alias in aliases) {
          final rrec = remote[alias];
          if (alias != key && rrec == null) continue;
          if (rrec != null && (rrec['deleted'] == true
              ? dT <= (_num(rrec['deleted_at']) ?? 0.0)
              : (_num(rrec['updated_at']) ?? 0.0) > dT)) continue;
          await cli.put(_bookPath(alias), utf8.encode(jsonEncode(tombstoneRecord(alias, dent, deviceName))));
          report.deleted++;
          report.lines.add('↑ 删除事件 ${dent['title'] ?? alias}');
          await _dropRemoteSource(cli, alias, rrec ?? <String, dynamic>{});
        }
      }

      // 2.5) 清理历史遗留：旧版安卓 contentKey 为空时用 book id 当 key 上传，
      // 回填 ck2 后再按新 key 推一次，远端那条旧记录就成了孤儿（表现为「远端未导入」）。
      // 只删“key 正是本机 book id”的文件，不会碰到别的设备/书。
      for (final entry in local.entries) {
        await _checkConfig(s);
        final matching = (await storage.loadBooks()).where((book) => book.id == entry.value.key);
        final meta = matching.isEmpty ? null : matching.first;
        for (final idKey in [entry.value.key, ...?meta?.aliases]) {
          if (entry.key == idKey || !remote.containsKey(idKey)) continue;
          final alias = remote[idKey]!;
          final canonical = remote[entry.key];
          if (alias['deleted'] != true && (_num(alias['progress_at']) ?? _num(alias['updated_at']) ?? 0) >
              (_num(canonical?['progress_at']) ?? _num(canonical?['updated_at']) ?? 0)) continue;
          try {
            await cli.delete(_bookPath(idKey));
            report.lines.add('清理旧记录 $idKey');
          } on WebDavException {
            // 删不掉不影响本次同步结果
          }
        }
      }

      // 2.6) 书源文件：只补远端缺的（本机独有的书，桌面靠它落地）
      final haveSources = <String>{};
      for (final e in await cli.propfind(_sourcesDir)) {
        if (!e.isDir) haveSources.add(e.name.toLowerCase());
      }
      final booksNow = await storage.loadBooks();
      for (final meta in booksNow) {
        await _checkConfig(s);
        final key = meta.contentKey.trim().isNotEmpty ? meta.contentKey.trim() : meta.id;
        final ext = _extOf(meta.format);
        final name = '$key$ext'.toLowerCase();
        if (haveSources.contains(name)) continue;
        final bytes = await _readSourceFile(meta.filePath);
        if (bytes == null) continue;
        try {
          await cli.put('$_sourcesDir/$key$ext', bytes,
              atomic: false, contentType: 'application/octet-stream');
          report.sourceUploaded++;
          haveSources.add(name);
        } on WebDavException catch (e) {
          report.lines.add('上传书源失败「${meta.title}」：${e.message}');
        }
      }

      // 3) 设备登记
      try {
        await cli.put(
          '$_devicesDir/$deviceId.json',
          utf8.encode(jsonEncode({
            'schema': schemaVersion,
            'device_id': deviceId,
            'device_name': deviceName,
            'last_sync': _round(DateTime.now().millisecondsSinceEpoch / 1000.0),
            'book_count': local.length,
            'platform': 'Android',
          })),
        );
      } on WebDavException {
        // 设备登记失败不影响主流程
      }

      await storage.updateSettings((current) {
        if (_configIdentity(current) != _configIdentity(s)) throw WebDavException('同步配置已更改，请重新同步');
        return {cfgLastTime: _round(DateTime.now().millisecondsSinceEpoch / 1000.0)};
      });
      report.ok = true;
      return report;
    } on WebDavException catch (e) {
      report.error = e.message;
      return report;
    } catch (e) {
      report.error = '同步失败：$e';
      return report;
    } finally {
      if (identical(_coordinator, operation)) _coordinator = null;
    }
  }

  // ---------------------------------------------------------------- 反向拉取

  /// 远端独有的书：下载 v1/sources 里的源文件 → 落到应用私有目录 → 解析校验 ck2
  /// → 入书架并套上远端进度与书签。任何一步不成立都只回一条日志，不产生空书。
  Future<bool> _importRemote(WebDavClient cli, String key, Map<String, dynamic> rec,
      {Future<void> Function()? checkConfig}) async {
    final src = rec['source'];
    final wantExt = (src is Map ? (src['ext'] as String? ?? '') : '').toLowerCase();
    final srcSize = src is Map ? ((src['size'] as num?)?.toInt() ?? 0) : 0;
    final title = (rec['title'] as String? ?? '').trim();
    if (srcSize > maxSourceBytes) {
      return false;
    }

    final candidates = <String>[
      if (const {'.txt', '.epub', '.pdf', '.docx'}.contains(wantExt)) wantExt,
      '.txt',
      '.epub',
      '.pdf',
    ];
    List<int>? bytes;
    var usedExt = '';
    for (final e in candidates) {
      try {
        bytes = await cli.get('$_sourcesDir/$key$e');
      } on WebDavException {
        bytes = null;
      }
      if (bytes != null && bytes.isNotEmpty) {
        usedExt = e;
        break;
      }
    }
    if (bytes == null || usedExt.isEmpty || bytes.length > maxSourceBytes) {
      return false; // 老记录没有源文件：只计数，不入书架
    }
    await checkConfig?.call();

    final dir = await _sourceDir();
    var path = '${dir.path}/$key$usedExt';
    if (await File(path).exists()) {
      final existing = await File(path).readAsBytes();
      if (!_sameBytes(existing, bytes)) {
        var suffix = 1;
        do { path = '${dir.path}/$key.remote-${suffix++}$usedExt'; } while (await File(path).exists());
        await File(path).writeAsBytes(bytes, flush: true);
      }
    } else {
      await File(path).writeAsBytes(bytes, flush: true);
    }

    final fmt = usedExt.replaceAll('.', '');
    final parsed = await _parseFor(path, fmt, title.isEmpty ? key : title);
    if (parsed == null) return false;
    final (chapters, total, ck) = parsed;
    if (ck != key) {
      // 分章口径不一致会让 key 漂移：宁可不导入，也不要造一本对不上的书
      return false;
    }
    await checkConfig?.call();

    final id = key;
    await storage.addBook(BookMeta(
      id: id,
      title: title.isEmpty ? key : title,
      filePath: path,
      format: fmt,
      addedAt: DateTime.now(),
      contentKey: key,
      totalChars: total,
      chapterCount: chapters,
    ), remote: true, activityAt: _num(rec['metadata_at']) ?? _num(rec['updated_at']) ?? 0,
        remoteVersion: _num(rec['updated_at']) ?? 0);
    if (!(await storage.loadBooks()).any((book) => book.id == id || book.aliases.contains(id))) return false;
    await applyRemote(id, rec);
    return true;
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) { if (a[i] != b[i]) return false; }
    return true;
  }

  /// 删除事件生效后清掉远端书源文件：省网盘空间，也避免正文残留在远端。
  Future<void> _dropRemoteSource(WebDavClient cli, String key, Map<String, dynamic> rec) async {
    final src = rec['source'];
    final wantExt = (src is Map ? (src['ext'] as String? ?? '') : '').toLowerCase();
    final candidates = <String>[
      if (const {'.txt', '.epub', '.pdf', '.docx'}.contains(wantExt)) wantExt,
      '.txt',
      '.epub',
      '.pdf',
    ];
    for (final e in candidates) {
      try {
        await cli.delete('$_sourcesDir/$key$e');
      } on WebDavException {
        // 远端没有这个文件（404）不影响同步
      }
    }
  }

  Future<Directory> _sourceDir() async {
    final base = sourceDirOverride;
    final d = base != null
        ? Directory(base)
        : Directory('${(await getApplicationDocumentsDirectory()).path}/$_docsBooksSub');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// 解析源文件，返回 (章节数, 总字数, ck2)。解析放后台 isolate，避免阻塞 UI。
  Future<(int, int, String)?> _parseFor(String path, String format, String title) async {
    try {
      final r = await Isolate.run(() async {
        final b = await BookParser().parse(
          id: 'probe',
          filePath: path,
          title: title,
          format: BookFormatX.fromExt('.$format'),
          addedAt: DateTime.now(),
        );
        return <Object?>[b.parseOk, b.chapterCount, b.totalDisplayLength, b.contentKey];
      });
      if (r[0] != true) return null;
      return (r[1] as int, r[2] as int, r[3] as String);
    } catch (_) {
      return null;
    }
  }

  Future<(bool, String)> testConnection() async {
    if (_coordinator != null) return (false, '已有同步任务在进行');
    final operation = Object();
    _coordinator = operation;
    try {
      final s = await settings();
      if (!configured(s)) return (false, '未配置 WebDAV 服务器地址');
      final cli = client(s);
      await prepareRemote(cli);
      final entries = await cli.propfind(_booksDir);
      await _checkConfig(s);
      final n = entries
          .where((e) => !e.isDir && e.name.toLowerCase().endsWith('.json'))
          .length;
      return (true, '连接成功，远端已有 $n 本书记录');
    } on WebDavException catch (e) {
      return (false, e.message);
    } catch (e) {
      return (false, '连接失败：$e');
    } finally {
      if (identical(_coordinator, operation)) _coordinator = null;
    }
  }
}
