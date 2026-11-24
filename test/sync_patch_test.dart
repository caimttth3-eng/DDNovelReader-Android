import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:duoduo_langdu/models/book.dart';
import 'package:duoduo_langdu/models/progress.dart';
import 'package:duoduo_langdu/services/annotation_store.dart';
import 'package:duoduo_langdu/services/app_storage.dart';
import 'package:duoduo_langdu/services/sync_engine.dart';
import 'package:duoduo_langdu/services/webdav_client.dart';

typedef _Attempt = ({String path, String? etag, bool ifNoneMatch});

/// A strict versioned transport: every conditional write is checked against
/// the current bytes, including changes made after the most recent GET.
class _MemoryDav extends WebDavClient {
  _MemoryDav() : super(server: 'https://synthetic.invalid/dav');

  final files = <String, List<int>>{};
  final etags = <String, String>{};
  final attempts = <_Attempt>[];
  final mutations = <String>[];
  final reads = <String>[];
  void Function(int number, String path)? beforeBookPut;
  var _revision = 0;

  void record(String key, Map<String, dynamic> value) {
    final path = 'v1/books/$key.json';
    files[path] = utf8.encode(jsonEncode(value));
    etags[path] = '"v${++_revision}"';
  }

  Map<String, dynamic> read(String key) =>
      jsonDecode(utf8.decode(files['v1/books/$key.json']!)) as Map<String, dynamic>;

  @override
  Future<void> mkdirs(String rel) async { mutations.add('mkdirs:$rel'); }

  @override
  Future<bool> mkdir(String rel) async { mutations.add('mkdir:$rel'); return true; }

  @override
  Future<List<WebDavEntry>> propfind([String rel = '', String depth = '1']) async {
    reads.add('propfind:$rel');
    return [for (final path in files.keys)
      if (path.startsWith('$rel/') && !path.substring(rel.length + 1).contains('/'))
        WebDavEntry(name: path.split('/').last, rel: path, isDir: false)];
  }

  @override
  Future<List<int>?> get(String rel) async {
    reads.add('get:$rel');
    return files[rel] == null ? null : List.of(files[rel]!);
  }

  @override
  Future<WebDavResponse> getWithMetadata(String rel) async {
    reads.add('getWithMetadata:$rel');
    return WebDavResponse(
      files.containsKey(rel) ? 200 : 404, List.of(files[rel] ?? const []),
      etag: etags[rel] ?? '');
  }

  @override
  Future<bool> put(String rel, List<int> data, {bool atomic = true,
      String? etag, bool ifNoneMatch = false,
      String contentType = 'application/json; charset=utf-8'}) async {
    if (rel.startsWith('v1/books/')) {
      attempts.add((path: rel, etag: etag, ifNoneMatch: ifNoneMatch));
      beforeBookPut?.call(attempts.length, rel);
    }
    if (ifNoneMatch && files.containsKey(rel) ||
        etag != null && etag != etags[rel]) {
      throw WebDavException('Synthetic precondition failed', 412);
    }
    files[rel] = List.of(data);
    etags[rel] = '"v${++_revision}"';
    mutations.add('put:$rel');
    return true;
  }

  @override
  Future<bool> delete(String rel, {String? etag}) async {
    if (etag != null && etag != etags[rel]) {
      throw WebDavException('Synthetic delete precondition failed', 412);
    }
    files.remove(rel); etags.remove(rel); mutations.add('delete:$rel');
    return true;
  }
}

class _Engine extends SyncEngine {
  _Engine(AppStorage storage, AnnotationStore annotations, this.dav)
      : super(storage: storage, annotations: annotations);
  final _MemoryDav dav;
  @override
  WebDavClient client(Map<String, dynamic> s) => dav;
}

/// Preview must not enter any reader that can repair paths or resolve aliases
/// through the normal shelf loader; exact-ID snapshots handle those in memory.
class _SnapshotOnlyStorage extends AppStorage {
  @override
  Future<List<BookMeta>> loadBooks() async => throw StateError('Mutating shelf reader used in preview');
  @override
  Future<BookProgress?> loadProgress(String id) async => throw StateError('Alias-resolving progress reader used in preview');
}

