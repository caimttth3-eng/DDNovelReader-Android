import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';

import 'package:duoduo_langdu/models/book.dart';
import 'package:duoduo_langdu/services/book_parser.dart';
import 'package:duoduo_langdu/services/content_key.dart';
import 'package:duoduo_langdu/services/tts_cache_store.dart';
import 'package:duoduo_langdu/services/text_decoder.dart';
import 'package:duoduo_langdu/services/reading_text.dart';
import 'package:duoduo_langdu/services/chapterizer.dart';

/// 跨端缓存契约对拍：把安卓端解析结果（key + 每句章内偏移 + 朗读文本）
/// 导出成 JSON，供 PC 端（tests/parity_dump.py）逐项比对。
///
/// 用法：
///   flutter test test/cache_parity_test.dart \
///     --dart-define=PARITY_SRC=<txt 路径> --dart-define=PARITY_TITLE=<书名> \
///     --dart-define=PARITY_OUT=<输出 json> --dart-define=PARITY_CH=<前 N 章>
const String _src = String.fromEnvironment('PARITY_SRC');
const String _title =
    String.fromEnvironment('PARITY_TITLE', defaultValue: '星火');
const String _out = String.fromEnvironment('PARITY_OUT');
const int _limitChapters =
    int.fromEnvironment('PARITY_CH', defaultValue: 1000);
const int _tailChapter =
    int.fromEnvironment('PARITY_TAIL', defaultValue: -1);

/// 指定章全文（排查端间差异时用）
String _tailTextOf(Book book, int ci) {
  if (ci < 0 || ci >= book.chapters.length) return '';
  return book.chapters[ci].paragraphs.map((p) => p.display).join('\n');
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  test('decoder accepts GBK without replacement characters', () {
    expect(decodeTextBytes([0xd6, 0xd0, 0xce, 0xc4]), '中文');
  });
  test('canonical cache offsets survive original indentation, line breaks and formatting', () {
    const display = '　　甲🙂。\n  乙。';
    final source = Book(id: 'coordinates', title: 'coordinates', filePath: '', format: BookFormat.txt, addedAt: DateTime(2026),
      chapters: [Chapter(title: '第一章', paragraphs: [ReadingText.paragraph(display)])]);
    final before = chapterSentenceOffsets(source.chapters.single);
    expect(before, [0, 4]);
    for (final merge in [true, false]) {
      final prepared = ReadingText.format(source, merge: merge, indent: true);
      expect(chapterSentenceOffsets(prepared.chapters.single), before);
    }
  });
  test('upstream line splitting never drops an unpunctuated tail', () {
    final parts = makeChapters('第一章 开始\n正文。尾句没有句号\n第二章 后续\n继续没有句号');
    expect(parts.first.$2, contains('尾句没有句号'));
    expect(parts.last.$2, contains('继续没有句号'));
  });
  for (final collision in [false, true]) {
    test('legacy cache migration preserves audio with collision=$collision', () async {
      final root = await Directory.systemTemp.createTemp('upstream-cache-migration-');
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async => root.path);
      addTearDown(() async {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
        await root.delete(recursive: true);
      });
      final legacy = File('${root.path}/tts_cache/old/voice/1.00/text-test/0000_00000000.mp3');
      await legacy.parent.create(recursive: true);
      await legacy.writeAsBytes([1]);
      final target = File('${root.path}/tts_cache/content/voice/0/text-test/0000_00000000.mp3');
      if (collision) {
        await target.parent.create(recursive: true);
        await target.writeAsBytes([2]);
      }
      final store = TtsCacheStore('old', 'voice', 1, contentKey: 'content', textFingerprint: 'test');
      await Future.wait([store.dir(), store.dir()]);
      expect(await target.readAsBytes(), collision ? [2] : [1]);
      if (collision) {
        expect(await File('${root.path}/tts_cache/content/voice/1.00/text-test/0000_00000000.mp3').readAsBytes(), [1]);
      }
    });
  }
  test('unversioned legacy audio is not reused as desktop source-coordinate audio', () async {
    final root = await Directory.systemTemp.createTemp('upstream-legacy-audio-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async => root.path);
    addTearDown(() async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      await root.delete(recursive: true);
    });
    final old = File('${root.path}/tts_cache/old/voice/1.00/0000_00000000.mp3');
    await old.parent.create(recursive: true);
    await old.writeAsBytes([9]);
    final store = TtsCacheStore('old', 'voice', 1, contentKey: 'content');
    expect(await store.read(0, 0), isNull);
    expect(await File('${root.path}/tts_cache/content/voice/1.00/0000_00000000.mp3').readAsBytes(), [9]);
  });
  test('导出安卓侧缓存坐标', () async {
    if (_src.isEmpty || _out.isEmpty) {
      markTestSkipped('PARITY_SRC and PARITY_OUT must be explicit public fixtures');
      return;
    }
    final book = await BookParser().parse(
      id: 'parity',
      filePath: _src,
      title: _title,
      format: BookFormat.txt,
      addedAt: DateTime(2026, 1, 1),
    );
    expect(book.parseOk, isTrue, reason: book.parseError ?? '');

    final chapterCount = book.chapters.length;
    final nCh = chapterCount < _limitChapters ? chapterCount : _limitChapters;
    final sentences = <Map<String, dynamic>>[];
    for (var ci = 0; ci < nCh; ci++) {
      final offs = chapterSentenceOffsets(book.chapters[ci]);
      var i = 0;
      for (final p in book.chapters[ci].paragraphs) {
        for (final s in p.sentences) {
          sentences.add({'ci': ci, 'off': offs[i], 'tts': s.tts});
          i++;
        }
      }
    }

    final fullNorm = ckNorm(bookFullText(book));
    final fullRunes = fullNorm.runes;
    final dump = {
      'key': book.contentKey,
      'title': book.title,
      'full_norm_len': fullRunes.length,
      'sample_norm': String.fromCharCodes(
          fullRunes.length > ckSampleLimit
              ? fullRunes.take(ckSampleLimit)
              : fullRunes),
      'chapter_count': chapterCount,
      'chapters_head': [for (var i = 0; i < nCh; i++) book.chapters[i].title],
      'all_titles': [for (final c in book.chapters) c.title],
      'compare_chapters': nCh,
      'chapter_para_counts': [
        for (var i = 0; i < nCh; i++) book.chapters[i].paragraphs.length
      ],
      'chapter_norm_lens': [
        for (final c in book.chapters)
          ckNorm(c.paragraphs.map((p) => p.display).join()).runes.length
      ],
      'tail_probe': _tailTextOf(book, _tailChapter),
      'sentences': sentences,
    };
    File(_out)
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(dump));
    // ignore: avoid_print
    print('android: key=${book.contentKey} title=${book.title} '
        'chapters=$chapterCount sentences(first $nCh)=${sentences.length} -> $_out');
  });
}
