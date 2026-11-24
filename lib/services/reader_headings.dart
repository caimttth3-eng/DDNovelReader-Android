import '../models/book.dart';
import 'chapterizer.dart';

/// Cached visual heading classification over an already formatted book.
///
/// This does not split chapters, edit paragraphs or change source/TTS offsets.
/// Construct once with prepared reading data; all rendering queries are O(1).
class ReaderHeadings {
  final List<Set<int>> _headings;
  final List<bool> _chapterLabels;

  ReaderHeadings(Book formatted, {bool autoExtractToc = true})
    : _headings = List.generate(formatted.chapters.length, (_) => <int>{}),
      _chapterLabels = List.filled(formatted.chapters.length, false) {
    final text = StringBuffer();
    final locations = <({int chapter, int paragraph, int start, int end})>[];
    var offset = 0;
    for (var chapter = 0; chapter < formatted.chapters.length; chapter++) {
      final value = formatted.chapters[chapter];
      final metadata = _normalized(value.title);
      final trusted = metadata.isNotEmpty &&
        (formatted.format == BookFormat.epub || detectChapterTitles(value.title).isNotEmpty);
      var duplicate = false;
      for (var paragraph = 0; paragraph < value.paragraphs.length; paragraph++) {
        final display = value.paragraphs[paragraph].display;
        if (metadata.isNotEmpty && _normalized(display) == metadata) {
          duplicate = true;
          // Existing EPUB metadata supplies reliable heading semantics even
          // for arbitrary names that do not match numbered-title heuristics.
          if (formatted.format == BookFormat.epub && trusted) _headings[chapter].add(paragraph);
        }
        if (autoExtractToc) {
          locations.add((chapter: chapter, paragraph: paragraph, start: offset, end: offset + display.length));
          text..write(display)..write('\n');
          offset += display.length + 1;
        }
      }
      _chapterLabels[chapter] = trusted && !duplicate;
    }
    if (!autoExtractToc || locations.isEmpty) return;
    // One complete-book detection pass retains the detector's conservative
    // support for recurring numbered headings separated by body paragraphs.
    var location = 0;
    for (final heading in detectChapterTitles(text.toString())) {
      while (location < locations.length && heading.offset >= locations[location].end) { location++; }
      if (location >= locations.length) break;
      final at = locations[location];
      if (heading.offset < at.start) continue;
      final display = formatted.chapters[at.chapter].paragraphs[at.paragraph].display;
      // Formatted paragraphs normally contain one source line. Be conservative
      // for legacy/malformed multi-line paragraphs: never bold an entire body
      // paragraph merely because one of its internal lines is a title.
      if (_normalized(display) == _normalized(heading.title)) _headings[at.chapter].add(at.paragraph);
    }
  }

  bool isHeading(int chapter, int paragraph) =>
    chapter >= 0 && chapter < _headings.length && _headings[chapter].contains(paragraph);

  bool showChapterLabel(int chapter) =>
    chapter >= 0 && chapter < _chapterLabels.length && _chapterLabels[chapter];

  static final _whitespace = RegExp(r'\s+');
  static String _normalized(String value) {
    var text = value.replaceAll('\uFEFF', '').trim();
    if (text.startsWith('【') && text.endsWith('】')) text = text.substring(1, text.length - 1).trim();
    return text.replaceAll(_whitespace, ' ').toLowerCase();
  }
}
