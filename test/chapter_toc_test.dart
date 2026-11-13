import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/models/book.dart';
import 'package:duoduo_langdu/services/book_parser.dart';
import 'package:duoduo_langdu/services/chapterizer.dart';
import 'package:duoduo_langdu/services/reading_text.dart';

Book source(List<Chapter> chapters) => Book(id: 'toc', title: 'book', filePath: '',
  format: BookFormat.txt, addedAt: DateTime(2026), chapters: chapters);
Chapter chapter(String title, String text) => Chapter(title: title, paragraphs: [ReadingText.paragraph(text)]);

void main() {
  test('trusted Chinese, traditional, English and mixed volume headings include a single chapter', () {
    for (final title in ['第一章 开始', '第 壹佰二十 節 開端', '第２章 继续', '卷三 江湖',
      '第十回 重逢', 'CHAPTER IV Return', 'Section 12 Start', '楔子', '【第一章 开端】']) {
      expect(detectChapterTitles('$title\n正文内容。').single.title, title.replaceAll('【', '').replaceAll('】', ''));
    }
    expect(detectChapterTitles('第一卷 江湖\n内容。\n第1章 初见\n内容。\n第二章 再见').length, 3);
  });

  test('body references, lessons, rounds, adverts and unnumbered short lines stay body text', () {
    const text = '第一章已经读完了\n第一节课马上开始\n第二回合即将开始\n第三部分已经结束\n'
      '他说第十章很精彩\n第一章 这是一段正文。\n第1章 https://example.com\n初入江湖\n“第一章 开始”';
    expect(detectChapterTitles(text), isEmpty);
  });

  test('ambiguous numeric headings need separated recurring entries', () {
    expect(detectChapterTitles('1、准备工作\n2、马上出发'), isEmpty);
    expect(detectChapterTitles('001 初见\n正文。\n002 再遇\n正文。').map((e) => e.title), ['001 初见', '002 再遇']);
    expect(detectChapterTitles('一、初见\n正文。\n二、再遇').length, 2);
  });

  test('TOC indexing retains the complete original book and precise physical coordinates', () {
    const text = '前言内容。\n　　第一章 开始\n正文。\n第二章 后续\n后来。';
    final book = source([chapter('第 1 节', text)]);
    final before = book.chapters.single.paragraphs.single.display;
    final entries = BookParser.extractToc(book);
    expect(entries.map((e) => e.title), ['正文', '第一章 开始', '第二章 后续']);
    expect(entries[1].displayOffset, text.indexOf('第一章'));
    expect(entries[2].displayOffset, text.indexOf('第二章'));
    expect(book.chapters.single.paragraphs.single.display, before);
    final formatted = ReadingText.format(book, merge: true, indent: true);
    final entry = entries[2];
    final anchor = ReadingText.anchor(book, entry.chapterIndex, entry.paragraphIndex, entry.displayOffset);
    final target = ReadingText.locate(formatted, entry.chapterIndex, anchor);
    expect(formatted.chapters[0].paragraphs[target.$1].display.substring(target.$2), startsWith('第二章'));
  });

  test('legacy chapter metadata is retained once and paragraph offsets remain exact', () {
    final book = source([Chapter(title: '第一章 开始', paragraphs: [
      ReadingText.paragraph('　　第一章 开始'), ReadingText.paragraph('内容。\n第二章 后续\n正文。')])]);
    final entries = BookParser.extractToc(book);
    expect(entries.map((e) => e.title), ['第一章 开始', '第二章 后续']);
    expect(entries.last.paragraphIndex, 1);
    expect(entries.last.displayOffset, '内容。\n'.length);
  });

  test('synthetic base sections do not pollute detected chapter titles', () {
    final book = source([chapter('第 1 节', '第一章 初见\n正文。'),
      chapter('第 2 节', '第二章 再遇\n正文。')]);
    final entries = BookParser.extractToc(book);
    expect(entries.map((e) => e.title), ['第一章 初见', '第二章 再遇']);
    expect(entries.map((e) => e.chapterIndex), [0, 1]);
  });

  test('disabled extraction makes 5000-character virtual sections without splitting surrogate pairs', () {
    final text = '${List.filled(4999, '甲').join()}😀乙丙';
    final book = source([chapter('第一章', text)]);
    final entries = BookParser.extractToc(book, autoExtractToc: false);
    expect(entries.map((e) => e.title), ['第 1 节', '第 2 节']);
    expect(entries.last.displayOffset, 5001);
    expect(text.substring(entries.last.displayOffset), '乙丙');
    expect(BookParser.extractToc(source([])), isEmpty);
  });
}
