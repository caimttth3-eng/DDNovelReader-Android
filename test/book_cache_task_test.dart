import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/models/book.dart';
import 'package:duoduo_langdu/models/speech_word.dart';
import 'package:duoduo_langdu/services/book_cache_task.dart';
import 'package:duoduo_langdu/services/edge_tts.dart';
import 'package:duoduo_langdu/services/reading_text.dart';
import 'package:duoduo_langdu/services/tts_cache_store.dart';

class _Store extends TtsCacheStore {
  final audio = <(int, int), Uint8List>{};
  final progress = <CacheProgress>[];
  final writeStarted = Completer<void>();
  Completer<void>? writeGate;
  Completer<void>? saveGate;
  bool failWrites = false;
  bool failScans = false;
  Completer<void>? scanGate;
  Completer<void>? scanStarted;
  _Store() : super('task-book', 'voice', 1);

  @override Future<bool> exists(int ci, int off) async => audio[(ci, off)]?.isNotEmpty ?? false;
  @override Future<CacheProgress?> loadProgress() async => progress.isEmpty ? null : progress.last;
  @override Future<Set<String>> listMp3Names() async {
    if (scanStarted != null && !scanStarted!.isCompleted) scanStarted!.complete();
    await scanGate?.future;
    if (failScans) throw const FileSystemException('Scan denied');
    return {for (final entry in audio.entries)
      if (entry.value.isNotEmpty) TtsCacheStore.fileName(entry.key.$1, entry.key.$2)};
  }
  @override Future<void> write(int ci, int off, Uint8List bytes, {List<SpeechWord>? words}) async {
    if (!writeStarted.isCompleted) writeStarted.complete();
    await writeGate?.future;
    if (failWrites) throw const FileSystemException('simulated disk full');
    audio[(ci, off)] = bytes;
  }
  @override Future<void> saveProgress({required int total, required int done,
    required Set<int> completed, required String state, int? fromChapter, int? fromOffset}) async {
    await saveGate?.future;
    progress.add((total: total, done: done, completed: Set.of(completed), state: state,
      fromChapter: fromChapter, fromOffset: fromOffset));
  }
  @override Future<int> clear() async { final count = audio.length; audio.clear(); progress.clear(); return count; }
}

class _Synthesis {
  final requests = <({EdgeSynthCancelToken token, Completer<Uint8List> gate})>[];
  int live = 0;
  int peak = 0;
  Future<Uint8List> call(String text, {required String voice, required String rate,
    required void Function(List<SpeechWord>) onWords, required EdgeSynthCancelToken cancelToken}) async {
    final gate = Completer<Uint8List>();
    requests.add((token: cancelToken, gate: gate));
    live++;
    if (live > peak) peak = live;
    try { return await gate.future; } finally { live--; }
  }

  void settle() {
    for (final request in requests.toList()) {
      if (!request.gate.isCompleted) request.gate.complete(Uint8List.fromList([1]));
    }
  }
}

class _BrokenLoadStore extends _Store {
  @override Future<CacheProgress?> loadProgress() async => throw StateError('Unable to load progress');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Book book(int sentences) => Book(id: 'task-book', title: 'task', filePath: '',
    format: BookFormat.txt, addedAt: DateTime(2026), chapters: [
      Chapter(title: 'chapter', paragraphs: [ReadingText.paragraph(
        List.generate(sentences, (i) => '第$i句。').join())]),
    ]);
  Future<void> flush() async {
    for (var i = 0; i < 12; i++) { await Future<void>.delayed(Duration.zero); }
  }
  Future<void> waitFor(bool Function() ready) async {
    for (var i = 0; i < 200 && !ready(); i++) { await flush(); }
    expect(ready(), isTrue);
  }

  test('cancel drains in-flight synthesis before clear and rejects late audio', () async {
    final store = _Store(), synthesis = _Synthesis();
    final task = BookCacheTask(book: book(4), bookId: 'task-book', store: store, synthesize: synthesis.call);
    await task.start();
    await waitFor(() => synthesis.live == BookCacheTask.workerCount);
    var settled = false;
    final cancelled = task.cancel().then((_) { settled = true; });
    expect(synthesis.requests.every((r) => r.token.cancelled), isTrue);
    await flush();
    expect(settled, isFalse);
    synthesis.settle();
    await cancelled;
    await store.clear();
    await flush();
    expect(store.audio, isEmpty);
    expect(store.progress, isEmpty);
    expect(task.status.state, 'cancelled');
    expect(task.status.done, 0);
  });

  test('cancel drains pending audio and progress writes before cache clear', () async {
    final store = _Store()..writeGate = Completer<void>()..saveGate = Completer<void>();
    final task = BookCacheTask(book: book(1), bookId: 'task-book', store: store,
      synthesize: (text, {required voice, required rate, required onWords, required cancelToken}) async => Uint8List.fromList([1]));
    await task.start();
    await store.writeStarted.future;
    var settled = false;
    final cancelled = task.cancel().then((_) { settled = true; });
    await flush();
    expect(settled, isFalse);
    store.writeGate!.complete();
    await flush();
    expect(settled, isFalse, reason: 'Progress persistence is part of quiescence too.');
    store.saveGate!.complete();
    await cancelled;
    await store.clear();
    await flush();
    expect(store.audio, isEmpty);
    expect(store.progress, isEmpty);
  });

