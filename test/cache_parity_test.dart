import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:duoduo_langdu/models/book.dart';
import 'package:duoduo_langdu/services/book_parser.dart';
import 'package:duoduo_langdu/services/content_key.dart';
import 'package:duoduo_langdu/services/tts_cache_store.dart';

/// 跨端缓存契约对拍：把安卓端解析结果（key + 每句章内偏移 + 朗读文本）
/// 导出成 JSON，供 PC 端（tests/parity_dump.py）逐项比对。
///
/// 用法：
///   flutter test test/cache_parity_test.dart \
///     --dart-define=PARITY_SRC=<txt 路径> --dart-define=PARITY_TITLE=<书名> \
///     --dart-define=PARITY_OUT=<输出 json> --dart-define=PARITY_CH=<前 N 章>
const String _src = String.fromEnvironment('PARITY_SRC',
    defaultValue:
        r'C:\Users\lyuga\Doubao\chats\2026-08-27\new-chat-1\sample\星火.txt');
const String _title =
    String.fromEnvironment('PARITY_TITLE', defaultValue: '星火');
const String _out = String.fromEnvironment('PARITY_OUT',
    defaultValue:
        r'C:\Users\lyuga\Doubao\chats\2026-09-01\new-chat\duoduo_langdu\build\parity_android.json');
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
  test('导出安卓侧缓存坐标', () async {    final book = await BookParser().parse(
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
