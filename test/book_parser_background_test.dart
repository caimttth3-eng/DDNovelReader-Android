import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:duoduo_langdu/models/book.dart';
import 'package:duoduo_langdu/services/book_parser.dart';
import 'package:duoduo_langdu/services/text_cleaner.dart';
import 'package:flutter_test/flutter_test.dart';

class _WorkerProbeCleaner extends TextCleaner {
  final SendPort report;
  bool reported = false;
  _WorkerProbeCleaner(this.report);

  @override
  CleanedText clean(String source) {
    if (!reported) {
      reported = true;
      report.send(Isolate.current.debugName);
    }
    return super.clean(source);
  }
}

void main() {
  late Directory directory;
  final addedAt = DateTime.utc(2026, 11, 13);
  setUp(() async {
    BookParser.clearMemoryCache();
    directory = await Directory.systemTemp.createTemp('book-parser-worker-');
  });
  tearDown(() async {
    BookParser.clearMemoryCache();
    await directory.delete(recursive: true);
  });

  Future<Book> parse(File file, {BookParser? parser}) => (parser ?? BookParser()).parse(
    id: 'worker-book', filePath: file.path, title: '后台解析',
    format: BookFormat.txt, addedAt: addedAt);

  test('large TXT cleaning runs in a worker and transfers intact chapters and sentence coordinates', () async {
    String paragraph(int chapter, int number) => '编号$chapter/$number：${List.filled(8, '清晨，阳光照进窗前。他展开来信，读起远方朋友的问候。').join()}🙂';
    final text = List.generate(24, (c) => '第${c + 1}章 山间来信\n\n${
      List.generate(100, (p) => paragraph(c, p)).join('\n\n')}').join('\n\n');
    final file = await File('${directory.path}/large.txt').writeAsString(text);
    final messages = ReceivePort();
    addTearDown(messages.close);
    final cleaner = _WorkerProbeCleaner(messages.sendPort);
    final workerStarted = messages.first;
    final pending = parse(file, parser: BookParser(cleaner: cleaner));
    expect(await workerStarted.timeout(const Duration(seconds: 15)), 'book-parser');
    final book = await pending;
    expect(cleaner.reported, isFalse, reason: 'The caller cleaner is not executed or mutated on the UI isolate');
    expect(book.parseOk, isTrue, reason: book.parseError);
    expect(book.id, 'worker-book');
    expect(book.filePath, file.path);
    expect(book.addedAt, addedAt);
    expect(book.chapterCount, 24);
    expect(book.chapters.first.title, '第1章 山间来信');
    expect(book.chapters.last.title, '第24章 山间来信');
    expect(book.chapters.first.paragraphs.first.display.trim(), paragraph(0, 0));
    expect(book.chapters.last.paragraphs.last.display.trim(), paragraph(23, 99));
    final first = book.chapters.first.paragraphs.first;
    expect(first.tts, isNot(contains('🙂')));
    expect(first.sentences, isNotEmpty);
    for (var i = 0; i < first.sentences.length; i++) {
      final sentence = first.sentences[i];
      expect(first.display.substring(sentence.displayStart, sentence.displayEnd), sentence.display);
      final start = first.sentenceStartTts[i];
      expect(first.tts.substring(start, start + sentence.tts.length), sentence.tts);
    }
  });

  test('UTF16 byte order decoding remains in the background pipeline', () async {
    const text = '第一章 初见\n甲乙。\n第二章 后来\n丙丁。';
    for (final littleEndian in [true, false]) {
      final bytes = <int>[if (littleEndian) ...[0xff, 0xfe] else ...[0xfe, 0xff]];
      for (final code in text.codeUnits) {
        bytes.addAll(littleEndian ? [code & 0xff, code >> 8] : [code >> 8, code & 0xff]);
      }
      final file = await File('${directory.path}/utf16-$littleEndian.txt').writeAsBytes(bytes);
      final book = await parse(file);
      expect(book.parseOk, isTrue, reason: book.parseError);
      expect(book.chapters.map((c) => c.title), ['第一章 初见', '第二章 后来']);
      expect(book.chapters.last.paragraphs.single.display, '丙丁。');
    }
  });

  test('missing and malformed archive files return failed books with caller metadata', () async {
    final missing = await parse(File('${directory.path}/missing.txt'));
    expect(missing.parseOk, isFalse);
    expect(missing.parseError, isNotEmpty);
    expect(missing.id, 'worker-book');
    expect(missing.addedAt, addedAt);
    final invalid = await File('${directory.path}/invalid.epub').writeAsBytes(utf8.encode('not a zip'));
    final book = await BookParser().parse(id: 'bad-archive', filePath: invalid.path,
      title: '坏文件', format: BookFormat.epub, addedAt: addedAt);
    expect(book.parseOk, isFalse);
    expect(book.title, '坏文件');
    expect(book.parseError, isNotEmpty);
  });

  test('default parsers share one recent book, deduplicate requests and evict older books', () async {
    final a = await File('${directory.path}/a.txt').writeAsString('甲乙。');
    final b = await File('${directory.path}/b.txt').writeAsString('丙丁。');
    final simultaneous = await Future.wait([parse(a), parse(a)]);
    expect(simultaneous[1], same(simultaneous[0]));
    expect(await parse(a), same(simultaneous[0]));
    final other = await parse(b);
    expect(await parse(b), same(other));
    expect(await parse(a), isNot(same(simultaneous[0])), reason: 'Only the last successful book stays resident');
  });

  test('stat changes and missing files cannot reuse stale books, and failures are not retained', () async {
    final file = await File('${directory.path}/changed.txt').writeAsString('甲乙。');
    final first = await parse(file);
    await file.writeAsString('丙丁。');
    await file.setLastModified(DateTime.utc(2020));
    final changed = await parse(file);
    expect(changed, isNot(same(first)));
    expect(changed.chapters.single.paragraphs.single.display, '丙丁。');
    await file.delete();
    final failed = await parse(file);
    expect(failed.parseOk, isFalse);
    expect(await parse(file), isNot(same(failed)));
    await file.writeAsString('重新出现的正文。');
    final restored = await parse(file);
    expect(restored.parseOk, isTrue);
    expect(restored.chapters.single.paragraphs.single.display, '重新出现的正文。');
    final renamed = await BookParser().parse(id: 'worker-book', filePath: file.path,
      title: '新书名', format: BookFormat.txt, addedAt: addedAt);
    expect(renamed, isNot(same(restored)));
    expect(renamed.title, '新书名');
  });

  test('clear and newer requests prevent older in-flight results taking over the cache', () async {
    final a = await File('${directory.path}/old.txt').writeAsString('旧正文。');
    final b = await File('${directory.path}/new.txt').writeAsString('新正文。');
    final beforeClear = parse(a);
    BookParser.clearMemoryCache();
    final invalidated = await beforeClear;
    expect(await parse(a), isNot(same(invalidated)));
    BookParser.clearMemoryCache();
    final oldRequest = parse(a), newRequest = parse(b);
    await oldRequest;
    final newest = await newRequest;
    expect(await parse(b), same(newest));
  });

  test('custom cleaners bypass and do not replace the shared default cache', () async {
    final file = await File('${directory.path}/custom.txt').writeAsString('原文。');
    final original = await parse(file);
    final messages = ReceivePort();
    addTearDown(messages.close);
    final started = messages.first;
    final custom = await parse(file, parser: BookParser(cleaner: _WorkerProbeCleaner(messages.sendPort)));
    expect(await started, 'book-parser');
    expect(custom, isNot(same(original)));
    expect(await parse(file), same(original));
  });
}
