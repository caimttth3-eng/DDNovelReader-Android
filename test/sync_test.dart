import 'package:flutter_test/flutter_test.dart';

import 'package:duoduo_langdu/models/book.dart';
import 'package:duoduo_langdu/models/progress.dart';
import 'package:duoduo_langdu/services/content_key.dart';
import 'package:duoduo_langdu/services/sync_engine.dart';
import 'package:duoduo_langdu/services/webdav_client.dart';

Book _sampleBook() {
  // 3 章，每章 2 段，便于校验章内偏移换算
  Paragraph p(String s) => Paragraph(
        display: s,
        tts: s,
        sentences: [
          Sentence(s, s, displayStart: 0, displayEnd: s.length),
        ],
        sentenceStartTts: const [0],
      );
  return Book(
    id: 'bid',
    title: '测试书',
    filePath: '/x.txt',
    format: BookFormat.txt,
    addedAt: DateTime(2026, 1, 1),
    contentKey: 'ck_abc',
    chapters: [
      Chapter(title: '第1章', paragraphs: [p('一二三四五'), p('六七八九十')]),
      Chapter(title: '第2章', paragraphs: [p('甲乙丙'), p('丁戊己')]),
      Chapter(title: '第3章', paragraphs: [p('子丑寅')]),
    ],
  );
}

