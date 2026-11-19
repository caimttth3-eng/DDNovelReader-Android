import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:duoduo_langdu/models/progress.dart';
import 'package:duoduo_langdu/services/annotation_store.dart';
import 'package:duoduo_langdu/services/app_storage.dart';
import 'package:duoduo_langdu/services/sync_engine.dart';

/// schema 2 同步规则单测：按字段计时、percent 口径、删除墓碑（与 PC 端同构）
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  BookMeta meta(String id, String key, {String title = '测试书', DateTime? added}) => BookMeta(
        id: id,
        title: title,
        filePath: '/books/$id.txt',
        format: 'txt',
        addedAt: added ?? DateTime(2026, 1, 1),
        contentKey: key,
        totalChars: 1000,
        chapterCount: 5,
      );

  test('percent 口径：远端 0~100 → 本机 0~1，且兼容旧的 0~1 记录', () {
    expect(SyncEngine.percentFromRemote(42.0), closeTo(0.42, 1e-9));
    expect(SyncEngine.percentFromRemote(100.0), closeTo(1.0, 1e-9));
    expect(SyncEngine.percentFromRemote(0.42), closeTo(0.42, 1e-9)); // 旧记录不再放大
    expect(SyncEngine.percentFromRemote(0), 0);
    expect(SyncEngine.percentFromRemote(null), 0);
  });

  test('localRecords：出站 percent 折成 0~100，进度/书签各带时间戳', () async {
    final storage = AppStorage();
    await storage.saveBooks([meta('b1', 'ck1')]);
    await storage.saveProgress(BookProgress(
      bookId: 'b1',
      chapterIndex: 2,
      paragraphIndex: 1,
      offsetInParagraph: 0,
      percent: 0.4,
      updatedAt: 1700000000.0,
      charOffsetInChapter: 111,
    ));
    final eng = SyncEngine(storage: storage, annotations: AnnotationStore());
    final recs = await eng.localRecords({}, 'Android');
    final rec = recs['ck1']!.value;
    expect(rec['schema'], 2);
    expect(rec['progress_at'], closeTo(1700000000.0, 0.01));
    expect(rec['bookmarks_at'], 0);
    expect(rec['updated_at'], closeTo(1700000000.0, 0.01));
    expect((rec['progress'] as Map)['percent'], closeTo(40.0, 0.01));
    expect((rec['progress'] as Map)['chapter_idx'], 2);
  });

  test('tombstoneRecord：删除事件的字段与 PC 一致', () {
    final rec = SyncEngine.tombstoneRecord(
      'ck_del',
      {'deleted_at': 1700000100.0, 'title': '被删的书'},
      'Android',
    );
    expect(rec['schema'], 2);
    expect(rec['deleted'], true);
    expect(rec['content_key'], 'ck_del');
    expect(rec['deleted_at'], closeTo(1700000100.0, 0.01));
    expect(rec['updated_at'], closeTo(1700000100.0, 0.01));
    expect(rec['title'], '被删的书');
    expect(rec['progress_at'], 0);
  });

  test('删除墓碑：removeBook 记账、重新导入撤销', () async {
    final storage = AppStorage();
    await storage.saveBooks([meta('b1', 'ck_del')]);
    await storage.removeBook('b1', deletedAt: 1700000200.0);
    final dels = await storage.loadDeletions();
    expect(dels.containsKey('ck_del'), isTrue);
    expect((dels['ck_del'] as Map)['deleted_at'], closeTo(1700000200.0, 0.01));
    expect(await storage.loadBooks(), isEmpty);

    // 重新导入同一本书 → 墓碑撤销，同步不会再把书删一次
    await storage.addBook(meta('b1b', 'ck_del'));
    expect((await storage.loadDeletions()).containsKey('ck_del'), isFalse);
  });

  test('applyRemote：进度比 progress_at，新者胜、旧者不动', () async {
    final storage = AppStorage();
    await storage.saveBooks([meta('b1', 'ck1')]);
    await storage.saveProgress(BookProgress(
      bookId: 'b1',
      chapterIndex: 8,
      paragraphIndex: 0,
      offsetInParagraph: 0,
      percent: 0.8,
      updatedAt: 1700000300.0,
    ));
    final eng = SyncEngine(storage: storage, annotations: AnnotationStore());

    // 远端更旧 → 不动
    final older = {
      'progress': {'chapter_idx': 2, 'char_offset': 0, 'percent': 20.0},
      'progress_at': 1700000000.0,
      'updated_at': 1700000000.0,
      'bookmarks': <dynamic>[],
    };
    expect(await eng.applyRemote('b1', older), isFalse);
    expect((await storage.loadProgress('b1'))!.chapterIndex, 8);

    // 远端更新 → 采用，percent 折成本机口径
    final newer = {
      'progress': {'chapter_idx': 4, 'char_offset': 9, 'percent': 55.0},
      'progress_at': 1700000400.0,
      'updated_at': 1700000400.0,
      'bookmarks': <dynamic>[],
    };
    expect(await eng.applyRemote('b1', newer), isTrue);
    final p = await storage.loadProgress('b1');
    expect(p!.chapterIndex, 4);
    expect(p.percent, closeTo(0.55, 0.001));
    expect(p.updatedAt, closeTo(1700000400.0, 0.01));
  });

  test('applyRemote：只有书签更新也算拉取，进度不被旧书签时间推动', () async {
    final storage = AppStorage();
    await storage.saveBooks([meta('b1', 'ck1')]);
    await storage.saveProgress(BookProgress(
      bookId: 'b1',
      chapterIndex: 1,
      paragraphIndex: 0,
      offsetInParagraph: 0,
      percent: 0.2,
      updatedAt: 1700000500.0,
    ));
    final eng = SyncEngine(storage: storage, annotations: AnnotationStore());
    final rec = {
      'progress': {'chapter_idx': 1, 'char_offset': 0, 'percent': 20.0},
      'progress_at': 1700000500.0,
      'bookmarks': [
        {'id': 'bm1', 'created_at': 1700000600.0, 'chapter_idx': 0, 'offset': 0, 'offset_end': 3, 'text': 'abc', 'note': ''}
      ],
      'bookmarks_at': 1700000600.0,
      'updated_at': 1700000600.0,
    };
    expect(await eng.applyRemote('b1', rec), isTrue);
    final bms = await AnnotationStore().loadRawBookmarks('b1');
    expect(bms.length, 1);
    expect((await storage.loadProgress('b1'))!.updatedAt, closeTo(1700000500.0, 0.01));
  });
}
