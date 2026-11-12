import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:duoduo_langdu/models/book.dart';
import 'package:duoduo_langdu/models/progress.dart';
import 'package:duoduo_langdu/services/app_storage.dart';
import 'package:duoduo_langdu/services/book_parser.dart';
import 'package:duoduo_langdu/services/reading_text.dart';

Book source(String text) => Book(id: 'text', title: 'text', filePath: '', format: BookFormat.txt,
  addedAt: DateTime(2026), chapters: [Chapter(title: '第一章', paragraphs: [ReadingText.paragraph(text)])]);
Book format(String text, {bool correction = true, bool indent = true, String filter = 'none'}) =>
  ReadingText.format(source(text), merge: correction, indent: indent, filter: filter);

void main() {
  test('hard wraps merge for display and speech, with punctuation boundaries', () {
    final book = format('山间传来\n朋友的问候。\n第二段！\n“真的吗？”\n下一段。');
    final p = book.chapters.first.paragraphs;
    expect(p.map((p) => p.display), ['　　山间传来朋友的问候。', '　　第二段！', '　　“真的吗？”', '　　下一段。']);
    expect(p.first.sentences.single.tts, '山间传来朋友的问候。');
    expect(format('山间传来\n朋友的问候。', correction: false).chapters.first.paragraphs.length, 2);
    expect(format('hello\nworld.', indent: false).chapters.first.paragraphs.single.display, 'hello world.');
  });

  test('closing quotes remain with the sentence and misplaced quotes are repaired', () {
    final p = format('“你好。\n”他说，“再见！”\n她点头。').chapters.first.paragraphs;
    expect(p.first.display, '　　“你好。”');
    expect(p.first.sentences.single.display.endsWith('。”'), isTrue);
    expect(p[1].display.startsWith('　　他说'), isTrue);
    final sentences = ReadingText.paragraph('“第一句。”他说，“第二句！”随后走开。').sentences;
    expect(sentences.first.display, '“第一句。”');
    expect(sentences[1].display, '他说，“第二句！”');
    expect(sentences.last.display, '随后走开。');
  });

  test('indent is exactly two characters when missing and existing indent is preserved', () {
    final p = format('甲。\n 乙。\n  丙。\n　　丁。', correction: false).chapters.first.paragraphs;
    expect(p.map((p) => p.display), ['　　甲。', '　　乙。', '  丙。', '　　丁。']);
    expect(format('甲。', indent: false).chapters.first.paragraphs.single.display, '甲。');
    expect(p.first.tts, '甲。');
  });

  test('filter levels require an explicit selection and preserve source positions', () {
    const text = '第一段。\nhttps://example.com/book\n访问本站获取更多小说\n求月票和收藏！\n第二段。他说道网址并不神秘。';
    final original = source(text);
    final untouched = ReadingText.format(original, merge: true, indent: true);
    expect(untouched.chapters.first.paragraphs.map((p) => p.display).join(), contains('example.com'));
    final filtered = ReadingText.format(original, merge: true, indent: true, filter: 'ads');
    final content = filtered.chapters.first.paragraphs.map((p) => p.display).join();
    expect(content, isNot(contains('example.com')));
    expect(content, isNot(contains('访问本站')));
    expect(content, contains('求月票和收藏'));
    expect(content, contains('他说道网址并不神秘'));
    final offset = text.indexOf('第二段');
    final anchor = ReadingText.anchor(original, 0, 0, offset);
    final target = ReadingText.locate(filtered, 0, anchor);
    expect(filtered.chapters.first.paragraphs[target.$1].display.substring(target.$2), startsWith('第二段'));
    expect(ReadingText.anchor(filtered, 0, target.$1, target.$2), anchor);
    expect(format(text, filter: 'extra').chapters.first.paragraphs.map((p) => p.display).join(), isNot(contains('求月票')));
    expect(original.chapters.first.paragraphs.single.display, text);
    expect(ReadingText.fingerprint(filtered), isNot(ReadingText.fingerprint(untouched)), reason: 'Changed TTS text must not reuse old coordinate-only audio');
  });

  test('parser preserves physical lines and original indentation for switches', () async {
    final dir = await Directory.systemTemp.createTemp('reading-text-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/sample.txt');
    await file.writeAsString('第一章 开始\n　　原始缩进。\n半句\n接下句。\n第二章 后续\n  两个空格。');
    final book = await BookParser().parse(id: 'parser', filePath: file.path, title: 'parser',
      format: BookFormat.txt, addedAt: DateTime(2026));
    expect(book.parseOk, isTrue);
    expect(book.chapters.first.paragraphs.first.display, startsWith('　　原始缩进。'));
    final processed = ReadingText.format(book, merge: true, indent: true);
    expect(processed.chapters.first.paragraphs.map((p) => p.display).join(), contains('半句接下句。'));
    expect(processed.chapters.last.paragraphs.first.display, startsWith('  两个空格。'));
  });

  test('book progress persists independently including a partially visible paragraph', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = AppStorage();
    await storage.saveProgress(BookProgress(bookId: 'a', chapterIndex: 8, paragraphIndex: 4,
      chapterAnchor: 720, viewportItem: 88, viewportAlignment: -0.35, layoutSignature: 'layout'));
    await storage.saveProgress(BookProgress(bookId: 'b', chapterIndex: 2, paragraphIndex: 1));
    final restored = await AppStorage().loadProgress('a');
    expect(restored!.chapterIndex, 8); expect(restored.chapterAnchor, 720);
    expect(restored.viewportAlignment, -0.35); expect(restored.viewportItem, 88);
    expect((await storage.loadProgress('b'))!.chapterIndex, 2);
  });
}
