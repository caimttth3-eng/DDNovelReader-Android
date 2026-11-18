import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:duoduo_langdu/models/book.dart';
import 'package:duoduo_langdu/models/progress.dart';
import 'package:duoduo_langdu/services/annotation_store.dart';
import 'package:duoduo_langdu/services/app_storage.dart';
import 'package:duoduo_langdu/services/book_parser.dart';
import 'package:duoduo_langdu/services/sync_engine.dart';
import 'package:duoduo_langdu/services/webdav_client.dart';

/// 端到端：真跑 HTTP 打到本机 mock WebDAV（tools/mock_webdav.py）。
/// 默认端口 8090：8080 常被桌面版/其它服务占用，误连时会 401。
/// 需要 mock server 监听 127.0.0.1:8090/dav，否则整组跳过。
const _port = int.fromEnvironment('DD_MOCK_DAV_PORT', defaultValue: 8090);
final _server = 'http://127.0.0.1:$_port/dav';
const _user = 'demo';
const _pass = 'demo';

Future<bool> _serverUp() async {
  try {
    final s = await Socket.connect('127.0.0.1', _port,
        timeout: const Duration(seconds: 1));
    s.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

BookMeta _meta(String ck) => BookMeta(
      id: 'local-id',
      title: '测试书',
      filePath: '/books/test.txt',
      format: 'txt',
      addedAt: DateTime(2026, 1, 1),
      contentKey: ck,
      totalChars: 1234,
      chapterCount: 5,
    );

Map<String, dynamic> _settings(String dir) => {
      SyncEngine.cfgServer: _server,
      SyncEngine.cfgUser: _user,
      SyncEngine.cfgPass: _pass,
      SyncEngine.cfgDir: dir,
      SyncEngine.cfgAuto: false,
      SyncEngine.cfgVerifyTls: false,
    };

void main() {
  setUpAll(() {
    // flutter_test 默认把所有 http 请求拦成 400 假响应，这里放开走真实网络
    HttpOverrides.global = null;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('push：本地书+进度推到远端，远端落 ck2 记录', () async {
    if (!await _serverUp()) {
      markTestSkipped('mock webdav 未启动');
      return;
    }
    final dir = 'DDTest_${DateTime.now().millisecondsSinceEpoch}';
    final storage = AppStorage();
    await storage.saveSettings(_settings(dir));
    await storage.saveBooks([_meta('ck_e2e_1')]);
    await storage.saveProgress(BookProgress(
      bookId: 'local-id',
      chapterIndex: 3,
      paragraphIndex: 1,
      offsetInParagraph: 0,
      percent: 0.75,
      updatedAt: 1700000000.0,
      charOffsetInChapter: 4321,
    ));

    final eng = SyncEngine(storage: storage, annotations: AnnotationStore());
    final rep = await eng.sync();
    expect(rep.ok, isTrue, reason: rep.error);
    expect(rep.pushed, greaterThanOrEqualTo(1));

    // 远端目录真的出现文件（直接走 WebDAV GET 校验）
    final cli = WebDavClient(
      server: _server,
      username: _user,
      password: _pass,
      remoteDir: dir,
      verifyTls: false,
    );
    final entries = await cli.propfind('v1/books');
    expect(entries.map((e) => e.name), contains('ck_e2e_1.json'));

    final bytes = await cli.get('v1/books/ck_e2e_1.json');
    expect(bytes, isNotNull);
    final rec = jsonDecode(utf8.decode(bytes!)) as Map<String, dynamic>;
    expect(rec['schema'], SyncEngine.schemaVersion);
    expect(rec['content_key'], 'ck_e2e_1');
    expect(rec['content_key_version'], 'ck2');
    expect(rec['chapter_count'], 5);
    expect(rec['total_chars'], 1234);
    expect(rec['progress']['chapter_idx'], 3);
    expect(rec['progress']['char_offset'], 4321);
    expect(rec['progress']['percent'], 75.0); // 远端 percent 是 0~100 口径
  });

  test('pull：本地进度清空后能拉回同一进度', () async {
    if (!await _serverUp()) {
      markTestSkipped('mock webdav 未启动');
      return;
    }
    final dir = 'DDTest_pull_${DateTime.now().millisecondsSinceEpoch}';
    final storage = AppStorage();
    await storage.saveSettings(_settings(dir));
    await storage.saveBooks([_meta('ck_e2e_2')]);
    await storage.saveProgress(BookProgress(
      bookId: 'local-id',
      chapterIndex: 9,
      paragraphIndex: 2,
      offsetInParagraph: 0,
      percent: 0.31,
      updatedAt: 1700000100.0,
      charOffsetInChapter: 888,
    ));
    final eng = SyncEngine(storage: storage, annotations: AnnotationStore());
    final push = await eng.sync();
    expect(push.ok, isTrue, reason: push.error);
    expect(push.pushed, 1);

    // 模拟另一台设备：书架同一本书，但没有任何进度
    SharedPreferences.setMockInitialValues({});
    final fresh = AppStorage();
    await fresh.saveSettings(_settings(dir));
    await fresh.saveBooks([_meta('ck_e2e_2')]);
    final eng2 = SyncEngine(storage: fresh, annotations: AnnotationStore());
    final pull = await eng2.sync();
    expect(pull.ok, isTrue, reason: pull.error);
    expect(pull.pulled, 1);

    final p = await fresh.loadProgress('local-id');
    expect(p, isNotNull);
    expect(p!.chapterIndex, 9);
    expect(p.paragraphIndex, 2);
    // 记录里带段落坐标 → 不需要换算，但 char_offset 原值必须保留以便回写 PC
    expect(p.charOffsetInChapter, isNull);
    expect(p.pcCharOffset, 888);
    expect(p.toPcJson()['char_offset'], 888);
    expect(p.percent, closeTo(0.31, 0.001));
    expect(p.updatedAt, closeTo(1700000100.0, 0.6));
  });

  test('import：远端独有书带 source → 下载源文件、解析入书架、套上进度', () async {
    if (!await _serverUp()) {
      markTestSkipped('mock webdav 未启动');
      return;
    }
    const sample = '第一章 开端\n正文一。\n\n第二章 转折\n正文二。\n';
    final tmp = Directory.systemTemp.createTempSync('dd_import_src');
    final srcPath = '${tmp.path}/remote_book.txt';
    File(srcPath).writeAsStringSync(sample);
    // 先用本机解析器算出 key（等价于桌面端算出的同一个 key）
    final probe = await BookParser().parse(
      id: 'probe',
      filePath: srcPath,
      title: '远端独有的书',
      format: BookFormat.txt,
      addedAt: DateTime(2026, 1, 1),
    );
    expect(probe.parseOk, isTrue);
    final key = probe.contentKey;
    expect(key.length, 16);

    final dir = 'DDTest_import_${DateTime.now().millisecondsSinceEpoch}';
    final cli = WebDavClient(
      server: _server,
      username: _user,
      password: _pass,
      remoteDir: dir,
      verifyTls: false,
    );
    await cli.mkdirs('v1/books');
    await cli.mkdirs('v1/sources');
    final size = File(srcPath).lengthSync();
    await cli.put(
      'v1/books/$key.json',
      utf8.encode(jsonEncode({
        'schema': 1,
        'content_key': key,
        'content_key_version': 'ck2',
        'title': '远端独有的书',
        'author': '某作者',
        'format': 'txt',
        'total_chars': probe.totalDisplayLength,
        'chapter_count': probe.chapterCount,
        'progress': {'chapter_idx': 1, 'char_offset': 30, 'percent': 0.5},
        'bookmarks': [
          {
            'id': 'bm1',
            'created_at': 1700000200.0,
            'chapter_idx': 1,
            'offset': 10,
            'offset_end': 20,
            'text': '正文二',
            'note': ''
          }
        ],
        'updated_at': 1700000200.0,
        'device': 'PC',
        'synced_at': 1700000200.0,
        'source': {'ext': '.txt', 'size': size, 'name': 'remote_book.txt'},
      })),
    );
    await cli.put('v1/sources/$key.txt', File(srcPath).readAsBytesSync(),
        atomic: false, contentType: 'application/octet-stream');

    // 本机：空书架
    SharedPreferences.setMockInitialValues({});
    final storage = AppStorage();
    await storage.saveSettings(_settings(dir));
    final eng = SyncEngine(
      storage: storage,
      annotations: AnnotationStore(),
      sourceDirOverride: '${tmp.path}/lands',
    );
    final rep = await eng.sync();
    expect(rep.ok, isTrue, reason: rep.error);
    expect(rep.imported, 1);
    expect(rep.remoteOnly, isEmpty);

    final books = await storage.loadBooks();
    expect(books.length, 1);
    final meta = books.single;
    expect(meta.contentKey, key);
    expect(meta.title, '远端独有的书');
    expect(meta.chapterCount, probe.chapterCount);
    expect(meta.totalChars, probe.totalDisplayLength);
    // 源文件真的落到本地，且能被解析（不是空壳书）
    expect(File(meta.filePath).existsSync(), isTrue);
    expect(File(meta.filePath).lengthSync(), size);

    // 远端进度套上了
    final prog = await storage.loadProgress(meta.id);
    expect(prog, isNotNull);
    expect(prog!.chapterIndex, 1);
    expect(prog.percent, closeTo(0.5, 0.001));

    // 二次同步：不重复导入
    final again = await eng.sync();
    expect(again.ok, isTrue, reason: again.error);
    expect(again.imported, 0);
    expect((await storage.loadBooks()).length, 1);
  });

  test('import：老记录没有 source 时只计数、不产生空书', () async {
    if (!await _serverUp()) {
      markTestSkipped('mock webdav 未启动');
      return;
    }
    final dir = 'DDTest_nosrc_${DateTime.now().millisecondsSinceEpoch}';
    final cli = WebDavClient(
      server: _server,
      username: _user,
      password: _pass,
      remoteDir: dir,
      verifyTls: false,
    );
    await cli.mkdirs('v1/books');
    await cli.put(
      'v1/books/deadbeef00000001.json',
      utf8.encode(jsonEncode({
        'schema': 1,
        'content_key': 'deadbeef00000001',
        'content_key_version': 'ck2',
        'title': '只有记录没有源文件',
        'format': 'txt',
        'progress': {'chapter_idx': 0, 'char_offset': 0, 'percent': 0.0},
        'bookmarks': <dynamic>[],
        'updated_at': 1700000300.0,
      })),
    );

    SharedPreferences.setMockInitialValues({});
    final storage = AppStorage();
    await storage.saveSettings(_settings(dir));
    final eng = SyncEngine(
      storage: storage,
      annotations: AnnotationStore(),
      sourceDirOverride: Directory.systemTemp.createTempSync('dd_nosrc').path,
    );
    final rep = await eng.sync();
    expect(rep.ok, isTrue, reason: rep.error);
    expect(rep.imported, 0);
    expect(rep.remoteOnly, contains('只有记录没有源文件'));
    expect((await storage.loadBooks()), isEmpty);
  });
}
