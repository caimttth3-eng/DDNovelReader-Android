import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/models/speech_word.dart';
import 'package:duoduo_langdu/services/tts_cache_store.dart';

class _UndeletableFile implements File {
  @override final String path;
  final FileSystemException failure;
  _UndeletableFile(this.path, this.failure);
  @override Future<File> delete({bool recursive = false}) async => throw failure;
  @override dynamic noSuchMethod(Invocation invocation) => throw StateError('$invocation');
}

class _ClearDirectory implements Directory {
  @override final String path;
  final FileSystemException? listingFailure;
  final FileSystemEntity? child;
  _ClearDirectory(this.path, {this.listingFailure, this.child});
  @override Future<bool> exists() async => true;
  @override Stream<FileSystemEntity> list({bool recursive = false, bool followLinks = true}) {
    if (listingFailure != null) return Stream.error(listingFailure!);
    return child == null ? const Stream.empty() : Stream.value(child!);
  }
  @override Future<Directory> delete({bool recursive = false}) async {
    if (listingFailure != null) throw listingFailure!;
    return this;
  }
  @override dynamic noSuchMethod(Invocation invocation) => throw StateError('$invocation');
}

class _ClearStore extends TtsCacheStore {
  _ClearStore() : super('synthetic-cache', 'voice', 1);
  @override Future<Directory> dir() async => Directory('synthetic-cache');
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('speech-cache-test-');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async => root.absolute.path);
  });
  tearDown(() async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    await root.delete(recursive: true);
  });

  for (final targetHasWords in [false, true]) {
    test('migration rejects differing audio and its sidecar together targetWords=$targetHasWords', () async {
      final sep = Platform.pathSeparator;
      final legacy = File([root.path, 'tts_cache', 'old', 'voice', '1.00', 'text-words2-test',
        TtsCacheStore.fileName(0, 0)].join(sep));
      final target = File([root.path, 'tts_cache', 'content', 'voice', '0', 'text-words2-test',
        TtsCacheStore.fileName(0, 0)].join(sep));
      await legacy.parent.create(recursive: true);
      await legacy.writeAsBytes([1]);
      await File('${legacy.path}.words.json').writeAsString('[{"text":"legacy"}]');
      await target.parent.create(recursive: true);
      await target.writeAsBytes([2]);
      if (targetHasWords) await File('${target.path}.words.json').writeAsString('[{"text":"target"}]');
      final store = TtsCacheStore('old', 'voice', 1, contentKey: 'content', textFingerprint: 'words2-test');
      await store.dir();
      expect(await store.read(0, 0), [2]);
      final targetWords = File('${target.path}.words.json');
      if (targetHasWords) {
        expect(await targetWords.readAsString(), '[{"text":"target"}]');
      } else {
        expect(await targetWords.exists(), isFalse, reason: 'Rejected source timings must not accompany retained target audio.');
      }
      final retained = File([root.path, 'tts_cache', 'content', 'voice', '1.00', 'text-words2-test',
        TtsCacheStore.fileName(0, 0)].join(sep));
      expect(await retained.readAsBytes(), [1]);
      expect(await File('${retained.path}.words.json').readAsString(), '[{"text":"legacy"}]');
    });
  }

  test('write exposes IO failure instead of reporting successful persistence', () async {
    final store = TtsCacheStore('write-failure', 'voice', 1);
    final directory = await store.dir();
    final blocked = Directory('${directory.path}${Platform.pathSeparator}${TtsCacheStore.fileName(0, 0)}');
    await blocked.create();
    await expectLater(store.write(0, 0, Uint8List.fromList([1])), throwsA(isA<FileSystemException>()));
    expect(await File('${blocked.path}.tmp').exists(), isFalse);
    expect(await store.exists(0, 0), isFalse);
  });

  test('scan lists only nonempty complete audio in the exact content and text partition', () async {
    final store = TtsCacheStore('id', 'voice', 1, contentKey: 'content-a', textFingerprint: 'text-a');
    final other = TtsCacheStore('id', 'voice', 1, contentKey: 'content-b', textFingerprint: 'text-a');
    final changedText = TtsCacheStore('id', 'voice', 1, contentKey: 'content-a', textFingerprint: 'text-b');
    await store.write(0, 0, Uint8List.fromList([1]));
    final dir = await store.dir();
    await File('${dir.path}/${TtsCacheStore.fileName(0, 1)}').writeAsBytes([]);
    await File('${dir.path}/pending.mp3.tmp').writeAsBytes([1]);
    expect(await store.listMp3Names(), {TtsCacheStore.fileName(0, 0)});
    expect(await other.listMp3Names(), isEmpty);
    expect(await changedText.listMp3Names(), isEmpty);
  });

  test('cache scan errors are visible instead of becoming an empty completed set', () async {
    const failure = FileSystemException('Scan access denied', 'synthetic-cache', OSError('Access denied', 5));
    await IOOverrides.runZoned(() async {
      await expectLater(_ClearStore().listMp3Names(), throwsA(same(failure)));
    }, createDirectory: (path) => _ClearDirectory(path, listingFailure: failure));
  });

  test('progress preserves text identity and rejects mismatched metadata', () async {
    final store = TtsCacheStore('id', 'voice', 1, contentKey: 'content', textFingerprint: 'current');
    await store.saveProgress(total: 1, done: 1, completed: {0}, state: 'done');
    expect((await store.loadProgress())!.done, 1);
    final path = '${(await store.dir()).path}/progress.json';
    final text = await File(path).readAsString();
    await File(path).writeAsString(text.replaceFirst('current', 'different'));
    expect(await store.loadProgress(), isNull);
  });

  test('rescan rediscovers a late known-ID legacy partition after its migration marker', () async {
    final store = TtsCacheStore('known-id', 'voice', 1, contentKey: 'known-content', textFingerprint: 'words2-same');
    await store.dir();
    final legacy = File('${root.path}/tts_cache/known-id/voice/1.00/text-words2-same/${TtsCacheStore.fileName(0, 0)}');
    await legacy.parent.create(recursive: true);
    await legacy.writeAsBytes([1, 2]);
    await File('${legacy.path}.words.json').writeAsString('[]');
    expect(await store.listMp3Names(), {TtsCacheStore.fileName(0, 0)});
    expect(await store.read(0, 0), [1, 2]);
    final unrelated = TtsCacheStore('unrelated-id', 'voice', 1, contentKey: 'unrelated-content', textFingerprint: 'words2-same');
    expect(await unrelated.listMp3Names(), isEmpty);
  });

  test('replacing an audio entry without timings removes the previous sidecar', () async {
    final store = TtsCacheStore('replace', 'voice', 1);
    await store.write(0, 0, Uint8List.fromList([1]), words: [
      const SpeechWord(startMicros: 0, durationMicros: 1, textStart: 0, textEnd: 1, text: '甲'),
    ]);
    expect(await store.readWords(0, 0), hasLength(1));
    await store.write(0, 0, Uint8List.fromList([2]));
    expect(await store.read(0, 0), [2]);
    expect(await store.readWords(0, 0), isEmpty);
  });

  final clearOperations = <String, Future<int> Function()>{
    'clear': () => _ClearStore().clear(),
    'clearAll': TtsCacheStore.clearAll,
    'clearBook': () => TtsCacheStore.clearBook('synthetic-cache'),
  };
  for (final operation in clearOperations.entries) {
    test('${operation.key} propagates cache listing and deletion IO failures', () async {
      for (final listing in [true, false]) {
        const failure = FileSystemException('Cache access denied', 'synthetic-cache', OSError('Access denied', 5));
        await IOOverrides.runZoned(() async {
          await expectLater(operation.value(), throwsA(same(failure)));
        }, createDirectory: (path) => _ClearDirectory(path,
          listingFailure: listing ? failure : null,
          child: listing ? null : _UndeletableFile('$path${Platform.pathSeparator}audio.mp3', failure)));
      }
    });
    test('${operation.key} tolerates entries already removed by another owner', () async {
      for (final listing in [true, false]) {
        const missing = FileSystemException('Already removed', 'synthetic-cache', OSError('Not found', 2));
        await IOOverrides.runZoned(() async {
          expect(await operation.value(), 0);
        }, createDirectory: (path) => _ClearDirectory(path,
          listingFailure: listing ? missing : null,
          child: listing ? null : _UndeletableFile('$path${Platform.pathSeparator}audio.mp3', missing)));
      }
    });
  }

  test('cache clear operations delete real fixture files and remain idempotent', () async {
    final store = TtsCacheStore('clear-fixture', 'voice', 1);
    await store.write(0, 0, Uint8List.fromList([1]));
    expect(await store.clear(), 1);
    expect(await store.clear(), 0);
    await store.write(0, 0, Uint8List.fromList([1]));
    expect(await TtsCacheStore.clearBook(store.cacheKey), greaterThan(0));
    expect(await TtsCacheStore.clearBook(store.cacheKey), 0);
    await store.write(0, 0, Uint8List.fromList([1]));
    expect(await TtsCacheStore.clearAll(), greaterThan(0));
    expect(await TtsCacheStore.clearAll(), 0);
  });
}
