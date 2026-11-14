import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/models/speech_word.dart';
import 'package:duoduo_langdu/services/edge_tts.dart';
import 'package:duoduo_langdu/services/tts_reader.dart';

// Keep queue/indicator timing under the widget clock without constructing the
// plugin singleton in another FakeAsync zone. TtsReader itself remains real.
class _QueuePlayer implements AudioPlayer {
  final completed = StreamController<void>.broadcast(sync: true);
  final played = <int>[];
  @override PositionUpdater? positionUpdater;
  @override Stream<void> get onPlayerComplete => completed.stream;
  @override Stream<Duration> get onPositionChanged => const Stream<Duration>.empty();
  @override Future<Duration?> getCurrentPosition() async => Duration.zero;
  @override Future<void> stop() async {}
  @override Future<void> pause() async {}
  @override Future<void> play(Source source, {double? volume, double? balance, AudioContext? ctx,
    Duration? position, PlayerMode? mode}) async {
    played.add((source as BytesSource).bytes.first);
  }
  @override Future<void> dispose() async {
    positionUpdater?.dispose();
    unawaited(completed.close());
  }
  @override dynamic noSuchMethod(Invocation invocation) =>
    throw StateError('Unexpected queue-player operation: ${invocation.memberName}');
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.ddnovelreader/system_tts'), (_) async => null);
    await Future<void>.delayed(Duration.zero);
  });
  tearDown(() => binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('com.ddnovelreader/system_tts'), null));

  Future<void> flushZeroTime(WidgetTester tester) async {
    // StreamSubscription.cancel and constructor-created completed Futures can
    // dispatch in the real setup zone. Drain that zone and FakeAsync without
    // advancing the virtual clock: an old 80/200 ms worker delay must not pass.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }

  Future<void> waitZeroTime(WidgetTester tester, bool Function() ready, String reason) async {
    for (var attempt = 0; attempt < 40 && !ready(); attempt++) { await flushZeroTime(tester); }
    expect(ready(), isTrue, reason: reason);
  }

  Future<void> disposeReader(WidgetTester tester, TtsReader reader) async {
    var finished = false;
    Object? failure;
    reader.dispose().then((_) { finished = true; }, onError: (Object error) { failure = error; finished = true; });
    await waitZeroTime(tester, () => finished, 'Reader cleanup must complete while both async zones are drained.');
    if (failure != null) throw failure!;
  }

  testWidgets('prefetch fills and refills immediately and ready transitions never reload or flash loading', (tester) async {
    final player = _QueuePlayer(), requested = <String>[], loading = <bool>[];
    Future<Uint8List> synth(String text, {required String voice, required String rate,
      required void Function(List<SpeechWord>) onWords, required EdgeSynthCancelToken cancelToken}) async {
      requested.add(text); onWords([]); return Uint8List.fromList([int.parse(text)]);
    }
    final reader = TtsReader(player: player, synthesize: synth)..setPrefetchSentences(2);
    reader.onLoadingChanged = loading.add;
    try {
    var started = false;
    unawaited(reader.start(['0', '1', '2', '3']).then((_) { started = true; }));
    await waitZeroTime(tester, () => started && requested.length == 3, 'Start and both prefetches must settle without advancing virtual time.');
    expect(started, isTrue);
    expect(requested, ['0', '1', '2'], reason: 'A ready successor must not pay an arbitrary 80 ms delay.');
    expect(player.played, [0]); expect(loading.where((value) => value), isEmpty);
    player.completed.add(null);
    await waitZeroTime(tester, () => player.played.length == 2 && requested.length == 4, 'The next sentence and refilled window must settle without a worker timer.');
    expect(player.played, [0, 1]);
    expect(requested, ['0', '1', '2', '3'], reason: 'Advancing must replenish the full window without a polling delay.');
    for (var i = 0; i < 2; i++) {
      player.completed.add(null);
      await waitZeroTime(tester, () => player.played.length == i + 3, 'A prefetched sentence must settle without advancing virtual time.');
    }
    expect(player.played, [0, 1, 2, 3]);
    expect(requested, ['0', '1', '2', '3'], reason: 'Every prefetched sentence is synthesized exactly once.');
    expect(loading.where((value) => value), isEmpty, reason: 'Ready memory hits are not network loads.');
    // A completed window and a settled loading indicator should have no
    // periodic worker left that changes state while the same audio plays.
    await tester.pump(const Duration(seconds: 1));
    expect(requested, ['0', '1', '2', '3']);
    } finally { await disposeReader(tester, reader); }
  }, timeout: const Timeout(Duration(seconds: 45)));

  testWidgets('foreground joins an in-flight prefetch and reports only a genuine wait', (tester) async {
    final player = _QueuePlayer(), requested = <String>[], loading = <bool>[];
    final next = Completer<Uint8List>();
    EdgeSynthCancelToken? nextToken;
    Future<Uint8List> synth(String text, {required String voice, required String rate,
      required void Function(List<SpeechWord>) onWords, required EdgeSynthCancelToken cancelToken}) {
      requested.add(text); onWords([]);
      if (text == '1') { nextToken = cancelToken; return next.future; }
      return Future.value(Uint8List.fromList([int.parse(text)]));
    }
    final reader = TtsReader(player: player, synthesize: synth)..setPrefetchSentences(1);
    reader.onLoadingChanged = loading.add;
    try {
    unawaited(reader.start(['0', '1', '2']));
    await waitZeroTime(tester, () => requested.length == 2 && player.played.length == 1, 'Initial playback must finish before testing the pending successor.');
    expect(requested, ['0', '1']);
    loading.clear(); player.completed.add(null); await flushZeroTime(tester);
    expect(reader.currentIndex, 1); expect(player.played, [0]);
    expect(requested, ['0', '1']); expect(nextToken!.cancelled, isFalse);
    await tester.pump(const Duration(milliseconds: 100));
    expect(loading.where((value) => value), isEmpty);
    await tester.pump(const Duration(milliseconds: 60));
    expect(loading.last, isTrue, reason: 'A still-pending synthesis must remain visible to the user.');
    next.complete(Uint8List.fromList([1]));
    await waitZeroTime(tester, () => player.played.length == 2 && requested.length == 3 && loading.isNotEmpty && !loading.last, 'Ready audio must finish the real pending request and clear loading.');
    expect(player.played, [0, 1]); expect(loading.last, isFalse);
    expect(requested, ['0', '1', '2'], reason: 'The foreground reuses the same transport rather than canceling or duplicating it.');
    } finally {
      if (!next.isCompleted) next.complete(Uint8List.fromList([1]));
      await disposeReader(tester, reader);
    }
  }, timeout: const Timeout(Duration(seconds: 45)));

  testWidgets('stop cancels a delayed indicator and stale prefetch cannot fill a new voice or rate queue', (tester) async {
    final player = _QueuePlayer(), loading = <bool>[];
    final oldPrefetch = Completer<Uint8List>();
    EdgeSynthCancelToken? oldToken;
    final requests = <(String, String, String)>[];
    Future<Uint8List> synth(String text, {required String voice, required String rate,
      required void Function(List<SpeechWord>) onWords, required EdgeSynthCancelToken cancelToken}) {
      requests.add((text, voice, rate)); onWords([]);
      if (voice == TtsReader.defaultVoice && text == '1') {
        oldToken = cancelToken; return oldPrefetch.future;
      }
      final marker = voice == TtsReader.defaultVoice ? 0 : rate == '-50%' ? 10 : 20;
      return Future.value(Uint8List.fromList([marker + int.parse(text)]));
    }
    final reader = TtsReader(player: player, synthesize: synth)..setPrefetchSentences(1);
    reader.onLoadingChanged = loading.add;
    try {
    unawaited(reader.start(['0', '1']));
    await waitZeroTime(tester, () => requests.length == 2 && player.played.length == 1, 'The old voice must reach its actual pending prefetch.');
    expect(requests, [('0', TtsReader.defaultVoice, '-50%'), ('1', TtsReader.defaultVoice, '-50%')]);
    reader.setVoice('zh-CN-YunxiNeural');
    unawaited(reader.start(['0', '1']));
    await waitZeroTime(tester, () => requests.length == 4 && player.played.length == 2, 'New voice audio and its own prefetch must replace the old queue.');
    expect(oldToken!.cancelled, isTrue);
    oldPrefetch.complete(Uint8List.fromList([99])); await flushZeroTime(tester);
    player.completed.add(null);
    await waitZeroTime(tester, () => player.played.length == 3, 'The prefetched new voice must enter playback.');
    expect(player.played, [0, 10, 11], reason: 'An old voice must never replace a newly prefetched voice.');
    unawaited(reader.setSpeechRate(1.1));
    await waitZeroTime(tester, () => player.played.length == 4, 'Changing rate must replace playback with a newly scoped request.');
    expect(player.played.last, 21);
    expect(requests.last, ('1', 'zh-CN-YunxiNeural', '+10%'));
    unawaited(reader.stop());
    await waitZeroTime(tester, () => reader.state == TtsState.stopped, 'Stop must settle before checking delayed-indicator cancellation.');
    loading.clear(); await tester.pump(const Duration(seconds: 1));
    expect(loading, isEmpty); expect(reader.state, TtsState.stopped);
    } finally {
      if (!oldPrefetch.isCompleted) oldPrefetch.complete(Uint8List.fromList([99]));
      await disposeReader(tester, reader);
    }
  }, timeout: const Timeout(Duration(seconds: 45)));
}
