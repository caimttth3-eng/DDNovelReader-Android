import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/models/speech_word.dart';
import 'package:duoduo_langdu/services/edge_tts.dart';
import 'package:duoduo_langdu/services/tts_reader.dart';
import 'package:duoduo_langdu/services/tts_cache_store.dart';

class _Player extends AudioPlayer {
  final played = <int>[];
  final completed = StreamController<void>.broadcast();
  bool _readerEvents = false;
  bool staleCompletionOnStop = false;
  _Player() { _readerEvents = true; }
  @override
  Stream<void> get onPlayerComplete => _readerEvents ? completed.stream : super.onPlayerComplete;
  @override
  Future<void> stop() async {
    if (staleCompletionOnStop && !completed.isClosed) { completed.add(null); await Future<void>.delayed(Duration.zero); }
  }
  @override
  Future<void> play(Source source, {double? volume, double? balance, AudioContext? ctx,
    Duration? position, PlayerMode? mode}) async {
    played.add((source as BytesSource).bytes.first);
  }
  @override
  Future<void> dispose() async { await super.dispose(); await completed.close(); }
}

class _ResumePlayer extends _Player {
  final positions = StreamController<Duration>.broadcast();
  final starts = <Duration>[];
  Duration clock = Duration.zero;
  Completer<void>? pauseGate;
  Completer<Duration?>? positionGate;
  @override
  Stream<Duration> get onPositionChanged => positions.stream;
  @override
  Future<Duration?> getCurrentPosition() async => positionGate == null ? clock : await positionGate!.future;
  @override
  Future<void> pause() async { await pauseGate?.future; }
  @override
  Future<void> stop() async { clock = Duration.zero; await super.stop(); }
  @override
  Future<void> play(Source source, {double? volume, double? balance, AudioContext? ctx,
    Duration? position, PlayerMode? mode}) async {
    starts.add(position ?? Duration.zero); clock = position ?? Duration.zero;
    await super.play(source, position: position);
  }
  void tick(int milliseconds) { clock = Duration(milliseconds: milliseconds); positions.add(clock); }
  @override
  Future<void> dispose() async { await super.dispose(); await positions.close(); }
}

class _BrokenPlayer extends _ResumePlayer {
  @override
  Future<void> play(Source source, {double? volume, double? balance, AudioContext? ctx,
    Duration? position, PlayerMode? mode}) async {
    throw TimeoutException('native player did not start');
  }
}

class _SlowCache extends TtsCacheStore {
  final reading = Completer<void>();
  final result = Completer<Uint8List?>();
  _SlowCache() : super('slow-cache', 'voice', .5);
  @override
  Future<Uint8List?> read(int ci, int off) {
    if (!reading.isCompleted) reading.complete();
    return result.future;
  }
  @override
  Future<List<SpeechWord>> readWords(int ci, int off) async => [];
}

