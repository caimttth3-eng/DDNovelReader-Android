import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:duoduo_langdu/models/book.dart';
import 'package:duoduo_langdu/models/progress.dart';
import 'package:duoduo_langdu/services/annotation_store.dart';
import 'package:duoduo_langdu/services/app_storage.dart';
import 'package:duoduo_langdu/services/sync_engine.dart';
import 'package:duoduo_langdu/services/webdav_client.dart';

/// 1.3.4 专项：字段级合并 / push-pull 三模式 / dryRun 预览 / ETag 412 重试。
/// 用内存版 WebDAV（不联网），远端文件直接放在 files 里。

class _FakeDav extends WebDavClient {
  final Map<String, List<int>> files = {};
  final Map<String, String> etags = {};
  int puts = 0;
  /// 下一次带 If-Match 的 PUT 先让对端"抢先写一次"再回 412（只触发一次）
  bool conflictOnce = false;
  Map<String, dynamic>? concurrentRec;

  _FakeDav() : super(server: 'http://fake.local/dav', verifyTls: false);

  String _relOf(String path) => path;

  @override
  Future<List<WebDavEntry>> propfind([String rel = '', String depth = '1']) async {
    final prefix = rel.isEmpty ? '' : '$rel/';
    final out = <WebDavEntry>[];
    for (final e in files.entries) {
      if (!e.key.startsWith(prefix)) continue;
      final rest = e.key.substring(prefix.length);
      if (rest.contains('/')) continue;
      out.add(WebDavEntry(
        name: rest,
        rel: e.key,
        isDir: false,
        size: e.value.length,
        etag: etags[e.key] ?? '',
      ));
    }
    return out;
  }

  @override
  Future<List<int>?> get(String rel) async => files[_relOf(rel)];

  @override
  Future<bool> put(String rel, List<int> data,
      {bool atomic = true,
      String? etag,
      String contentType = 'application/json; charset=utf-8'}) async {
    if (etag != null && etag.isNotEmpty) {
      if (conflictOnce) {
        conflictOnce = false;
        if (concurrentRec != null) {
          files[rel] = utf8.encode(jsonEncode(concurrentRec));
          etags[rel] = 'concurrent';
        }
        throw WebDavException('HTTP 412 PUT', 412);
      }
      final cur = etags[rel] ?? '';
      if (cur.isNotEmpty && cur != etag) {
        throw WebDavException('HTTP 412 PUT', 412);
      }
    }
    files[rel] = data;
    puts++;
    etags[rel] = 'v${puts}';
    return true;
  }

  @override
  Future<bool> delete(String rel) async {
    files.remove(rel);
    etags.remove(rel);
    return true;
  }

  @override
  Future<void> mkdirs(String rel) async {}

  @override
  Future<bool> mkdir(String rel) async => true;
}

class _Eng extends SyncEngine {
  final _FakeDav dav;
  _Eng({required super.storage, required super.annotations, required this.dav});

  @override
  WebDavClient client(Map<String, dynamic> s) => dav;
}

Map<String, dynamic> remoteRec(String key, {
  int chapter = 1,
  double progressAt = 0,
  List<Map<String, dynamic>> bookmarks = const [],
  double bookmarksAt = 0,
}) => {
      'schema': 2,
      'content_key': key,
      'content_key_version': 'ck2',
      'title': '远端书',
      'author': '',
      'format': 'txt',
      'total_chars': 1000,
      'chapter_count': 5,
      'progress': {'chapter_idx': chapter, 'char_offset': 0, 'percent': chapter * 20.0},
      'progress_at': progressAt,
      'bookmarks': bookmarks,
      'bookmarks_at': bookmarksAt,
      'updated_at': progressAt > bookmarksAt ? progressAt : bookmarksAt,
    };

