import 'dart:convert';
import 'package:crypto/crypto.dart';

import '../models/book.dart';
import 'text_cleaner.dart';
import 'chapterizer.dart';

/// Rebuild display paragraphs and TTS sentences from the same source text.
/// The imported file is never rewritten.
class ReadingText {
  static final _maps = Expando<List<List<List<int>>>>();
  static final _spaces = RegExp(r'\s');
  static final _end = RegExp(r'''[。！？!?；;.…][”’」』）》）\]"']*$''');
  static final _speechDash = RegExp(r'[\u2014\u2015]+');
  static final _speechSentence = RegExp(r'''[^。！？!?；;\n]+(?:[。！？!?；;]+[”’」』）》）\]"']*)?''');
  static final _onlySpeechPunctuation = RegExp(r'''^[\s。！？!?；;，,：:.…“”‘’「」『』《》〈〉（）()\[\]"'、]+$''');

  static Paragraph paragraph(String display) {
    final sentences = <Sentence>[];
    final starts = <int>[];
    final tts = StringBuffer();
    final dashes = _speechDash.allMatches(display).toList();
    void extendLast(int end, {bool pause = false}) {
      if (sentences.isEmpty) return;
      final previous = sentences.last;
      sentences[sentences.length - 1] = Sentence(display.substring(previous.displayStart, end), previous.tts,
        displayStart: previous.displayStart, displayEnd: end,
        pauseAfterMilliseconds: pause ? 300 : previous.pauseAfterMilliseconds);
    }
    void appendSpeech(int from, int to) {
      final cleaned = const TextCleaner().clean(display.substring(from, to));
      // A trailing closing quote after a dash belongs to the visible segment;
      // it must not cause a punctuation-only synthesis request.
      if (dashes.isNotEmpty && (cleaned.tts.isEmpty || _onlySpeechPunctuation.hasMatch(cleaned.tts))) {
        extendLast(to);
        return;
      }
      final base = tts.length;
      tts.write(cleaned.tts);
      for (final m in _speechSentence.allMatches(cleaned.tts)) {
        if (m.group(0)!.trim().isEmpty) continue;
        final start = (from + cleaned.displayOffsetOfTts(m.start)).clamp(from, to);
        final end = (from + cleaned.displayOffsetOfTts(m.end)).clamp(start, to);
        starts.add(base + m.start);
        sentences.add(Sentence(display.substring(start, end), m.group(0)!,
          displayStart: start, displayEnd: end));
      }
    }
    var cursor = 0;
    for (final dash in dashes) {
      appendSpeech(cursor, dash.start);
      extendLast(dash.end, pause: true);
      cursor = dash.end;
    }
    appendSpeech(cursor, display.length);
    return Paragraph(display: display, tts: tts.toString(),
      sentences: sentences, sentenceStartTts: starts);
  }

  static Book format(Book source, {required bool merge, required bool indent,
    String filter = 'none'}) {
    final maps = <List<List<int>>>[];
    final chapters = <Chapter>[];
    for (final chapter in source.chapters) {
      final result = _paragraphs(chapter, merge, indent, filter);
      chapters.add(Chapter(title: chapter.title, paragraphs: result.$1));
      maps.add(result.$2);
    }
    final book = Book(id: source.id, title: source.title, filePath: source.filePath,
      format: source.format, addedAt: source.addedAt, chapters: [
        ...chapters,
      ]);
    _maps[book] = maps;
    return book;
  }

  static final _link = RegExp(r'(?:https?://|www\.)[A-Za-z0-9][A-Za-z0-9._~:/?#\[\]@!$&()*+,;=%+-]*|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', caseSensitive: false);
  static final _advert = RegExp(r'^(?:[【\[（(].*?[】\]）)]\s*)?(?:请?访问本站|请?记住本站|本书(?:由|来自)|更多(?:精彩|好书|小说)|(?:请|欢迎)?下载.{0,16}(?:APP|客户端)|(?:请|欢迎)?加入.{0,16}(?:群|QQ群)|(?:手机|电脑)访问).{0,160}$', caseSensitive: false);
  static final _author = RegExp(r'^(?:[【\[（(].*?[】\]）)]\s*)?(?:PS[：:]|P\.S\.|作者(?:有话说|的话)[：:]|(?:求|跪求|请大家).{0,12}(?:月票|推荐票|收藏|订阅|打赏)|本章完|未完待续).{0,160}$', caseSensitive: false);

