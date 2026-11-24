import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/services/text_cleaner.dart';

void main() {
  const cleaner = TextCleaner();

  group('TextCleaner 双文本清洗', () {
    test('普通文本：tts 与 display 一致', () {
      final r = cleaner.clean('今天天气真好，我们去公园散步。');
      expect(r.display, '今天天气真好，我们去公园散步。');
      expect(r.tts, '今天天气真好，我们去公园散步。');
    });

    test('连续标点被压缩', () {
      final r = cleaner.clean('太棒了！！！真的吗？？？');
      expect(r.tts, '太棒了！真的吗？');
      expect(r.display, '太棒了！！！真的吗？？？');
    });

    test('连续空白被压缩为单个空格', () {
      final r = cleaner.clean('你好    世界');
      expect(r.tts, '你好 世界');
    });

    test('emoji 被剔除', () {
      final r = cleaner.clean('加油😄你真棒🎉');
      expect(r.tts.contains('😄'), isFalse);
      expect(r.tts.contains('🎉'), isFalse);
      expect(r.tts, contains('加油'));
      expect(r.tts, contains('你真棒'));
    });

    test('颜文字被剔除', () {
      final r = cleaner.clean('开心(≧▽≦)每一天');
      expect(r.tts.contains('≧'), isFalse);
      expect(r.tts, contains('开心'));
      expect(r.tts, contains('每一天'));
    });

    test('ASCII 标点归一为中文标点', () {
      final r = cleaner.clean('hello, world!');
      expect(r.tts, 'hello， world！');
    });

    test('零宽字符剔除', () {
      final r = cleaner.clean('好\u200B坏');
      expect(r.tts, '好坏');
    });

    test('tts->display 映射正确', () {
      final r = cleaner.clean('你好！！！世界');
      // tts = "你好！世界" (4 chars + punct)
      expect(r.tts, '你好！世界');
      // 映射长度 = tts.length + 1
      expect(r.ttsToDisplay.length, r.tts.length + 1);
      // tts[0]('你') -> display[0]
      expect(r.displayOffsetOfTts(0), 0);
      // tts 末尾哨兵 -> display.length
      expect(r.displayOffsetOfTts(r.tts.length), r.display.length);
    });

    test('URL speech starts and visible cursors use retained characters after collapsed slashes', () {
      final r = cleaner.clean('https://example.com');
      final speech = r.tts.indexOf('example');
      final visible = r.display.indexOf('example');
      expect(speech, 7); expect(visible, 8);
      expect(r.displayOffsetOfTts(speech), 7,
        reason: 'Existing sentence boundary mapping must remain compatible');
      expect(r.displayStartOfTts(speech), visible);
      expect(r.ttsOffsetOfDisplay(visible), speech);
      expect(r.ttsOffsetOfDisplay(visible - 1), speech,
        reason: 'A removed duplicate slash should advance to the next spoken character');
    });

    test('speech cursor starts round-trip across repeated punctuation, spaces and removed glyphs', () {
      for (final source in ['你好！！！世界', '甲    乙', '  甲😄乙  ', 'name__tag@example.com', '甲\u200B乙']) {
        final r = cleaner.clean(source);
        for (var i = 0; i < r.tts.length; i++) {
          final start = r.displayStartOfTts(i);
          expect(start, inInclusiveRange(0, source.length - 1));
          expect(r.ttsOffsetOfDisplay(start), i, reason: '$source / $i');
        }
        expect(r.displayStartOfTts(r.tts.length), source.length);
        expect(r.ttsOffsetOfDisplay(source.length), r.tts.length);
      }
      expect(cleaner.clean('').displayStartOfTts(0), 0);
      expect(cleaner.clean('').ttsOffsetOfDisplay(0), 0);
    });

    test('空文本安全', () {
      final r = cleaner.clean('');
      expect(r.display, '');
      expect(r.tts, '');
    });
  });
}
