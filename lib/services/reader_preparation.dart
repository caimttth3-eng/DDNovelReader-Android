// 来源：NayGnehz/DDNovelReader-Android 的 PR #2（commit 27b6a1e，部分代码，已修改适配本项目的缓存/同步架构）。
import 'dart:isolate';
import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';
import '../models/book.dart';
import '../models/progress.dart';
import 'app_storage.dart';
import 'reader_header_layout.dart';
import 'book_parser.dart';
import 'reading_text.dart';
import 'reader_headings.dart';
import 'speech_breaks.dart';

class ReaderPreparationRequest {
  final Book source;
  final bool merge, indent, autoExtractToc;
  final String filter;
  final SpeechPauseSettings pauseSettings;
  const ReaderPreparationRequest(this.source, {required this.merge, required this.indent,
    required this.filter, required this.autoExtractToc, this.pauseSettings = const SpeechPauseSettings()});
}

class PreparedReadingBook {
  final Book book;
  final String fingerprint;
  final List<List<List<int>>> sourceMaps;
  final List<BookTocEntry> toc;
  final List<int> tocAnchors;
  final List<bool> chapterTitles;
  final ReaderHeadings? headings;
  /// Complete distinct displayed grapheme clusters for later native font-face
  /// probing. This is an inventory, not proof of final page/glyph geometry.
  final String? fontProbeText;
  const PreparedReadingBook(this.book, this.fingerprint, this.sourceMaps, this.toc, this.tocAnchors, this.chapterTitles,
    {this.headings, this.fontProbeText});
  void attachSourceMaps() => ReadingText.attachSourceMaps(book, sourceMaps);
}

typedef ReaderPreparationRunner = Future<PreparedReadingBook> Function(ReaderPreparationRequest request);

bool _samePreparation(ReaderPreparationRequest a, ReaderPreparationRequest b) =>
  identical(a.source, b.source) && a.merge == b.merge && a.indent == b.indent &&
  a.filter == b.filter && a.autoExtractToc == b.autoExtractToc && a.pauseSettings == b.pauseSettings;

class _PendingPreparation {
  final ReaderPreparationRequest request;
  int latestCall;
  late final Future<PreparedReadingBook> future;
  _PendingPreparation(this.request, this.latestCall);
}

class ReaderInitialData {
  final PreparedReadingBook prepared;
  final ReadingSettings settings;
  final BookProgress? progress;
  final DisplayCutoutGeometry? geometry;
  final double devicePixelRatio;
  const ReaderInitialData({required this.prepared, required this.settings, this.progress,
    this.geometry, required this.devicePixelRatio});
}

class ReaderPreparation {
  static const maxCachedDisplayCharacters = BookParser.maxCachedDisplayCharacters;
  @visibleForTesting
  static ReaderPreparationRunner? runnerForTesting;
  static (ReaderPreparationRequest, PreparedReadingBook)? _cached;
  static final List<_PendingPreparation> _pending = [];
  static int _latestCall = 0;

  // Keep joiners/selectors inside meaningful clusters (e.g. emoji ZWJ sequences)
  // intact. Only a cluster made entirely of whitespace or invisible controls
  // is omitted; combining characters are never decomposed or normalized.
  static final _fontProbeSeparators = RegExp(
    r'^[\s\u0000-\u001F\u007F-\u009F\u00AD\u034F\u061C\u180E\u200B-\u200F\u202A-\u202E\u2060-\u206F\uFE00-\uFE0F\uFEFF\u{E0100}-\u{E01EF}]+$',
    unicode: true,
  );

  /// Enumerates the whole already-formatted book without changing its text,
  /// source coordinates, or heading classification. No truncation is applied.
  ///
  /// Call in an existing preparation/snapshot worker. Supplying its existing
  /// heading index avoids a second heading-classification pass.
  static String collectFontProbeText(Book formatted, {ReaderHeadings? headings, bool autoExtractToc = true}) {
    final classified = headings ?? ReaderHeadings(formatted, autoExtractToc: autoExtractToc);
    final clusters = <String>{};
    void add(String text) {
      // Classify each distinct cluster once, rather than run a separator regex
      // for every repeated character of a long book.
      clusters.addAll(text.characters);
    }
    for (var chapter = 0; chapter < formatted.chapters.length; chapter++) {
      final value = formatted.chapters[chapter];
      if (classified.showChapterLabel(chapter)) add(value.title);
      for (final paragraph in value.paragraphs) { add(paragraph.display); }
    }
    // Newline-only clusters were removed above. Spaces keep adjacent clusters
    // from accidentally forming a different contextual/combining probe token.
    return clusters.where((cluster) => !_fontProbeSeparators.hasMatch(cluster)).join(' ');
  }

  static void clearMemoryCache() {
    ++_latestCall;
    _cached = null;
    _pending.clear();
  }

  static Future<PreparedReadingBook> prepare(ReaderPreparationRequest request) {
    final call = ++_latestCall;
    final cached = _cached;
    if (cached != null && _samePreparation(cached.$1, request)) {
      cached.$2.attachSourceMaps();
      return Future.value(cached.$2);
    }
    for (final pending in _pending) {
      if (_samePreparation(pending.request, request)) {
        pending.latestCall = call;
        return pending.future;
      }
    }
    final runner = runnerForTesting;
    final pending = _PendingPreparation(request, call);
    _pending.add(pending);
    pending.future = () async {
      try {
        final prepared = await (runner != null ? runner(request) : Isolate.run(() => prepareSynchronously(request)));
        prepared.attachSourceMaps();
        if (pending.latestCall == _latestCall && _pending.contains(pending)) {
          _cached = request.source.totalDisplayLength + prepared.book.totalDisplayLength <= maxCachedDisplayCharacters
            ? (request, prepared) : null;
        }
        return prepared;
      } finally {
        _pending.remove(pending);
      }
    }();
    return pending.future;
  }

  @visibleForTesting
  static PreparedReadingBook prepareSynchronously(ReaderPreparationRequest request) {
    final source = request.source;
    final book = ReadingText.format(source, merge: request.merge, indent: request.indent, filter: request.filter,
      pauseSettings: request.pauseSettings);
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
    final headings = ReaderHeadings(book, autoExtractToc: request.autoExtractToc);
    return PreparedReadingBook(book, 'words2-${ReadingText.fingerprint(book)}', maps, toc, anchors, titles,
      headings: headings, fontProbeText: collectFontProbeText(book, headings: headings));
  }
}
