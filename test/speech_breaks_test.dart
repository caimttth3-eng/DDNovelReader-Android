import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/models/book.dart';
import 'package:duoduo_langdu/services/reading_text.dart';

Book bookWith(Paragraph paragraph) => Book(id: 'dash', title: 'dash', filePath: '',
  format: BookFormat.txt, addedAt: DateTime(2026),
  chapters: [Chapter(title: '章节', paragraphs: [paragraph])]);

void main() {
  test('a dash separates speech while preserving its original display positions', () {
    const text = '前半句——后半句。';
    final p = ReadingText.paragraph(text);
    expect(p.display, text);
    expect(p.tts, '前半句后半句。');
    expect(p.sentences.map((s) => s.tts), ['前半句', '后半句。']);
    expect(p.sentences.map((s) => s.pauseAfterMilliseconds), [300, 0]);
    expect(p.sentenceStartTts, [0, 3]);
    expect(p.sentences.first.display, '前半句——');
    expect(p.sentences.last.displayStart, text.indexOf('后'));
    expect(p.sentences.map((s) => text.substring(s.displayStart, s.displayEnd)),
      p.sentences.map((s) => s.display));
  });

  test('each continuous em dash or horizontal bar run adds only one pause', () {
    for (final dash in ['—', '——', '————', '―', '――', '—―—']) {
      final p = ReadingText.paragraph('甲${dash}乙。');
      expect(p.sentences.map((s) => s.tts), ['甲', '乙。']);
      expect(p.sentences.map((s) => s.pauseAfterMilliseconds), [300, 0]);
    }
    final p = ReadingText.paragraph('甲——乙―丙。');
    expect(p.sentences.map((s) => s.tts), ['甲', '乙', '丙。']);
    expect(p.sentences.map((s) => s.pauseAfterMilliseconds), [300, 300, 0]);
    expect(p.sentenceStartTts, [0, 1, 2]);
  });

  test('sentence-final dashes keep a pause without creating empty requests', () {
    for (final text in ['甲——', '甲。——', '甲——   ——']) {
      final p = ReadingText.paragraph(text);
      expect(p.sentences, hasLength(1));
      expect(p.sentences.single.pauseAfterMilliseconds, 300);
      expect(p.sentences.single.display, text);
      expect(p.sentences.single.tts, isNot(contains('—')));
    }
    final p = ReadingText.paragraph('甲。——乙。');
    expect(p.sentences.map((s) => s.tts), ['甲。', '乙。']);
    expect(p.sentences.map((s) => s.pauseAfterMilliseconds), [300, 0]);
  });

  test('quoted speech retains quotes and offsets across its dash break', () {
    const text = '“甲——乙。”';
    final p = ReadingText.paragraph(text);
    expect(p.sentences.map((s) => s.tts), ['“甲', '乙。”']);
    expect(p.sentences.map((s) => s.display), ['“甲——', '乙。”']);
    expect(p.sentences.last.displayStart, 4);
    final trailingQuote = ReadingText.paragraph('“甲——”');
    expect(trailingQuote.sentences, hasLength(1));
    expect(trailingQuote.sentences.single.display, '“甲——”');
    expect(trailingQuote.sentences.single.pauseAfterMilliseconds, 300);
  });

  test('formatting retains the source anchor after a dash', () {
    const text = '甲——乙。';
    final source = bookWith(ReadingText.paragraph(text));
    final formatted = ReadingText.format(source, merge: true, indent: true);
    final target = ReadingText.locate(formatted, 0, ReadingText.anchor(source, 0, 0, 3));
    final paragraph = formatted.chapters.single.paragraphs[target.$1];
    expect(paragraph.display.substring(target.$2), '乙。');
    expect(paragraph.sentences.last.displayStart, target.$2);
    expect(ReadingText.anchor(formatted, 0, target.$1, target.$2), 3);
  });

  test('ordinary hyphens, negative numbers and dates do not create pauses', () {
    final p = ReadingText.paragraph('2026-11-12 foo-bar -3');
    expect(p.tts, '2026-11-12 foo-bar -3');
    expect(p.sentences, hasLength(1));
    expect(p.sentences.single.pauseAfterMilliseconds, 0);
  });

  test('empty and dash-only text never creates a punctuation-only speech request', () {
    for (final text in ['', '   ', '——', ' ―― —— ', '——。”']) {
      final p = ReadingText.paragraph(text);
      expect(p.display, text);
      expect(p.tts, isEmpty);
      expect(p.sentences, isEmpty);
      expect(p.sentenceStartTts, isEmpty);
    }
    final leading = ReadingText.paragraph('——甲。');
    expect(leading.sentences.map((s) => s.tts), ['甲。']);
    expect(leading.sentences.single.displayStart, 2);
  });

  test('cache fingerprint includes explicit pause configuration', () {
    Book withPause(int pause) => bookWith(Paragraph(display: '甲', tts: '甲',
      sentences: [Sentence('甲', '甲', pauseAfterMilliseconds: pause)], sentenceStartTts: [0]));
    expect(ReadingText.fingerprint(withPause(0)), isNot(ReadingText.fingerprint(withPause(300))));
    expect(const Sentence('甲', '甲').pauseAfterMilliseconds, 0);
  });
}
