import 'dart:convert';
import 'dart:io';

import 'package:characters/characters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/models/book.dart';
import 'package:duoduo_langdu/models/progress.dart';
import 'package:duoduo_langdu/services/app_storage.dart';
import 'package:duoduo_langdu/services/book_snapshot_cache.dart';
import 'package:duoduo_langdu/services/reader_preparation.dart';
import 'package:duoduo_langdu/services/reading_text.dart';

void main() {
  setUp(() {
    ReaderPreparation.clearMemoryCache();
    ReaderPreparation.runnerForTesting = null;
  });
  tearDown(() {
    ReaderPreparation.clearMemoryCache();
    ReaderPreparation.runnerForTesting = null;
  });

  test('inventory deduplicates complete CJK emoji and combining graphemes without splitting or normalization', () {
    final book = _book('clusters', [Chapter(title: '第一章 锦🐉', paragraphs: [
      _paragraph('中中👩🏽‍💻👩🏽‍💻e\u0301e\u0301éé🇨🇳🇨🇳'),
      _paragraph(' \t\r\n\u200B\u200C\u200D\u2060\uFEFF\uFE0F\u034F'),
    ])]);
    final probe = ReaderPreparation.collectFontProbeText(book);
    expect(probe.split(' '), ['第', '一', '章', '锦', '🐉', '中', '👩🏽‍💻', 'e\u0301', 'é', '🇨🇳']);
    expect(probe, isNot(contains('\n')));
    expect(probe, isNot(contains('\r')));
    expect(probe.split(' ').toSet().length, probe.split(' ').length);
    expect('👩🏽‍💻'.characters, hasLength(1));
    expect('e\u0301'.characters, hasLength(1));
    expect(probe.split(' '), isNot(contains('e')));
    expect(probe.split(' '), isNot(contains('\u0301')));
    expect(probe, contains('\u200D'), reason: 'A meaningful emoji joiner must survive the separator-only filter');
  });

  test('all displayed source headings and genuine metadata are included, while non-displayed metadata is excluded', () {
    final txt = _book('titles', [
      Chapter(title: '第39节', paragraphs: [_paragraph('第39节'), _paragraph('甲')]),
      Chapter(title: 'Chapter 2 Ω', paragraphs: [_paragraph('乙')]),
      Chapter(title: 'ONLYMETA', paragraphs: [_paragraph('丙')]),
      Chapter(title: '', paragraphs: [_paragraph('丁')]),
    ]);
    final tokens = ReaderPreparation.collectFontProbeText(txt).split(' ');
    for (final cluster in ['第', '3', '9', '节', '甲', 'C', 'h', 'a', 'p', 't', 'e', 'r', '2', 'Ω', '乙', '丙', '丁']) {
      expect(tokens, contains(cluster));
    }
    expect(tokens.where((token) => token == '节'), hasLength(1), reason: 'Metadata duplicated in the source does not add a second token');
    expect(tokens, isNot(contains('O')));
    expect(tokens, isNot(contains('Y')));
    final epub = _book('epub-metadata', [Chapter(title: 'Ω附录', paragraphs: [_paragraph('正文')])], format: BookFormat.epub);
    expect(ReaderPreparation.collectFontProbeText(epub).split(' '), containsAll(['Ω', '附', '录']));
  });

  test('inventory is complete beyond common preview limits and has no silent truncation', () {
    final clusters = List.generate(9000, (index) => String.fromCharCode(0x4E00 + index));
    final book = _book('complete', [Chapter(title: '', paragraphs: [_paragraph(clusters.join())])]);
    final probe = ReaderPreparation.collectFontProbeText(book);
    expect(probe.split(' '), orderedEquals(clusters));
    expect(probe.split(' ').last, clusters.last);
    expect(probe.length, greaterThan(8192));
    expect(ReaderPreparation.collectFontProbeText(_book('empty', const [])), isEmpty);
  });

  test('cold preparation adds inventory without rewriting body identity fingerprint or source coordinates', () {
    final source = _sample('cold');
    final before = _shape(source), originalParagraph = source.chapters.first.paragraphs.last;
    final expectedBook = ReadingText.format(source, merge: false, indent: true, filter: 'links');
    final expectedMaps = ReadingText.sourceMapsForTransfer(expectedBook);
    final prepared = ReaderPreparation.prepareSynchronously(_request(source, filter: 'links'));
    expect(_shape(source), before);
    expect(source.chapters.first.paragraphs.last, same(originalParagraph));
    expect(_shape(prepared.book), _shape(expectedBook));
    expect(prepared.sourceMaps, expectedMaps);
    expect(prepared.book.id, source.id); expect(prepared.book.contentKey, source.contentKey);
    expect(prepared.fingerprint, 'words2-${ReadingText.fingerprint(expectedBook)}');
    final preparedIdentity = prepared.book, mapsIdentity = prepared.sourceMaps;
    expect(prepared.fontProbeText, ReaderPreparation.collectFontProbeText(prepared.book, headings: prepared.headings));
    expect(prepared.book, same(preparedIdentity)); expect(prepared.sourceMaps, same(mapsIdentity));
    prepared.attachSourceMaps();
    final sourceText = originalParagraph.display;
    final anchor = ReadingText.anchor(source, 0, 1, sourceText.indexOf('尾段'));
    final location = ReadingText.locate(prepared.book, 0, anchor);
    expect(prepared.book.chapters[0].paragraphs[location.$1].display.substring(location.$2), startsWith('尾段'));
    expect(ReadingText.anchor(prepared.book, 0, location.$1, location.$2), anchor);
    final legacy = PreparedReadingBook(source, 'legacy', const [], const [], const [], const []);
    expect(legacy.fontProbeText, isNull, reason: 'Existing constructors remain source-compatible');
  });

  test('the existing preparation memory cache reuses the complete inventory and prepared graph', () async {
    var runs = 0;
    ReaderPreparation.runnerForTesting = (request) async {
      runs++;
      return ReaderPreparation.prepareSynchronously(request);
    };
    final request = _request(_sample('memory'));
    final first = await ReaderPreparation.prepare(request), second = await ReaderPreparation.prepare(request);
    expect(second, same(first)); expect(runs, 1);
    expect(second.fontProbeText, isNotNull);
    expect(second.fontProbeText, first.fontProbeText);
    expect(second.fontProbeText!.split(' '), contains('👩🏽‍💻'));
  });

  test('snapshot worker derives the same complete inventory as cold preparation without changing snapshot schema', () async {
    // LocalBuild redirects systemTemp to this project's managed test TEMP.
    // Every file below is newly created synthetic data owned by this test.
    final directory = await Directory.systemTemp.createTemp('reader-font-inventory-');
    try {
      final original = File('${directory.path}/source.txt');
      final template = _sample('snapshot');
      await original.writeAsString(template.chapters.expand((chapter) => chapter.paragraphs).map((paragraph) => paragraph.display).join('\n'));
      final source = _book(template.id, template.chapters, filePath: original.path);
      final meta = BookMeta(id: source.id, title: source.title, filePath: source.filePath,
        format: source.format.name, addedAt: source.addedAt);
      final settings = ReadingSettings()..mergeNonSentenceBreaks = false..firstLineIndent = true
        ..informationFilter = false..autoExtractToc = true;
      final cold = ReaderPreparation.prepareSynchronously(_request(source));
      final directoryPath = '${directory.path}/snapshot';
      final cache = BookSnapshotCache(directoryPath: directoryPath);
      final lookup = await cache.lookup(meta, settings);
      await cache.save(lookup, source, cold);
      final memory = (await cache.lookup(meta, settings)).snapshot!;
      expect(memory.prepared, same(cold));
      final stored = jsonDecode(await File('$directoryPath/latest.json').readAsString()) as Map<String, dynamic>;
      expect(stored['schema'], BookSnapshotCache.schema);
      expect(stored.containsKey('fontProbeText'), isFalse, reason: 'The derived inventory need not duplicate serialized source content');
      final restored = (await BookSnapshotCache(directoryPath: directoryPath).lookup(meta, settings)).snapshot!;
      expect(restored.prepared, isNot(same(cold)), reason: 'This must exercise the actual disk read worker, not a memory hit');
      expect(restored.prepared.fontProbeText, cold.fontProbeText);
      expect(restored.prepared.fontProbeText!.split(' '), containsAll(['👩🏽‍💻', 'e\u0301', 'Ω']));
      expect(_shape(restored.source), _shape(source));
      expect(_shape(restored.prepared.book), _shape(cold.book));
      expect(restored.prepared.sourceMaps, cold.sourceMaps);
      expect(restored.prepared.fingerprint, cold.fingerprint);
      expect(restored.prepared.tocAnchors, cold.tocAnchors);
      final again = ReaderPreparation.prepareSynchronously(_request(restored.source));
      expect(again.fontProbeText, restored.prepared.fontProbeText);
    } finally {
      await directory.delete(recursive: true);
    }
  });
}

