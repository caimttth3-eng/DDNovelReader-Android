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

  test('display slicing covers punctuation, quotes and line endings exactly', () {
    const text = '  开头：“第一小段。”\n然后是第二小段；最后还有第三部分？！  ';
    final parts = observedParts(text, maxColumns: 10);
    expect(parts.join(), text);
    expect(parts.every((part) => part.isNotEmpty), isTrue);
    expect(MediaSpeechText(text, maxColumns: 0).textAt(0), isNotEmpty);
  });
}
