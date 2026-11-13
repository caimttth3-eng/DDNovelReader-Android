import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:path_provider/path_provider.dart';
import '../models/book.dart';
import '../models/progress.dart';
import 'app_storage.dart';
import 'book_parser.dart';
import 'reader_preparation.dart';

class BookSnapshot {
  final Book source;
  final PreparedReadingBook prepared;
  const BookSnapshot(this.source, this.prepared);
}

class SnapshotLookup {
  final BookSnapshot? snapshot;
  final Map<String, dynamic>? _stamp;
  final List<Object> _key;
  final int _generation;
  final bool _needsPublish;
  const SnapshotLookup._(this.snapshot, this._stamp, this._key, this._generation, [this._needsPublish = false]);
}

/// One expendable, private last-book snapshot. Never stores reading progress.
class BookSnapshotCache {
  static final shared = BookSnapshotCache();
  // Bump when parser/preparation semantics or the serialized graph change.
  static const schema = 1;
  static const maxBytes = 64 * 1024 * 1024;
  final String? directoryPath;
  int _generation = 0;
  Future<void> _writes = Future<void>.value();
  BookSnapshot? _memory;
  Map<String, dynamic>? _memoryStamp;
  List<Object>? _memoryKey;
  int? _activeWriteGeneration;
  BookSnapshotCache({this.directoryPath});
  void clearMemoryCache() { _generation++; _memory = null; _memoryStamp = null; _memoryKey = null; }

  void _remember(BookSnapshot snapshot, Map<String, dynamic> stamp, List<Object> key) {
    var characters = 0;
    for (final book in [snapshot.source, snapshot.prepared.book]) {
      for (final chapter in book.chapters) { for (final paragraph in chapter.paragraphs) { characters += paragraph.display.length; } }
    }
    _memory = characters <= 4000000 ? snapshot : null;
    _memoryStamp = _memory == null ? null : stamp;
    _memoryKey = _memory == null ? null : key;
  }

  Future<String> _path() async => directoryPath ?? '${(await getTemporaryDirectory()).path}/book_snapshot';

  Future<SnapshotLookup> lookup(BookMeta meta, ReadingSettings settings) async {
    final generation = ++_generation;
    final key = <Object>[meta.id, meta.title, meta.filePath, meta.format, meta.addedAt.toIso8601String(),
      settings.mergeNonSentenceBreaks, settings.firstLineIndent,
      settings.informationFilter ? settings.informationFilterLevel : 'none', settings.autoExtractToc];
    try {
      if (_memory != null && _same(_memoryKey, key)) {
        final current = await _stat(meta.filePath);
        if (generation != _generation) return SnapshotLookup._(null, null, key, generation);
        if (_same(current, _memoryStamp)) {
          _memory!.prepared.attachSourceMaps();
          return SnapshotLookup._(_memory, current, key, generation, _activeWriteGeneration != null);
        }
        _memory = null; _memoryKey = null; _memoryStamp = null;
      }
      final path = await _path();
      final result = await _readInWorker(path, key);
      if (generation != _generation) return SnapshotLookup._(null, null, key, generation);
      result.$2?.prepared.attachSourceMaps();
      if (result.$2 != null && result.$1 != null) _remember(result.$2!, result.$1!, key);
      return SnapshotLookup._(result.$2, result.$1, key, generation, _activeWriteGeneration != null);
    } catch (_) { return SnapshotLookup._(null, null, key, generation); }
  }

  /// Call unawaited after handing prepared data to the reader. Serial writes
  /// and generation checks prevent an older completion replacing a newer book.
  Future<void> save(SnapshotLookup lookup, Book source, PreparedReadingBook prepared, {ReadingSettings? settings}) {
    if (lookup._stamp == null || !source.parseOk) return Future<void>.value();
    final task = _writes.then((_) async {
      if (lookup._generation != _generation) return;
      final path = await _path();
      if (lookup._generation != _generation) return;
      final stamp = lookup._stamp!, key = [...lookup._key];
      if (settings != null) key.replaceRange(5, 9, [settings.mergeNonSentenceBreaks, settings.firstLineIndent,
        settings.informationFilter ? settings.informationFilterLevel : 'none', settings.autoExtractToc]);
      if (lookup.snapshot != null && !lookup._needsPublish && _same(key, lookup._key)) return;
      _activeWriteGeneration = lookup._generation;
      try {
        final written = await _writeInWorker(path, key, stamp, source, prepared);
        if (written && lookup._generation == _generation) _remember(BookSnapshot(source, prepared), stamp, key);
      } finally { _activeWriteGeneration = null; }
    });
    _writes = task.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return _writes;
  }
}

Future<(Map<String, dynamic>?, BookSnapshot?)> _readInWorker(String path, List<Object> key) =>
  Isolate.run(() => _readSnapshot(path, key));
Future<bool> _writeInWorker(String path, List<Object> key, Map<String, dynamic> stamp, Book source, PreparedReadingBook prepared) =>
  Isolate.run(() => _writeSnapshot(path, key, stamp, source, prepared));

Future<Map<String, dynamic>?> _stat(String path) async {
  final stat = await File(path).stat();
  if (stat.type != FileSystemEntityType.file) return null;
  return {'size': stat.size, 'modified': stat.modified.microsecondsSinceEpoch,
    'changed': stat.changed.microsecondsSinceEpoch};
}
bool _same(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);
bool _identityMatches(Book book, List<Object> key) => _same(
  [book.id, book.title, book.filePath, book.format.name, book.addedAt.toIso8601String()], key.take(5).toList());

