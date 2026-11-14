import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/models/book.dart';
import 'package:duoduo_langdu/models/progress.dart';
import 'package:duoduo_langdu/services/app_storage.dart';
import 'package:duoduo_langdu/services/book_snapshot_cache.dart';
import 'package:duoduo_langdu/services/reader_preparation.dart';
import 'package:duoduo_langdu/services/reading_text.dart';
import 'package:duoduo_langdu/services/speech_breaks.dart';

void main() {
  late Directory directory;
  late File original;
  late BookMeta meta;
  late Book source;
  late ReadingSettings settings;
  late PreparedReadingBook prepared;
  late BookSnapshotCache cache;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('book-snapshot-test-');
    original = File('${directory.path}/original.txt');
    await original.writeAsString('前言。\n第一章 开始\n甲——乙。\n下一段。');
    meta = BookMeta(id: 'snapshot', title: '快照', filePath: original.path, format: 'txt', addedAt: DateTime(2026));
    source = Book(id: meta.id, title: meta.title, filePath: meta.filePath, format: BookFormat.txt,
      addedAt: meta.addedAt, chapters: [Chapter(title: '正文', paragraphs: [ReadingText.paragraph(await original.readAsString())])]);
    settings = ReadingSettings()..informationFilter = true..informationFilterLevel = 'links';
    prepared = ReaderPreparation.prepareSynchronously(ReaderPreparationRequest(source,
      merge: true, indent: true, filter: 'links', autoExtractToc: true));
    cache = BookSnapshotCache(directoryPath: '${directory.path}/cache');
  });
  tearDown(() async { await directory.delete(recursive: true); });

  test('saving changed pauses uses the latest key and never reuses the older pause policy', () async {
    final lookup = await cache.lookup(meta, settings);
    final latest = ReadingSettings.fromJson(settings.toJson());
    latest.speechPauses = latest.speechPauses.withPause(SpeechPauseKind.dash, 750);
    final changed = ReaderPreparation.prepareSynchronously(ReaderPreparationRequest(source,
      merge: true, indent: true, filter: 'links', autoExtractToc: true, pauseSettings: latest.speechPauses));
    await cache.save(lookup, source, changed, settings: latest);
    cache.clearMemoryCache();
    expect((await cache.lookup(meta, settings)).snapshot, isNull);
    final hit = (await cache.lookup(meta, latest)).snapshot!;
    expect(hit.prepared.book.chapters.expand((c) => c.paragraphs).expand((p) => p.sentences)
      .any((s) => s.pauseAfterMilliseconds == 750), isTrue);
  });

  test('disk round trip restores source, sentences, pause, TOC and exact source mapping', () async {
    final lookup = await cache.lookup(meta, settings);
    expect(lookup.snapshot, isNull);
    await cache.save(lookup, source, prepared);
    final restored = (await BookSnapshotCache(directoryPath: '${directory.path}/cache').lookup(meta, settings)).snapshot!;
    expect(identical(restored.source, source), isFalse);
    expect(restored.source.chapters[0].paragraphs[0].display, await original.readAsString());
    expect(restored.prepared.fingerprint, prepared.fingerprint);
    expect(restored.prepared.sourceMaps, prepared.sourceMaps);
    expect(restored.prepared.toc.map((e) => e.title), prepared.toc.map((e) => e.title));
    expect(restored.prepared.tocAnchors, prepared.tocAnchors);
    expect(restored.prepared.chapterTitles, prepared.chapterTitles);
    expect(restored.prepared.book.chapters.expand((c) => c.paragraphs).expand((p) => p.sentences)
      .any((s) => s.pauseAfterMilliseconds == 300), isTrue);
    final entry = restored.prepared.toc.last;
    expect(ReadingText.anchor(restored.prepared.book, entry.chapterIndex, entry.paragraphIndex, entry.displayOffset),
      restored.prepared.tocAnchors.last);
    expect((await Directory('${directory.path}/cache').list().toList()).map((e) => e.uri.pathSegments.last), ['latest.json']);
  });

  test('formatting and file metadata changes invalidate while font-only changes reuse', () async {
    await cache.save(await cache.lookup(meta, settings), source, prepared);
    final font = ReadingSettings.fromJson(settings.toJson())..fontSize = 64;
    expect((await cache.lookup(meta, font)).snapshot, isNotNull);
    for (final change in <void Function(ReadingSettings)>[
      (s) => s.firstLineIndent = false, (s) => s.mergeNonSentenceBreaks = false,
      (s) => s.informationFilterLevel = 'ads', (s) => s.autoExtractToc = false]) {
      final changed = ReadingSettings.fromJson(settings.toJson()); change(changed);
      expect((await cache.lookup(meta, changed)).snapshot, isNull);
    }
    final renamed = BookMeta(id: meta.id, title: '新书名', filePath: meta.filePath, format: meta.format, addedAt: meta.addedAt);
    expect((await cache.lookup(renamed, settings)).snapshot, isNull);
    await original.setLastModified(DateTime.now().add(const Duration(seconds: 2)));
    expect((await cache.lookup(meta, settings)).snapshot, isNull);
  });

  test('a source changed during cold preparation cannot publish a snapshot', () async {
    final lookup = await cache.lookup(meta, settings);
    await original.writeAsString('已替换的源文件，长度也改变。');
    await cache.save(lookup, source, prepared);
    expect(await File('${directory.path}/cache/latest.json').exists(), isFalse);
  });

  test('corruption, incompatible schema and oversized snapshots safely miss', () async {
    await cache.save(await cache.lookup(meta, settings), source, prepared);
    final file = File('${directory.path}/cache/latest.json');
    final good = await file.readAsString();
    await file.writeAsString('{broken');
    cache.clearMemoryCache();
    expect((await cache.lookup(meta, settings)).snapshot, isNull);
    final json = jsonDecode(good) as Map<String, dynamic>; json['schema'] = 999;
    await file.writeAsString(jsonEncode(json));
    cache.clearMemoryCache();
    expect((await cache.lookup(meta, settings)).snapshot, isNull);
    final handle = await file.open(mode: FileMode.write);
    await handle.truncate(BookSnapshotCache.maxBytes + 1); await handle.close();
    cache.clearMemoryCache();
    expect((await cache.lookup(meta, settings)).snapshot, isNull);
  });

  test('the recent memory snapshot reuses the graph and valid hits do not rewrite JSON', () async {
    await cache.save(await cache.lookup(meta, settings), source, prepared);
    final file = File('${directory.path}/cache/latest.json');
    final before = await file.stat();
    final hit = await cache.lookup(meta, settings);
    expect(identical(hit.snapshot!.source, source), isTrue);
    expect(identical(hit.snapshot!.prepared, prepared), isTrue);
    await cache.save(hit, source, prepared, settings: settings);
    expect((await file.stat()).modified, before.modified);
    cache.clearMemoryCache();
    final diskHit = await cache.lookup(meta, settings);
    expect(diskHit.snapshot, isNotNull);
    expect(identical(diskHit.snapshot!.source, source), isFalse);
    await original.writeAsString('源文件改变');
    expect((await cache.lookup(meta, settings)).snapshot, isNull);
  });

  test('newer lookup generation suppresses an old queued save and leaves one snapshot', () async {
    final old = await cache.lookup(meta, settings);
    final current = await cache.lookup(meta, settings);
    await cache.save(old, source, prepared);
    expect(await File('${directory.path}/cache/latest.json').exists(), isFalse);
    await cache.save(current, source, prepared);
    expect((await cache.lookup(meta, settings)).snapshot, isNotNull);
    expect((await Directory('${directory.path}/cache').list().toList()), hasLength(1));
  });
}
