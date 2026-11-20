import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:duoduo_langdu/models/annotation.dart';
import 'package:duoduo_langdu/models/book.dart';
import 'package:duoduo_langdu/models/progress.dart';
import 'package:duoduo_langdu/services/annotation_store.dart';
import 'package:duoduo_langdu/services/app_storage.dart';
import 'package:duoduo_langdu/services/book_parser.dart';
import 'package:duoduo_langdu/services/sync_engine.dart';
import 'package:duoduo_langdu/services/webdav_client.dart';

class _MemoryDav extends WebDavClient {
  _MemoryDav() : super(server: 'https://synthetic.invalid/dav');

  final files = <String, List<int>>{};
  final bookPuts = <String>[];
  List<WebDavEntry>? bookEntries;
  Future<void> Function()? beforeBookList;

  void record(String key, Map<String, dynamic> value) {
    files['v1/books/$key.json'] = utf8.encode(jsonEncode(value));
  }

  Map<String, dynamic> read(String key) =>
      jsonDecode(utf8.decode(files['v1/books/$key.json']!)) as Map<String, dynamic>;

  @override
  Future<void> mkdirs(String rel) async {}

  @override
  Future<List<WebDavEntry>> propfind([String rel = '', String depth = '1']) async {
    if (rel == 'v1/books') {
      await beforeBookList?.call();
      if (bookEntries != null) return bookEntries!;
    }
    return [for (final path in files.keys)
      if (path.startsWith('$rel/') && !path.substring(rel.length + 1).contains('/'))
        WebDavEntry(name: path.split('/').last, rel: path, isDir: false)];
  }

  @override
  Future<List<int>?> get(String rel) async => files[rel];

  @override
  Future<bool> put(String rel, List<int> data, {bool atomic = true,
      String contentType = 'application/json; charset=utf-8'}) async {
    files[rel] = List<int>.from(data);
    if (rel.startsWith('v1/books/')) bookPuts.add(rel);
    return true;
  }

  @override
  Future<bool> delete(String rel) async { files.remove(rel); return true; }
}

class _Engine extends SyncEngine {
  final _MemoryDav dav;
  _Engine(AppStorage storage, AnnotationStore annotations, this.dav, {String? sourceDirOverride})
      : super(storage: storage, annotations: annotations, sourceDirOverride: sourceDirOverride);

  @override
  WebDavClient client(Map<String, dynamic> s) => dav;
}

BookMeta _meta(String id, {String key = 'content', String path = ''}) => BookMeta(
  id: id, title: 'Synthetic book', filePath: path, format: 'txt',
  addedAt: DateTime(2026), contentKey: key);

Map<String, dynamic> _record(String key, {double progressAt = 100,
    double bookmarkAt = 0, List<Map<String, dynamic>> bookmarks = const [],
    Map<String, double> deletions = const {}, double percent = 25}) => {
  'schema': 2, 'content_key': key, 'title': 'Synthetic book',
  'progress': {'chapter_idx': 2, 'char_offset': 42, 'percent': percent},
  'progress_at': progressAt, 'bookmarks': bookmarks,
  'bookmarks_at': bookmarkAt, 'bookmark_deletions': deletions,
  'metadata_at': 0,
  'updated_at': progressAt > bookmarkAt ? progressAt : bookmarkAt,
};

