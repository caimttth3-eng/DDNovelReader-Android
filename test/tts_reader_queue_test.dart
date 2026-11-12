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

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
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