BookMeta meta(String id, String key, {String title = '本机书', DateTime? added}) => BookMeta(
      id: id,
      title: title,
      filePath: '/books/$id.txt',
      format: 'txt',
      addedAt: added ?? DateTime(2026, 1, 1),
      contentKey: key,
      totalChars: 1000,
      chapterCount: 5,
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<(_Eng, _FakeDav, AppStorage)> setup(
    List<BookMeta> books, {
    Map<String, List<int>>? remote,
    Map<String, String>? etags,
    Map<String, BookProgress>? progress,
  }) async {
    final dav = _FakeDav();
    if (remote != null) {
      dav.files.addAll(remote);
      dav.etags.addAll(etags ?? {});
    }
    final storage = AppStorage();
    await storage.saveSettings({
      SyncEngine.cfgServer: 'http://fake.local/dav',
      SyncEngine.cfgUser: 'demo',
      SyncEngine.cfgPass: 'demo',
      SyncEngine.cfgDir: 'DD/Test',
      SyncEngine.cfgVerifyTls: false,
      SyncEngine.cfgDeviceName: 'Android-Test',
      SyncEngine.cfgAuto: false,
    });
    await storage.saveBooks(books);
    if (progress != null) {
      for (final e in progress.entries) {
        await storage.saveProgress(e.value);
      }
    }
    final eng = _Eng(storage: storage, annotations: AnnotationStore(), dav: dav);
    return (eng, dav, storage);
  }

  test('mergeRecord：对端新进度胜出，本机新书签并集，谁也不被整条覆盖', () {
    final local = <String, dynamic>{
      'content_key': 'ck1',
      'title': '本机书',
      'progress': {'chapter_idx': 1, 'char_offset': 0, 'percent': 20.0},
      'progress_at': 100.0,
      'bookmarks': [
        {'id': 'b1', 'created_at': 300.0, 'chapter_idx': 0}
      ],
      'bookmarks_at': 300.0,
      'updated_at': 300.0,
    };
    final remote = <String, dynamic>{
      'schema': 2,
      'content_key': 'ck1',
      'title': '远端书',
      'format': 'txt',
      'progress': {'chapter_idx': 5, 'char_offset': 0, 'percent': 100.0},
      'progress_at': 400.0,
      'bookmarks': <Map<String, dynamic>>[],
      'bookmarks_at': 0.0,
      'updated_at': 400.0,
    };
    final m = SyncEngine.mergeRecord(local, remote, 'Android-Test');
    expect((m['progress'] as Map)['chapter_idx'], 5); // 对端新进度没被旧进度盖掉
    expect(m['progress_at'], closeTo(400.0, 0.01));
    expect((m['bookmarks'] as List).length, 1); // 本机书签并进去
    expect(((m['bookmarks'] as List).first as Map)['id'], 'b1');
    expect(m['bookmarks_at'], closeTo(300.0, 0.01));
    expect(m['updated_at'], closeTo(400.0, 0.01));
    expect(m['device'], 'Android-Test');
    expect(m.containsKey('_etag'), isFalse);
  });

  test('mergeRecord：远端是墓碑（复活）时用本机进度，并清掉 deleted 标记', () {
    final local = <String, dynamic>{
      'content_key': 'ck2',
      'title': '本机书',
      'progress': {'chapter_idx': 3, 'char_offset': 0, 'percent': 60.0},
      'progress_at': 130.0,
      'bookmarks': <Map<String, dynamic>>[],
      'bookmarks_at': 0.0,
      'updated_at': 130.0,
    };
    final tomb = <String, dynamic>{
      'schema': 2,
      'content_key': 'ck2',
      'progress': <String, dynamic>{},
      'progress_at': 0,
      'bookmarks': <Map<String, dynamic>>[],
      'bookmarks_at': 0,
      'deleted': true,
      'deleted_at': 128.0,
      'updated_at': 128.0,
    };
    final m = SyncEngine.mergeRecord(local, tomb, 'Android-Test');
    expect(m.containsKey('deleted'), isFalse);
    expect(m.containsKey('deleted_at'), isFalse);
    expect((m['progress'] as Map)['chapter_idx'], 3);
  });

  test('pushNeeded：只有本机真的更新/对端缺失才推', () {
    final local = <String, dynamic>{
      'content_key': 'ck1',
      'progress_at': 100.0,
      'bookmarks_at': 100.0,
      'bookmarks': [
        {'id': 'b1'}
      ],
    };
    final same = <String, dynamic>{
      'content_key': 'ck1',
      'progress_at': 100.0,
      'bookmarks_at': 100.0,
      'bookmarks': [
        {'id': 'b1'}
      ],
    };
    expect(SyncEngine.pushNeeded(local, same), isFalse);
    expect(SyncEngine.pushNeeded(local, null), isTrue);

    final localNewer = Map<String, dynamic>.from(local)..['progress_at'] = 200.0;
    expect(SyncEngine.pushNeeded(localNewer, same), isTrue);

    final localExtraBm = Map<String, dynamic>.from(local)
      ..['bookmarks'] = [
        {'id': 'b1'},
        {'id': 'b2'},
      ];
    expect(SyncEngine.pushNeeded(localExtraBm, same), isTrue);

    final tomb = Map<String, dynamic>.from(same)..['deleted'] = true;
    expect(SyncEngine.pushNeeded(local, tomb), isTrue);
  });

  test('push 模式：只往上写，不导入、不采纳远端', () async {
    final (eng, dav, storage) = await setup(
      [meta('b1', 'ck_local')],
      remote: {
        'v1/books/ck_remote.json': utf8.encode(jsonEncode(remoteRec('ck_remote', chapter: 4, progressAt: 500.0))),
      },
      etags: {'v1/books/ck_remote.json': 'r1'},
    );
    final rep = await eng.sync(mode: 'push');
    expect(rep.ok, isTrue, reason: rep.error);
    expect(rep.pushed, greaterThanOrEqualTo(1));
    expect(rep.imported, 0);
    expect(rep.pulled, 0);
    expect(dav.files.containsKey('v1/books/ck_local.json'), isTrue);
    expect((await storage.loadBooks()).length, 1); // 没导入远端书
  });

  test('pull 模式：只往下拉，本机独有书不上去', () async {
    final (eng, dav, storage) = await setup(
      [meta('b1', 'ck_local')],
      progress: {
        'b1': BookProgress(
          bookId: 'b1',
          chapterIndex: 1,
          paragraphIndex: 0,
          offsetInParagraph: 0,
          percent: 0.2,
          updatedAt: 100.0,
        ),
      },
      remote: {
        'v1/books/ck_local.json': utf8.encode(jsonEncode(remoteRec('ck_local', chapter: 5, progressAt: 900.0))),
      },
      etags: {'v1/books/ck_local.json': 'e1'},
    );
    final before = dav.files['v1/books/ck_local.json'];
    final rep = await eng.sync(mode: 'pull');
    expect(rep.ok, isTrue, reason: rep.error);
    expect(rep.pushed, 0);
    expect((await storage.loadProgress('b1'))!.chapterIndex, 5);
    // 远端记录一个字节都没被改写
    expect(dav.files['v1/books/ck_local.json'], before);
  });

  test('dryRun：只统计、不写（PUT 次数为 0）', () async {
    final (eng, dav, storage) = await setup(
      [meta('b1', 'ck_local')],
      progress: {
        'b1': BookProgress(
          bookId: 'b1',
          chapterIndex: 4,
          paragraphIndex: 0,
          offsetInParagraph: 0,
          percent: 0.8,
          updatedAt: 800.0,
        ),
      },
    );
    final rep = await eng.sync(mode: 'push', dryRun: true);
    expect(rep.ok, isTrue, reason: rep.error);
    expect(rep.dryRun, isTrue);
    expect(rep.pushed, greaterThanOrEqualTo(1));
    expect(dav.puts, 0);
    expect(dav.files.isEmpty, isTrue);
    expect((await storage.loadProgress('b1'))!.chapterIndex, 4);
  });

  test('412：对端在读取后又改过 → 重读重合并重写，两边改动都留下', () async {
    final localBm = {'id': 'bc', 'created_at': 700.0, 'chapter_idx': 0};
    final (eng, dav, storage) = await setup(
      [meta('b1', 'ck_conf')],
      remote: {
        'v1/books/ck_conf.json': utf8.encode(jsonEncode(remoteRec('ck_conf', chapter: 2, progressAt: 100.0))),
      },
      etags: {'v1/books/ck_conf.json': 'old'},
    );
    await AnnotationStore().saveRawBookmarks('b1', [localBm]);
    dav.conflictOnce = true;
    dav.concurrentRec = remoteRec('ck_conf', chapter: 5, progressAt: 950.0);
    final rep = await eng.sync();
    expect(rep.ok, isTrue, reason: rep.error);
    expect(rep.conflicts, 1);
    final rec = jsonDecode(utf8.decode(dav.files['v1/books/ck_conf.json']!)) as Map<String, dynamic>;
    expect((rec['progress'] as Map)['chapter_idx'], 5); // 对端更新胜出
    expect((rec['bookmarks'] as List).any((b) => (b as Map)['id'] == 'bc'), isTrue);
  });

  test('减量双向：本地删书推墓碑，对端墓碑让本机删除', () async {
    final (eng, dav, storage) = await setup(
      [meta('b1', 'ck_del_a'), meta('b2', 'ck_del_b')],
      remote: {
        'v1/books/ck_del_b.json': utf8.encode(jsonEncode({
          'schema': 2,
          'content_key': 'ck_del_b',
          'title': '对端删的书',
          'progress': <String, dynamic>{},
          'progress_at': 0,
          'bookmarks': <Map<String, dynamic>>[],
          'bookmarks_at': 0,
          'deleted': true,
          'deleted_at': DateTime.now().millisecondsSinceEpoch / 1000.0,
          'updated_at': DateTime.now().millisecondsSinceEpoch / 1000.0,
        })),
      },
    );
    await storage.removeBook('b1', deletedAt: DateTime.now().millisecondsSinceEpoch / 1000.0);
    final rep = await eng.sync();
    expect(rep.ok, isTrue, reason: rep.error);
    final tomb = jsonDecode(utf8.decode(dav.files['v1/books/ck_del_a.json']!)) as Map<String, dynamic>;
    expect(tomb['deleted'], isTrue);
    expect(rep.deleted, greaterThanOrEqualTo(1));
    expect(rep.removed, greaterThanOrEqualTo(1));
    expect((await storage.loadBooks()).any((b) => b.id == 'b2'), isFalse);
  });
}
