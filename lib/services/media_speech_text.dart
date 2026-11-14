import 'package:characters/characters.dart';

/// Short media-card text selected by an actual UTF-16 speech position.
///
/// This only changes displayed metadata. It does not split synthesis requests,
/// infer timings, or drive the system's own marquee animation.
class MediaSpeechText {
  final String text;
  final List<({int start, int end})> _ranges;
  final int _contentStart;

  MediaSpeechText(this.text, {int maxColumns = 32})
      : _ranges = _split(text, maxColumns < 1 ? 1 : maxColumns),
        _contentStart = text.length - text.trimLeft().length;

  /// No usable range information means displaying the complete original line,
  /// with only its paragraph-leading layout whitespace omitted.
  /// An exact end-of-text position still selects its last displayed fragment.
  String textAt(int? utf16Offset) {
    if (utf16Offset == null || utf16Offset < 0 || utf16Offset > text.length ||
        _ranges.length < 2) return text.substring(_contentStart);
    // Keep all cached ranges and incoming offsets in the untouched source's
    // UTF-16 coordinates. A range in indentation alone selects the first real
    // text rather than publishing an empty fragment for that indentation.
    final offset = utf16Offset < _contentStart ? _contentStart : utf16Offset;
    if (offset == text.length) {
      final range = _ranges.last;
      return _displayRange(range.start, range.end);
    }
    var low = 0, high = _ranges.length;
    while (low + 1 < high) {
      final middle = (low + high) >> 1;
      if (_ranges[middle].start <= offset) {
        low = middle;
      } else {
        high = middle;
      }
    }
    final range = _ranges[low];
    return _displayRange(range.start, range.end);
  }

  String _displayRange(int start, int end) =>
      text.substring(start < _contentStart ? _contentStart : start, end);

  static final _punctuation = RegExp(r'^[，、。；：！？…—,.;:!?]');
  static final _word = RegExp(r"^[\p{L}\p{N}_'’-]", unicode: true);
  static const _closing = '”’」』）》】〉〕〗〙〛»›)]}';
  static const _opening = '“‘「『（《【〈〔〖〘〚«‹([{';

  static List<({int start, int end})> _split(String text, int budget) {
    if (text.isEmpty) return const [];
    final clusters = text.characters.toList(growable: false);
    final offsets = <int>[0];
    final widths = <int>[];
    final word = <bool>[];
    for (final cluster in clusters) {
      offsets.add(offsets.last + cluster.length);
      final width = cluster.runes.any(_wide) ? 2 : 1;
      widths.add(width);
      word.add(width == 1 && _word.hasMatch(cluster));
    }
    final ranges = <({int start, int end})>[];
    var start = 0;
    while (start < clusters.length) {
      var end = start, columns = 0, punctuationEnd = -1, whitespaceEnd = -1;
      while (end < clusters.length && (columns + widths[end] <= budget || end == start)) {
        columns += widths[end];
        end++;
        // Avoid a tiny first fragment solely because a comma appears early.
        if (columns * 2 >= budget) {
          if (_punctuation.hasMatch(clusters[end - 1])) punctuationEnd = end;
          if (clusters[end - 1].trim().isEmpty) whitespaceEnd = end;
        }
      }
      if (end < clusters.length) {
        if (punctuationEnd > start) {
          end = punctuationEnd;
        } else if (whitespaceEnd > start) {
          end = whitespaceEnd;
        } else if (word[end - 1] && word[end]) {
          // Keep a normal word together. A word longer than the whole budget
          // falls back to grapheme boundaries, so one huge token stays usable.
          var wordStart = end - 1;
          while (wordStart > start && word[wordStart - 1]) { wordStart--; }
          if (wordStart > start) end = wordStart;
        }
        while (end > start + 1 && _opening.contains(clusters[end - 1])) { end--; }
        // A closing quotation mark or punctuation belongs to the preceding
        // fragment, even if this slightly exceeds its preferred width budget.
        while (end < clusters.length &&
            (_closing.contains(clusters[end]) || _punctuation.hasMatch(clusters[end]))) {
          end++;
        }
      }
      ranges.add((start: offsets[start], end: offsets[end]));
      start = end;
    }
    return ranges;
  }

  static bool _wide(int cp) =>
      cp >= 0x1100 && cp <= 0x115F ||
      cp >= 0x2E80 && cp <= 0xA4CF ||
      cp >= 0xAC00 && cp <= 0xD7A3 ||
      cp >= 0xF900 && cp <= 0xFAFF ||
      cp >= 0xFE10 && cp <= 0xFE6F ||
      cp >= 0xFF01 && cp <= 0xFF60 ||
      cp >= 0xFFE0 && cp <= 0xFFE6 ||
      cp >= 0x1F000 && cp <= 0x1FAFF ||
      cp >= 0x20000 && cp <= 0x3FFFF;
}
