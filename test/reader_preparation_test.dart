import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/models/book.dart';
import 'package:duoduo_langdu/services/book_parser.dart';
import 'package:duoduo_langdu/services/reader_preparation.dart';
import 'package:duoduo_langdu/services/reading_text.dart';

void main() {
  setUp(() { ReaderPreparation.clearMemoryCache(); ReaderPreparation.runnerForTesting = null; });
  tearDown(() { ReaderPreparation.clearMemoryCache(); ReaderPreparation.runnerForTesting = null; });
  Book source(String id) => Book(id: id, title: id, filePath: '', format: BookFormat.txt,
    addedAt: DateTime(2026), chapters: [Chapter(title: '正文', paragraphs: [ReadingText.paragraph('甲乙。\n丙丁。')])]);
  ReaderPreparationRequest request(Book book, {bool merge = true, bool indent = true,
      String filter = 'none', bool autoToc = true}) => ReaderPreparationRequest(book,
    merge: merge, indent: indent, filter: filter, autoExtractToc: autoToc);

  test('same source and options reuse preparation and reattach its original source maps', () async {
    var runs = 0;
    ReaderPreparation.runnerForTesting = (r) async { runs++; return ReaderPreparation.prepareSynchronously(r); };
    final book = source('memory');
    final first = await ReaderPreparation.prepare(request(book));
    // Expando metadata must be restored even if another caller attached maps.
    ReadingText.attachSourceMaps(first.book, [first.book.chapters.single.paragraphs
      .map((p) => List<int>.filled(p.display.length + 1, 999)).toList()]);
    final hit = await ReaderPreparation.prepare(request(book));
    expect(hit, same(first));
    expect(runs, 1);
    final location = ReadingText.locate(hit.book, 0, 2);
    expect(ReadingText.anchor(hit.book, 0, location.$1, location.$2), 2);
    await ReaderPreparation.prepare(request(book, merge: false));
    await ReaderPreparation.prepare(request(book, merge: false, indent: false));
    await ReaderPreparation.prepare(request(book, merge: false, indent: false, filter: 'links'));
    await ReaderPreparation.prepare(request(book, merge: false, indent: false, filter: 'links', autoToc: false));
    expect(runs, 5, reason: 'All four formatting options participate in the cache key');
    await ReaderPreparation.prepare(request(source('memory'), merge: false, indent: false, filter: 'links', autoToc: false));
    expect(runs, 6, reason: 'Equal metadata does not substitute for source Book identity');
    expect(await ReaderPreparation.prepare(request(book)), isNot(same(first)), reason: 'Only one completed preparation is retained');
  });

  test('in-flight work is shared and a late older result cannot evict the newest preparation', () async {
    final runs = <(ReaderPreparationRequest, Completer<PreparedReadingBook>)>[];
    ReaderPreparation.runnerForTesting = (r) {
      final result = Completer<PreparedReadingBook>(); runs.add((r, result)); return result.future;
    };
    final a = source('old'), b = source('new');
    final old = ReaderPreparation.prepare(request(a));
    final duplicate = ReaderPreparation.prepare(request(a));
    expect(duplicate, same(old)); expect(runs, hasLength(1));
    final newer = ReaderPreparation.prepare(request(b));
    final newest = ReaderPreparation.prepareSynchronously(runs[1].$1);
    runs[1].$2.complete(newest); await newer;
    runs[0].$2.complete(ReaderPreparation.prepareSynchronously(runs[0].$1)); await old;
    expect(await ReaderPreparation.prepare(request(b)), same(newest));
    expect(runs, hasLength(2));
  });

  test('failed work retries and cache clear invalidates pending completions', () async {
    var runs = 0;
    final pending = Completer<PreparedReadingBook>();
    ReaderPreparation.runnerForTesting = (r) {
      runs++;
      if (runs == 1) return Future.error(StateError('worker failed'));
      if (runs == 2) return pending.future;
      return Future.value(ReaderPreparation.prepareSynchronously(r));
    };
    final r = request(source('retry'));
    await expectLater(ReaderPreparation.prepare(r), throwsStateError);
    final old = ReaderPreparation.prepare(r);
    ReaderPreparation.clearMemoryCache();
    final stale = ReaderPreparation.prepareSynchronously(r);
    pending.complete(stale); await old;
    expect(await ReaderPreparation.prepare(r), isNot(same(stale)));
    expect(runs, 3);
  });

  test('oversized books skip retention and release the previous completed cache', () async {
    final text = '${List.filled(2000, List.filled(1000, '甲').join()).join()}乙';
    final paragraph = Paragraph(display: text, tts: '', sentences: const [], sentenceStartTts: const []);
    Book sized(List<Paragraph> paragraphs) => Book(id: 'budget', title: 'budget', filePath: '',
      format: BookFormat.txt, addedAt: DateTime(2026), chapters: [Chapter(title: '正文', paragraphs: paragraphs)]);
    final big = sized([paragraph]);
    expect(BookParser.fitsMemoryCache(big), isTrue);
    expect(BookParser.fitsMemoryCache(sized([paragraph, paragraph])), isFalse);
    var runs = 0;
    ReaderPreparation.runnerForTesting = (r) async {
      runs++;
      // No full text processing is needed to exercise retention policy.
      return PreparedReadingBook(r.source, 'budget', const [], const [], const [], const []);
    };
    final small = source('small');
    await ReaderPreparation.prepare(request(small));
    await ReaderPreparation.prepare(request(big));
    await ReaderPreparation.prepare(request(big));
    await ReaderPreparation.prepare(request(small));
    expect(runs, 4, reason: 'The combined source/formatted display budget is 4M characters, not one unbounded book');
  });

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
