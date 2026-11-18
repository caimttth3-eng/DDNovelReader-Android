import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:duoduo_langdu/models/progress.dart';
import 'package:duoduo_langdu/services/annotation_store.dart';
import 'package:duoduo_langdu/services/app_storage.dart';
import 'package:duoduo_langdu/services/sync_engine.dart';

/// 跨端联调（PC ⇄ 安卓 真打同一台 mock WebDAV）
///
/// 由 tests/e2e_cross.py 分阶段驱动：
///   PHASE=1  空书架 → 拉 PC 的两本书 → 把 A 的进度改新 → 删掉 B → 同步
///   PHASE=2  PC 删掉 A 之后 → 同步 → A 也应从本机移除
///
/// 跑法（ctx 由 python 生成）：
///   flutter test test/e2e_cross_test.dart --dart-define=PHASE=1 --dart-define=CTX=<path>
void main() {
  const phase = String.fromEnvironment('PHASE');
  const ctxPath = String.fromEnvironment('CTX');

  setUpAll(() {
    HttpOverrides.global = null;
  });

  test('cross phase $phase', () async {
    if (ctxPath.isEmpty) {
      markTestSkipped('没有 CTX');
      return;
    }
    final ctx = jsonDecode(File(ctxPath).readAsStringSync()) as Map<String, dynamic>;
    final server = ctx['server'] as String;
    final dir = ctx['dir'] as String;
    final user = ctx['user'] as String;
    final pass = ctx['pass'] as String;

    final settings = <String, dynamic>{
      SyncEngine.cfgServer: server,
      SyncEngine.cfgUser: user,
      SyncEngine.cfgPass: pass,
      SyncEngine.cfgDir: dir,
      SyncEngine.cfgAuto: false,
      SyncEngine.cfgVerifyTls: false,
    };

    SharedPreferences.setMockInitialValues({});
    final storage = AppStorage();
    await storage.saveSettings(settings);
    final eng = SyncEngine(
      storage: storage,
      annotations: AnnotationStore(),
      sourceDirOverride: Directory.systemTemp.createTempSync('dd_cross').path,
    );

    final out = <String, dynamic>{};
    var rep = await eng.sync();
    expect(rep.ok, isTrue, reason: rep.error);
    out['phase'] = phase;
    out['imported'] = rep.imported;
    out['pushed'] = rep.pushed;
    out['pulled'] = rep.pulled;
    out['removed'] = rep.removed;
    out['deleted'] = rep.deleted;
    out['lines'] = rep.lines;

    final books = await storage.loadBooks();
    out['books'] = books.map((b) => {'id': b.id, 'title': b.title, 'key': b.contentKey}).toList();

    if (phase == '1') {
      // 目标：把 PC 的两本书都拉过来（增量）
      expect(rep.imported, 2, reason: '应导入 PC 的两本书，实际 ${rep.imported}：${rep.lines}');
      final byTitle = {for (final b in books) b.title: b};

      // 安卓读到更后面的一章：进度时间戳用"现在"，确保比 PC 的新
      final a = byTitle['跨端测试A']!;
      final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
      await storage.saveProgress(BookProgress(
        bookId: a.id,
        chapterIndex: 2,
        paragraphIndex: 1,
        offsetInParagraph: 0,
        percent: 0.9,
        updatedAt: now,
        charOffsetInChapter: 321,
      ));

      // 安卓删掉 B（减量）
      final b = byTitle['跨端测试B']!;
      await storage.removeBook(b.id);
      out['deletedLocal'] = b.contentKey;

      rep = await eng.sync();
      expect(rep.ok, isTrue, reason: rep.error);
      out['phase1_second_pushed'] = rep.pushed;
      out['phase1_second_deleted'] = rep.deleted;
      expect(rep.deleted, greaterThanOrEqualTo(1), reason: '本地删除应作为墓碑上传');
    } else if (phase == '2') {
      // 模拟"这本书本机本来就有、而且读过"：预置一本 A（进度时间早于对端删除）
      final key = (ctx['keys'] as Map)['跨端测试A'] as String;
      final srcPath = (ctx['bookA'] as String?) ?? '';
      final old = DateTime.now().subtract(const Duration(days: 1));
      await storage.addBook(BookMeta(
        id: key,
        title: '跨端测试A',
        filePath: srcPath,
        format: 'txt',
        addedAt: old,
        contentKey: key,
        totalChars: 0,
        chapterCount: 0,
      ));
      await storage.saveProgress(BookProgress(
        bookId: key,
        chapterIndex: 1,
        paragraphIndex: 0,
        offsetInParagraph: 0,
        percent: 0.2,
        updatedAt: old.millisecondsSinceEpoch / 1000.0,
      ));
      rep = await eng.sync();
      expect(rep.ok, isTrue, reason: rep.error);
      out['phase2_removed'] = rep.removed;

      // PC 已经删掉 A：本机也应移除
      expect(rep.removed, greaterThanOrEqualTo(1), reason: '应移除 PC 删除的书：${rep.lines}');
      final titles = (await storage.loadBooks()).map((b) => b.title).toList();
      expect(titles, isNot(contains('跨端测试A')));
      out['titles'] = titles;
      // 再同步一次：不应复活
      final again = await eng.sync();
      expect(again.imported, 0);
      expect((await storage.loadBooks()).map((b) => b.title), isNot(contains('跨端测试A')));
    } else if (phase == '3') {
      // 老书场景：远端那条记录当初用 book id 当 key 上传（contentKey 还没回填），
      // 现在在安卓端删掉它 —— 删除必须传到远端，且不能被当成"远端独有书"导回来。
      final bookId = 'laoshu0001';
      final cli = eng.client(settings);
      await cli.mkdirs('v1/books');
      final t0 = DateTime.now().millisecondsSinceEpoch / 1000.0 - 600;
      await cli.put('v1/books/$bookId.json', utf8.encode(jsonEncode({
        'schema': 2,
        'content_key': bookId,
        'title': '老书',
        'format': 'txt',
        'total_chars': 0,
        'chapter_count': 0,
        'progress': {'chapter_idx': 1, 'char_offset': 0, 'percent': 10.0},
        'progress_at': t0,
        'bookmarks': <dynamic>[],
        'bookmarks_at': 0,
        'updated_at': t0,
      })));
      await storage.addBook(BookMeta(
        id: bookId,
        title: '老书',
        filePath: (ctx['bookA'] as String?) ?? '',
        format: 'txt',
        addedAt: DateTime.now().subtract(const Duration(days: 3)),
        contentKey: '', // 没回填 ck2 的老书
        totalChars: 0,
        chapterCount: 0,
      ));
      await storage.removeBook(bookId);
      rep = await eng.sync();
      expect(rep.ok, isTrue, reason: rep.error);
      out['phase3_deleted'] = rep.deleted;
      final raw = await cli.get('v1/books/$bookId.json');
      final rec = raw == null ? null : jsonDecode(utf8.decode(raw));
      out['remote_record'] = rec;
      expect(rec is Map && rec['deleted'] == true, isTrue,
          reason: '远端必须收到删除墓碑：${rep.lines}');
      final again = await eng.sync();
      expect(again.imported, 0, reason: '已删除的老记录不该被重新导入：${again.lines}');
      expect((await storage.loadBooks()).map((b) => b.id), isNot(contains(bookId)));
      out['phase3_second_imported'] = again.imported;
    }

    File(ctxPath.replaceAll('.json', '_dart_phase$phase.json'))
        .writeAsStringSync(const JsonEncoder.withIndent(' ').convert(out));
  });
}
