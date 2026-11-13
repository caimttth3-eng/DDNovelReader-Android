import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/models/book.dart';
import 'package:duoduo_langdu/services/book_parser.dart';
import 'package:duoduo_langdu/services/reader_preparation.dart';
import 'package:duoduo_langdu/services/reading_text.dart';

void main() {
  for (final merge in [false, true]) {
    test('real worker transfers filtered progress and annotation anchors merge=$merge', () async {
      const text = '开篇尚未结束\n第一章 山中\n前文 https://example.com/a?x=1\n继续前进，看见树林。\n第二章 海边\n海边还有后文。';
      final source = Book(id: 'worker', title: 'worker', filePath: '', format: BookFormat.txt,
        addedAt: DateTime(2026), chapters: [Chapter(title: '正文', paragraphs: [ReadingText.paragraph(text)])]);
      final start = ReadingText.anchor(source, 0, 0, text.indexOf('继续前进'));
      final end = ReadingText.anchor(source, 0, 0, text.indexOf('继续前进') + 4);
      final prepared = await ReaderPreparation.prepare(ReaderPreparationRequest(source,
        merge: merge, indent: true, filter: 'links', autoExtractToc: true));
      // This is the UI-isolate install step. Merely transferring Book would
      // lose its worker-isolate Expando and misplace these source coordinates.
      prepared.attachSourceMaps();
      final progress = ReadingText.locate(prepared.book, 0, start);
      final highlightEnd = ReadingText.locate(prepared.book, 0, end);
      final display = prepared.book.chapters[0].paragraphs[progress.$1].display;
      expect(display.substring(progress.$2), startsWith('继续前进'));
      expect(ReadingText.anchor(prepared.book, 0, progress.$1, progress.$2), start);
      expect(highlightEnd.$1, progress.$1);
      expect(display.substring(progress.$2, highlightEnd.$2), '继续前进');
      expect(prepared.book.chapters[0].paragraphs.any((p) => p.display.contains('example.com')), isFalse);
      expect(prepared.toc.map((entry) => entry.title), ['正文', '第一章 山中', '第二章 海边']);
      final rawToc = BookParser.extractToc(source);
      for (var i = 0; i < rawToc.length; i++) {
        final raw = rawToc[i], actual = prepared.toc[i];
        final anchor = ReadingText.anchor(source, raw.chapterIndex, raw.paragraphIndex, raw.displayOffset);
        expect(prepared.tocAnchors[i], anchor);
        expect(ReadingText.anchor(prepared.book, actual.chapterIndex, actual.paragraphIndex, actual.displayOffset), anchor);
        expect(ReadingText.locate(prepared.book, actual.chapterIndex, anchor), (actual.paragraphIndex, actual.displayOffset));
      }
      expect(prepared.fingerprint, matches(RegExp(r'^words1-[a-f0-9]{20}$')));
    });
  }
}
