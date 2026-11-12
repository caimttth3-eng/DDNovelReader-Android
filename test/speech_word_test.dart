import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/models/speech_word.dart';
import 'package:duoduo_langdu/services/reader_typography.dart';

void main() {
  test('Edge timestamps map repeated words and XML entities to source text', () {
    final collector = SpeechWordCollector('你好，你好，A&B。');
    collector.addMetadata(jsonEncode({'Metadata': [
      for (final w in [(1000000, 2000000, '你好'), (4000000, 2000000, '你好'), (8000000, 3000000, 'A&amp;B')])
        {'Type': 'WordBoundary', 'Data': {'Offset': w.$1, 'Duration': w.$2, 'text': {'Text': w.$3}}},
    ]}));
    expect(collector.words.map((w) => w.textStart), [0, 3, 6]);
    expect(collector.words.first.startMicros, 100000);
    expect(speechWordAt(collector.words, const Duration(milliseconds: 99)), isNull);
    expect(speechWordAt(collector.words, const Duration(milliseconds: 150))!.textStart, 0);
    expect(speechWordAt(collector.words, const Duration(milliseconds: 350)), isNull);
    expect(speechWordAt(collector.words, const Duration(milliseconds: 450))!.textStart, 3);
    expect(speechWordAt(collector.words, const Duration(milliseconds: 850))!.text, 'A&B');
    expect(speechWordAt(collector.words, const Duration(milliseconds: 1200)), isNull);
    final restored = collector.words.map((w) => SpeechWord.fromJson(w.toJson())).toList();
    expect(restored.last.textEnd, 9);
  });
  test('missing or malformed metadata does not invent word timings', () {
    final collector = SpeechWordCollector('正文。');
    collector.addMetadata('broken');
    collector.addMetadata('{"Metadata":[{"Type":"SentenceBoundary"}]}');
    collector.addMetadata('{"Metadata":[{"Type":"WordBoundary","Data":{"Offset":0,"Duration":10,"text":{"Text":"其他文字"}}}]}');
    expect(collector.words, isEmpty);
  });
  test('relaxed punctuation preserves all characters and source coordinates', () {
    const source = '　　“你好。”他说，世界真大！';
    final layout = ReaderTypography.layout(source, paragraphStart: true);
    expect(layout.replaceAll('\u200B', '').replaceFirst('\uFFFC', '　　'), source);
    expect(layout, contains('\u200B。\u200B”'));
    for (var i = 2; i < source.length; i++) {
      final rendered = ReaderTypography.layoutOffset(source, i);
      expect(layout[rendered], source[i]);
      expect(ReaderTypography.sourceOffset(source, rendered), i);
    }
  });
}
