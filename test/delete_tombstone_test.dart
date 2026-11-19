import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:duoduo_langdu/models/progress.dart';
import 'package:duoduo_langdu/services/app_storage.dart';

/// 删除墓碑记账的两个边界（这两条是"安卓端减量不同步"的真实成因）
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  BookMeta meta(String id, String key, {String title = '书'}) => BookMeta(
        id: id,
        title: title,
        filePath: '/books/$id.txt',
        format: 'txt',
        addedAt: DateTime(2026, 1, 1),
        contentKey: key,
        totalChars: 1000,
        chapterCount: 5,
      );

  test('有 contentKey：墓碑记 contentKey，并带上 id_key 用于清理旧的孤儿记录', () async {
    final st = AppStorage();
    await st.addBook(meta('bid_a', 'ck_aaa', title: '甲'));
    await st.removeBook('bid_a', deletedAt: 1700000000.0);
    final d = await st.loadDeletions();
    expect(d.containsKey('ck_aaa'), isTrue);
    final e = d['ck_aaa'] as Map;
    expect((e['deleted_at'] as num).toDouble(), closeTo(1700000000.0, 0.01));
    expect(e['id_key'], 'bid_a');
    expect((await st.loadBooks()), isEmpty);
  });

  test('contentKey 为空（老书没回填 ck2）：用 book id 兜底记墓碑，否则远端收不到删除', () async {
    final st = AppStorage();
    await st.addBook(meta('bid_old', '', title: '老书'));
    await st.removeBook('bid_old', deletedAt: 1700000001.0);
    final d = await st.loadDeletions();
    expect(d.containsKey('bid_old'), isTrue, reason: '老书上传时用 book id 当 key，删除也必须用同一个 key');
    expect(((d['bid_old'] as Map)['title'] as String), '老书');
  });

  test('同一本书反复删除只保留最新一次删除事件', () async {
    final st = AppStorage();
    await st.addBook(meta('bid_b', 'ck_bbb'));
    await st.removeBook('bid_b', deletedAt: 1700000100.0);
    await st.addBook(meta('bid_b2', 'ck_bbb')); // 重新导入 → 撤销墓碑
    expect((await st.loadDeletions()).containsKey('ck_bbb'), isFalse);
    await st.removeBook('bid_b2', deletedAt: 1700000200.0);
    final d = await st.loadDeletions();
    expect(((d['ck_bbb'] as Map)['deleted_at'] as num).toDouble(), closeTo(1700000200.0, 0.01));
  });
}
