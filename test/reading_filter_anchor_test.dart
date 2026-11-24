import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/models/book.dart';
import 'package:duoduo_langdu/services/reading_text.dart';
import 'package:duoduo_langdu/services/reader_preparation.dart';

Book fixture() => Book(id: 'filter-anchor', title: '合成过滤定位', filePath: '',
  format: BookFormat.txt, addedAt: DateTime(2026), chapters: [
    Chapter(title: '第一章', paragraphs: [
      ReadingText.paragraph('开篇正文。\n𠀀星👩🏽‍💻目标正文。'),
      ReadingText.paragraph('联系https://example.com/book。保留甲。'),
      ReadingText.paragraph('请访问本站获取更多小说。'),
      ReadingText.paragraph('求月票和收藏！'),
      ReadingText.paragraph('联系www.example.com或reader@example.org。保留乙。'),
      ReadingText.paragraph('裸域名abc.example仍是正文。\n最后目标正文。'),
    ]),
    Chapter(title: '第二章', paragraphs: [ReadingText.paragraph('第二章目标正文。')]),
  ]);

(int, int) phrasePosition(Book book, int chapter, String phrase) {
  final paragraphs = book.chapters[chapter].paragraphs;
  for (var p = 0; p < paragraphs.length; p++) {
    final offset = paragraphs[p].display.indexOf(phrase);
    if (offset >= 0) return (p, offset);
  }
  throw StateError('Missing synthetic phrase: $phrase');
}

