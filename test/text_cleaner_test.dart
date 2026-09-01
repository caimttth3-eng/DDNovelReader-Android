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

    test('空文本安全', () {
      final r = cleaner.clean('');
      expect(r.display, '');
      expect(r.tts, '');
    });
  });
}