  test('rapid pause resume waits for old workers and retries their claimed indices', () async {
    final store = _Store(), synthesis = _Synthesis();
    final task = BookCacheTask(book: book(4), bookId: 'task-book', store: store, synthesize: synthesis.call);
    await task.start();
    await waitFor(() => synthesis.live == BookCacheTask.workerCount);
    final paused = task.pause();
    final resumed = task.resume();
    final pausedAgain = task.pause();
    final resumedAgain = task.resume();
    await flush();
    expect(synthesis.requests, hasLength(BookCacheTask.workerCount));
    synthesis.settle();
    await Future.wait([paused, resumed, pausedAgain, resumedAgain]);
    await waitFor(() => synthesis.requests.length == BookCacheTask.workerCount * 2);
    expect(synthesis.peak, BookCacheTask.workerCount);
    synthesis.settle();
    await waitFor(() => synthesis.requests.length == BookCacheTask.workerCount * 3);
    synthesis.settle();
    await waitFor(() => task.status.isDone);
    await task.pause();
    expect(task.status.done, 4);
    expect(store.audio, hasLength(4));
    expect(store.progress.last.completed, {0, 1, 2, 3});
    expect(synthesis.peak, BookCacheTask.workerCount);
  });

  test('pause preserves persisted completions and resume does not resynthesize them', () async {
    final store = _Store(), synthesis = _Synthesis();
    final task = BookCacheTask(book: book(3), bookId: 'task-book', store: store, synthesize: synthesis.call);
    await task.start();
    await waitFor(() => synthesis.requests.length == 2);
    synthesis.requests.first.gate.complete(Uint8List.fromList([1]));
    await waitFor(() => synthesis.requests.length == 3);
    final paused = task.pause();
    synthesis.settle();
    await paused;
    expect(task.status.done, 1);
    expect(store.progress.last.completed, {0});
    await task.resume();
    await waitFor(() => synthesis.requests.length == 5);
    synthesis.settle();
    await waitFor(() => task.status.isDone);
    await task.pause();
    expect(task.status.done, 3);
  });

  test('pause during launch preserves the requested starting offset for resume', () async {
    final store = _Store(), synthesis = _Synthesis();
    final source = book(4);
    final fromOffset = chapterSentenceOffsets(source.chapters.single)[2];
    final task = BookCacheTask(book: source, bookId: 'task-book', store: store, synthesize: synthesis.call);
    final starting = task.start(fromChapter: 0, fromOffset: fromOffset);
    final paused = task.pause();
    final resumed = task.resume();
    await Future.wait([starting, paused, resumed]);
    await waitFor(() => synthesis.requests.length == 2);
    expect(task.status.total, 2);
    expect(store.progress.single.fromOffset, fromOffset);
    expect(store.progress.single.state, 'paused');
    synthesis.settle();
    await waitFor(() => task.status.isDone);
    await task.pause();
    expect(task.status.done, 2);
    expect(synthesis.peak, BookCacheTask.workerCount);
  });

