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
  /// 补传到 v1/sources 的源文件个数
  int sourceUploaded = 0;
  final List<String> remoteOnly = [];
  final List<String> lines = [];
  String error = '';

  String get summary {
    if (!ok) return error;
    final b = StringBuffer('同步完成：上传 $pushed 本，拉取 $pulled 本，跳过 $skipped 本');
    if (imported > 0) b.write('，新增 $imported 本');
    if (sourceUploaded > 0) b.write('，补传书源 $sourceUploaded 个');
    if (remoteOnly.isNotEmpty) {
      b.write('；远端有 ${remoteOnly.length} 本本机未导入（无源文件）');
    }
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
/// 冲突策略（照抄 PC，不解自创）：
///   - 进度：updated_at 新者胜（差值 > 0.5 秒才算更新）
///   - 书签：按 id 取并集，同 id 取 created_at 较新的一份，任何一边都不会丢
class SyncEngine {
  static const schemaVersion = 1;
  static const remoteDirDefault = WebDavClient.defaultRemoteDir;

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

  bool _running = false;

  SyncEngine({
    required this.storage,
    required this.annotations,
    this.sourceDirOverride,
  });

  // ---------------------------------------------------------------- 配置

  Future<Map<String, dynamic>> settings() => storage.loadSettings();

  Future<void> saveSettings(Map<String, dynamic> s) => storage.saveSettings(s);

  /// 确保本机有稳定的 device_id / device_name，返回 (id, name)。
  Future<(String, String)> ensureDevice(Map<String, dynamic> s) async {
    var id = (s[cfgDeviceId] as String? ?? '').trim();
    if (id.isEmpty) {
      final name = (s[cfgDeviceName] as String? ?? '').trim();
      id = _newDeviceId(name.isEmpty ? _platformName() : name);
      s[cfgDeviceId] = id;
    }
    final name = (s[cfgDeviceName] as String? ?? '').trim();
    if (name.isEmpty) {
      s[cfgDeviceName] = _platformName();
    }
    await saveSettings(s);
    return (id, (s[cfgDeviceName] as String? ?? _platformName()).trim());
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
    final books = await storage.loadBooks();
    final out = <String, MapEntry<String, Map<String, dynamic>>>{};
    for (final meta in books) {
      final key = meta.contentKey.trim().isNotEmpty ? meta.contentKey.trim() : meta.id;
      final progress = await storage.loadProgress(meta.id);
      final bms = await annotations.loadRawBookmarks(meta.id);
      var updated = progress?.updatedAt ?? 0.0;
      for (final bm in bms) {
        final t = (bm['created_at'] as num?)?.toDouble() ??
            (bm['createdAt'] != null
                ? (DateTime.tryParse(bm['createdAt'] as String)?.millisecondsSinceEpoch ?? 0) / 1000.0
                : 0.0);
        if (t > updated) updated = t;
      }
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
                'updated_at': progress.updatedAt,
              },
        'bookmarks': bms,
        'updated_at': _round(updated),
        'device': deviceName,
        'synced_at': _round(DateTime.now().millisecondsSinceEpoch / 1000.0),
      });
    }
    return out;
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
      if (raw == null || raw.isEmpty) continue;
      Map<String, dynamic> rec;
      try {
        rec = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
      } catch (_) {
        continue; // 远端文件不是合法 JSON，跳过
      }
      final ck = (rec['content_key'] as String? ?? '').trim();
      if (ck.isEmpty) continue;
      out[ck] = rec;
    }
    return out;
  }

  // ---------------------------------------------------------------- 合并

  /// 书签按 id 取并集；同 id 取 created_at 较新的一份。返回 (并集, 是否变化)
  static (List<Map<String, dynamic>>, bool) mergeBookmarks(
    List<Map<String, dynamic>> local,
    List<Map<String, dynamic>> remote,
  ) {
    final merged = <String, Map<String, dynamic>>{};
    var changed = false;
    for (final bm in local) {
      final id = (bm['id'] ?? '').toString();
      if (id.isEmpty) continue;
      merged[id] = bm;
    }
    for (final bm in remote) {
      final id = (bm['id'] ?? '').toString();
      if (id.isEmpty) continue;
      final cur = merged[id];
      if (cur == null) {
        merged[id] = bm;
        changed = true;
        continue;
      }
      if (_createdAt(bm) > _createdAt(cur)) {
        merged[id] = bm;
        changed = true;
      }
    }
    final list = merged.values.toList()
      ..sort((a, b) => _createdAt(a).compareTo(_createdAt(b)));
    return (list, changed);
  }

  static double _createdAt(Map<String, dynamic> bm) {
    final c = bm['created_at'];
    if (c is num) return c.toDouble();
    final d = bm['createdAt'];
    if (d is String) {
      return (DateTime.tryParse(d)?.millisecondsSinceEpoch ?? 0) / 1000.0;
    }
    return 0;
  }

  /// 把远端记录合到本地书，返回是否改动。
  Future<bool> applyRemote(String bookId, Map<String, dynamic> rec) async {
    var changed = false;
    final local = await storage.loadProgress(bookId);
    final localUpd = local?.updatedAt ?? 0.0;
    final remoteUpd = (rec['updated_at'] as num?)?.toDouble() ?? 0.0;
    final rp = rec['progress'];
    if (rp is Map && rp.isNotEmpty && remoteUpd > localUpd + 0.5) {
      final p = BookProgress.fromPcJson(bookId, rp.cast<String, dynamic>());
      await storage.saveProgress(
        BookProgress(
          bookId: bookId,
          chapterIndex: p.chapterIndex,
          paragraphIndex: p.paragraphIndex,
          offsetInParagraph: p.offsetInParagraph,
          percent: p.percent,
          updatedAt: remoteUpd > 0 ? remoteUpd : p.updatedAt,
          charOffsetInChapter: p.charOffsetInChapter,
          pcCharOffset: p.pcCharOffset,
        ),
      );
      changed = true;
    }
    final remoteBms = <Map<String, dynamic>>[];
    final rb = rec['bookmarks'];
    if (rb is List) {
      for (final x in rb) {
        if (x is Map) remoteBms.add(x.cast<String, dynamic>());
      }
    }
    if (remoteBms.isNotEmpty) {
      final localBms = await annotations.loadRawBookmarks(bookId);
      final (merged, bmChanged) = mergeBookmarks(localBms, remoteBms);
      if (bmChanged || localBms.isEmpty) {
        await annotations.saveRawBookmarks(bookId, merged);
        changed = true;
      }
    }
    return changed;
  }

  // ---------------------------------------------------------------- 主流程

  Future<SyncReport> sync() async {
    final report = SyncReport();
    final s = await settings();
    if (!configured(s)) {
      report.error = '未配置 WebDAV 服务器地址';
      return report;
    }
    if (_running) {
      report.error = '已有同步任务在进行';
      return report;
    }
    _running = true;
    try {
      final cli = client(s);
      await prepareRemote(cli);
      final (deviceId, deviceName) = await ensureDevice(s);
      var local = await localRecords(s, deviceName);
      final remote = await readRemoteBooks(cli);

      // 1) 远端更新 → 拉到本地；远端独有的书尝试下载书源并入书架
      var localUpdated = 0;
      var imported = 0;
      for (final entry in remote.entries) {
        final key = entry.key;
        final rec = entry.value;
        final item = local[key];
        if (item == null) {
          final title = (rec['title'] as String? ?? '').trim();
          if (await _importRemote(cli, key, rec)) {
            imported++;
            report.imported++;
            report.lines.add('↓ 新增 ${title.isEmpty ? key : title}');
          } else {
            report.remoteOnly.add(title.isEmpty ? key : title);
          }
          continue;
        }
        final lUpd = (item.value['updated_at'] as num?)?.toDouble() ?? 0.0;
        final rUpd = (rec['updated_at'] as num?)?.toDouble() ?? 0.0;
        if (rUpd > lUpd + 0.5) {
          if (await applyRemote(item.key, rec)) {
            localUpdated++;
            report.pulled++;
            report.lines.add('↓ ${item.value['title'] ?? key}（远端更新）');
          }
        } else {
          report.skipped++;
        }
      }

      if (localUpdated > 0 || imported > 0) {
        local = await localRecords(s, deviceName);
      }

      // 2) 本地更新 → 推到远端
      for (final entry in local.entries) {
        final key = entry.key;
        final rec = entry.value.value;
        final rrec = remote[key];
        if (rrec != null) {
          final lUpd = (rec['updated_at'] as num?)?.toDouble() ?? 0.0;
          final rUpd = (rrec['updated_at'] as num?)?.toDouble() ?? 0.0;
          if (lUpd <= rUpd + 0.5) continue;
        }
        await cli.put(_bookPath(key), utf8.encode(jsonEncode(rec)));
        report.pushed++;
        report.lines.add('↑ ${rec['title'] ?? key}');
      }

      // 2.5) 清理历史遗留：旧版安卓 contentKey 为空时用 book id 当 key 上传，
      // 回填 ck2 后再按新 key 推一次，远端那条旧记录就成了孤儿（表现为「远端未导入」）。
      // 只删“key 正是本机 book id”的文件，不会碰到别的设备/书。
      for (final entry in local.entries) {
        final idKey = entry.value.key;
        if (entry.key == idKey) continue; // 本机仍没回填，保留旧记录
        if (!remote.containsKey(idKey)) continue;
        try {
          await cli.delete(_bookPath(idKey));
          report.lines.add('清理旧记录 $idKey');
        } on WebDavException {
          // 删不掉不影响本次同步结果
        }
      }

      // 2.6) 书源文件：只补远端缺的（本机独有的书，桌面靠它落地）
      final haveSources = <String>{};
      try {
        for (final e in await cli.propfind(_sourcesDir)) {
          if (!e.isDir) haveSources.add(e.name.toLowerCase());
        }
      } on WebDavException {
        await cli.mkdirs(_sourcesDir);
      }
      final booksNow = await storage.loadBooks();
      for (final meta in booksNow) {
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

      s[cfgLastTime] = _round(DateTime.now().millisecondsSinceEpoch / 1000.0);
      await saveSettings(s);
      report.ok = true;
      return report;
    } on WebDavException catch (e) {
      report.error = e.message;
      return report;
    } catch (e) {
      report.error = '同步失败：$e';
      return report;
    } finally {
      _running = false;
    }
  }

  // ---------------------------------------------------------------- 反向拉取

  /// 远端独有的书：下载 v1/sources 里的源文件 → 落到应用私有目录 → 解析校验 ck2
  /// → 入书架并套上远端进度与书签。任何一步不成立都只回一条日志，不产生空书。
  Future<bool> _importRemote(WebDavClient cli, String key, Map<String, dynamic> rec) async {
    final src = rec['source'];
    final wantExt = (src is Map ? (src['ext'] as String? ?? '') : '').toLowerCase();
    final srcSize = src is Map ? ((src['size'] as num?)?.toInt() ?? 0) : 0;
    final title = (rec['title'] as String? ?? '').trim();
    if (srcSize > maxSourceBytes) {
      return false;
    }

    final candidates = <String>[
      if (wantExt.isNotEmpty) wantExt,
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
    if (bytes == null || usedExt.isEmpty) {
      return false; // 老记录没有源文件：只计数，不入书架
    }

    final dir = await _sourceDir();
    final path = '${dir.path}/$key$usedExt';
    await File(path).writeAsBytes(bytes, flush: true);

    final fmt = usedExt.replaceAll('.', '');
    final parsed = await _parseFor(path, fmt, title.isEmpty ? key : title);
    if (parsed == null) return false;
    final (chapters, total, ck) = parsed;
    if (ck != key) {
      // 分章口径不一致会让 key 漂移：宁可不导入，也不要造一本对不上的书
      return false;
    }

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
    ));

    final rp = rec['progress'];
    if (rp is Map && rp.isNotEmpty) {
      final p = BookProgress.fromPcJson(id, rp.cast<String, dynamic>());
      final upd = (rec['updated_at'] as num?)?.toDouble() ?? p.updatedAt;
      await storage.saveProgress(BookProgress(
        bookId: id,
        chapterIndex: p.chapterIndex,
        paragraphIndex: p.paragraphIndex,
        offsetInParagraph: p.offsetInParagraph,
        percent: p.percent,
        updatedAt: upd,
        charOffsetInChapter: p.charOffsetInChapter,
        pcCharOffset: p.pcCharOffset,
      ));
    }
    final rb = rec['bookmarks'];
    if (rb is List && rb.isNotEmpty) {
      final list = rb.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      await annotations.saveRawBookmarks(id, list);
    }
    return true;
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
    final s = await settings();
    if (!configured(s)) {
      return (false, '未配置 WebDAV 服务器地址');
    }
    try {
      final cli = client(s);
      await prepareRemote(cli);
      final entries = await cli.propfind(_booksDir);
      final n = entries
          .where((e) => !e.isDir && e.name.toLowerCase().endsWith('.json'))
          .length;
      return (true, '连接成功，远端已有 $n 本书记录');
    } on WebDavException catch (e) {
      return (false, e.message);
    } catch (e) {
      return (false, '连接失败：$e');
    }
  }
}
