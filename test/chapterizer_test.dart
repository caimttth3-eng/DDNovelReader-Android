import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/services/chapterizer.dart';

void main() {
  group('chapterizer 智能分章', () {
    test('识别 第X章（阿拉伯/中文数字）', () {
      final text = '第一章 初识\n正文甲。\n\n第二章 发展\n正文乙。\n\n第三十三章 大结局\n正文丙。';
      final chapters = makeChapters(text);
      expect(chapters.length, greaterThanOrEqualTo(3));
      expect(chapters[0].$1, contains('第一章'));
      expect(chapters[1].$1, contains('第二章'));
      expect(chapters[2].$1, contains('第三十三章'));
    });

    test('识别 第X卷（卷级标题）', () {
      final text = '第一卷 风云起\n卷一正文。\n\n第二卷 天地变\n卷二正文。';
      final chapters = makeChapters(text);
      expect(chapters.length, greaterThanOrEqualTo(2));
      expect(chapters[0].$1, contains('第一卷'));
      expect(chapters[1].$1, contains('第二卷'));
    });

    test('识别 Chapter N（英文章节）', () {
      final text = 'Chapter 1 Start\nEnglish body one.\n\nChapter 2 Continue\nEnglish body two.';
      final chapters = makeChapters(text);
      expect(chapters.length, greaterThanOrEqualTo(2));
      expect(chapters[0].$1, contains('Chapter 1'));
      expect(chapters[1].$1, contains('Chapter 2'));
    });

    test('识别 序章/楔子/番外 等特殊章节', () {
      final text = '序章 引子\n序章正文。\n\n第一章 正篇\n正篇正文。\n\n番外 后日谈\n番外正文。';
      final chapters = makeChapters(text);
      expect(chapters.length, greaterThanOrEqualTo(3));
      expect(chapters[0].$1, contains('序章'));
      expect(chapters[1].$1, contains('第一章'));
      expect(chapters[2].$1, contains('番外'));
    });

    test('识别 书名前缀 的"书名 第1章"格式', () {
      final text = '凡人修仙传 第1章 山村少年\n正文一。\n\n凡人修仙传 第2章 初入仙门\n正文二。';
      final chapters = makeChapters(text);
      expect(chapters.length, greaterThanOrEqualTo(2));
      expect(chapters[0].$1, contains('第1章'));
      // 标题应剥离书名前缀
      expect(chapters[0].$1, isNot(contains('凡人修仙传')));
    });

    test('分隔线 + 短标题 识别为章节', () {
      final text = '初入江湖\n------------\n正文一。\n\n锋芒毕露\n------------\n正文二。';
      final chapters = makeChapters(text);
      expect(chapters.length, greaterThanOrEqualTo(2));
      expect(chapters[0].$1, contains('初入江湖'));
    });

    test('无章节标题时 fallback 按 5000 字分节', () {
      final longBody = List.filled(400, '这是一个很长的自然段落文本，没有章节标题。').join();
      final chapters = makeChapters(longBody);
      expect(chapters.length, greaterThanOrEqualTo(2));
      expect(chapters[0].$1, contains('第 1 节'));
    });

    test('简短文本单章（fallback 兜底）', () {
      final chapters = makeChapters('只有一小段正文，不成章节。');
      expect(chapters.length, 1);
      final title = chapters[0].$1;
      expect(title.contains('正文') || title.contains('第 1 节'), isTrue);
    });
  });
}