class _SnapshotOnlyAnnotations extends AnnotationStore {
  @override
  Future<List<Map<String, dynamic>>> loadRawBookmarks(String id) async => throw StateError('Resolving bookmark reader used in preview');
  @override
  Future<Map<String, double>> loadBookmarkDeletions(String id) async => throw StateError('Resolving deletion reader used in preview');
  @override
  Future<double> loadBookmarksAt(String id) async => throw StateError('Resolving bookmark clock reader used in preview');
}

BookMeta _meta(String id, {String key = 'content', List<String> aliases = const [], String path = ''}) => BookMeta(
  id: id, title: 'Synthetic book', filePath: path, format: 'txt',
  addedAt: DateTime(2026), contentKey: key, aliases: aliases);

Map<String, dynamic> _bm(String id, double version, {String? text}) => {
  'id': id, 'created_at': version, 'chapter_idx': 0,
  'offset': 1, 'offset_end': 2, 'text': text ?? id,
};

Map<String, dynamic> _record(String key, {double progressAt = 0, int chapter = 1,
    double bookmarksAt = 0, double metadataAt = 0,
    List<Map<String, dynamic>> bookmarks = const [],
    Map<String, double> deletions = const {}}) => {
  'schema': 2, 'content_key': key, 'title': 'Remote title', 'author': 'Remote author',
  'format': 'txt', 'total_chars': 1000, 'chapter_count': 10,
  'progress': {'chapter_idx': chapter, 'char_offset': 42, 'percent': 25, 'percent_unit': 'percent'},
  'progress_at': progressAt, 'bookmarks_at': bookmarksAt,
  'metadata_at': metadataAt, 'bookmarks': bookmarks, 'bookmark_deletions': deletions,
  'updated_at': [progressAt, bookmarksAt, metadataAt].reduce((a, b) => a > b ? a : b),
};

Map<String, dynamic> _tomb(String key, double at) =>
    SyncEngine.tombstoneRecord(key, {'deleted_at': at, 'title': 'Deleted book'}, 'other');