Map<String, dynamic> _bm(String id, double version) => {
  'id': id, 'created_at': version, 'chapter_idx': 0, 'offset': 1,
  'offset_end': 2, 'text': id,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppStorage> configured() async {
    final storage = AppStorage();
    await storage.saveSettings({SyncEngine.cfgServer: 'https://synthetic.invalid/dav'});
    return storage;
  }

  for (final localNewer in [false, true]) {
    test('sync unions distinct older IDs before upload (local newer: $localNewer)', () async {
      final storage = await configured();
      final annotations = AnnotationStore();
      await storage.saveBooks([_meta('book')]);
      await storage.saveProgress(BookProgress(bookId: 'book', chapterIndex: 7,
        percent: .75, updatedAt: localNewer ? 300 : 100));
      await annotations.saveRawBookmarks('book', [_bm('local', localNewer ? 400 : 50)]);
      final dav = _MemoryDav()..record('content', _record('content', progressAt: 200,
        bookmarkAt: localNewer ? 50 : 400, bookmarks: [_bm('remote', localNewer ? 50 : 400)]));
      final engine = _Engine(storage, annotations, dav);
      final report = await engine.sync();
      expect(report.ok, isTrue, reason: report.error);
      expect((dav.read('content')['bookmarks'] as List).map((bm) => bm['id']),
        containsAll(['local', 'remote']));
      expect(dav.read('content')['progress_at'], localNewer ? 300 : 200);
      expect((await storage.loadProgress('book'))!.chapterIndex, localNewer ? 7 : 2);
      final pushed = dav.bookPuts.length;
      expect((await engine.sync()).ok, isTrue);
      expect(dav.bookPuts.length, pushed, reason: 'A settled union must not keep creating edits.');
    });
  }

  test('bookmark deletion-only wire roundtrip blocks stale raw and typed resurrection', () async {
    final sender = AppStorage();
    final annotations = AnnotationStore();
    await sender.saveBooks([_meta('sender')]);
    await annotations.saveRawBookmarks('sender', [_bm('gone', 100)]);
    await annotations.deleteBookmark('sender', 'gone');
    final record = (await SyncEngine(storage: sender, annotations: annotations)
        .localRecords({}, 'sender'))['content']!.value;
    final deleted = (record['bookmark_deletions'] as Map)['gone'] as double;
    expect(record['bookmarks'], isEmpty);
    expect(record['bookmarks_at'], deleted);
    expect(record['updated_at'], deleted);
    expect(record['progress_at'], 0);

    SharedPreferences.setMockInitialValues({});
    final receiver = AppStorage();
    final received = AnnotationStore();
    await receiver.saveBooks([_meta('receiver')]);
    final engine = SyncEngine(storage: receiver, annotations: received);
    expect(await engine.applyRemote('receiver', record), isTrue);
    await received.saveRawBookmarks('receiver', [_bm('gone', 100)]);
    await received.saveBookmarks('receiver', [Bookmark.fromJson(_bm('gone', 100))]);
    expect(await received.loadBookmarks('receiver'), isEmpty);
    expect((await received.loadBookmarkDeletions('receiver'))['gone'], deleted);
    final before = await received.loadBookmarksAt('receiver');
    expect(await engine.applyRemote('receiver', record), isFalse);
    expect(await received.loadBookmarksAt('receiver'), before);
    await received.saveRawBookmarks('receiver', [
      {..._bm('gone', 100), 'modified_at': deleted + 1, 'text': 'explicitly recreated'},
    ]);
    expect((await received.loadRawBookmarks('receiver')).single['text'], 'explicitly recreated');
  });

  test('stale typed and raw snapshots preserve unseen bookmarks; deletion must be explicit', () async {
    final store = AnnotationStore();
    final first = Bookmark.fromJson(_bm('first', 100));
    final second = Bookmark.fromJson(_bm('second', 200));
    await store.saveBookmarks('book', [first, second]);
    await store.saveBookmarks('book', [second]);
    await store.saveRawBookmarks('book', [_bm('third', 50)]);
    expect((await store.loadBookmarks('book')).map((bm) => bm.id), ['third', 'first', 'second']);
    expect(await store.loadBookmarkDeletions('book'), isEmpty);
    await store.deleteBookmark('book', 'first');
    expect((await store.loadBookmarks('book')).map((bm) => bm.id), ['third', 'second']);
    expect((await store.loadBookmarkDeletions('book')).keys, ['first']);
    await store.saveRawBookmarks('book', []);
    expect((await store.loadBookmarks('book')).length, 2);
  });

  test('remote empty bookmarks plus deletion clock removes local bookmark without advancing progress', () async {
    final storage = AppStorage();
    final annotations = AnnotationStore();
    await storage.saveBooks([_meta('book')]);
    await storage.saveProgress(BookProgress(bookId: 'book', updatedAt: 150));
    await annotations.saveRawBookmarks('book', [_bm('gone', 100)]);
    final prefs = await SharedPreferences.getInstance();
    final events = <BookStorageChange>[];
    final subscription = AppStorage.bookChanges.listen((event) {
      if (event.kind == BookStorageChangeKind.annotations) {
        events.add(event);
        expect(jsonDecode(prefs.getString('duoduo.bookmarks.book')!), isEmpty);
        expect(jsonDecode(prefs.getString('duoduo.bookmarkDeletions.book')!)['gone'], 200);
      }
    });
    addTearDown(subscription.cancel);
    final engine = SyncEngine(storage: storage, annotations: annotations);
    await engine.applyRemote('book', _record('content', progressAt: 100,
      bookmarkAt: 200, deletions: {'gone': 200}));
    expect(await annotations.loadBookmarks('book'), isEmpty);
    expect((await storage.loadProgress('book'))!.updatedAt, 150);
    expect(events.single.remote, isTrue);
    expect((await engine.localRecords({}, 'device'))['content']!.value['bookmarks_at'], 200);
  });

  test('duplicate identities retain true progress, bookmarks, highlights, sources and references', () async {
    final directory = await Directory.systemTemp.createTemp('sync-storage-');
    addTearDown(() => directory.delete(recursive: true));
    final fileA = File('${directory.path}${Platform.pathSeparator}a.txt')..writeAsStringSync('first source');
    final fileB = File('${directory.path}${Platform.pathSeparator}b.txt')..writeAsStringSync('second source');
    final storage = AppStorage();
    final annotations = AnnotationStore();
    await storage.saveBooks([_meta('a', path: fileA.path), _meta('b', path: fileB.path)]);
    await storage.saveProgress(BookProgress(bookId: 'a', chapterIndex: 8, updatedAt: 400));
    await storage.saveProgress(BookProgress(bookId: 'b', chapterIndex: 1, updatedAt: 300));
    await annotations.saveRawBookmarks('a', [_bm('a-mark', 100)], deletions: {'gone': 250});
    await annotations.saveRawBookmarks('b', [_bm('b-mark', 200), _bm('gone', 200)]);
    Highlight highlight(String book, String note, {String id = 'highlight'}) => Highlight(id: id, bookId: book,
      chapterIndex: 0, paragraphIndex: 0, charStart: 0, charEnd: 1,
      color: 1, note: note, createdAt: DateTime(2026));
    await annotations.saveHighlights('a', [highlight('a', 'first note'),
      highlight('a', 'existing suffixed note', id: 'highlight@b')]);
    await annotations.saveHighlights('b', [highlight('b', 'second note')]);
    await storage.touchOpened('a');
    await storage.touchOpened('b');
    await storage.saveLastBookId('b');
    await storage.consolidateBooks();

    final book = (await storage.loadBooks()).single;
    expect(book.id, 'a');
    expect(book.aliases, contains('b'));
    expect(book.sourcePaths, containsAll([fileA.path, fileB.path]));
    expect(fileA.readAsStringSync(), 'first source');
    expect(fileB.readAsStringSync(), 'second source');
    expect((await storage.loadProgress('b'))!.chapterIndex, 8);
    expect((await annotations.loadBookmarks('b')).map((bm) => bm.id), ['a-mark', 'b-mark']);
    expect((await annotations.loadHighlights('b')).map((h) => h.note),
      containsAll(['first note', 'second note', 'existing suffixed note']));
    expect(await storage.loadLastBookId(), 'a');
    expect(await storage.loadOpenOrder(), ['a']);
    await storage.addBook(_meta('c', path: fileB.path));
    expect((await storage.loadBooks()).single.id, 'a');
    expect(await storage.resolveBookId('c'), 'a');
    expect(await storage.trySaveProgress(BookProgress(bookId: 'c', updatedAt: 350)), isFalse);
    await storage.consolidateBooks();
    expect((await annotations.loadHighlights('a')).length, 3);
  });

  test('duplicate consolidation publishes changed alias progress only after the shelf and references commit', () async {
    final storage = AppStorage();
    await storage.saveBooks([_meta('a'), _meta('b')]);
    await storage.saveProgress(BookProgress(bookId: 'a', chapterIndex: 1, updatedAt: 100));
    await storage.saveProgress(BookProgress(bookId: 'b', chapterIndex: 2, updatedAt: 200));
    await AnnotationStore().saveRawBookmarks('b', [_bm('merged-bookmark', 100)]);
    await storage.saveLastBookId('b');
    await storage.touchOpened('b');
    final prefs = await SharedPreferences.getInstance();
    final events = <BookStorageChange>[];
    final subscription = AppStorage.bookChanges.listen((event) {
      events.add(event);
      expect((jsonDecode(prefs.getString('duoduo.books.v1')!) as List).single['id'], 'a');
      expect(prefs.getString('duoduo.lastBookId'), 'a');
      expect(prefs.getStringList('duoduo.openOrder.v1'), ['a']);
      expect(jsonDecode(prefs.getString('duoduo.progress.a')!)['updatedAt'], 200);
    });
    addTearDown(subscription.cancel);
    await storage.consolidateBooks();
    final progress = events.where((event) => event.kind == BookStorageChangeKind.progress).single;
    expect(progress.bookId, 'a');
    expect(progress.remote, isTrue);
    expect(progress.progress!.chapterIndex, 2);
    expect(progress.progress!.updatedAt, 200);
    final annotations = events.where((event) => event.kind == BookStorageChangeKind.annotations).toList();
    expect(annotations.map((event) => event.bookId).toSet(), {'a', 'b'});
    expect(annotations.every((event) => event.remote), isTrue);
    final count = events.length;
    await storage.consolidateBooks();
    expect(events.length, count);
    expect((await storage.loadProgress('b'))!.updatedAt, 200);
  });

  test('deletion covers duplicate aliases even when canonical remote tombstone already exists', () async {
    final storage = await configured();
    await storage.saveBooks([_meta('a'), _meta('b')]);
    await storage.consolidateBooks();
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    await storage.removeBook('b', deletedAt: now);
    final dav = _MemoryDav()
      ..record('content', SyncEngine.tombstoneRecord('content', {'deleted_at': now}, 'remote'))
      ..record('a', _record('a'))
      ..record('b', _record('b'));
    final report = await _Engine(storage, AnnotationStore(), dav).sync();
    expect(report.ok, isTrue, reason: report.error);
    expect(dav.read('a')['deleted'], isTrue);
    expect(dav.read('b')['deleted'], isTrue);
    expect(await storage.trySaveProgress(BookProgress(bookId: 'b', updatedAt: now + 100)), isFalse);
  });

  for (final tombstoneFirst in [false, true]) {
    test('newer live alias survives an older tombstone (tombstone first: $tombstoneFirst)', () async {
      final storage = await configured();
      await storage.saveBooks([_meta('a'), _meta('b')]);
      await storage.consolidateBooks();
      final dav = _MemoryDav();
      void tombstone() => dav.record('content',
        SyncEngine.tombstoneRecord('content', {'deleted_at': 150}, 'remote'));
      void live() => dav.record('b', _record('b', progressAt: 200));
      if (tombstoneFirst) { tombstone(); live(); } else { live(); tombstone(); }
      final report = await _Engine(storage, AnnotationStore(), dav).sync();
      expect(report.ok, isTrue, reason: report.error);
      expect((await storage.loadBooks()).single.id, 'a');
      expect((await storage.loadProgress('a'))!.updatedAt, 200);
      expect(dav.read('content')['deleted'], isNot(true));
      expect(dav.read('content')['progress_at'], 200);
    });
  }

  test('user reimport exports a stable activity clock against a retained remote tombstone', () async {
    final storage = await configured();
    final tomb = DateTime.now().millisecondsSinceEpoch / 1000.0 - 100;
    await storage.markDeleted('content', 'Synthetic book', deletedAt: tomb);
    await storage.addBook(_meta('reimport'));
    final activity = (await storage.loadBooks()).single.activityAt;
    expect(activity, greaterThan(tomb));
    final dav = _MemoryDav();
    final engine = _Engine(storage, AnnotationStore(), dav);
    for (var i = 0; i < 2; i++) {
      dav.record('content', SyncEngine.tombstoneRecord('content', {'deleted_at': tomb}, 'old client'));
      final report = await engine.sync();
      expect(report.ok, isTrue, reason: report.error);
      expect(dav.read('content')['deleted'], isNot(true));
      expect(dav.read('content')['metadata_at'], closeTo(activity, .001));
      expect(dav.read('content')['updated_at'], closeTo(activity, .001));
      expect(dav.read('content')['progress_at'], 0);
    }
    expect((await storage.loadBooks()).single.activityAt, activity);
  });

  test('automatic remote import keeps real versions and never creates a local user event', () async {
    final storage = AppStorage();
    final annotations = AnnotationStore();
    await storage.addBook(_meta('automatic'), remote: true, activityAt: 40, remoteVersion: 100);
    final engine = SyncEngine(storage: storage, annotations: annotations);
    await engine.applyRemote('automatic', {..._record('content'), 'metadata_at': 40});
    final exported = (await engine.localRecords({}, 'device'))['content']!.value;
    expect(exported['metadata_at'], 40);
    expect(exported['progress_at'], 100);
    expect(exported['updated_at'], 100);
    await storage.removeBook('automatic', deletedAt: 200, remote: true);
    await storage.addBook(_meta('stale-import'), remote: true, remoteVersion: 100);
    expect(await storage.loadBooks(), isEmpty);
    await storage.addBook(_meta('new-remote'), remote: true, remoteVersion: 300);
    expect((await storage.loadBooks()).single.activityAt, 0);
  });

  test('synthetic source pull does not revive against a later remote delete or delete local sources', () async {
    final directory = await Directory.systemTemp.createTemp('sync-source-');
    addTearDown(() => directory.delete(recursive: true));
    const text = '第一章 开始\n甲乙丙丁。\n\n第二章 后续\n子丑寅卯。\n';
    final original = File('${directory.path}${Platform.pathSeparator}original.txt')..writeAsStringSync(text);
    final parsed = await BookParser().parse(id: 'probe', filePath: original.path,
      title: 'Synthetic book', format: BookFormat.txt, addedAt: DateTime(2026));
    expect(parsed.parseOk, isTrue);
    final key = parsed.contentKey;
    final storage = await configured();
    final dav = _MemoryDav()..record(key, {..._record(key),
      'source': {'ext': '.txt', 'size': original.lengthSync(), 'name': 'original.txt'}});
    dav.files['v1/sources/$key.txt'] = original.readAsBytesSync();
    final engine = _Engine(storage, AnnotationStore(), dav,
      sourceDirOverride: '${directory.path}${Platform.pathSeparator}received');
    final pulled = await engine.sync();
    expect(pulled.ok, isTrue, reason: pulled.error);
    expect(pulled.imported, 1);
    final meta = (await storage.loadBooks()).single;
    expect(meta.activityAt, 0);
    final exported = (await engine.localRecords({}, 'device'))[key]!.value;
    expect(exported['updated_at'], 100);
    expect(exported['progress_at'], 100);
    dav.record(key, SyncEngine.tombstoneRecord(key, {'deleted_at': 200}, 'remote'));
    final deleted = await engine.sync();
    expect(deleted.ok, isTrue, reason: deleted.error);
    expect(await storage.loadBooks(), isEmpty);
    expect(original.readAsStringSync(), text);
    expect(File(meta.filePath).readAsStringSync(), text);
  });

  test('device and completion patches preserve edits made after captured settings', () async {
    final storage = await configured();
    final engine = _Engine(storage, AnnotationStore(), _MemoryDav());
    await storage.saveSettings({'fontSize': 20, 'voice': 'old'});
    final stale = await engine.settings();
    await AppStorage().saveSettings({'fontSize': 31, 'voice': 'new'});
    final devices = await Future.wait([engine.ensureDevice(stale),
      _Engine(AppStorage(), AnnotationStore(), _MemoryDav()).ensureDevice(stale)]);
    expect(devices.first.$1, devices.last.$1);
    final dav = _MemoryDav();
    dav.beforeBookList = () => AppStorage().saveSettings({'fontSize': 37, 'themeMode': 'dark'});
    final report = await _Engine(storage, AnnotationStore(), dav).sync();
    expect(report.ok, isTrue, reason: report.error);
    final current = await storage.loadSettings();
    expect(current['fontSize'], 37);
    expect(current['voice'], 'new');
    expect(current['themeMode'], 'dark');
    expect(current[SyncEngine.cfgDeviceId], isNotEmpty);
    expect(current[SyncEngine.cfgLastTime], greaterThan(0));
    await Future.wait([AppStorage().saveSettings({'fontSize': 42}),
      AppStorage().saveSettings({SyncEngine.cfgAuto: false})]);
    expect((await storage.loadSettings())['fontSize'], 42);
    expect((await storage.loadSettings())[SyncEngine.cfgAuto], isFalse);
  });

  test('canonical wire char offset wins over Android coordinates while local viewport fields survive', () async {
    final storage = AppStorage();
    await storage.saveBooks([_meta('book')]);
    final local = BookProgress(bookId: 'book', chapterIndex: 1, paragraphIndex: 8,
      chapterAnchor: 800, viewportItem: 9, layoutSignature: 'local', updatedAt: 100);
    await storage.saveProgress(local);
    expect((await storage.loadProgress('book'))!.viewportItem, 9);
    final engine = SyncEngine(storage: storage, annotations: AnnotationStore());
    await engine.applyRemote('book', {..._record('content', progressAt: 200),
      'progress': {'chapter_idx': 2, 'char_offset': 123, 'paragraph_index': 99,
        'offset_in_paragraph': 77, 'chapterAnchor': 9999, 'percent': .5}});
    final received = (await storage.loadProgress('book'))!;
    expect(received.charOffsetInChapter, 123);
    expect(received.pcCharOffset, 123);
    expect(received.chapterAnchor, isNull);
    expect(received.layoutSignature, isEmpty);
    final legacy = BookProgress.fromPcJson('book', {
      'chapter_idx': 2, 'paragraph_index': 3, 'offset_in_paragraph': 7,
    });
    expect(legacy.charOffsetInChapter, isNull);
    expect(legacy.paragraphIndex, 3);
    expect(BookProgress.fromPcJson('book', legacy.toPcJson()).charOffsetInChapter, isNull);
    final oldRemote = BookProgress.fromJson({'bookId': 'book', 'paragraphIndex': 99,
      'pcCharOffset': 123, 'updatedAt': 10});
    expect(oldRemote.charOffsetInChapter, 123);
    final localViewport = BookProgress.fromJson({...local.toJson(), 'pcCharOffset': 123});
    expect(localViewport.charOffsetInChapter, isNull);
    expect(localViewport.chapterAnchor, 800);
    expect(localViewport.viewportItem, 9);
  });

  test('encoded DAV roots, hrefs and relative hrefs stay in one encoding domain', () {
    final client = WebDavClient(server: 'https://synthetic.invalid/server%20sub/%E4%B9%A6',
      remoteDir: '中文 space/100%');
    final root = client.urlOf('');
    final request = '${client.urlOf('v1/books')}/';
    final path = 'v1/books/书 %25.json';
    final url = client.urlOf(path);
    final xml = '<D:multistatus xmlns:D="DAV:">'
      '<D:response><D:href>$request</D:href><D:collection/></D:response>'
      '<D:response><D:href>${Uri.parse(url).path}</D:href></D:response>'
      '</D:multistatus>';
    final entries = WebDavClient.parsePropfind(xml, root, requestUrl: request);
    expect(entries.last.rel, path);
    expect(client.urlOf(entries.last.rel), url);
    final relative = WebDavClient.parsePropfind(
      '<response><href>${Uri.encodeComponent('书 %25.json')}</href></response>', root, requestUrl: request);
    expect(relative.single.rel, path);
    expect(() => WebDavClient.parsePropfind('<response><href>/unrelated/file.json</href></response>', root),
      throwsA(isA<WebDavException>()));
  });

  test('unread listed remote record stops replacement uploads instead of silently overwriting it', () async {
    final storage = await configured();
    await storage.saveBooks([_meta('book')]);
    final dav = _MemoryDav()..bookEntries = [
      const WebDavEntry(name: 'content.json', rel: 'duplicated/root/content.json', isDir: false),
    ];
    final report = await _Engine(storage, AnnotationStore(), dav).sync();
    expect(report.ok, isFalse);
    expect(dav.bookPuts, isEmpty);
    dav.bookEntries = null;
    expect((await _Engine(storage, AnnotationStore(), dav).sync()).ok, isTrue);
  });

  test('engine instances and connection entrypoints share a guard that releases on exceptions', () async {
    final storage = await configured();
    final annotations = AnnotationStore();
    final entered = Completer<void>();
    final release = Completer<void>();
    final dav = _MemoryDav()..beforeBookList = () async {
      entered.complete();
      await release.future;
      throw WebDavException('synthetic failure');
    };
    final first = _Engine(storage, annotations, dav).sync();
    await entered.future;
    final otherDav = _MemoryDav();
    final second = _Engine(AppStorage(), AnnotationStore(), otherDav);
    expect((await second.sync()).ok, isFalse);
    expect((await second.testConnection()).$1, isFalse);
    expect(otherDav.files, isEmpty);
    release.complete();
    expect((await first).ok, isFalse);
    expect((await second.sync()).ok, isTrue);
  });

  test('config changes during sync do not apply old records or stamp the new target as synced', () async {
    final storage = await configured();
    await storage.saveBooks([_meta('book')]);
    final dav = _MemoryDav()..record('content', _record('content'));
    dav.beforeBookList = () => storage.saveSettings({SyncEngine.cfgServer: 'https://other.synthetic.invalid'});
    final report = await _Engine(storage, AnnotationStore(), dav).sync();
    expect(report.ok, isFalse);
    expect(await storage.loadProgress('book'), isNull);
    expect((await storage.loadSettings())[SyncEngine.cfgLastTime], isNull);
    expect(dav.bookPuts, isEmpty);
  });

  test('persisted and wire missing clocks stay unknown through bootstrap and lose to real remote progress', () async {
    SharedPreferences.setMockInitialValues({
      'duoduo.progress.book': jsonEncode({'bookId': 'book', 'chapterIndex': 9, 'percent': .9}),
    });
    final storage = AppStorage();
    await storage.saveBooks([_meta('book')]);
    expect((await storage.loadProgress('book'))!.updatedAt, 0);
    expect(BookProgress.fromPcJson('book', {'chapter_idx': 9}).updatedAt, 0);
    final engine = SyncEngine(storage: storage, annotations: AnnotationStore());
    expect((await engine.localRecords({}, 'device'))['content']!.value['progress_at'], 0);
    expect((await storage.loadBooks()).single.activityAt, 0);
    await engine.applyRemote('book', _record('content', progressAt: 100));
    expect((await storage.loadProgress('book'))!.updatedAt, 100);
    expect((await storage.loadProgress('book'))!.chapterIndex, 2);
  });

  test('schema2 sub-one-percent and explicit legacy ratios roundtrip without magnitude guessing', () async {
    final storage = AppStorage();
    await storage.saveBooks([_meta('book')]);
    final engine = SyncEngine(storage: storage, annotations: AnnotationStore());
    await engine.applyRemote('book', _record('content', percent: .5));
    expect((await storage.loadProgress('book'))!.percent, .005);
    final first = (await engine.localRecords({}, 'device'))['content']!.value;
    expect((first['progress'] as Map)['percent'], .5);
    expect((first['progress'] as Map)['percent_unit'], 'percent');
    await engine.applyRemote('book', {..._record('content', progressAt: 200),
      'schema': 1, 'progress': {'chapter_idx': 1, 'char_offset': 2,
        'percent': .005, 'percent_unit': 'ratio'}});
    expect((await storage.loadProgress('book'))!.percent, .005);
    expect((await storage.loadProgress('book'))!.ambiguousPercent, isNull);
  });

  test('ambiguous legacy percent preserves original value, canonical position and real clock', () async {
    final storage = await configured();
    await storage.saveBooks([_meta('book')]);
    await storage.saveProgress(BookProgress(bookId: 'book', percent: .3, updatedAt: 50));
    final dav = _MemoryDav()..record('content', {..._record('content'), 'schema': 1});
    final engine = _Engine(storage, AnnotationStore(), dav);
    final report = await engine.sync();
    expect(report.ok, isTrue, reason: report.error);
    expect(report.summary, contains('百分比单位未知'));
    final p = (await storage.loadProgress('book'))!;
    expect(p.percent, .3);
    expect(p.ambiguousPercent, 25);
    expect(p.charOffsetInChapter, 42);
    expect(p.updatedAt, 100);
    final exported = (await engine.localRecords({}, 'device'))['content']!.value;
    expect((exported['progress'] as Map)['percent'], 25);
    expect((exported['progress'] as Map)['percent_unit'], 'unknown');
    expect(exported['progress_at'], 100);
  });

  test('serialized progress rejects stale versions and emits remote events only after persistence', () async {
    final storage = AppStorage();
    await storage.saveBooks([_meta('book')]);
    final prefs = await SharedPreferences.getInstance();
    final changes = <BookStorageChange>[];
    final subscription = AppStorage.bookChanges.listen((change) {
      changes.add(change);
      if (change.kind == BookStorageChangeKind.progress) {
        expect(jsonDecode(prefs.getString('duoduo.progress.book')!)['updatedAt'], change.progress!.updatedAt);
      }
      if (change.kind == BookStorageChangeKind.removed) {
        expect(jsonDecode(prefs.getString('duoduo.books.v1')!), isEmpty);
        expect(prefs.getString('duoduo.progress.book'), isNull);
      }
    });
    addTearDown(subscription.cancel);
    final accepted = await Future.wait([
      storage.trySaveProgress(BookProgress(bookId: 'book', updatedAt: 30), remote: true),
      AppStorage().trySaveProgress(BookProgress(bookId: 'book', updatedAt: 20)),
    ]);
    expect(accepted, [true, false]);
    expect(changes.single.remote, isTrue);
    await storage.removeBook('book', deletedAt: 40, remote: true);
    expect(changes.last.kind, BookStorageChangeKind.removed);
    expect(changes.last.remote, isTrue);
    expect(await storage.trySaveProgress(BookProgress(bookId: 'book', updatedAt: 100)), isFalse);
    expect(await storage.loadProgress('book'), isNull);
    await AnnotationStore().saveRawBookmarks('book', [_bm('late', 200)]);
    expect(changes.where((change) => change.kind == BookStorageChangeKind.annotations), isEmpty);
  });
}