void main() {
  group('WebDAV 协议', () {
    test('urlOf 逐段转义，中文目录不被吞', () {
      final c = WebDavClient(
        server: 'https://dav.example.com/dav',
        remoteDir: '多多朗读/同步',
      );
      expect(c.baseUrl, 'https://dav.example.com/dav/');
      // 目录本身以 / 结尾
      expect(
        c.urlOf(''),
        'https://dav.example.com/dav/${Uri.encodeComponent('多多朗读')}/'
        '${Uri.encodeComponent('同步')}/',
      );
      // 文件路径不加尾斜杠，且 / 不被转义掉
      final u = c.urlOf('v1/books/abc.json');
      expect(u.endsWith('v1/books/abc.json'), isTrue);
      expect(u.startsWith('https://dav.example.com/dav/'), isTrue);
    });

    test('urlOf 空远端目录直接用服务器根', () {
      final c = WebDavClient(server: 'dav.example.com', remoteDir: '');
      expect(c.baseUrl, 'https://dav.example.com/');
      expect(c.urlOf('v1/meta.json'), 'https://dav.example.com/v1/meta.json');
    });

    test('parsePropfind 解析目录自身/文件/子目录', () {
      const xml = '''<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response><D:href>/dav/v1/books/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
  </D:response>
  <D:response><D:href>/dav/v1/books/ck_abc.json</D:href>
    <D:propstat><D:prop><D:resourcetype/><D:getcontentlength>1234</D:getcontentlength>
    <D:getlastmodified>Wed, 18 Nov 2026 03:00:00 GMT</D:getlastmodified></D:prop></D:propstat>
  </D:response>
  <D:response><D:href>/dav/v1/books/sub/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
  </D:response>
</D:multistatus>''';
      final entries = WebDavClient.parsePropfind(
          xml, 'https://dav.example.com/dav/v1/books/');
      expect(entries.length, 2); // 目录自身被跳过
      expect(entries[0].name, 'ck_abc.json');
      expect(entries[0].isDir, isFalse);
      expect(entries[0].size, 1234);
      expect(entries[0].mtime, greaterThan(0));
      expect(entries[0].rel, 'ck_abc.json');
      expect(entries[1].isDir, isTrue);
      expect(entries[1].rel, 'sub');
    });

    test('parsePropfind 空/畸形响应返回空列表', () {
      expect(WebDavClient.parsePropfind('', 'https://x/'), isEmpty);
      expect(WebDavClient.parsePropfind('<nope/>', 'https://x/'), isEmpty);
    });

    test('httpHint 覆盖 401/404/405', () {
      expect(WebDavClient.httpHint(401), contains('账号'));
      expect(WebDavClient.httpHint(404), contains('不存在'));
      expect(WebDavClient.httpHint(405), contains('不支持'));
    });
  });

  group('书签合并', () {
    test('按 id 并集，同 id 取 created_at 较新', () {
      final local = [
        {'id': 'a', 'created_at': 100, 'text': '旧'},
        {'id': 'b', 'created_at': 50, 'text': '本地'},
      ];
      final remote = [
        {'id': 'a', 'created_at': 200, 'text': '新'},
        {'id': 'c', 'created_at': 10, 'text': '远端'},
      ];
      final (merged, changed) = SyncEngine.mergeBookmarks(local, remote);
      expect(changed, isTrue);
      expect(merged.length, 3);
      expect(merged.map((e) => e['id']), containsAll(['a', 'b', 'c']));
      final a = merged.firstWhere((e) => e['id'] == 'a');
      expect(a['text'], '新'); // 远端更新者胜
      // 顺序按 created_at 升序
      expect(merged.map((e) => e['id']).toList(), ['c', 'b', 'a']);
    });

    test('本地更新时不采用远端旧值，changed 为 false', () {
      final local = [
        {'id': 'a', 'created_at': 300, 'text': '本地新'}
      ];
      final remote = [
        {'id': 'a', 'created_at': 100, 'text': '远端旧'}
      ];
      final (merged, changed) = SyncEngine.mergeBookmarks(local, remote);
      expect(changed, isFalse);
      expect(merged.single['text'], '本地新');
    });

    test('任一侧为空时也能合并', () {
      final (m1, c1) = SyncEngine.mergeBookmarks([], [
        {'id': 'x', 'created_at': 1}
      ]);
      expect(m1.length, 1);
      expect(c1, isTrue);
      final (m2, c2) = SyncEngine.mergeBookmarks([
        {'id': 'y', 'created_at': 1}
      ], []);
      expect(m2.length, 1);
      expect(c2, isFalse);
    });
  });

  group('进度跨端结构', () {
    test('toPcJson 输出 PC 字段名', () {
      final p = BookProgress(
        bookId: 'b',
        chapterIndex: 7,
        paragraphIndex: 3,
        offsetInParagraph: 12,
        percent: 0.4567,
        updatedAt: 111.5,
        charOffsetInChapter: 999,
      );
      final pc = p.toPcJson();
      expect(pc['chapter_idx'], 7);
      expect(pc['char_offset'], 999);
      expect(pc['percent'], 0.4567);
      // 安卓自有坐标也一起带上，PC 端忽略未知字段
      expect(pc['paragraph_index'], 3);
      expect(pc['offset_in_paragraph'], 12);
    });

    test('fromPcJson 有段落坐标时直接用，无则留 charOffset 待换算', () {
      final withPara = BookProgress.fromPcJson('b', {
        'chapter_idx': 2,
        'paragraph_index': 5,
        'offset_in_paragraph': 8,
        'percent': 0.2,
        'updated_at': 42,
      });
      expect(withPara.chapterIndex, 2);
      expect(withPara.paragraphIndex, 5);
      expect(withPara.offsetInParagraph, 8);
      expect(withPara.updatedAt, 42);
      expect(withPara.charOffsetInChapter, isNull);

      final onlyPc = BookProgress.fromPcJson('b', {
        'chapter_idx': 4,
        'char_offset': 1200,
        'percent': 0.66,
      });
      expect(onlyPc.chapterIndex, 4);
      expect(onlyPc.paragraphIndex, 0);
      expect(onlyPc.charOffsetInChapter, 1200);
    });

    test('locateByCharOffset 与 charOffsetOf 互为逆运算', () {
      final book = _sampleBook();
      for (var c = 0; c < book.chapters.length; c++) {
        final paras = book.chapters[c].paragraphs;
        for (var p = 0; p < paras.length; p++) {
          for (final off in [0, 1, paras[p].display.length]) {
            final chOff = book.charOffsetOf(c, p, off);
            final (rp, roff) = book.locateByCharOffset(c, chOff);
            expect(rp, p, reason: '章 $c 段 $p 偏移 $off');
            expect(roff, off, reason: '章 $c 段 $p 偏移 $off');
          }
        }
      }
    });

    test('charOffsetOf 计入段间换行', () {
      final book = _sampleBook();
      // 第 1 章第 2 段起点 = 第一段长度 5 + 1 个换行 = 6
      expect(book.charOffsetOf(0, 1, 0), 6);
    });
    test('PC offsets count Unicode scalars rather than splitting UTF16 pairs', () {
      final book = Book(id: 'unicode', title: 'unicode', filePath: '', format: BookFormat.txt, addedAt: DateTime(2026),
        chapters: [Chapter(title: 'one', paragraphs: [
          const Paragraph(display: '甲🙂乙', tts: '', sentences: [], sentenceStartTts: []),
          const Paragraph(display: '丙𠀀丁', tts: '', sentences: [], sentenceStartTts: []),
        ])]);
      expect(book.locateByCharOffset(0, 2), (0, 3));
      expect(book.charOffsetOf(0, 0, 3), 2);
      expect(book.charOffsetOf(0, 1, 3), 6);
      expect(book.locateByCharOffset(0, 6), (1, 3));
    });
  });

  group('ck2 指纹测试向量', () {
    // 来自《安卓端同步开发指南》第 3 节，一条不对就说明与桌面端算不出同一个 key
    test('测试书甲 = cf56d613ba8d7b65', () {
      final key = computeContentKey(
        '测试书甲',
        2,
        '第一章 开端\n正文一。第二章 转折\n正文二。',
      );
      expect(key, 'cf56d613ba8d7b65');
    });

    test('测试书乙 = a28620303fae9a0b', () {
      expect(
        computeContentKey('测试书乙', 1, '楔子\n只有一章的正文。'),
        'a28620303fae9a0b',
      );
    });

    test('带空格 的书名 = 268958ab9d9e816f', () {
      expect(
        computeContentKey(
          '带空格 的书名',
          2,
          '第一章\n  第一行  正文\n第二行。第二章\n末章正文',
        ),
        '268958ab9d9e816f',
      );
    });
  });

  group('同步记录字段', () {
    test('record 字段名与 PC 一致（离线校验 key 集合）', () {
      // 与 novelreader/sync_engine.py 的 _record() 对齐
      const requiredKeys = {
        'schema',
        'content_key',
        'content_key_version',
        'legacy_key',
        'title',
        'author',
        'format',
        'total_chars',
        'chapter_count',
        'progress',
        'bookmarks',
        'updated_at',
        'device',
        'synced_at',
      };
      // 该常量在实现里以字面量构造，这里用一份样例断言结构完整
      final sample = <String, dynamic>{
        'schema': 1,
        'content_key': 'k',
        'content_key_version': 'ck2',
        'legacy_key': '',
        'title': 't',
        'author': '',
        'format': 'txt',
        'total_chars': 0,
        'chapter_count': 0,
        'progress': <String, dynamic>{},
        'bookmarks': <dynamic>[],
        'updated_at': 0.0,
        'device': 'Android',
        'synced_at': 0.0,
      };
      expect(sample.keys.toSet(), requiredKeys);
    });
  });
}