Future<(Map<String, dynamic>?, BookSnapshot?)> _readSnapshot(String path, List<Object> key) async {
  final before = await _stat(key[2] as String);
  if (before == null) return (null, null);
  try {
    final file = File('$path/latest.json');
    final length = await file.length();
    if (length <= 0 || length > BookSnapshotCache.maxBytes) return (before, null);
    final bytes = await file.readAsBytes();
    if (bytes.length > BookSnapshotCache.maxBytes) return (before, null);
    final data = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    if (data['schema'] != BookSnapshotCache.schema || !_same(data['key'], key) || !_same(data['stamp'], before)) return (before, null);
    final source = _bookFromJson(data['source'] as Map<String, dynamic>);
    final book = _bookFromJson(data['book'] as Map<String, dynamic>);
    if (!_identityMatches(source, key) || !_identityMatches(book, key)) return (before, null);
    final maps = [for (final c in data['maps'] as List) [for (final p in c as List) (p as List).cast<int>()]];
    if (maps.length != book.chapters.length) return (before, null);
    for (var c = 0; c < maps.length; c++) {
      if (maps[c].length != book.chapters[c].paragraphs.length) return (before, null);
      for (var p = 0; p < maps[c].length; p++) {
        final map = maps[c][p];
        if (map.length != book.chapters[c].paragraphs[p].display.length + 1) return (before, null);
        for (var i = 0; i < map.length; i++) { if (map[i] < 0 || i > 0 && map[i] < map[i - 1]) return (before, null); }
      }
    }
    final toc = [for (final e in data['toc'] as List) BookTocEntry(title: e['title'] as String,
      chapterIndex: e['c'] as int, paragraphIndex: e['p'] as int, displayOffset: e['offset'] as int)];
    final anchors = (data['anchors'] as List).cast<int>(), titles = (data['titles'] as List).cast<bool>();
    if (anchors.length != toc.length || titles.length != toc.length) return (before, null);
    for (final entry in toc) {
      if (entry.chapterIndex < 0 || entry.chapterIndex >= book.chapters.length) return (before, null);
      final paragraphs = book.chapters[entry.chapterIndex].paragraphs;
      if (entry.paragraphIndex < 0 || entry.paragraphIndex >= paragraphs.length || entry.displayOffset < 0 ||
        entry.displayOffset > paragraphs[entry.paragraphIndex].display.length) return (before, null);
    }
    if (!_same(before, await _stat(key[2] as String))) return (null, null);
    return (before, BookSnapshot(source, PreparedReadingBook(book, data['fingerprint'] as String, maps, toc, anchors, titles)));
  } catch (_) { return (before, null); }
}

Future<bool> _writeSnapshot(String path, List<Object> key, Map<String, dynamic> stamp, Book source, PreparedReadingBook prepared) async {
  final temporary = File('$path/writing.tmp');
  try {
    if (!_identityMatches(source, key) || !_identityMatches(prepared.book, key)) return false;
    if (!_same(stamp, await _stat(key[2] as String))) return false;
    final bytes = utf8.encode(jsonEncode({'schema': BookSnapshotCache.schema, 'key': key, 'stamp': stamp,
      'source': _bookJson(source), 'book': _bookJson(prepared.book), 'maps': prepared.sourceMaps,
      'fingerprint': prepared.fingerprint, 'toc': [for (final e in prepared.toc)
        {'title': e.title, 'c': e.chapterIndex, 'p': e.paragraphIndex, 'offset': e.displayOffset}],
      'anchors': prepared.tocAnchors, 'titles': prepared.chapterTitles}));
    if (bytes.length > BookSnapshotCache.maxBytes) return false;
    await Directory(path).create(recursive: true);
    await temporary.writeAsBytes(bytes, flush: true);
    if (!_same(stamp, await _stat(key[2] as String))) return false;
    await temporary.rename('$path/latest.json');
    return true;
  } catch (_) { return false; }
  finally { if (await temporary.exists()) await temporary.delete(); }
}

Map<String, dynamic> _bookJson(Book b) => {'id': b.id, 'title': b.title, 'path': b.filePath,
  'format': b.format.name, 'added': b.addedAt.toIso8601String(), 'chapters': [for (final c in b.chapters)
    {'title': c.title, 'paragraphs': [for (final p in c.paragraphs)
      {'display': p.display, 'tts': p.tts, 'starts': p.sentenceStartTts, 'sentences': [for (final s in p.sentences)
        {'display': s.display, 'tts': s.tts, 'start': s.displayStart, 'end': s.displayEnd, 'pause': s.pauseAfterMilliseconds}]}]}]};

Book _bookFromJson(Map<String, dynamic> b) => Book(id: b['id'] as String, title: b['title'] as String,
  filePath: b['path'] as String, format: BookFormat.values.byName(b['format'] as String),
  addedAt: DateTime.parse(b['added'] as String), chapters: [for (final c in b['chapters'] as List)
    Chapter(title: c['title'] as String, paragraphs: [for (final p in c['paragraphs'] as List)
      Paragraph(display: p['display'] as String, tts: p['tts'] as String, sentenceStartTts: (p['starts'] as List).cast<int>(),
        sentences: [for (final s in p['sentences'] as List) Sentence(s['display'] as String, s['tts'] as String,
          displayStart: s['start'] as int, displayEnd: s['end'] as int, pauseAfterMilliseconds: s['pause'] as int)])])]);