class _DeferredWriteCache extends TtsCacheStore {
  final started = Completer<void>();
  final release = Completer<void>();
  _DeferredWriteCache() : super('deferred-write', 'voice', .5);
  @override
  Future<Uint8List?> read(int ci, int off) async => null;
  @override
  Future<void> write(int ci, int off, Uint8List audio, {List<SpeechWord>? words}) {
    if (!started.isCompleted) started.complete();
    return release.future;
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  Future<void> waitFor(bool Function() ready, String reason) async {
    for (var attempt = 0; attempt < 400 && !ready(); attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(ready(), isTrue, reason: reason);
  }
  setUp(() {
    final messenger = binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers.global'), (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers.global/events'), (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers'), (call) async {
      if (call.method == 'create') messenger.setMockMethodCallHandler(
        MethodChannel('xyz.luan/audioplayers/events/${(call.arguments as Map)['playerId']}'), (_) async => null);
      return null;
    });
  });
  test('current sentence precedes prefetch and old chapter audio cannot enter a new queue', () async {
    final player = _Player();
    final requests = <String, Completer<Uint8List>>{};
    final requested = <String>[];
    Future<Uint8List> synth(String text, {required String voice, required String rate,
      required void Function(List<SpeechWord>) onWords, required EdgeSynthCancelToken cancelToken}) {
      requested.add(text);
      return (requests[text] = Completer<Uint8List>()).future;
    }
    Future<void> waitFor(String text) async {
      for (var i = 0; i < 100 && !requests.containsKey(text); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(requests, contains(text));
    }
    final reader = TtsReader(player: player, synthesize: synth);
    final old = reader.start(['old-0', 'old-1']);
    await waitFor('old-0');
    expect(requested, ['old-0'], reason: 'Future sentences must not compete with first sound');
    requests['old-0']!.complete(Uint8List.fromList([1]));
    await old.timeout(const Duration(seconds: 3), onTimeout: () => throw StateError('initial current sentence did not enter playback'));
    await waitFor('old-1');
    player.staleCompletionOnStop = true;
    final next = reader.start(['new-0', 'new-1']); await waitFor('new-0');
    expect(reader.currentIndex, 0, reason: 'A completion queued during stop must not advance the new chapter');
    requests['new-0']!.complete(Uint8List.fromList([2]));
    await next.timeout(const Duration(seconds: 3), onTimeout: () => throw StateError('new chapter current sentence did not enter playback'));
    requests['old-1']!.complete(Uint8List.fromList([99]));
    await waitFor('new-1');
    final cancelledRequest = requests['new-1']!;
    final jump = reader.jumpTo(1);
    for (var i = 0; i < 100 && identical(requests['new-1'], cancelledRequest); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    // A cancelled transport is deliberately allowed to resolve late above;
    // the stale value 99 must never become playable in the new chapter.
    final currentRequest = requests['new-1']!;
    expect(identical(currentRequest, cancelledRequest), isFalse);
    cancelledRequest.complete(Uint8List.fromList([77]));
    currentRequest.complete(Uint8List.fromList([3]));
    await jump.timeout(const Duration(seconds: 3), onTimeout: () => throw StateError('jump did not use its fresh audio request'));
    expect(player.played, [1, 2, 3]);
    await reader.dispose().timeout(const Duration(seconds: 3), onTimeout: () => throw StateError('mock player disposal did not finish'));
  });

  test('cache writes do not delay playback but disposal drains them before cache teardown', () async {
    final cache = _DeferredWriteCache();
    Future<Uint8List> synth(String text, {required String voice, required String rate,
      required void Function(List<SpeechWord>) onWords, required EdgeSynthCancelToken cancelToken}) async {
      onWords([]); return Uint8List.fromList([7]);
    }
    final player = _ResumePlayer();
    final reader = TtsReader(player: player, synthesize: synth)..setCache(cache)..setPrefetchSentences(0);
    Future<void>? disposal;
    addTearDown(() async {
      if (!cache.release.isCompleted) cache.release.complete();
      await (disposal ??= reader.dispose());
    });
    await reader.start(['正文。'], offsets: [0]).timeout(const Duration(seconds: 1));
    await cache.started.future;
    expect(player.played, [7]); expect(cache.release.isCompleted, isFalse);
    var disposed = false;
    final disposing = reader.dispose().then((_) { disposed = true; });
    disposal = disposing;
    await waitFor(() => player.state == PlayerState.disposed, 'Player cleanup must finish before waiting for cache writes.');
    expect(disposed, isFalse, reason: 'A completed dispose must guarantee no cache file is still being written.');
    cache.release.complete();
    await disposing.timeout(const Duration(seconds: 1));
    expect(disposed, isTrue);
  });

  test('dynamic prefetch windows preserve useful audio, cancel excess requests and never interrupt the current sentence', () async {
    final player = _ResumePlayer();
    final calls = <(int, Completer<Uint8List>, EdgeSynthCancelToken)>[];
    Future<Uint8List> synth(String text, {required String voice, required String rate,
      required void Function(List<SpeechWord>) onWords, required EdgeSynthCancelToken cancelToken}) {
      onWords([]);
      final pending = Completer<Uint8List>();
      calls.add((int.parse(text), pending, cancelToken));
      return pending.future;
    }
    Future<void> waitCount(int count) async {
      for (var attempt = 0; attempt < 300 && calls.length < count; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(calls.length, count);
    }
    final reader = TtsReader(player: player, synthesize: synth)..setPrefetchSentences(2);
    addTearDown(reader.dispose);
    final starting = reader.start([for (var i = 0; i < 8; i++) '$i']);
    await waitCount(1);
    reader.setPrefetchSentences(3);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calls.map((call) => call.$1), [0], reason: 'Changing the window while loading must not compete with first sound.');
    calls[0].$2.complete(Uint8List.fromList([0]));
    await starting;
    await waitCount(2); calls[1].$2.complete(Uint8List.fromList([1]));
    await waitCount(3);
    expect(calls[2].$1, 2);
    reader.setPrefetchSentences(1);
    expect(calls[2].$3.cancelled, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(calls.length, 3);
    expect(player.played, [0]); expect(reader.currentIndex, 0);
    reader.setPrefetchSentences(3);
    await waitCount(4);
    expect(calls[3].$1, 2, reason: 'The enlarged window must not wait for a cancelled transport to resolve.');
    calls[2].$2.complete(Uint8List.fromList([99]));
    await Future<void>.delayed(Duration.zero);
    calls[3].$2.complete(Uint8List.fromList([2]));
    await waitCount(5); expect(calls[4].$1, 3);
    calls[4].$2.complete(Uint8List.fromList([3]));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calls.map((call) => call.$1), [0, 1, 2, 2, 3],
      reason: 'Valid sentence 1 remains cached when shrinking and growing the window.');
    reader.setPrefetchSentences(2);
    reader.setPrefetchSentences(3);
    await waitCount(6);
    expect(calls[5].$1, 3, reason: 'Shrinking must evict the audio beyond the new bounded window.');
    calls[5].$2.complete(Uint8List.fromList([3]));
    reader.setPrefetchSentences(0);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(calls.length, 6); expect(player.played, [0]);
    player.clock = const Duration(milliseconds: 1234);
    await reader.pause(); expect(await reader.resume(), isTrue);
    expect(player.starts.last, const Duration(milliseconds: 1234));
    expect(calls.length, 6, reason: 'Turning off prefetch must retain the current offline-resumable audio.');
    player.completed.add(null);
    await waitCount(7);
    expect(calls[6].$1, 1);
    calls[6].$2.complete(Uint8List.fromList([1]));
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(calls.length, 7, reason: 'With prefetch disabled, only the now-current sentence is fetched.');
    expect(player.played, [0, 0, 1]);
  });

  test('zero disables prefetch and changes made while paused take effect only after audio resumes', () async {
    final player = _ResumePlayer();
    final requested = <String>[];
    Future<Uint8List> synth(String text, {required String voice, required String rate,
      required void Function(List<SpeechWord>) onWords, required EdgeSynthCancelToken cancelToken}) async {
      requested.add(text); onWords([]); return Uint8List.fromList([int.parse(text)]);
    }
    final reader = TtsReader(player: player, synthesize: synth)..setPrefetchSentences(-1);
    addTearDown(reader.dispose);
    expect(reader.prefetchSentences, 0);
    await reader.start(['0', '1', '2', '3']);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(requested, ['0']);
    await reader.pause();
    reader.setPrefetchSentences(2);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(requested, ['0']);
    expect(await reader.resume(), isTrue);
    for (var attempt = 0; attempt < 100 && requested.length < 3; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(requested, ['0', '1', '2']);
    reader.setPrefetchSentences(900); expect(reader.prefetchSentences, 100);
    reader.setPrefetchSentences(0); expect(reader.prefetchSentences, 0);
    expect(reader.state, TtsState.playing); expect(reader.currentIndex, 0);
    expect(player.played, [0, 0]);
  });

  test('system voice never starts online prefetch even at the maximum count', () async {
    final messenger = binding.defaultBinaryMessenger;
    const systemChannel = MethodChannel('com.ddnovelreader/system_tts');
    messenger.setMockMethodCallHandler(systemChannel, (call) async {
      if (call.method == 'speak') {
        final delivered = Completer<void>();
        messenger.handlePlatformMessage(systemChannel.name,
          const StandardMethodCodec().encodeMethodCall(MethodCall('start', {'id': (call.arguments as Map)['id']})),
          (_) => delivered.complete());
        await delivered.future;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(systemChannel, null));
    var onlineCalls = 0;
    Future<Uint8List> synth(String text, {required String voice, required String rate,
      required void Function(List<SpeechWord>) onWords, required EdgeSynthCancelToken cancelToken}) async {
      onlineCalls++; return Uint8List.fromList([1]);
    }
    final reader = TtsReader(player: _Player(), synthesize: synth)..setVoice(TtsReader.systemVoice);
    addTearDown(reader.dispose);
    await reader.start(['第一句。', '第二句。']);
    reader.setPrefetchSentences(100);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await reader.pause(); expect(await reader.resume(), isTrue);
    expect(onlineCalls, 0);
  });

  for (final knownOffline in [true, false]) {
    test('${knownOffline ? 'OS disconnect' : 'actual connection failure'} consumes prefetch and disk audio before sticky system fallback', () async {
      final messenger = binding.defaultBinaryMessenger;
      const systemChannel = MethodChannel('com.ddnovelreader/system_tts');
      final spoken = <Map>[];
      Future<void> systemEvent(String event, Object? id) async {
        final done = Completer<void>();
        messenger.handlePlatformMessage(systemChannel.name,
          const StandardMethodCodec().encodeMethodCall(MethodCall(event, {'id': id})), (_) => done.complete());
        await done.future;
      }
      messenger.setMockMethodCallHandler(systemChannel, (call) async {
        if (call.method == 'speak') {
          spoken.add(call.arguments as Map);
          await systemEvent('start', spoken.last['id']);
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(systemChannel, null));
      final directory = await Directory.systemTemp.createTemp('tts-fallback-cache-');
      const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
      messenger.setMockMethodCallHandler(pathChannel, (_) async => directory.path);
      addTearDown(() async {
        messenger.setMockMethodCallHandler(pathChannel, null); await directory.delete(recursive: true);
      });
      final cache = TtsCacheStore('fallback', TtsReader.defaultVoice, .5);
      await cache.write(0, 20, Uint8List.fromList([2]), words: []);
      final requested = <String>[];
      Future<Uint8List> synth(String text, {required String voice, required String rate,
        required void Function(List<SpeechWord>) onWords, required EdgeSynthCancelToken cancelToken}) async {
        requested.add(text);
        if (text == '3') throw const EdgeTtsException('connection');
        onWords([]); return Uint8List.fromList([int.parse(text)]);
      }
      final player = _ResumePlayer();
      final reader = TtsReader(player: player, synthesize: synth)..setPrefetchSentences(1)..setCache(cache);
      addTearDown(reader.dispose);
      final modes = <bool>[];
      var errors = 0;
      reader.onVoiceModeChanged = modes.add; reader.onError = () => errors++;
      await reader.start(['0', '1', '2', '3', '4'], offsets: [0, 10, 20, 30, 40]);
      await waitFor(() => requested.contains('1'), 'Sentence 1 must be preloaded.');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (knownOffline) reader.setNetworkAvailable(false);
      expect(reader.usingSystemFallback, isFalse);
      player.completed.add(null);
      await waitFor(() => player.played.length == 2, 'The completed memory preload must survive disconnection.');
      expect(player.played, [0, 1]); expect(spoken, isEmpty);
      player.completed.add(null);
      await waitFor(() => player.played.length == 3, 'Existing disk audio must play even when offline.');
      expect(player.played, [0, 1, 2]);
      if (!knownOffline) await waitFor(() => requested.contains('3'), 'A real failed prefetch supplies connection failure evidence.');
      expect(reader.usingSystemFallback, isFalse, reason: 'A background failure cannot skip usable foreground audio.');
      expect(spoken, isEmpty);
      player.completed.add(null);
      await waitFor(() => spoken.length == 1, 'Only the first uncached current sentence switches to system speech.');
      expect(spoken.single['text'], '3');
      expect(reader.usingSystemFallback, isTrue); expect(reader.usesSystemVoice, isTrue);
      expect(reader.voice, TtsReader.defaultVoice); expect(modes, [true]); expect(errors, 0);
      expect(requested, knownOffline ? ['0', '1'] : ['0', '1', '3']);
      final beforeRecovery = requested.length;
      reader.setNetworkAvailable(true);
      await systemEvent('done', spoken.last['id']);
      await waitFor(() => spoken.length == 2, 'System speech remains selected after network recovery.');
      expect(spoken.last['text'], '4'); expect(requested.length, beforeRecovery);
      expect(reader.usingSystemFallback, isTrue);
      reader.setVoice(TtsReader.defaultVoice);
      expect(reader.usingSystemFallback, isFalse); expect(modes, [true, false]);
      await reader.jumpTo(4);
      await waitFor(() => player.played.length == 4, 'Manually selecting the same online source must allow returning online.');
      expect(requested.last, '4'); expect(player.played.last, 4);
      expect(errors, 0);
    });
  }

  for (final error in <Object>[
    const EdgeTtsException('timeout'),
    TimeoutException('transport deadline'),
    const SocketException('connection lost'),
    const EdgeTtsException('service', status: 403),
    const EdgeTtsException('service', status: 429),
    const EdgeTtsException('no_audio'),
  ]) {
    test('only network synthesis failures can trigger fallback: $error', () async {
      final messenger = binding.defaultBinaryMessenger;
      const channel = MethodChannel('com.ddnovelreader/system_tts');
      var systemStarts = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'speak') {
          systemStarts++;
          final delivered = Completer<void>();
          messenger.handlePlatformMessage(channel.name,
            const StandardMethodCodec().encodeMethodCall(MethodCall('start', {'id': (call.arguments as Map)['id']})),
            (_) => delivered.complete());
          await delivered.future;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      Future<Uint8List> synth(String text, {required String voice, required String rate,
        required void Function(List<SpeechWord>) onWords, required EdgeSynthCancelToken cancelToken}) async => throw error;
      final reader = TtsReader(player: _ResumePlayer(), synthesize: synth);
      addTearDown(reader.dispose);
      var errors = 0; reader.onError = () => errors++;
      await reader.start(['正文。']);
      final networkError = error is TimeoutException || error is SocketException || error is EdgeTtsException && error.kind == 'timeout';
      expect(reader.usingSystemFallback, networkError);
      expect(systemStarts, networkError ? 1 : 0);
      expect(errors, networkError ? 0 : 1);
    });
  }

  test('a native player timeout is not misclassified as a network failure', () async {
    Future<Uint8List> synth(String text, {required String voice, required String rate,
      required void Function(List<SpeechWord>) onWords, required EdgeSynthCancelToken cancelToken}) async {
      onWords([]); return Uint8List.fromList([1]);
    }
    final reader = TtsReader(player: _BrokenPlayer(), synthesize: synth);
    addTearDown(reader.dispose);
    var errors = 0; reader.onError = () => errors++;
    await reader.start(['正文。']);
    expect(reader.usingSystemFallback, isFalse); expect(errors, 1);
    expect(reader.lastFailure, isA<TimeoutException>());
  });

  test('an unavailable system engine reports one real failure without online retries', () async {
    final messenger = binding.defaultBinaryMessenger;
    const channel = MethodChannel('com.ddnovelreader/system_tts');
    var initializationCalls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'initialize') { initializationCalls++; throw PlatformException(code: 'engine_unavailable'); }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    var onlineCalls = 0;
    Future<Uint8List> synth(String text, {required String voice, required String rate,
      required void Function(List<SpeechWord>) onWords, required EdgeSynthCancelToken cancelToken}) async {
      onlineCalls++; return Uint8List.fromList([1]);
    }
    final reader = TtsReader(player: _ResumePlayer(), synthesize: synth)..setNetworkAvailable(false);
    addTearDown(reader.dispose);
    var errors = 0; reader.onError = () => errors++;
    await reader.start(['正文。']);
    expect(onlineCalls, 0); expect(initializationCalls, 1); expect(errors, 1);
    expect(reader.state, TtsState.stopped); expect(reader.lastFailure, isA<PlatformException>());
    reader.setNetworkAvailable(true);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(onlineCalls, 0); expect(initializationCalls, 1);
    reader.setVoice(TtsReader.systemVoice);
    expect(reader.usingSystemFallback, isFalse); expect(reader.usesSystemVoice, isTrue);
  });

  test('disconnect preserves an in-progress cache read instead of prematurely falling back', () async {
    final cache = _SlowCache();
    var onlineCalls = 0;
    Future<Uint8List> synth(String text, {required String voice, required String rate,
      required void Function(List<SpeechWord>) onWords, required EdgeSynthCancelToken cancelToken}) async {
      onlineCalls++; return Uint8List.fromList([99]);
    }
    final player = _ResumePlayer();
    final reader = TtsReader(player: player, synthesize: synth)..setCache(cache)..setPrefetchSentences(0);
    addTearDown(reader.dispose);
    final starting = reader.start(['已有音频。'], offsets: [0]);
    await cache.reading.future;
    reader.setNetworkAvailable(false);
    cache.result.complete(Uint8List.fromList([7]));
    await starting.timeout(const Duration(seconds: 1));
    expect(player.played, [7]); expect(reader.usingSystemFallback, isFalse);
    expect(onlineCalls, 0);
  });

  for (final stoppedBeforeDisconnect in [false, true]) {
    test('disconnect promptly cancels a loading transport without reviving ${stoppedBeforeDisconnect ? 'stopped' : 'old'} audio', () async {
      final messenger = binding.defaultBinaryMessenger;
      const channel = MethodChannel('com.ddnovelreader/system_tts');
      var systemStarts = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'speak') {
          systemStarts++;
          final delivered = Completer<void>();
          messenger.handlePlatformMessage(channel.name,
            const StandardMethodCodec().encodeMethodCall(MethodCall('start', {'id': (call.arguments as Map)['id']})),
            (_) => delivered.complete());
          await delivered.future;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final pending = Completer<Uint8List>();
      EdgeSynthCancelToken? token;
      Future<Uint8List> synth(String text, {required String voice, required String rate,
        required void Function(List<SpeechWord>) onWords, required EdgeSynthCancelToken cancelToken}) {
        token = cancelToken; return pending.future;
      }
      final player = _ResumePlayer();
      final reader = TtsReader(player: player, synthesize: synth)..setPrefetchSentences(0);
      addTearDown(reader.dispose);
      var errors = 0; reader.onError = () => errors++;
      final starting = reader.start(['正在连接。']);
      await waitFor(() => token != null, 'The actual current-sentence transport must have started.');
      if (stoppedBeforeDisconnect) await reader.stop();
      reader.setNetworkAvailable(false);
      await starting.timeout(const Duration(seconds: 1));
      expect(token!.cancelled, isTrue);
      expect(systemStarts, stoppedBeforeDisconnect ? 0 : 1);
      expect(reader.usingSystemFallback, !stoppedBeforeDisconnect);
      pending.complete(Uint8List.fromList([99]));
      await Future<void>.delayed(Duration.zero);
      expect(player.played, isEmpty); expect(errors, 0);
      expect(reader.currentIndex, stoppedBeforeDisconnect ? -1 : 0);
    });
  }

  test('restoring sticky fallback bypasses online synthesis even after network recovery or another chapter', () async {
    final messenger = binding.defaultBinaryMessenger;
    const channel = MethodChannel('com.ddnovelreader/system_tts');
    final spoken = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'speak') {
        spoken.add((call.arguments as Map)['text'] as String);
        final delivered = Completer<void>();
        messenger.handlePlatformMessage(channel.name,
          const StandardMethodCodec().encodeMethodCall(MethodCall('start', {'id': (call.arguments as Map)['id']})),
          (_) => delivered.complete());
        await delivered.future;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    var onlineCalls = 0;
    Future<Uint8List> synth(String text, {required String voice, required String rate,
      required void Function(List<SpeechWord>) onWords, required EdgeSynthCancelToken cancelToken}) async {
      onlineCalls++; onWords([]); return Uint8List.fromList([1]);
    }
    final reader = TtsReader(player: _ResumePlayer(), synthesize: synth)
      ..setVoice(TtsReader.defaultVoice)..restoreSystemFallback(true);
    addTearDown(reader.dispose);
    reader.setNetworkAvailable(false); reader.setNetworkAvailable(true);
    await reader.start(['重启后。']);
    await reader.start(['下一章。'], chapterIndex: 1);
    expect(spoken, ['重启后。', '下一章。']); expect(onlineCalls, 0);
    expect(reader.voice, TtsReader.defaultVoice); expect(reader.usingSystemFallback, isTrue);
    reader.setVoice(TtsReader.defaultVoice);
    await reader.start(['手动恢复。']);
    expect(onlineCalls, 1); expect(reader.usingSystemFallback, isFalse);
    reader.setVoice(TtsReader.systemVoice); reader.restoreSystemFallback(true);
    expect(reader.usesSystemVoice, isTrue); expect(reader.usingSystemFallback, isFalse);
  });

  test('repeated pause reloads the retained audio at the exact position offline and then completes the next sentence', () async {
    final player = _ResumePlayer();
    final requested = <String>[];
    var offline = false;
    Future<Uint8List> synth(String text, {required String voice, required String rate,
      required void Function(List<SpeechWord>) onWords, required EdgeSynthCancelToken cancelToken}) async {
      requested.add(text);
      if (offline) throw StateError('offline');
      onWords([
        const SpeechWord(startMicros: 0, durationMicros: 1000000, textStart: 0, textEnd: 2, text: '甲乙'),
        const SpeechWord(startMicros: 1000000, durationMicros: 700000, textStart: 2, textEnd: 4, text: '丙丁'),
        const SpeechWord(startMicros: 1700000, durationMicros: 600000, textStart: 4, textEnd: 6, text: '戊己'),
      ]);
      return Uint8List.fromList([text == 'current' ? 1 : 2]);
    }
    final reader = TtsReader(player: player, synthesize: synth);
    addTearDown(reader.dispose);
    final words = <(int, int)>[];
    final sentences = <int>[];
    var finished = false;
    reader.onSentenceChanged = sentences.add;
    reader.onWordChanged = (start, end) => words.add((start, end));
    reader.onCompleted = () => finished = true;
    await reader.start(['current', 'next']);
    // Let the already-successful next-sentence prefetch enter memory.
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(requested, ['current', 'next']);
    player.tick(1200); await Future<void>.delayed(Duration.zero);
    expect(reader.currentWordStart, 2);
    player.clock = const Duration(milliseconds: 1437);
    await reader.pause();
    expect(reader.state, TtsState.paused); expect(reader.currentIndex, 0);
    expect(reader.currentWordStart, 2); expect(reader.currentWordEnd, 4);
    player.tick(0); player.completed.add(null); await Future<void>.delayed(Duration.zero);
    expect(reader.currentIndex, 0); expect(reader.currentWordStart, 2);
    offline = true;
    expect(await reader.resume(), isTrue);
    expect(player.starts.last, const Duration(milliseconds: 1437));
    expect(reader.currentWordStart, 2);
    player.clock = const Duration(milliseconds: 1742);
    player.pauseGate = Completer<void>();
    final pausing = reader.pause();
    final resuming = reader.resume();
    await Future<void>.delayed(Duration.zero);
    expect(player.played, [1, 1], reason: 'Resume must wait until pause captured the clock.');
    player.pauseGate!.complete();
    await pausing; expect(await resuming, isTrue);
    expect(player.starts.last, const Duration(milliseconds: 1742));
    expect(reader.currentWordStart, 4);
    expect(sentences, [0], reason: 'Resuming the same sentence must not scroll the reader back to its beginning.');
    player.tick(1850); await Future<void>.delayed(Duration.zero);
    expect(words.last, (4, 6));
    player.completed.add(null); await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(reader.currentIndex, 1);
    expect(sentences, [0, 1], reason: 'Only a genuinely new sentence should move the sentence cursor.');
    expect(player.played, [1, 1, 1, 2]);
    expect(player.starts.last, Duration.zero, reason: 'A new sentence must not inherit the pause seek.');
    expect(requested, ['current', 'next'], reason: 'Current audio, words and completed prefetch must survive pause without network.');
    player.completed.add(null); await Future<void>.delayed(Duration.zero);
    expect(finished, isTrue);
  });

  test('system character offsets do not alter online synthesis or its audio seek position', () async {
    final player = _ResumePlayer();
    final requested = <String>[];
    Future<Uint8List> synth(String text, {required String voice, required String rate,
      required void Function(List<SpeechWord>) onWords, required EdgeSynthCancelToken cancelToken}) async {
      requested.add(text); onWords([]); return Uint8List.fromList([1]);
    }
    final reader = TtsReader(player: player, synthesize: synth)..setPrefetchSentences(0);
    addTearDown(reader.dispose);
    await reader.start(['甲乙丙丁。'], initialTtsOffset: 2);
    expect(reader.currentTtsOffset, 0); expect(player.starts, [Duration.zero]);
    await reader.jumpTo(0, ttsOffset: 3);
    expect(requested, ['甲乙丙丁。', '甲乙丙丁。']);
    expect(reader.currentTtsOffset, 0); expect(player.starts.last, Duration.zero);
  });
  test('online synthesis preserves the complete numbered title regardless of system-only start cursors', () async {
    const title = '第 3 章 一寸金03';
    final player = _ResumePlayer(); final requested = <String>[];
    Future<Uint8List> synth(String text, {required String voice, required String rate,
      required void Function(List<SpeechWord>) onWords, required EdgeSynthCancelToken cancelToken}) async {
      requested.add(text); onWords([]); return Uint8List.fromList([1]);
    }
    final reader = TtsReader(player: player, synthesize: synth)..setPrefetchSentences(0);
    addTearDown(reader.dispose);
    for (final offset in [0, title.indexOf('一'), title.length, title.length + 20]) {
      await reader.start([title], initialTtsOffset: offset);
      expect(requested.last, title); expect(reader.currentTtsOffset, 0);
      expect(player.starts.last, Duration.zero);
    }
    expect(requested, List.filled(4, title));
  });

  test('jump, voice and rate changes discard the paused audio position', () async {
    final player = _ResumePlayer();
    var requests = 0;
    Future<Uint8List> synth(String text, {required String voice, required String rate,
      required void Function(List<SpeechWord>) onWords, required EdgeSynthCancelToken cancelToken}) async {
      requests++; onWords([]); return Uint8List.fromList([requests]);
    }
    final reader = TtsReader(player: player, synthesize: synth);
    addTearDown(reader.dispose);
    await reader.start(['one']);
    for (final change in <Future<void> Function()>[
      () => reader.jumpTo(0),
      () async => reader.setVoice('another-voice'),
      () => reader.setSpeechRate(1.5),
      () => reader.start(['new chapter']),
    ]) {
      player.clock = const Duration(milliseconds: 900);
      await reader.pause();
      await change();
      if (reader.state != TtsState.playing) expect(await reader.resume(), isTrue);
      expect(player.starts.last, Duration.zero);
    }
    expect(requests, 5);
  });

  test('an unresponsive pause position read falls back to the latest tick without blocking resume or stop', () async {
    final player = _ResumePlayer();
    Future<Uint8List> synth(String text, {required String voice, required String rate,
      required void Function(List<SpeechWord>) onWords, required EdgeSynthCancelToken cancelToken}) async {
      onWords([const SpeechWord(startMicros: 1000000, durationMicros: 1000000,
        textStart: 2, textEnd: 4, text: '丙丁')]);
      return Uint8List.fromList([1]);
    }
    final reader = TtsReader(player: player, synthesize: synth);
    addTearDown(reader.dispose);
    await reader.start(['甲乙丙丁。']);
    player.tick(1234); await Future<void>.delayed(Duration.zero);
    player.positionGate = Completer<Duration?>();
    await reader.pause().timeout(const Duration(seconds: 3));
    expect(reader.currentWordStart, 2);
    expect(await reader.resume().timeout(const Duration(seconds: 1)), isTrue);
    expect(player.starts.last, const Duration(milliseconds: 1234));
    await reader.stop().timeout(const Duration(seconds: 1));
    player.positionGate!.complete(const Duration(milliseconds: 9999));
    await Future<void>.delayed(Duration.zero);
    expect(reader.state, TtsState.stopped);
    expect(reader.currentIndex, -1);
  });

  test('pause during punctuation delay resumes only its remaining silence and jump cancels it', () async {
    final player = _ResumePlayer();
    Future<Uint8List> synth(String text, {required String voice, required String rate,
      required void Function(List<SpeechWord>) onWords, required EdgeSynthCancelToken cancelToken}) async {
      onWords([]); return Uint8List.fromList([text == 'first' ? 1 : 2]);
    }
    final reader = TtsReader(player: player, synthesize: synth);
    addTearDown(reader.dispose);
    await reader.start(['first', 'second'], pauseAfterMilliseconds: [300, 0]);
    player.completed.add(null);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(reader.currentIndex, 0); expect(player.played, [1]);
    await reader.pause();
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(reader.currentIndex, 0);
    expect(await reader.resume(), isTrue);
    expect(player.played, [1], reason: 'Completed audio must not replay when resuming a dash pause.');
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(player.played, [1, 2]);
    await reader.start(['first', 'second'], pauseAfterMilliseconds: [300, 0]);
    player.completed.add(null); await Future<void>.delayed(Duration.zero);
    await reader.jumpTo(1);
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(reader.currentIndex, 1, reason: 'The old delay must not advance a new navigation.');
    expect(player.played, [1, 2, 1, 2]);
  });

  for (final diskHit in [false, true]) {
    test('real AudioPlayer keeps sentence and word callbacks after ${diskHit ? 'disk cache' : 'prefetch'} transition', () async {
      // Keep the real AudioPlayer's internal completion listener and timer.
      // Overriding play/stop/onPlayerComplete hides lifecycle races here.
      final messenger = binding.defaultBinaryMessenger;
      final directory = await Directory.systemTemp.createTemp('tts-player-events-');
      const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
      messenger.setMockMethodCallHandler(pathChannel, (_) async => directory.path);
      addTearDown(() async {
        messenger.setMockMethodCallHandler(pathChannel, null);
        await directory.delete(recursive: true);
      });
      final player = AudioPlayer();
      var positionMillis = 0;
      var resumes = 0;
      var loading = false;
      var holdNextPosition = false;
      Completer<int>? delayedOldPosition;
      final sourceBytes = <int>[];
      final seeks = <int>[];
      Future<void> emit(String name, [Object? value]) async {
        final done = Completer<void>();
        messenger.handlePlatformMessage('xyz.luan/audioplayers/events/${player.playerId}',
          const StandardMethodCodec().encodeSuccessEnvelope({'event': name, 'value': value}),
          (_) => done.complete());
        await done.future;
      }
      messenger.setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers'), (call) async {
        switch (call.method) {
          case 'create':
            messenger.setMockMethodCallHandler(MethodChannel('xyz.luan/audioplayers/events/${(call.arguments as Map)['playerId']}'), (_) async => null);
          case 'setSourceBytes':
            sourceBytes.add(((call.arguments as Map)['bytes'] as Uint8List).first);
            await emit('audio.onPrepared', true);
          case 'resume':
            resumes++;
          case 'stop':
            positionMillis = 0;
          case 'seek':
            positionMillis = (call.arguments as Map)['position'] as int;
            seeks.add(positionMillis);
            await emit('audio.onSeekComplete');
          case 'getCurrentPosition':
            if (holdNextPosition) {
              holdNextPosition = false;
              delayedOldPosition = Completer<int>();
              return delayedOldPosition!.future;
            }
            return positionMillis;
        }
        return null;
      });
      Future<void> waitUntil(bool Function() ready, String stage) async {
        for (var i = 0; i < 300 && !ready(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(ready(), isTrue, reason: stage);
      }
      const texts = ['甲乙丙丁。', '一二三四五六。', '后续文字。'];
      final timing = [for (var i = 0; i < texts.length; i++) [
        SpeechWord(startMicros: 100000, durationMicros: 200000, textStart: i, textEnd: i + 2, text: texts[i].substring(i, i + 2)),
        SpeechWord(startMicros: 400000, durationMicros: 200000, textStart: i + 2, textEnd: i + 3, text: texts[i].substring(i + 2, i + 3)),
      ]];
      final cache = TtsCacheStore('native-events', 'voice', .5, textFingerprint: 'words1');
      if (diskHit) {
        for (var i = 0; i < texts.length; i++) {
          await cache.write(0, i * 20, Uint8List.fromList([i + 1]), words: timing[i]);
        }
      }
      final synthesized = <String>[];
      Future<Uint8List> synth(String text, {required String voice, required String rate,
        required void Function(List<SpeechWord>) onWords, required EdgeSynthCancelToken cancelToken}) async {
        synthesized.add(text);
        final i = texts.indexOf(text);
        onWords(timing[i]);
        return Uint8List.fromList([i + 1]);
      }
      final reader = TtsReader(player: player, synthesize: synth)..setCache(cache);
      addTearDown(reader.dispose);
      final sentences = <int>[];
      final words = <(int, int, int)>[];
      reader.onSentenceChanged = sentences.add;
      reader.onWordChanged = (start, end) { if (start >= 0) words.add((reader.currentIndex, start, end)); };
      reader.onLoadingChanged = (value) => loading = value;
      await reader.start(texts, offsets: [0, 20, 40]).timeout(const Duration(seconds: 3));
      positionMillis = 150;
      await waitUntil(() => words.contains((0, 0, 2)), 'first sentence must receive the timer position');
      positionMillis = 450;
      await waitUntil(() => words.contains((0, 2, 3)), 'first sentence must advance its word');
      // All future audio has been acquired before completing the current one.
      await waitUntil(() => diskHit || synthesized.length == 3, 'future sentences must finish prefetching');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      for (final position in [475, 485]) {
        positionMillis = position;
        await reader.pause();
        expect(reader.currentIndex, 0); expect(reader.currentWordStart, 2);
        expect(await reader.resume(), isTrue);
        expect(positionMillis, position, reason: 'Real AudioPlayer must seek the reloaded BytesSource before resume.');
        expect(reader.currentWordStart, 2);
      }
      expect(seeks, [475, 485]);
      holdNextPosition = true;
      await emit('audio.onComplete');
      await waitUntil(() => resumes == 4 && !loading, 'completion must start the prefetched next sentence');
      expect(delayedOldPosition, isNotNull);
      delayedOldPosition!.complete(6000);
      positionMillis = 150;
      await waitUntil(() => words.contains((1, 1, 3)), 'next sentence must recover from a delayed old position');
      positionMillis = 450;
      await waitUntil(() => words.contains((1, 3, 4)), 'next sentence must advance its own word');
      expect(sentences, [0, 1], reason: 'Reloading and seeking paused audio must not emit another sentence-start notification.');
      expect(sourceBytes, [1, 1, 1, 2]);
      expect(synthesized, diskHit ? isEmpty : orderedEquals(texts));
      await reader.stop();
    });
  }
}
