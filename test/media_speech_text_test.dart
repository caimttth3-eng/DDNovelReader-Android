import 'package:characters/characters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/services/media_speech_text.dart';

List<String> observedParts(String source, {int maxColumns = 32}) {
  final media = MediaSpeechText(source, maxColumns: maxColumns);
  final result = <String>[];
  for (var offset = 0; offset < source.length; offset++) {
    final fragment = media.textAt(offset);
    if (result.isEmpty || result.last != fragment) result.add(fragment);
  }
  return result;
}

void main() {
  test('empty and short text remain complete at every usable position', () {
    final empty = MediaSpeechText('');
    expect(empty.textAt(null), '');
    expect(empty.textAt(0), '');
    const text = '他说：“你好。”';
    final media = MediaSpeechText(text);
    for (var offset = 0; offset <= text.length; offset++) {
      expect(media.textAt(offset), text);
    }
  });

  test('missing and out-of-range cursors do not invent a speaking position', () {
    const text = '甲乙丙丁戊己庚辛壬癸子丑寅卯辰巳午未申酉戌亥，后面的正文。';
    final media = MediaSpeechText(text);
    expect(media.textAt(null), text);
    expect(media.textAt(-1), text);
    expect(media.textAt(text.length + 1), text);
    final parts = observedParts(text);
    expect(parts.length, greaterThan(1));
    expect(parts.join(), text);
    expect(media.textAt(text.length), parts.last);
  });

  test('long Chinese text prefers punctuation and retains closing quotes', () {
    const text = '甲乙丙丁戊己，庚辛壬癸子丑；“寅卯辰巳。”午未申酉戌亥。';
    final parts = observedParts(text, maxColumns: 16);
    expect(parts.first, '甲乙丙丁戊己，');
    expect(parts.join(), text);
    expect(parts, contains('“寅卯辰巳。”'));
    expect(parts.every((part) => !part.startsWith('”') && !part.startsWith('；')), isTrue);
  });

  test('ordinary English words stay together and whitespace is lossless', () {
    const text = 'Alpha bravo charlie delta echo foxtrot golf hotel india.';
    final parts = observedParts(text, maxColumns: 16);
    expect(parts.length, greaterThan(1));
    expect(parts.join(), text);
    for (final word in text.split(' ')) {
      expect(parts.any((part) => part.contains(word)), isTrue, reason: word);
    }
    final longToken = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final tokenParts = observedParts(longToken, maxColumns: 8);
    expect(tokenParts.join(), longToken);
    expect(tokenParts.every((part) => part.length <= 8), isTrue);
  });

  test('emoji ZWJ, surrogate pairs, accents and flags stay whole', () {
    const text = '甲乙👩🏽‍💻丙e\u0301丁🇨🇳戊𠀀己庚👨‍👩‍👧‍👦辛壬癸。';
    final parts = observedParts(text, maxColumns: 7);
    expect(parts.join(), text);
    final boundaries = <int>{0};
    var offset = 0;
    for (final cluster in text.characters) {
      offset += cluster.length;
      boundaries.add(offset);
    }
    var position = 0;
    final media = MediaSpeechText(text, maxColumns: 7);
    for (final part in parts) {
      expect(boundaries, contains(position));
      for (var i = position; i < position + part.length; i++) {
        expect(media.textAt(i), part);
      }
      position += part.length;
      expect(boundaries, contains(position));
    }
    expect(position, text.length);
  });

  test('display slicing preserves content whitespace after paragraph indentation', () {
    const text = '  开头：“第一小段。”\n然后是第二小段；最后还有第三部分？！  ';
    final parts = observedParts(text, maxColumns: 10);
    expect(parts.join(), text.trimLeft());
    expect(parts.every((part) => part.isNotEmpty), isTrue);
    expect(MediaSpeechText(text, maxColumns: 0).textAt(0), isNotEmpty);
  });

  test('only paragraph-leading layout whitespace is hidden in full-line fallback', () {
    const content = '正文 A  B\u00A0C。  ';
    for (final indent in ['  ', '　　', '\u00A0\u00A0', '\t  ', '\u2002\u2003']) {
      final source = '$indent$content';
      final media = MediaSpeechText(source);
      expect(media.text, source, reason: 'The screen and speech source must remain untouched');
      for (final offset in <int?>[null, -1, source.length + 1, 0, indent.length, source.length]) {
        expect(media.textAt(offset), content, reason: 'indent=$indent offset=$offset');
      }
    }
    expect(MediaSpeechText(' \u3000\u00A0').textAt(null), '');
    expect(MediaSpeechText(' \u3000\u00A0', maxColumns: 1).textAt(0), '');
  });

  test('long CJK slices use original UTF-16 positions after hiding indentation', () {
    const source = '　　甲乙👩🏽‍💻丙丁戊己庚辛壬癸，子丑寅卯辰巳午未申酉戌亥。';
    final media = MediaSpeechText(source, maxColumns: 12);
    final parts = observedParts(source, maxColumns: 12);
    expect(media.text, source);
    expect(parts.length, greaterThan(2));
    expect(parts.join(), source.substring(2));
    expect(parts.first.startsWith('甲'), isTrue);
    expect(media.textAt(0), parts.first);
    expect(media.textAt(1), parts.first);
    expect(media.textAt(source.indexOf('壬')), contains('壬'));
    expect(media.textAt(source.indexOf('戌')), contains('戌'));
    expect(media.textAt(source.indexOf('👩') + 1), contains('👩🏽‍💻'));
    expect(media.textAt(source.length), parts.last);
  });

  test('spaces at later fragment boundaries and inside content are not trimmed', () {
    const source = '  abc  def ghi  jkl mno';
    final parts = observedParts(source, maxColumns: 5);
    expect(parts.join(), 'abc  def ghi  jkl mno');
    expect(parts.any((part) => part.startsWith(' ')), isTrue,
      reason: 'Whitespace belonging to later text is not paragraph indentation');
    expect(MediaSpeechText('  A\u00A0\u00A0B  C').textAt(null), 'A\u00A0\u00A0B  C');
  });
}
