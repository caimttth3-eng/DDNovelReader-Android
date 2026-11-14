import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/models/speech_word.dart';
import 'package:duoduo_langdu/services/app_storage.dart';
import 'package:duoduo_langdu/services/edge_tts.dart';
import 'package:duoduo_langdu/services/system_tts.dart';
import 'package:duoduo_langdu/services/tts_cache_store.dart';
import 'package:duoduo_langdu/services/tts_reader.dart';

class _RatePlayer extends AudioPlayer {
  final completed = StreamController<void>.broadcast();
  final positions = StreamController<Duration>.broadcast();
  final starts = <Duration>[];
  final audio = <int>[];
  Duration clock = Duration.zero;
  bool _ready = false;
  _RatePlayer() { _ready = true; }
  @override
  Stream<void> get onPlayerComplete => _ready ? completed.stream : super.onPlayerComplete;
  @override
  Stream<Duration> get onPositionChanged => positions.stream;
  @override
  Future<Duration?> getCurrentPosition() async => clock;
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async { clock = Duration.zero; }
  @override
  Future<void> play(Source source, {double? volume, double? balance, AudioContext? ctx,
    Duration? position, PlayerMode? mode}) async {
    starts.add(position ?? Duration.zero);
    clock = position ?? Duration.zero;
    audio.add((source as BytesSource).bytes.first);
  }
  void tick(int milliseconds) {
    clock = Duration(milliseconds: milliseconds); positions.add(clock);
  }
  @override
  Future<void> dispose() async {
    await super.dispose(); await completed.close(); await positions.close();
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  Future<void> event(String name, Map<String, Object> data) async {
    final done = Completer<void>();
    messenger.handlePlatformMessage(SystemTtsClient.channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(name, data)), (_) => done.complete());
    await done.future;
  }
  Future<void> flush() async => Future<void>.delayed(const Duration(milliseconds: 10));
  setUp(() {
    messenger.setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers.global'), (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers.global/events'), (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers'), (call) async {
      if (call.method == 'create') messenger.setMockMethodCallHandler(
        MethodChannel('xyz.luan/audioplayers/events/${(call.arguments as Map)['playerId']}'), (_) async => null);
      return null;
    });
  });

  test('each 0.02 rate step has distinct synthesis, cache and saved values', () {
    for (final rate in [0.5, 0.52, 0.54, 1.0, 1.02, 1.04, 2.98, 3.0]) {
      final saved = ReadingSettings()..speechRate = rate;
      expect(ReadingSettings.fromJson(saved.toJson()).speechRate, rate);
      expect(TtsCacheStore('book', 'voice', rate).rateKey, rate.toStringAsFixed(2));
    }
    expect([edgeRateStr(0.5), edgeRateStr(0.52), edgeRateStr(0.54)], ['-50%', '-48%', '-46%']);
    expect([edgeRateStr(1), edgeRateStr(1.02), edgeRateStr(1.04)], ['+0%', '+2%', '+4%']);
  });

  test('playing rate change replaces audio at the same word and still advances', () async {
    final player = _RatePlayer(), requested = <(String, String)>[];
    Future<Uint8List> synth(String text, {required String voice, required String rate,
      required void Function(List<SpeechWord>) onWords, required EdgeSynthCancelToken cancelToken}) async {
      requested.add((text, rate));
      onWords([
        const SpeechWord(startMicros: 0, durationMicros: 1000000, textStart: 0, textEnd: 2, text: '甲乙'),
        SpeechWord(startMicros: rate == '+0%' ? 1200000 : 900000, durationMicros: 1000000,
          textStart: 2, textEnd: 4, text: '丙丁'),
      ]);
      return Uint8List.fromList([requested.length]);
    }
    final reader = TtsReader(player: player, synthesize: synth)..setPrefetchSentences(0);
    addTearDown(reader.dispose);
    await reader.setSpeechRate(1); await reader.start(['甲乙丙丁。', '下一句。']);
    player.tick(1300); await flush(); expect(reader.currentWordStart, 2);
    await reader.setSpeechRate(1.02);
    expect(requested, [('甲乙丙丁。', '+0%'), ('甲乙丙丁。', '+2%')]);
    expect(player.audio, [1, 2]);
    expect(player.starts.last, const Duration(milliseconds: 900),
      reason: 'Use the new word metadata, never the old audio time or an estimated ratio');
    expect(reader.currentWordStart, 2);
    player.completed.add(null); await flush();
    expect(reader.currentIndex, 1); expect(requested.last, ('下一句。', '+2%'));
    await reader.setSpeechRate(1.04);
    expect(requested.last, ('下一句。', '+4%'));
    player.completed.add(null); await flush(); expect(reader.state, TtsState.stopped);
  });

  test('paused rate changes retain the word anchor until explicit resume', () async {
    final player = _RatePlayer(), rates = <String>[];
    Future<Uint8List> synth(String text, {required String voice, required String rate,
      required void Function(List<SpeechWord>) onWords, required EdgeSynthCancelToken cancelToken}) async {
      rates.add(rate); onWords([const SpeechWord(startMicros: 500000, durationMicros: 1000000,
        textStart: 2, textEnd: 4, text: '丙丁')]);
      return Uint8List.fromList([rates.length]);
    }
    final reader = TtsReader(player: player, synthesize: synth)..setPrefetchSentences(0);
    addTearDown(reader.dispose);
    await reader.setSpeechRate(1); await reader.start(['甲乙丙丁。']);
    player.tick(600); await flush(); await reader.pause();
    await reader.setSpeechRate(1.02); await reader.setSpeechRate(1.04);
    expect(reader.state, TtsState.paused); expect(rates, ['+0%']);
    expect(await reader.resume(), isTrue); expect(rates, ['+0%', '+4%']);
    expect(player.starts.last, const Duration(milliseconds: 500));
    await reader.setSpeechRate(1.04); expect(rates.length, 2);
  });

  test('without word metadata a new rate honestly restarts at sentence start', () async {
    final player = _RatePlayer();
    Future<Uint8List> synth(String text, {required String voice, required String rate,
      required void Function(List<SpeechWord>) onWords, required EdgeSynthCancelToken cancelToken}) async {
      onWords([]); return Uint8List.fromList([1]);
    }
    final reader = TtsReader(player: player, synthesize: synth)..setPrefetchSentences(0);
    addTearDown(reader.dispose);
    await reader.start(['甲乙丙丁。']); player.tick(1800); await flush();
    await reader.setSpeechRate(0.52); expect(player.starts, [Duration.zero, Duration.zero]);
  });

  test('stop cancels an in-flight replacement at a finer rate', () async {
    final player = _RatePlayer(), gates = <Completer<Uint8List>>[];
    Future<Uint8List> synth(String text, {required String voice, required String rate,
      required void Function(List<SpeechWord>) onWords, required EdgeSynthCancelToken cancelToken}) {
      onWords([]); final gate = Completer<Uint8List>(); gates.add(gate); return gate.future;
    }
    final reader = TtsReader(player: player, synthesize: synth)..setPrefetchSentences(0);
    addTearDown(reader.dispose);
    final first = reader.start(['原句。']); await flush();
    final replacement = reader.setSpeechRate(0.52); await flush(); expect(gates.length, 2);
    await reader.stop();
    for (final gate in gates) { gate.complete(Uint8List.fromList([1])); }
    await first; await replacement;
    expect(player.audio, isEmpty); expect(reader.state, TtsState.stopped);
  });

  test('rapid rate changes retain the word cursor while replacement synthesis is pending', () async {
    final player = _RatePlayer(), gates = <Completer<Uint8List>>[], rates = <String>[];
    Future<Uint8List> synth(String text, {required String voice, required String rate,
      required void Function(List<SpeechWord>) onWords, required EdgeSynthCancelToken cancelToken}) async {
      rates.add(rate);
      onWords([const SpeechWord(startMicros: 700000, durationMicros: 1000000,
        textStart: 2, textEnd: 4, text: '丙丁')]);
      if (rates.length == 1) return Uint8List.fromList([1]);
      final gate = Completer<Uint8List>(); gates.add(gate); return gate.future;
    }
    final reader = TtsReader(player: player, synthesize: synth)..setPrefetchSentences(0);
    addTearDown(reader.dispose);
    await reader.setSpeechRate(1); await reader.start(['甲乙丙丁。']);
    player.tick(800); await flush();
    final first = reader.setSpeechRate(1.02); await flush();
    final second = reader.setSpeechRate(1.04); await flush();
    expect(rates, ['+0%', '+2%', '+4%']);
    gates.last.complete(Uint8List.fromList([3])); await second;
    gates.first.complete(Uint8List.fromList([2])); await first;
    expect(player.audio, [1, 3]); expect(player.starts.last, const Duration(milliseconds: 700));
    expect(reader.currentWordStart, 2);
  });

  test('changing rate during punctuation silence does not repeat the completed sentence', () async {
    final player = _RatePlayer(), requested = <(String, String)>[];
    Future<Uint8List> synth(String text, {required String voice, required String rate,
      required void Function(List<SpeechWord>) onWords, required EdgeSynthCancelToken cancelToken}) async {
      requested.add((text, rate)); onWords([]); return Uint8List.fromList([1]);
    }
    final reader = TtsReader(player: player, synthesize: synth)..setPrefetchSentences(0);
    addTearDown(reader.dispose);
    await reader.setSpeechRate(1); await reader.start(['已经读完。', '下一句。'], pauseAfterMilliseconds: [1000, 0]);
    player.completed.add(null); await flush(); await reader.pause();
    await reader.setSpeechRate(1.02);
    expect(requested, [('已经读完。', '+0%')]); expect(await reader.resume(), isTrue);
    expect(requested.length, 1);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(requested, [('已经读完。', '+0%'), ('下一句。', '+2%')]);
  });

  test('system receives 0.02 steps and keeps its exact reported sentence cursor', () async {
    final spoken = <Map>[], player = _RatePlayer();
    messenger.setMockMethodCallHandler(SystemTtsClient.channel, (call) async {
      if (call.method == 'initialize') return 'default';
      if (call.method == 'speak') {
        final data = call.arguments as Map; spoken.add(data);
        await event('start', {'id': data['id'] as String});
      }
      return null;
    });
    final reader = TtsReader(player: player)..setVoice(TtsReader.systemVoice);
    addTearDown(reader.dispose);
    await reader.setSpeechRate(1); await reader.start(['甲乙丙丁戊己。', '下一句。']);
    await event('range', {'id': spoken.last['id'] as String, 'start': 2, 'end': 4});
    await reader.setSpeechRate(1.02);
    expect(spoken.last['rate'], 1.02); expect(spoken.last['text'], '丙丁戊己。');
    await event('range', {'id': spoken.last['id'] as String, 'start': 2, 'end': 4});
    await reader.pause(); await reader.setSpeechRate(1.04);
    expect(spoken.length, 2); expect(await reader.resume(), isTrue);
    expect(spoken.last['rate'], 1.04); expect(spoken.last['text'], '戊己。');
    await event('done', {'id': spoken.last['id'] as String}); await flush();
    expect(spoken.last['text'], '下一句。'); expect(spoken.last['rate'], 1.04);
  });
}
