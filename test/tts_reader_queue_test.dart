import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/models/speech_word.dart';
import 'package:duoduo_langdu/services/edge_tts.dart';
import 'package:duoduo_langdu/services/tts_reader.dart';

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
}