void main() {
  test('filter levels are cumulative and retain bare domains without rewriting the source', () {
    final source = fixture();
    final raw = source.chapters.first.paragraphs.map((p) => p.display).join('\n');
    for (final filter in ['none', 'links', 'ads', 'extra']) {
      final result = ReadingText.format(source, merge: false, indent: false, filter: filter);
      final text = result.chapters.first.paragraphs.map((p) => p.display).join('\n');
      for (final address in ['https://example.com/book', 'www.example.com', 'reader@example.org']) {
        expect(text.contains(address), filter == 'none', reason: '$filter: $address');
      }
      expect(text.contains('请访问本站'), filter == 'none' || filter == 'links', reason: filter);
      expect(text.contains('求月票和收藏'), filter != 'extra', reason: filter);
      expect(text, contains('裸域名abc.example仍是正文。'), reason: filter);
      expect(text, contains('保留甲。'), reason: filter);
      expect(text, contains('保留乙。'), reason: filter);
      expect(source.chapters.first.paragraphs.map((p) => p.display).join('\n'), raw);
    }
  });

  for (final merge in [false, true]) {
    for (final indent in [false, true]) {
      test('surviving source and sentence positions round-trip through repeated filters merge=$merge indent=$indent', () {
        final source = fixture();
        final fingerprints = <String, String>{};
        for (final filter in ['none', 'links', 'ads', 'extra', 'none', 'extra', 'links', 'ads', 'none']) {
          final result = ReadingText.format(source, merge: merge, indent: indent, filter: filter);
          for (final target in [(0, '目标正文'), (0, '保留甲'), (0, '保留乙'), (0, '裸域名abc.example'),
              (0, '最后目标正文'), (1, '第二章目标正文')]) {
            final original = phrasePosition(source, target.$1, target.$2);
            final anchor = ReadingText.anchor(source, target.$1, original.$1, original.$2);
            final located = ReadingText.locate(result, target.$1, anchor);
            final paragraph = result.chapters[target.$1].paragraphs[located.$1];
            expect(paragraph.display.substring(located.$2), startsWith(target.$2), reason: '$filter / $target');
            expect(ReadingText.anchor(result, target.$1, located.$1, located.$2), anchor);
            expect(result.charOffsetOf(target.$1, located.$1, located.$2),
              source.charOffsetOf(target.$1, original.$1, original.$2), reason: 'Canonical source position survives filtering');
            final sentence = paragraph.sentences[ReadingText.sentenceAt(paragraph, located.$2)];
            expect(sentence.displayStart, lessThanOrEqualTo(located.$2));
            expect(sentence.displayEnd, greaterThan(located.$2));
            expect(sentence.display[located.$2 - sentence.displayStart], target.$2[0],
              reason: 'The containing sentence starts at the same source character even when a domain spans sentences');
          }
          final fingerprint = ReadingText.fingerprint(result);
          if (fingerprints.containsKey(filter)) expect(fingerprint, fingerprints[filter], reason: 'Returning to a filter restores its cache text identity');
          fingerprints[filter] = fingerprint;
        }
        expect(fingerprints.values.toSet(), hasLength(4), reason: 'Changed speech content cannot reuse another filter partition');
      });
    }
  }

  test('a deleted anchor projects forward to surviving text rather than resurrecting a hidden line', () {
    final source = fixture();
    for (final target in [
      ('links', 'https://example.com/book', '。保留甲。'),
      ('ads', '请访问本站', '求月票和收藏！'),
      ('extra', '求月票和收藏', '联系'),
    ]) {
      final original = phrasePosition(source, 0, target.$2);
      final anchor = ReadingText.anchor(source, 0, original.$1, original.$2 + 1);
      final result = ReadingText.format(source, merge: false, indent: true, filter: target.$1);
      final location = ReadingText.locate(result, 0, anchor);
      final display = result.chapters.first.paragraphs[location.$1].display;
      expect(display.substring(location.$2), startsWith(target.$3));
      expect(ReadingText.anchor(result, 0, location.$1, location.$2), greaterThan(anchor));
    }
  });

  test('an entirely filtered chapter has a safe end anchor and no speech sentences', () {
    final source = Book(id: 'empty-filter', title: '合成空章', filePath: '', format: BookFormat.txt,
      addedAt: DateTime(2026), chapters: [Chapter(title: '第一章', paragraphs: [
        ReadingText.paragraph('https://example.com/book'),
        ReadingText.paragraph('请访问本站获取更多小说。'),
        ReadingText.paragraph('求月票和收藏！'),
      ])]);
    final result = ReadingText.format(source, merge: true, indent: false, filter: 'extra');
    expect(result.chapters.single.paragraphs.single.display, isEmpty);
    expect(result.chapters.single.paragraphs.single.sentences, isEmpty);
    expect(ReadingText.locate(result, 0, 1), (0, 0));
    expect(ReadingText.anchor(result, 0, 0, 0),
      ReadingText.anchor(source, 0, 2, source.chapters.single.paragraphs.last.display.length));
  });

  test('prepared source maps preserve filtered positions when attached to a transferred book', () {
    final source = fixture();
    for (final filter in ['none', 'links', 'ads', 'extra', 'none']) {
      final prepared = ReaderPreparation.prepareSynchronously(ReaderPreparationRequest(source,
        merge: true, indent: true, filter: filter, autoExtractToc: false));
      final transferred = Book(id: prepared.book.id, title: prepared.book.title, filePath: '',
        format: prepared.book.format, addedAt: prepared.book.addedAt, chapters: prepared.book.chapters);
      PreparedReadingBook(transferred, prepared.fingerprint, prepared.sourceMaps,
        prepared.toc, prepared.tocAnchors, prepared.chapterTitles).attachSourceMaps();
      final original = phrasePosition(source, 0, '最后目标正文');
      final anchor = ReadingText.anchor(source, 0, original.$1, original.$2);
      final location = ReadingText.locate(transferred, 0, anchor);
      expect(transferred.chapters.first.paragraphs[location.$1].display.substring(location.$2), startsWith('最后目标正文'));
      expect(ReadingText.anchor(transferred, 0, location.$1, location.$2), anchor);
      expect(prepared.fingerprint, 'words2-${ReadingText.fingerprint(transferred)}');
    }
  });
}
