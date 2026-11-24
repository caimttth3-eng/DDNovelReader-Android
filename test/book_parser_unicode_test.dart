import 'dart:convert';
import 'dart:io';

import 'package:duoduo_langdu/models/book.dart';
import 'package:duoduo_langdu/services/book_parser.dart';
import 'package:duoduo_langdu/services/chapterizer.dart';
import 'package:duoduo_langdu/services/content_key.dart';
import 'package:duoduo_langdu/services/tts_cache_store.dart';
import 'package:duoduo_langdu/services/tts_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  setUp(() async {
    BookParser.clearMemoryCache();
    directory = await Directory.systemTemp.createTemp('book-parser-unicode-');
  });
  tearDown(() async {
    BookParser.clearMemoryCache();
    await directory.delete(recursive: true);
  });

  Future<Book> parse(String source, {String name = 'source.txt'}) async {
    final file = await File('${directory.path}${Platform.pathSeparator}$name')
        .writeAsBytes([0xef, 0xbb, 0xbf, ...utf8.encode(source)]);
    return BookParser().parse(
      id: 'unicode', filePath: file.path, title: 'Unicode',
      format: BookFormat.txt, addedAt: DateTime.utc(2026, 11, 20),
    );
  }

  test('UTF8 BOM supplementary CJK import', () async {
    const source = '甲𠀀。';
    final book = await parse(source);
    expect(book.parseOk, isTrue, reason: book.parseError);
    final chapter = book.chapters.single;
    final paragraph = chapter.paragraphs.single;
    final sentence = paragraph.sentences.single;
    expect(paragraph.display, source);
    expect(paragraph.tts, source);
    expect(sentence.display, source);
    expect(sentence.tts, source);
    expect((sentence.displayStart, sentence.displayEnd), (0, 4));
    expect(paragraph.sentenceStartTts, [0]);
    expect(chapter.sourceCoordinates, [0, 1, 1, 2, 3]);
    expect(chapterSentenceOffsets(chapter), [0]);
    expect(book.charOffsetOf(0, 0, 4), 3);
    expect(book.locateByCharOffset(0, 2), (0, 3));
    expect(bookFullText(book), '$source\n');
    expect(book.contentKey, '4d48752f355bf8f7');
  });

  test('untitled TXT parse retains block source tables without generated visible labels', () async {
    final a = List.filled(400, '甲𠀀。').join();
    final b = List.filled(400, '乙𠀁。').join();
    final c = List.filled(600, '丙𠀂。').join();
    final book = await parse('$a\n\n$b\n\n$c', name: 'untitled-blocks.txt');
    expect(book.parseOk, isTrue, reason: book.parseError);
    expect(book.chapters.map((chapter) => chapter.title), ['', '']);
    expect(book.chapters.map((chapter) => chapter.paragraphs.map((p) => p.display).toList()), [[a, b], [c]]);
    expect(bookFullText(book), '$a\n$b\n$c\n');
    expect(book.contentKey, computeContentKey('Unicode', 2, '$a\n$b\n$c\n'));
    final bodies = ['$a\n$b', c];
    for (var index = 0; index < book.chapters.length; index++) {
      final chapter = book.chapters[index];
      expect(chapter.sourceCoordinates, canonicalSourceOffsets(bodies[index]));
      expect(chapter.sourceCoordinates.length, bodies[index].length + 1);
      expect(chapter.sourceCoordinates[1], 1);
      expect(chapter.sourceCoordinates[2], 1);
      expect(chapter.sourceCoordinates.last, bodies[index].runes.length);
      for (final paragraph in chapter.paragraphs) {
        expect(paragraph.tts, paragraph.display);
      }
    }
    for (final automatic in [false, true]) {
      final toc = BookParser.extractToc(book, autoExtractToc: automatic);
      expect(toc, isNotEmpty);
      for (final entry in toc) {
        final original = book.chapters[entry.chapterIndex].paragraphs[entry.paragraphIndex].display;
        expect(original.substring(entry.displayOffset), startsWith(entry.title));
        expect(entry.title.runes.length, lessThanOrEqualTo(24));
        expect(entry.title, isNot(matches(RegExp(r'^第\s*\d+\s*节$|^正文$|^简介$'))));
      }
    }
  });

  test('emoji cleanup preserves source layout and coordinates', () async {
    const source = '　　甲🙂𠀀！？\n  乙𠀁';
    final book = await parse(source);
    expect(book.parseOk, isTrue, reason: book.parseError);
    final chapter = book.chapters.single;
    final paragraph = chapter.paragraphs.single;
    expect(paragraph.display, source);
    expect(paragraph.tts, '甲𠀀？乙𠀁');
    expect(paragraph.sentences.map((s) => s.tts), ['甲𠀀？', '乙𠀁']);
    expect(paragraph.sentences.map((s) => s.display), ['　　甲🙂𠀀！？', '  乙𠀁']);
    expect(paragraph.sentences.map((s) => (s.displayStart, s.displayEnd)), [(0, 9), (10, 15)]);
    expect(paragraph.sentenceStartTts, [0, 4]);
    expect(chapter.sourceCoordinates, [0, 0, 0, 1, 1, 2, 2, 3, 4, 5, 6, 6, 6, 7, 7, 8]);
    expect(chapterSentenceOffsets(chapter), [0, 6]);
    expect(book.charOffsetOf(0, 0, paragraph.sentences.first.displayEnd), 5);
    expect(book.charOffsetOf(0, 0, paragraph.sentences.last.displayEnd), 8);
  });

  test('160-codepoint chunks preserve supplementary CJK', () async {
    for (final count in [159, 160]) {
      final prefix = List.filled(count, '甲').join();
      final source = '${prefix}𠀀乙。';
      final first = count == 159 ? '${prefix}𠀀' : prefix;
      final second = count == 159 ? '乙。' : '𠀀乙。';
      final book = await parse(source, name: 'boundary-$count.txt');
      expect(book.parseOk, isTrue, reason: book.parseError);
      final chapter = book.chapters.single;
      final paragraph = chapter.paragraphs.single;
      expect(paragraph.display, source);
      expect(paragraph.tts, source);
      expect(paragraph.sentences.map((s) => s.tts), [first, second]);
      expect(paragraph.sentences.map((s) => s.display), [first, second]);
      expect(paragraph.sentences.map((s) => (s.displayStart, s.displayEnd)),
        [(0, first.length), (first.length, source.length)]);
      expect(paragraph.sentenceStartTts, [0, first.length]);
      expect(chapterSentenceOffsets(chapter), [0, 160]);
      expect(chapter.sourceCoordinates[count], count);
      expect(chapter.sourceCoordinates[count + 1], count);
      expect(chapter.sourceCoordinates.last, count + 3);
    }
  });

  test('TTS cmap maps both surrogate units', () {
    const source = ' 甲🙂𠀀！？\n---\n𠀁';
    final clean = preprocessForTts(source);
    expect(clean.clean, '甲𠀀？𠀁');
    expect(clean.cmap, [1, 4, 5, 7, 13, 14]);
    expect(splitSentenceRanges(clean.clean), [(0, 4), (4, 6)]);
  });

  test('comma fallback uses codepoint thresholds', () {
    for (final comma in ['，', ',']) {
      for (final count in [79, 80]) {
        final prefix = List.filled(count, '𠀀').join();
        final tail = List.filled(81, '乙').join();
        final clean = '$prefix$comma$tail。';
        final ranges = splitSentenceRanges(clean);
        expect(ranges, count == 79 ? [(0, 239), (239, 241)] : [(0, 160), (160, 243)]);
        expect(ranges.map((r) => clean.substring(r.$1, r.$2)), count == 79
          ? ['$prefix$comma${List.filled(80, '乙').join()}', '乙。']
          : [prefix, '$comma$tail。']);
      }
    }
  });
}
