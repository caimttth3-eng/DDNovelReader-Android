import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/models/book.dart';
import 'package:duoduo_langdu/services/reading_text.dart';
import 'package:duoduo_langdu/services/speech_breaks.dart';

Book bookWith(Paragraph paragraph) => Book(id: 'dash', title: 'dash', filePath: '',
  format: BookFormat.txt, addedAt: DateTime(2026),
  chapters: [Chapter(title: '章节', paragraphs: [paragraph])]);

void main() {
  test('pause settings migrate defaults, clamp and quantize, and serialize without mutable aliases', () {
    const defaults = SpeechPauseSettings();
    expect(defaults.millisecondsFor(SpeechPauseKind.dash), 300);
    expect(defaults.millisecondsFor(SpeechPauseKind.comma), 0);
    final custom = defaults.withPause(SpeechPauseKind.comma, 226).withPause(SpeechPauseKind.paragraph, 9999);
    expect(custom.millisecondsFor(SpeechPauseKind.comma), 250);
    expect(custom.millisecondsFor(SpeechPauseKind.paragraph), 3000);
    expect(defaults.millisecondsFor(SpeechPauseKind.comma), 0);
    expect(SpeechPauseSettings.fromJson(custom.toJson()), custom);
    expect(SpeechPauseSettings.fromJson({'version': 2, 'dash': 0}), defaults);
    expect(SpeechPauseSettings.fromJson({'dash': double.nan}), defaults);
    expect(defaults.withPause(SpeechPauseKind.dash, -5).millisecondsFor(SpeechPauseKind.dash), 0);
  });

  test('custom punctuation adds delays with complete UTF16 display and TTS offsets', () {
    final pauses = const SpeechPauseSettings().withPause(SpeechPauseKind.comma, 150)
      .withPause(SpeechPauseKind.question, 250).withPause(SpeechPauseKind.exclamation, 450)
      .withPause(SpeechPauseKind.paragraph, 600);
    const text = '“甲😀，乙？！丙。”';
    final p = ReadingText.paragraph(text, pauseSettings: pauses);
    expect(p.sentences.map((s) => s.tts), ['“甲，', '乙？！', '丙。”']);
    expect(p.sentences.map((s) => s.pauseAfterMilliseconds), [150, 450, 600]);
    expect(p.sentences.map((s) => s.display).join(), text);
    expect(p.sentences[1].displayStart, text.indexOf('乙'));
    for (var i = 0; i < p.sentences.length; i++) {
      final s = p.sentences[i];
      expect(text.substring(s.displayStart, s.displayEnd), s.display);
      expect(p.tts.substring(p.sentenceStartTts[i], p.sentenceStartTts[i] + s.tts.length), s.tts);
    }
  });

  test('collapsed ellipses retain their display run and share max delay with a dash or paragraph', () {
    final pauses = const SpeechPauseSettings().withPause(SpeechPauseKind.ellipsis, 700)
      .withPause(SpeechPauseKind.period, 100).withPause(SpeechPauseKind.paragraph, 500);
    for (final ellipsis in ['……', '...']) {
      final p = ReadingText.paragraph('甲${ellipsis}乙。', pauseSettings: pauses);
      expect(p.sentences.first.pauseAfterMilliseconds, 700);
      expect(p.sentences.first.display, '甲$ellipsis');
      expect(p.sentences.last.display, '乙。');
      expect(p.sentences.last.pauseAfterMilliseconds, 500);
    }
    final p = ReadingText.paragraph('甲。——', pauseSettings: pauses);
    expect(p.sentences.single.pauseAfterMilliseconds, 500);
    expect(SpeechBreaks.boundaries('3.14', pauses), isEmpty);
  });

  test('zero custom pauses preserve ordinary prosody and custom pauses invalidate audio coordinates', () {
    const text = '甲，乙、丙：丁。';
    final baseline = ReadingText.paragraph(text);
    expect(baseline.sentences, hasLength(1));
    expect(baseline.sentences.single.tts, text);
    final custom = ReadingText.paragraph(text, pauseSettings: const SpeechPauseSettings().withPause(SpeechPauseKind.comma, 100));
    expect(custom.sentences, hasLength(2));
    expect(ReadingText.fingerprint(bookWith(custom)), isNot(ReadingText.fingerprint(bookWith(baseline))));
  });

  test('extra pauses do not split numeric commas, decimal points or clock colons', () {
    final pauses = const SpeechPauseSettings().withPause(SpeechPauseKind.comma, 400)
      .withPause(SpeechPauseKind.period, 400).withPause(SpeechPauseKind.colon, 400);
    for (final number in ['3.14', '12:30', '1,000', '１２：３０']) {
      expect(SpeechBreaks.boundaries(number, pauses), isEmpty);
      final natural = ReadingText.paragraph(number), custom = ReadingText.paragraph(number, pauseSettings: pauses);
      expect(custom.sentences.map((s) => s.tts), natural.sentences.map((s) => s.tts));
      expect(custom.sentences.every((s) => s.pauseAfterMilliseconds == 0), isTrue);
    }
  });

  test('leading punctuation and closing quotes never create a punctuation-only request', () {
    final pauses = const SpeechPauseSettings().withPause(SpeechPauseKind.comma, 250)
      .withPause(SpeechPauseKind.period, 300);
    for (final prefix in ['，', '，”', '，。”']) {
      final text = '${prefix}你好。';
      final p = ReadingText.paragraph(text, pauseSettings: pauses);
      expect(p.display, text);
      expect(p.sentences, hasLength(1));
      expect(p.sentences.single.tts, '你好。');
      expect(p.sentences.single.displayStart, text.indexOf('你'));
      expect(p.sentences.single.display, '你好。');
      expect(p.sentenceStartTts.single, p.tts.indexOf('你'));
    }
  });

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