  test('failed persistence stays resumable and never counts as completed', () async {
    final store = _Store()..failWrites = true;
    final messages = <String>[];
    final previousPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) { if (message != null) messages.add(message); };
    addTearDown(() { debugPrint = previousPrint; });
    final task = BookCacheTask(book: book(1), bookId: 'task-book', store: store,
      synthesize: (text, {required voice, required rate, required onWords, required cancelToken}) async => Uint8List.fromList([1]));
    await task.start();
    await waitFor(() => task.status.isPaused);
    await task.pause();
    expect(task.status.done, 0);
    expect(task.lastFailure, isA<FileSystemException>());
    expect(store.progress.last.completed, isEmpty);
    expect(messages, contains(contains('persistence failed')));
    store.failWrites = false;
    await task.resume();
    await waitFor(() => task.status.isDone);
    await task.pause();
    expect(task.status.done, 1);
  });

  test('control failures are exposed unconditionally through lastFailure', () async {
    final task = BookCacheTask(book: book(1), bookId: 'task-book', store: _BrokenLoadStore());
    await expectLater(task.start(resume: true), throwsStateError);
    expect(task.lastFailure, isA<StateError>());
    expect(task.status.isPaused, isTrue);
  });

  test('rescan reconciles saved, unrecorded, missing and empty audio atomically', () async {
    final source = book(4), store = _Store();
    final offsets = chapterSentenceOffsets(source.chapters.single);
    store.audio[(0, offsets[0])] = Uint8List.fromList([1]);
    store.audio[(0, offsets[1])] = Uint8List.fromList([2]);
    store.audio[(0, offsets[3])] = Uint8List(0);
    store.progress.add((total: 4, done: 3, completed: {0, 2, 3}, state: 'done',
      fromChapter: null, fromOffset: null));
    final task = BookCacheTask(book: source, bookId: source.id, store: store);
    await task.restoreFromDisk();
    expect(task.status.done, 2); expect(task.status.state, 'paused');
    expect(store.progress.last.completed, {0, 1});
    await task.rescan();
    expect(task.status.done, 2); expect(store.progress.last.completed, {0, 1});
  });

  test('disk-only complete cache is restored as done and persisted', () async {
    final source = book(2), store = _Store();
    for (final offset in chapterSentenceOffsets(source.chapters.single)) {
      store.audio[(0, offset)] = Uint8List.fromList([1]);
    }
    final task = BookCacheTask(book: source, bookId: source.id, store: store);
    await task.restoreFromDisk();
    expect(task.status.isDone, isTrue); expect(task.status.done, 2);
    expect(store.progress.single.completed, {0, 1});
    expect(store.progress.single.state, 'done');
  });

  test('rescan preserves the persisted starting offset when task counts change', () async {
    final source = book(4), store = _Store();
    final offsets = chapterSentenceOffsets(source.chapters.single);
    store.audio[(0, offsets[0])] = Uint8List.fromList([1]);
    store.audio[(0, offsets[2])] = Uint8List.fromList([1]);
    store.progress.add((total: 99, done: 1, completed: {0}, state: 'paused',
      fromChapter: 0, fromOffset: offsets[2]));
    final task = BookCacheTask(book: source, bookId: source.id, store: store);
    await task.rescan();
    expect(task.status.total, 2); expect(task.status.done, 1);
    expect(store.progress.last.completed, {0});
    expect(store.progress.last.fromOffset, offsets[2]);
  });

  test('scan IO failure preserves previous completions and progress bytes', () async {
    final source = book(2), store = _Store();
    store.audio[(0, 0)] = Uint8List.fromList([1]);
    final task = BookCacheTask(book: source, bookId: source.id, store: store);
    await task.rescan();
    final previous = store.progress.toList();
    store.failScans = true;
    await expectLater(task.rescan(), throwsA(isA<FileSystemException>()));
    expect(task.status.done, 1); expect(task.status.total, 2);
    expect(task.status.isPaused, isTrue);
    expect(store.progress, previous); expect(task.lastFailure, isA<FileSystemException>());
  });

  test('cancel during rescan discards late scan results without losing old state', () async {
    final source = book(2), store = _Store();
    store.audio[(0, 0)] = Uint8List.fromList([1]);
    final task = BookCacheTask(book: source, bookId: source.id, store: store);
    await task.rescan();
    store.scanGate = Completer<void>(); store.scanStarted = Completer<void>();
    final scan = task.rescan();
    await store.scanStarted!.future;
    final cancel = task.cancel();
    store.audio[(0, chapterSentenceOffsets(source.chapters.single)[1])] = Uint8List.fromList([1]);
    store.scanGate!.complete();
    await Future.wait([scan, cancel]);
    expect(task.status.state, 'cancelled'); expect(task.status.done, 1);
    expect(store.progress.last.completed, {0});
  });

  test('rescan cancels and drains live producers before inspecting disk', () async {
    final source = book(2), store = _Store(), synthesis = _Synthesis();
    final task = BookCacheTask(book: source, bookId: source.id, store: store, synthesize: synthesis.call);
    await task.start(); await waitFor(() => synthesis.live == 2);
    final scan = task.rescan();
    expect(synthesis.requests.every((request) => request.token.cancelled), isTrue);
    expect(task.status.state, 'building');
    synthesis.settle(); await scan;
    expect(store.audio, isEmpty); expect(task.status.done, 0);
    expect(task.status.state, 'idle'); expect(synthesis.live, 0);
    await task.start(resume: true); await waitFor(() => synthesis.live == 2);
    synthesis.settle(); await waitFor(() => task.status.isDone);
    expect(synthesis.peak, 2); await task.pause();
  });

  test('rescan future waits for its corrected progress to persist', () async {
    final source = book(1), store = _Store()..saveGate = Completer<void>();
    store.audio[(0, 0)] = Uint8List.fromList([1]);
    final task = BookCacheTask(book: source, bookId: source.id, store: store);
    var returned = false;
    final scan = task.rescan().then((_) => returned = true);
    await flush(); expect(returned, isFalse); expect(store.progress, isEmpty);
    store.saveGate!.complete(); await scan;
    expect(store.progress.single.completed, {0});
  });

  test('successful synthesis retry does not retain a transient failure', () async {
    var attempts = 0;
    final task = BookCacheTask(book: book(1), bookId: 'task-book', store: _Store(),
      synthesize: (text, {required voice, required rate, required onWords, required cancelToken}) async {
        if (attempts++ == 0) throw const EdgeTtsException('connection');
        return Uint8List.fromList([1]);
      });
    final finished = Completer<void>();
    task.onProgress = (status) { if (status.isDone && !finished.isCompleted) finished.complete(); };
    await task.start();
    await finished.future.timeout(const Duration(seconds: 3));
    await task.pause();
    expect(attempts, 2);
    expect(task.lastFailure, isNull);
    expect(task.status.done, 1);
  });
}
