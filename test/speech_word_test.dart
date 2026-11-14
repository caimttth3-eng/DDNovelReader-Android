import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/models/speech_word.dart';
import 'package:duoduo_langdu/services/reader_typography.dart';
import 'package:duoduo_langdu/services/tts_cache_store.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  test('cached audio and word timings round-trip together', () async {
    final dir = await Directory.systemTemp.createTemp('word-cache-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async => dir.path);
    addTearDown(() async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      await dir.delete(recursive: true);
    });
    final cache = TtsCacheStore('sample', 'voice', 1, textFingerprint: 'words1-test');
    final words = [const SpeechWord(startMicros: 100000, durationMicros: 200000,
      textStart: 0, textEnd: 2, text: '你好')];
    await cache.write(0, 0, Uint8List.fromList([1, 2, 3]), words: words);
    expect(await cache.read(0, 0), [1, 2, 3]);
    final restored = await cache.readWords(0, 0);
    expect(restored.single.text, '你好');
    expect(speechWordAt(restored, const Duration(milliseconds: 150))!.textStart, 0);
    expect(await cache.readWords(0, 99), isEmpty);
  });
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
  test('a retained viewport line has reversible display coordinates', () {
    const source = '　　前面的正文，当前位置之后保持换行。';
    const split = 8;
    final layout = ReaderTypography.layout(source, paragraphStart: true, lineBreakAt: split);
    expect(layout, contains('\n${source[split]}'));
    for (var i = 2; i < source.length; i++) {
      final rendered = ReaderTypography.layoutOffset(source, i, lineBreakAt: split);
      expect(layout[rendered], source[i]);
      expect(ReaderTypography.sourceOffset(source, rendered, lineBreakAt: split), i);
    }
  });
}