Paragraph _paragraph(String display) => Paragraph(display: display, tts: display,
  sentences: [Sentence(display, display, displayEnd: display.length)], sentenceStartTts: const [0]);

Book _book(String id, List<Chapter> chapters, {BookFormat format = BookFormat.txt, String filePath = ''}) =>
  Book(id: id, title: '字体清单合成文本', filePath: filePath, format: format,
    contentKey: '0123456789abcdef', addedAt: DateTime(2026), chapters: chapters);

Book _sample(String id) => _book(id, [
  Chapter(title: '第一章 原文', paragraphs: [
    _paragraph('第一章 原文'), _paragraph('甲中👩🏽‍💻e\u0301👩🏽‍💻 https://example.invalid/link 尾段继续。'),
  ]),
  Chapter(title: 'Chapter 2 Ω', paragraphs: [_paragraph('乙丙丁，余下文字。')]),
]);

ReaderPreparationRequest _request(Book source, {String filter = 'none'}) => ReaderPreparationRequest(source,
  merge: false, indent: true, filter: filter, autoExtractToc: true);

Map<String, Object?> _shape(Book book) => {
  'identity': [book.id, book.title, book.filePath, book.format.name, book.contentKey, book.addedAt.toIso8601String()],
  'chapters': [for (final chapter in book.chapters) {
    'title': chapter.title, 'coordinates': List<int>.of(chapter.sourceCoordinates),
    'paragraphs': [for (final paragraph in chapter.paragraphs) {
      'display': paragraph.display, 'tts': paragraph.tts, 'starts': paragraph.sentenceStartTts,
      'sentences': [for (final sentence in paragraph.sentences) [sentence.display, sentence.tts,
        sentence.displayStart, sentence.displayEnd, sentence.pauseAfterMilliseconds]],
    }],
  }],
};
