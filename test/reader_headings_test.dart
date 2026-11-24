import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/models/book.dart';
import 'package:duoduo_langdu/services/reader_headings.dart';
import 'package:duoduo_langdu/services/reading_text.dart';

void main() {
  test('untitled TXT blocks keep original section headings without extra labels', () {
    final book = _book([
      _chapter('', ['第一节 清晨', '山路延伸到村庄。']),
      _chapter('正文', ['第二章 黄昏', '天色渐渐暗下来。']),
      _chapter('简介', ['没有章节格式的普通正文。']),
    ]);
    final headings = ReaderHeadings(book);
    expect([for (var chapter = 0; chapter < 3; chapter++) headings.showChapterLabel(chapter)], [false, false, false]);
    expect(headings.isHeading(0, 0), isTrue); expect(headings.isHeading(1, 0), isTrue);
    expect(headings.isHeading(0, 1), isFalse); expect(headings.isHeading(2, 0), isFalse);
    final exact = ReaderHeadings(_book([_chapter('第1节', ['第1节', '这一行是真实原文。'])]));
    expect(exact.showChapterLabel(0), isFalse); expect(exact.isHeading(0, 0), isTrue);
  });

  test('real missing TXT metadata labels remain visible without fabricating headings', () {
    final headings = ReaderHeadings(_book([
      _chapter('第一章 山间', ['山间的小路很长。']),
      _chapter('Chapter 2 Evening', ['The evening was quiet.']),
      _chapter('第一节', ['原文标题由旧解析器放到了章节元数据。']),
      _chapter('随意生成的名称', ['没有足够依据把这个名称当作正文标题。']),
    ]));
    expect(headings.showChapterLabel(0), isTrue);
    expect(headings.showChapterLabel(1), isTrue);
    expect(headings.showChapterLabel(2), isTrue);
    expect(headings.showChapterLabel(3), isFalse);
    for (var chapter = 0; chapter < 4; chapter++) { expect(headings.isHeading(chapter, 0), isFalse); }
  });

  test('real numeric section metadata is classified without synthetic-name suppression', () {
    for (final automatic in [false, true]) {
      final headings = ReaderHeadings(_book([
        _chapter('第1节', ['原文中真实存在的章节元数据。']),
        _chapter('第 2 节', ['同样保留原始名称。']),
      ]), autoExtractToc: automatic);
      expect(headings.showChapterLabel(0), isTrue);
      expect(headings.showChapterLabel(1), isTrue);
    }
  });

  test('same original title suppresses duplicate metadata after indentation and bracket normalization', () {
    final headings = ReaderHeadings(_book([
      _chapter('第一章 开端', ['　　【第一章 开端】', '正文内容。']),
      _chapter('Chapter 2 Return', ['  CHAPTER   2 Return  ', 'The road was empty.']),
    ]));
    expect(headings.showChapterLabel(0), isFalse); expect(headings.showChapterLabel(1), isFalse);
    expect(headings.isHeading(0, 0), isTrue); expect(headings.isHeading(1, 0), isTrue);
  });

  test('EPUB metadata keeps arbitrary real labels and classifies a matching original paragraph', () {
    for (final automatic in [false, true]) {
      final headings = ReaderHeadings(_book([
        _chapter('深夜的访客', ['　　深夜的访客', '门外传来了敲门声。']),
        _chapter('简介', ['这本书从一个安静的夜晚开始。']),
        _chapter('第 1 节', ['这是 EPUB 中真实的目录名称，未出现在正文。']),
      ], format: BookFormat.epub), autoExtractToc: automatic);
      expect(headings.showChapterLabel(0), isFalse); expect(headings.isHeading(0, 0), isTrue);
      expect(headings.showChapterLabel(1), isTrue); expect(headings.showChapterLabel(2), isTrue);
      expect(headings.isHeading(0, 1), isFalse);
    }
  });

  test('disabling automatic extraction retains duplicate hiding without extra TXT body classification', () {
    final headings = ReaderHeadings(_book([
      _chapter('第一章 开端', ['第一章 开端', '正文。', '第二章 回来', '后来。']),
      _chapter('', ['第三节 原文标题', '正文内容。']),
      _chapter('第四章 未重复', ['仅元数据中存在真实章节名。']),
    ]), autoExtractToc: false);
    expect(headings.showChapterLabel(0), isFalse); expect(headings.showChapterLabel(1), isFalse);
    expect(headings.showChapterLabel(2), isTrue);
    expect(headings.isHeading(0, 0), isFalse); expect(headings.isHeading(0, 2), isFalse);
    expect(headings.isHeading(1, 0), isFalse);
  });

  test('full-book recurring numeric rules and chapter paragraph offsets remain precise', () {
    final headings = ReaderHeadings(_book([
      _chapter('', ['001 初见', '山间的小路。', '002 再遇', '村庄里的灯光。']),
      _chapter('', ['第三卷 江湖', '第一节课马上开始', '1、准备工作', '2、马上出发']),
    ]));
    expect(headings.isHeading(0, 0), isTrue); expect(headings.isHeading(0, 2), isTrue);
    expect(headings.isHeading(1, 0), isTrue); expect(headings.isHeading(1, 1), isFalse);
    expect(headings.isHeading(1, 2), isFalse); expect(headings.isHeading(1, 3), isFalse);
  });

  test('an internal heading cannot turn a multiline body paragraph into a heading', () {
    final headings = ReaderHeadings(_book([
      _chapter('', ['第一章 山间\n正文也在同一个旧段落中。', '第二章 夜晚']),
    ]));
    expect(headings.isHeading(0, 0), isFalse); expect(headings.isHeading(0, 1), isTrue);
  });

  test('classification never edits display speech chapter structure or raw source mappings', () {
    final source = _book([_chapter('', ['第一章 开端', '正文第一句。', '第二节 回来', '后面的内容。'])]);
    final formatted = ReadingText.format(source, merge: true, indent: true, filter: 'none');
    final paragraphs = formatted.chapters.single.paragraphs;
    final displays = paragraphs.map((paragraph) => paragraph.display).toList();
    final speech = paragraphs.map((paragraph) => paragraph.tts).toList();
    final sentenceLists = paragraphs.map((paragraph) => paragraph.sentences).toList();
    final before = ReadingText.anchor(formatted, 0, 2, 3);
    final headings = ReaderHeadings(formatted);
    for (var iteration = 0; iteration < 20; iteration++) {
      expect(headings.isHeading(0, 0), isTrue); expect(headings.isHeading(0, 2), isTrue);
      expect(headings.showChapterLabel(0), isFalse);
    }
    expect(identical(formatted.chapters.single.paragraphs, paragraphs), isTrue);
    expect(paragraphs.map((paragraph) => paragraph.display), displays);
    expect(paragraphs.map((paragraph) => paragraph.tts), speech);
    for (var paragraph = 0; paragraph < paragraphs.length; paragraph++) {
      expect(identical(paragraphs[paragraph].sentences, sentenceLists[paragraph]), isTrue);
    }
    expect(ReadingText.anchor(formatted, 0, 2, 3), before);
  });

  test('empty and invalid index queries have no visible headings', () {
    final headings = ReaderHeadings(_book([]));
    expect(headings.showChapterLabel(0), isFalse); expect(headings.showChapterLabel(-1), isFalse);
    expect(headings.isHeading(0, 0), isFalse); expect(headings.isHeading(-1, -1), isFalse);
    final nonempty = ReaderHeadings(_book([_chapter('正文', ['没有标题。'])]));
    expect(nonempty.isHeading(0, -1), isFalse); expect(nonempty.isHeading(0, 100), isFalse);
  });
}

Book _book(List<Chapter> chapters, {BookFormat format = BookFormat.txt}) => Book(
  id: 'reader-headings', title: '标题分类', filePath: '', format: format,
  addedAt: DateTime(2026), chapters: chapters);
Chapter _chapter(String title, List<String> paragraphs) => Chapter(title: title,
  paragraphs: paragraphs.map(ReadingText.paragraph).toList());
