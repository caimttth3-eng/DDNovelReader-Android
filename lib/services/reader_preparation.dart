import 'dart:isolate';
import 'package:flutter/foundation.dart';
import '../models/book.dart';
import 'book_parser.dart';
import 'reading_text.dart';

class ReaderPreparationRequest {
  final Book source;
  final bool merge, indent, autoExtractToc;
  final String filter;
  const ReaderPreparationRequest(this.source, {required this.merge, required this.indent,
    required this.filter, required this.autoExtractToc});
}

class PreparedReadingBook {
  final Book book;
  final String fingerprint;
  final List<List<List<int>>> sourceMaps;
  final List<BookTocEntry> toc;
  final List<int> tocAnchors;
  final List<bool> chapterTitles;
  const PreparedReadingBook(this.book, this.fingerprint, this.sourceMaps, this.toc, this.tocAnchors, this.chapterTitles);
  void attachSourceMaps() => ReadingText.attachSourceMaps(book, sourceMaps);
}

typedef ReaderPreparationRunner = Future<PreparedReadingBook> Function(ReaderPreparationRequest request);

class ReaderPreparation {
  @visibleForTesting
  static ReaderPreparationRunner? runnerForTesting;

  static Future<PreparedReadingBook> prepare(ReaderPreparationRequest request) {
    final runner = runnerForTesting;
    return runner != null ? runner(request) : Isolate.run(() => prepareSynchronously(request));
  }

  @visibleForTesting
  static PreparedReadingBook prepareSynchronously(ReaderPreparationRequest request) {
    final source = request.source;
    final book = ReadingText.format(source, merge: request.merge, indent: request.indent, filter: request.filter);
    final maps = ReadingText.sourceMapsForTransfer(book);
    final rawToc = BookParser.extractToc(source, autoExtractToc: request.autoExtractToc);
    final toc = <BookTocEntry>[], anchors = <int>[], titles = <bool>[];
    final spaces = RegExp(r'\s');
    var chapter = -1, sourceParagraph = 0, sourceOffset = 0, anchor = 0, paragraph = 0, offset = 0;
    // Both indices are sorted in source order. Consume each source/display
    // character at most once rather than rescanning a long chapter per entry.
    for (final entry in rawToc) {
      final c = entry.chapterIndex;
      if (chapter != c) { chapter = c; sourceParagraph = 0; sourceOffset = 0; anchor = 0; paragraph = 0; offset = 0; }
      final originals = source.chapters[c].paragraphs;
      while (sourceParagraph <= entry.paragraphIndex) {
        final text = originals[sourceParagraph].display;
        final end = sourceParagraph == entry.paragraphIndex ? entry.displayOffset : text.length;
        while (sourceOffset < end) { if (!spaces.hasMatch(text[sourceOffset])) anchor++; sourceOffset++; }
        if (sourceParagraph == entry.paragraphIndex) break;
        sourceParagraph++; sourceOffset = 0;
      }
      anchors.add(anchor);
      final paragraphs = book.chapters[c].paragraphs;
      var found = false;
      while (paragraph < paragraphs.length) {
        final text = paragraphs[paragraph].display;
        while (offset < text.length) {
          if (!spaces.hasMatch(text[offset]) && maps[c][paragraph][offset] >= anchor) { found = true; break; }
          offset++;
        }
        if (found) break;
        paragraph++; offset = 0;
      }
      final p = found ? paragraph : paragraphs.length - 1;
      final at = found ? offset : paragraphs.last.display.length;
      toc.add(BookTocEntry(title: entry.title, chapterIndex: c, paragraphIndex: p, displayOffset: at));
      titles.add(entry.paragraphIndex == 0 && entry.displayOffset == 0 && entry.title == source.chapters[c].title &&
        !originals.first.display.trimLeft().startsWith(entry.title));
    }
    return PreparedReadingBook(book, 'words1-${ReadingText.fingerprint(book)}', maps, toc, anchors, titles);
  }
}
