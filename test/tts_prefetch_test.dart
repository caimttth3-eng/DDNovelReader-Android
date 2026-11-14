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
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('prefetch fills and refills immediately and ready transitions never reload or flash loading', (tester) async {
    final player = _QueuePlayer(), requested = <String>[], loading = <bool>[];
    Future<Uint8List> synth(String text, {required String voice, required String rate,
      required void Function(List<SpeechWord>) onWords, required EdgeSynthCancelToken cancelToken}) async {
      requested.add(text); onWords([]); return Uint8List.fromList([int.parse(text)]);
    }
    final reader = TtsReader(player: player, synthesize: synth)..setPrefetchSentences(2);
    addTearDown(reader.dispose);
    reader.onLoadingChanged = loading.add;
    var started = false;
    unawaited(reader.start(['0', '1', '2', '3']).then((_) { started = true; }));
    await tester.pump();
    expect(started, isTrue);
    expect(requested, ['0', '1', '2'], reason: 'A ready successor must not pay an arbitrary 80 ms delay.');
    expect(player.played, [0]); expect(loading.where((value) => value), isEmpty);
    player.completed.add(null); await tester.pump();
    expect(player.played, [0, 1]);
    expect(requested, ['0', '1', '2', '3'], reason: 'Advancing must replenish the full window without a polling delay.');
    for (var i = 0; i < 2; i++) { player.completed.add(null); await tester.pump(); }
    expect(player.played, [0, 1, 2, 3]);
    expect(requested, ['0', '1', '2', '3'], reason: 'Every prefetched sentence is synthesized exactly once.');
    expect(loading.where((value) => value), isEmpty, reason: 'Ready memory hits are not network loads.');
    // A completed window and a settled loading indicator should have no
    // periodic worker left that changes state while the same audio plays.
    await tester.pump(const Duration(seconds: 1));
    expect(requested, ['0', '1', '2', '3']);
  });

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
    addTearDown(reader.dispose); reader.onLoadingChanged = loading.add;
    unawaited(reader.start(['0', '1', '2'])); await tester.pump();
    expect(requested, ['0', '1']);
    loading.clear(); player.completed.add(null); await tester.pump();
    expect(reader.currentIndex, 1); expect(player.played, [0]);
    expect(requested, ['0', '1']); expect(nextToken!.cancelled, isFalse);
    await tester.pump(const Duration(milliseconds: 100));
    expect(loading.where((value) => value), isEmpty);
    await tester.pump(const Duration(milliseconds: 60));
    expect(loading.last, isTrue, reason: 'A still-pending synthesis must remain visible to the user.');
    next.complete(Uint8List.fromList([1])); await tester.pump();
    expect(player.played, [0, 1]); expect(loading.last, isFalse);
    expect(requested, ['0', '1', '2'], reason: 'The foreground reuses the same transport rather than canceling or duplicating it.');
  });

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
    addTearDown(reader.dispose); reader.onLoadingChanged = loading.add;
    unawaited(reader.start(['0', '1'])); await tester.pump();
    expect(requests, [('0', TtsReader.defaultVoice, '-50%'), ('1', TtsReader.defaultVoice, '-50%')]);
    reader.setVoice('zh-CN-YunxiNeural');
    unawaited(reader.start(['0', '1'])); await tester.pump();
    expect(oldToken!.cancelled, isTrue);
    oldPrefetch.complete(Uint8List.fromList([99])); await tester.pump();
    player.completed.add(null); await tester.pump();
    expect(player.played, [0, 10, 11], reason: 'An old voice must never replace a newly prefetched voice.');
    unawaited(reader.setSpeechRate(1.1)); await tester.pump();
    expect(player.played.last, 21);
    expect(requests.last, ('1', 'zh-CN-YunxiNeural', '+10%'));
    unawaited(reader.stop()); await tester.pump();
    loading.clear(); await tester.pump(const Duration(seconds: 1));
    expect(loading, isEmpty); expect(reader.state, TtsState.stopped);
  });
}