  static (List<Paragraph>, List<List<int>>) _paragraphs(Chapter chapter, bool merge, bool indent, String filter) {
    final lines = <_MappedLine>[];
    final sourceLines = [for (final p in chapter.paragraphs)
      ...p.display.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n')];
    final headings = merge ? detectChapterTitles(sourceLines.join('\n')).map((h) => h.offset).toSet() : <int>{};
    var lineOffset = 0;
    var previousHeading = false;
    var sourceAnchor = 0;
      for (final line in sourceLines) {
        final isHeading = headings.contains(lineOffset + line.length - line.trimLeft().length);
        lineOffset += line.length + 1;
        final anchors = <int>[];
        for (var i = 0; i < line.length; i++) {
          anchors.add(sourceAnchor);
          if (!_spaces.hasMatch(line[i])) sourceAnchor++;
        }
        anchors.add(sourceAnchor);
        if (line.trim().isEmpty) continue;
        var mapped = _MappedLine(line, anchors).trimRight();
        if (filter != 'none') {
          if ((filter == 'ads' || filter == 'extra') && _advert.hasMatch(mapped.text.trim())) continue;
          if (filter == 'extra' && _author.hasMatch(mapped.text.trim())) continue;
          mapped = mapped.remove(_link);
          if (mapped.text.trim().isEmpty) continue;
        }
        if (merge) {
          mapped = mapped.remove(RegExp(r'[\uFEFF\u200B\u200C\u200D\u2060\u00AD]'));
          // A misplaced closing quote belongs to an unmatched opening quote on
          // the preceding line. Never invent or reverse quotation marks.
          if (lines.isNotEmpty && !isHeading && !previousHeading) {
            var trimmed = mapped.trimLeft();
            while (trimmed.text.startsWith('”') &&
              '“'.allMatches(lines.last.text).length > '”'.allMatches(lines.last.text).length) {
              lines[lines.length - 1] = lines.last.append(trimmed.slice(0, 1));
              trimmed = trimmed.slice(1).trimLeft();
              mapped = trimmed;
            }
            if (mapped.text.trim().isEmpty) continue;
          }
        }
        if (merge && !isHeading && !previousHeading && lines.isNotEmpty && !_end.hasMatch(lines.last.text.trimRight())) {
          // Restore a separating space for words in Latin-script text.
          final right = mapped.trimLeft();
          final space = RegExp(r'[A-Za-z0-9]$').hasMatch(lines.last.text) &&
            RegExp(r'^[A-Za-z0-9]').hasMatch(right.text) ? ' ' : '';
          lines[lines.length - 1] = lines.last.append(right.prepend(space));
        } else {
          lines.add(mapped);
        }
        previousHeading = isHeading;
      }
    final output = lines.map((line) {
      final leading = RegExp(r'^[ \t\u3000]*').firstMatch(line.text)!.group(0)!;
      return indent && leading.length < 2 ? line.trimLeft().prepend('　　') : line;
    }).toList();
    if (output.isEmpty) output.add(_MappedLine('', [sourceAnchor]));
    return (output.map((line) => paragraph(line.text)).toList(), output.map((line) => line.anchors).toList());
  }

  /// Stable chapter coordinate, independent of inserted spaces and line breaks.
  static int anchor(Book book, int c, int p, int offset) {
    if (book.chapters.isEmpty) return 0;
    final mapped = _maps[book];
    if (mapped != null) {
      final chapter = mapped[c.clamp(0, mapped.length - 1)];
      final paragraph = chapter[p.clamp(0, chapter.length - 1)];
      return paragraph[offset.clamp(0, paragraph.length - 1)];
    }
    final paras = book.chapters[c.clamp(0, book.chapters.length - 1)].paragraphs;
    var n = 0;
    for (var i = 0; i < paras.length; i++) {
      if (i > p) break;
      final text = paras[i].display;
      n += (i == p ? text.substring(0, offset.clamp(0, text.length)) : text)
        .replaceAll(_spaces, '').length;
    }
    return n;
  }

  static (int paragraph, int offset) locate(Book book, int c, int anchor) {
    final paras = book.chapters[c.clamp(0, book.chapters.length - 1)].paragraphs;
    if (paras.isEmpty) return (0, 0);
    final mapped = _maps[book];
    if (mapped != null) {
      final chapter = mapped[c.clamp(0, mapped.length - 1)];
      for (var p = 0; p < paras.length; p++) {
        for (var i = 0; i < paras[p].display.length; i++) {
          if (!_spaces.hasMatch(paras[p].display[i]) && chapter[p][i] >= anchor) return (p, i);
        }
      }
      return (paras.length - 1, paras.last.display.length);
    }
    var remaining = anchor < 0 ? 0 : anchor;
    for (var p = 0; p < paras.length; p++) {
      final text = paras[p].display;
      for (var i = 0; i < text.length; i++) {
        if (_spaces.hasMatch(text[i])) continue;
        if (remaining == 0) return (p, i);
        remaining--;
      }
    }
    return (paras.length - 1, paras.last.display.length);
  }

  static int sentenceAt(Paragraph paragraph, int offset) {
    final index = paragraph.sentences.indexWhere((s) => s.displayEnd > offset);
    return index < 0 ? (paragraph.sentences.length - 1).clamp(0, 1 << 30) : index;
  }

  /// Before text switches existed, the parser flattened each whole chapter
  /// into one paragraph. Migrate its stored annotation coordinates before
  /// projecting them onto the new physical paragraphs.
  static String _legacyText(Book source, int chapter) => source.chapters[chapter].paragraphs
    .expand((p) => p.display.split('\n')).map((line) => line.trim())
    .where((line) => line.isNotEmpty).join(' ');

  static int legacyAnchor(Book source, int chapter, int offset) {
    final text = _legacyText(source, chapter);
    return text.substring(0, offset.clamp(0, text.length)).replaceAll(_spaces, '').length;
  }

  static int legacySentenceAnchor(Book source, int chapter, int sentence) {
    final text = _legacyText(source, chapter);
    final cleaned = const TextCleaner().clean(text);
    final matches = RegExp(r'[^。！？!?；;\n]+[。！？!?；;]?').allMatches(cleaned.tts).toList();
    if (matches.isEmpty) return 0;
    final index = sentence.clamp(0, matches.length - 1);
    return legacyAnchor(source, chapter, cleaned.displayOffsetOfTts(matches[index].start));
  }

  // Old cache coordinates alone cannot distinguish changed sentence text.
  static String fingerprint(Book book) => sha256.convert(utf8.encode(jsonEncode([
    for (final c in book.chapters) [for (final p in c.paragraphs) [for (final s in p.sentences) [s.tts, s.pauseAfterMilliseconds]]],
  ]))).toString().substring(0, 20);
}

class _MappedLine {
  final String text;
  final List<int> anchors;
  const _MappedLine(this.text, this.anchors);
  _MappedLine slice(int start, [int? end]) => _MappedLine(text.substring(start, end), anchors.sublist(start, (end ?? text.length) + 1));
  _MappedLine trimLeft() => slice(text.length - text.trimLeft().length);
  _MappedLine trimRight() => slice(0, text.trimRight().length);
  _MappedLine prepend(String prefix) => _MappedLine('$prefix$text', [...List.filled(prefix.length, anchors.first), ...anchors]);
  _MappedLine append(_MappedLine other) => _MappedLine('$text${other.text}', [...anchors.take(text.length), ...other.anchors]);
  _MappedLine remove(RegExp pattern) {
    var result = _MappedLine('', [anchors.first]);
    var cursor = 0;
    for (final match in pattern.allMatches(text)) {
      result = result.append(slice(cursor, match.start));
      cursor = match.end;
    }
    return result.append(slice(cursor));
  }
}