Future<Map<String, Object?>> _preferences() async {
  final prefs = await SharedPreferences.getInstance();
  return {for (final key in prefs.getKeys()) key: prefs.get(key)};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<(AppStorage, AnnotationStore)> configure({List<BookMeta>? books}) async {
    final storage = AppStorage(), annotations = AnnotationStore();
    await storage.saveSettings({SyncEngine.cfgServer: 'https://synthetic.invalid/dav',
      SyncEngine.cfgAuto: false, 'fontSize': 39.0});
    await storage.saveBooks(books ?? [_meta('book')]);
    return (storage, annotations);
  }

  test('pure record merge preserves remote extensions and independent field versions', () {
    final local = _record('content', progressAt: 100, bookmarksAt: 300, metadataAt: 700,
      bookmarks: [_bm('local', 300), {..._bm('edit', 10), 'modified_at': 250, 'text': 'new'}],
      deletions: {'gone': 230});
    final remote = {..._record('content', progressAt: 500, chapter: 7, bookmarksAt: 260,
      bookmarks: [_bm('remote', 260), _bm('edit', 10), _bm('gone', 200)],
      deletions: {'earlier': 180}), 'desktop_extension': {'retained': true}, '_etag': 'transport'};
    final beforeLocal = jsonEncode(local), beforeRemote = jsonEncode(remote);
    final merged = SyncEngine.mergeRecord(local, remote, 'this-device');
    expect((merged['progress'] as Map)['chapter_idx'], 7);
    expect(merged['progress_at'], 500);
    expect(merged['metadata_at'], 700);
    expect(merged['updated_at'], 700);
    expect(merged['title'], 'Remote title');
    expect(merged['desktop_extension'], {'retained': true});
    expect(merged.containsKey('_etag'), isFalse);
    final bookmarks = (merged['bookmarks'] as List).cast<Map>();
    expect(bookmarks.map((bm) => bm['id']), containsAll(['local', 'remote', 'edit']));
    expect(bookmarks.map((bm) => bm['id']), isNot(contains('gone')));
    expect(bookmarks.singleWhere((bm) => bm['id'] == 'edit')['text'], 'new');
    expect(merged['bookmark_deletions'], {'earlier': 180, 'gone': 230});
    expect(jsonEncode(local), beforeLocal); expect(jsonEncode(remote), beforeRemote);
  });

  test('record merge honors progress tolerance and actual resurrection activity', () {
    final remote = _record('content', progressAt: 100, chapter: 5);
    final within = SyncEngine.mergeRecord(_record('content', progressAt: 100.25, chapter: 2), remote, 'device');
    expect((within['progress'] as Map)['chapter_idx'], 5);
    final newer = SyncEngine.mergeRecord(_record('content', progressAt: 101, chapter: 2), remote, 'device');
    expect((newer['progress'] as Map)['chapter_idx'], 2);
    final deletion = _tomb('content', 500);
    final loses = SyncEngine.mergeRecord(_record('content', progressAt: 400), deletion, 'device');
    expect(loses['deleted'], isTrue); expect(loses['deleted_at'], 500);
    final tie = SyncEngine.mergeRecord(_record('content', metadataAt: 500), deletion, 'device');
    expect(tie['deleted'], isTrue);
    final restored = SyncEngine.mergeRecord(_record('content', metadataAt: 501), deletion, 'device');
    expect(restored['deleted'], isNot(true)); expect(restored['metadata_at'], 501);
    expect(restored['updated_at'], 501);
    final both = SyncEngine.mergeRecord(_tomb('content', 600), deletion, 'device');
    expect(both['deleted'], isTrue); expect(both['deleted_at'], 600);
  });

  test('push detection includes edits, deletion-only state, metadata and missing fields without clock noise', () {
    final remote = _record('content', progressAt: 100, bookmarksAt: 200,
      bookmarks: [_bm('same', 200)]);
    expect(SyncEngine.pushNeeded({...remote, 'device': 'different', 'synced_at': 999}, remote), isFalse);
    expect(SyncEngine.pushNeeded(remote, null), isTrue);
    expect(SyncEngine.pushNeeded({...remote, 'metadata_at': 300, 'updated_at': 300}, remote), isTrue);
    expect(SyncEngine.pushNeeded({...remote, 'bookmarks': [{..._bm('same', 200), 'modified_at': 201}]}, remote), isTrue);
    expect(SyncEngine.pushNeeded({...remote, 'bookmarks': [], 'bookmark_deletions': {'same': 210}}, remote), isTrue);
    final incomplete = Map<String, dynamic>.from(remote)..remove('source');
    expect(SyncEngine.pushNeeded({...remote, 'source': {'ext': '.txt', 'size': 12}}, incomplete), isTrue);
    expect(SyncEngine.pushNeeded(_record('content', progressAt: 90), remote), isFalse,
      reason: 'Merely having an older snapshot must never replace newer remote progress or bookmarks');
  });

  test('two consecutive 412 conflicts each re-read and conditionally merge the latest record', () async {
    final (storage, annotations) = await configure();
    await storage.saveProgress(BookProgress(bookId: 'book', chapterIndex: 1, updatedAt: 100));
    await annotations.saveRawBookmarks('book', [_bm('local', 300)]);
    final dav = _MemoryDav()..record('content', _record('content', progressAt: 150,
      bookmarks: [_bm('old', 50)]));
    dav.beforeBookPut = (number, path) {
      if (number <= 2) {
        dav.record('content', {..._record('content', progressAt: 400.0 + number * 100,
          chapter: 6 + number, bookmarksAt: 350,
          bookmarks: [_bm('remote-$number', 350)], deletions: {'old': 250}),
          'foreign_extension': number});
      }
    };
    final report = await _Engine(storage, annotations, dav).sync(mode: 'push');
    expect(report.ok, isTrue, reason: report.error);
    expect(report.conflicts, 2); expect(dav.attempts, hasLength(3));
    expect(dav.attempts.every((attempt) => attempt.etag != null && !attempt.ifNoneMatch), isTrue);
    expect(dav.attempts.map((attempt) => attempt.etag).toSet(), hasLength(3));
    final actual = dav.read('content');
    expect(actual['progress_at'], 600); expect((actual['progress'] as Map)['chapter_idx'], 8);
    expect(actual['foreign_extension'], 2);
    expect((actual['bookmarks'] as List).map((bm) => bm['id']), containsAll(['local', 'remote-2']));
    expect((actual['bookmarks'] as List).map((bm) => bm['id']), isNot(contains('old')));
    expect((actual['bookmark_deletions'] as Map)['old'], 250);
    expect((await storage.loadProgress('book'))!.updatedAt, 100,
      reason: 'Conflict handling in push mode does not apply downloaded progress locally');
    expect((await annotations.loadRawBookmarks('book')).map((bm) => bm['id']), ['local']);
  });

  test('concurrent creation uses If-None-Match then fresh If-Match without losing the new remote record', () async {
    final (storage, annotations) = await configure();
    await storage.saveProgress(BookProgress(bookId: 'book', updatedAt: 100));
    await annotations.saveRawBookmarks('book', [_bm('local', 200)]);
    final dav = _MemoryDav();
    dav.beforeBookPut = (number, path) {
      if (number == 1) dav.record('content', _record('content', progressAt: 900, chapter: 9,
        bookmarksAt: 600, bookmarks: [_bm('remote', 600)]));
    };
    final report = await _Engine(storage, annotations, dav).sync(mode: 'push');
    expect(report.ok, isTrue, reason: report.error);
    expect(report.conflicts, 1); expect(dav.attempts, hasLength(2));
    expect(dav.attempts.first.ifNoneMatch, isTrue); expect(dav.attempts.first.etag, isNull);
    expect(dav.attempts.last.ifNoneMatch, isFalse); expect(dav.attempts.last.etag, isNotEmpty);
    expect(dav.read('content')['progress_at'], 900);
    expect((dav.read('content')['bookmarks'] as List).map((bm) => bm['id']), containsAll(['local', 'remote']));
  });

  test('a newer tombstone arriving during conflict cannot be resurrected by an old push', () async {
    final (storage, annotations) = await configure();
    await storage.saveProgress(BookProgress(bookId: 'book', updatedAt: 200));
    final dav = _MemoryDav()..record('content', _record('content', progressAt: 100));
    dav.beforeBookPut = (number, path) {
      if (number == 1) dav.record('content', _tomb('content', 500));
    };
    final report = await _Engine(storage, annotations, dav).sync(mode: 'push');
    expect(report.ok, isTrue, reason: report.error);
    expect(report.conflicts, 1);
    expect(dav.read('content')['deleted'], isTrue);
    expect(dav.read('content')['deleted_at'], 500);
    expect(dav.mutations.where((operation) => operation == 'put:v1/books/content.json'), isEmpty);
    expect((await storage.loadBooks()).map((book) => book.id), ['book']);
    expect((await storage.loadProgress('book'))!.updatedAt, 200);
  });

  test('persistent conflicts fail within a bounded number of fully conditional attempts', () async {
    final (storage, annotations) = await configure();
    await annotations.saveRawBookmarks('book', [_bm('local', 300)]);
    final dav = _MemoryDav()..record('content', _record('content', progressAt: 100));
    dav.beforeBookPut = (number, path) => dav.record('content',
      _record('content', progressAt: 1000.0 + number, chapter: number));
    final report = await _Engine(storage, annotations, dav).sync(mode: 'push');
    expect(report.ok, isFalse); expect(dav.attempts, hasLength(4));
    expect(dav.attempts.every((attempt) => attempt.etag != null && !attempt.ifNoneMatch), isTrue);
    expect(dav.read('content')['progress_at'], 1004);
    expect(dav.mutations.where((operation) => operation == 'put:v1/books/content.json'), isEmpty);
  });

  test('push retains local state despite newer remote progress, bookmarks and tombstones', () async {
    final (storage, annotations) = await configure(books: [_meta('book'), _meta('kept', key: 'kept')]);
    await storage.saveProgress(BookProgress(bookId: 'book', updatedAt: 100));
    await annotations.saveRawBookmarks('book', [_bm('local', 150)]);
    final dav = _MemoryDav()
      ..record('content', _record('content', progressAt: 500, chapter: 8,
        bookmarksAt: 300, bookmarks: [_bm('remote', 300)]))
      ..record('kept', _tomb('kept', 1000));
    final report = await _Engine(storage, annotations, dav).sync(mode: 'push');
    expect(report.ok, isTrue, reason: report.error);
    expect((await storage.loadProgress('book'))!.updatedAt, 100);
    expect((await annotations.loadRawBookmarks('book')).map((bm) => bm['id']), ['local']);
    expect((await storage.loadBooks()).map((book) => book.id), containsAll(['book', 'kept']));
    expect(dav.read('content')['progress_at'], 500);
    expect(dav.read('kept')['deleted'], isTrue);
    expect((dav.read('content')['bookmarks'] as List).map((bm) => bm['id']), containsAll(['local', 'remote']));
  });

  test('pull applies remote changes but makes no remote mutations, including source deletion and registration', () async {
    final (storage, annotations) = await configure(books: [_meta('book'), _meta('gone', key: 'gone')]);
    await storage.saveProgress(BookProgress(bookId: 'book', updatedAt: 100));
    final dav = _MemoryDav()
      ..record('content', _record('content', progressAt: 500, chapter: 8,
        bookmarksAt: 300, bookmarks: [_bm('remote', 300)]))
      ..record('gone', _tomb('gone', 1000));
    dav.files['v1/sources/gone.txt'] = utf8.encode('Synthetic source that pull must leave untouched.');
    final before = jsonEncode(dav.files);
    final report = await _Engine(storage, annotations, dav).sync(mode: 'pull');
    expect(report.ok, isTrue, reason: report.error);
    expect((await storage.loadProgress('book'))!.updatedAt, 500);
    expect((await annotations.loadRawBookmarks('book')).single['id'], 'remote');
    expect((await storage.loadBooks()).map((book) => book.id), ['book']);
    expect(report.removedIds, ['gone']);
    expect(dav.mutations, isEmpty); expect(dav.attempts, isEmpty);
    expect(jsonEncode(dav.files), before);
  });

  test('preview and exact-ID snapshots never repair paths, consolidate duplicates or write first device settings', () async {
    final books = [
      _meta('a', aliases: ['legacy-a'], path: '/synthetic/old-ios-container/a.txt'),
      _meta('b', path: '/synthetic/old-ios-container/b.txt'),
    ];
    SharedPreferences.setMockInitialValues({
      'duoduo.settings.v1': jsonEncode({SyncEngine.cfgServer: 'https://synthetic.invalid/dav', 'fontSize': 39}),
      'duoduo.books.v1': jsonEncode(books.map((book) => book.toJson()).toList()),
      'duoduo.progress.a': jsonEncode(BookProgress(bookId: 'a', updatedAt: 100).toJson()),
      'duoduo.progress.b': jsonEncode(BookProgress(bookId: 'b', chapterIndex: 7, updatedAt: 200).toJson()),
      'duoduo.progress.legacy-a': jsonEncode(BookProgress(bookId: 'legacy-a', updatedAt: 150).toJson()),
      'duoduo.bookmarks.a': jsonEncode([_bm('a-bookmark', 100)]),
      'duoduo.bookmarks.b': jsonEncode([_bm('b-bookmark', 200)]),
      'duoduo.bookmarkDeletions.b': jsonEncode({'gone': 175}),
      'duoduo.bookmarksAt.a': 100.0,
      'duoduo.bookmarksAt.b': 200.0,
      'duoduo.lastBookId': 'b',
    });
    final storage = _SnapshotOnlyStorage(), annotations = _SnapshotOnlyAnnotations();
    final original = await _preferences();
    expect((await storage.loadBooksSnapshot()).map((book) => book.filePath), books.map((book) => book.filePath));
    expect((await storage.loadProgressSnapshot('legacy-a'))!.bookId, 'legacy-a');
    expect((await storage.loadProgressSnapshot('legacy-a'))!.updatedAt, 150);
    expect((await annotations.loadRawBookmarksSnapshot('b')).single['id'], 'b-bookmark');
    expect(await annotations.loadBookmarkDeletionsSnapshot('b'), {'gone': 175});
    expect(await annotations.loadBookmarksAtSnapshot('b'), 200);
    final dav = _MemoryDav()..record('content', _record('content', progressAt: 500,
      bookmarks: [_bm('remote', 400)], bookmarksAt: 400));
    final beforeRemote = jsonEncode(dav.files);
    final engine = _Engine(storage, annotations, dav);
    for (final mode in ['both', 'push', 'pull']) {
      final report = await engine.sync(mode: mode, dryRun: true);
      expect(report.ok, isTrue, reason: '$mode: ${report.error}');
      expect(report.dryRun, isTrue);
      expect(report.hasChanges, isTrue, reason: '$mode preview must actually report pending field changes');
      expect(await _preferences(), original, reason: '$mode preview must preserve every stored byte and key');
      expect(dav.mutations, isEmpty); expect(dav.attempts, isEmpty);
      expect(jsonEncode(dav.files), beforeRemote);
    }
  });

  test('invalid sync mode is rejected before any local or remote mutation', () async {
    final (storage, annotations) = await configure();
    final before = await _preferences(), dav = _MemoryDav();
    final report = await _Engine(storage, annotations, dav).sync(mode: 'invalid-mode');
    expect(report.ok, isFalse);
    expect(await _preferences(), before); expect(dav.mutations, isEmpty);
  });

  test('read-only local aggregation includes newer exact-ID alias state without consolidating storage', () async {
    final books = [_meta('a', aliases: ['legacy-a']), _meta('b')];
    SharedPreferences.setMockInitialValues({
      'duoduo.books.v1': jsonEncode(books.map((book) => book.toJson()).toList()),
      'duoduo.progress.a': jsonEncode(BookProgress(bookId: 'a', updatedAt: 100).toJson()),
      'duoduo.progress.b': jsonEncode(BookProgress(bookId: 'b', chapterIndex: 2, updatedAt: 200).toJson()),
      'duoduo.progress.legacy-a': jsonEncode(BookProgress(bookId: 'legacy-a', chapterIndex: 9, updatedAt: 900).toJson()),
      'duoduo.bookmarks.a': jsonEncode([_bm('canonical', 100), _bm('gone', 90)]),
      'duoduo.bookmarks.b': jsonEncode([_bm('duplicate', 200)]),
      'duoduo.bookmarks.legacy-a': jsonEncode([_bm('alias', 700)]),
      'duoduo.bookmarkDeletions.legacy-a': jsonEncode({'gone': 800}),
      'duoduo.bookmarksAt.legacy-a': 800.0,
      'duoduo.lastBookId': 'b',
    });
    final before = await _preferences();
    final engine = _Engine(_SnapshotOnlyStorage(), _SnapshotOnlyAnnotations(), _MemoryDav());
    final records = await engine.localRecords({}, 'preview', readOnly: true);
    expect(records.keys, ['content']); expect(records['content']!.key, 'a');
    final actual = records['content']!.value;
    expect(actual['progress_at'], 900); expect((actual['progress'] as Map)['chapter_idx'], 9);
    expect((actual['bookmarks'] as List).map((bm) => bm['id']), containsAll(['canonical', 'duplicate', 'alias']));
    expect((actual['bookmarks'] as List).map((bm) => bm['id']), isNot(contains('gone')));
    expect((actual['bookmark_deletions'] as Map)['gone'], 800);
    expect(actual['bookmarks_at'], 800);
    expect(await _preferences(), before);
  });

  test('a deletion upload rebases to a newer live record without deleting it or undoing the local deletion', () async {
    final (storage, annotations) = await configure();
    final deletedAt = DateTime.now().millisecondsSinceEpoch / 1000.0;
    await storage.removeBook('book', deletedAt: deletedAt);
    final dav = _MemoryDav()..record('content', _record('content', progressAt: deletedAt - 50));
    dav.beforeBookPut = (number, path) {
      if (number == 1) dav.record('content', _record('content', progressAt: deletedAt + 100,
        chapter: 8, bookmarksAt: deletedAt + 100,
        bookmarks: [_bm('remote-survivor', deletedAt + 100)]));
    };
    final report = await _Engine(storage, annotations, dav).sync(mode: 'push');
    expect(report.ok, isTrue, reason: report.error);
    expect(report.conflicts, 1); expect(dav.attempts, hasLength(1));
    final actual = dav.read('content');
    expect(actual['deleted'], isNot(true)); expect(actual['progress_at'], deletedAt + 100);
    expect((actual['bookmarks'] as List).single['id'], 'remote-survivor');
    expect(dav.mutations.where((operation) => operation == 'put:v1/books/content.json'), isEmpty);
    expect(await storage.loadBooks(), isEmpty);
    expect(((await storage.loadDeletions())['content'] as Map)['deleted_at'], deletedAt);
  });

  for (final validator in ['', 'W/"weak-version"']) {
    test('missing or weak validator $validator blocks an unsafe push but permits a read-only pull', () async {
      final (storage, annotations) = await configure();
      await storage.saveProgress(BookProgress(bookId: 'book', updatedAt: 200));
      final dav = _MemoryDav()..record('content', _record('content', progressAt: 100));
      dav.etags['v1/books/content.json'] = validator;
      final engine = _Engine(storage, annotations, dav);
      final pushed = await engine.sync(mode: 'push');
      expect(pushed.ok, isFalse); expect(pushed.error, contains('ETag'));
      expect(dav.attempts, isEmpty, reason: 'Do not issue an unconditional fallback write');
      expect(dav.read('content')['progress_at'], 100);
      dav.record('content', _record('content', progressAt: 500, chapter: 8));
      dav.etags['v1/books/content.json'] = validator;
      dav.mutations.clear();
      final pulled = await engine.sync(mode: 'pull');
      expect(pulled.ok, isTrue, reason: pulled.error);
      expect((await storage.loadProgress('book'))!.updatedAt, 500);
      expect(dav.mutations, isEmpty); expect(dav.attempts, isEmpty);
    });
  }

  test('preview target identity rejects changed settings before the first remote operation', () async {
    final (storage, annotations) = await configure();
    final expected = await storage.loadSettings();
    await storage.saveSettings({SyncEngine.cfgServer: 'https://other.synthetic.invalid/dav'});
    final before = await _preferences(), dav = _MemoryDav();
    final report = await _Engine(storage, annotations, dav).sync(
      mode: 'both', dryRun: true, expectedSettings: expected);
    expect(report.ok, isFalse); expect(report.error, isNotEmpty);
    expect(dav.reads, isEmpty); expect(dav.mutations, isEmpty); expect(dav.attempts, isEmpty);
    expect(await _preferences(), before);
  });

  for (final legacyIsLocal in [false, true]) {
    test('schema 1 unknown percent keeps its unit unknown when upgrading the chosen progress (local=$legacyIsLocal)', () {
      final legacy = {..._record('content', progressAt: 500, chapter: 8), 'schema': 1,
        'progress': {'chapter_idx': 8, 'char_offset': 42, 'percent': .5}};
      final known = _record('content', progressAt: 100, chapter: 2);
      final merged = SyncEngine.mergeRecord(legacyIsLocal ? legacy : known,
        legacyIsLocal ? known : legacy, 'device');
      expect(merged['schema'], 2); expect(merged['progress_at'], 500);
      final progress = merged['progress'] as Map;
      expect(progress['chapter_idx'], 8); expect(progress['char_offset'], 42);
      expect(progress['percent'], .5);
      expect(progress['percent_unit'], 'unknown',
        reason: 'Changing record schema must not reinterpret an unmarked legacy value as a known percentage');
    });
  }
}
