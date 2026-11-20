import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/services/system_tts.dart';
import 'package:duoduo_langdu/services/tts_reader.dart';

class _FocusPlayer implements AudioPlayer {
  final List<String> events;
  final completed = StreamController<void>.broadcast(sync: true);
  bool audible = false;
  bool failPlayback = false;
  Completer<void>? disposeGate;
  _FocusPlayer(this.events);
  @override PositionUpdater? positionUpdater;
  @override Stream<void> get onPlayerComplete => completed.stream;
  @override Stream<Duration> get onPositionChanged => const Stream.empty();
  @override Future<Duration?> getCurrentPosition() async => Duration.zero;
  @override Future<void> stop() async { audible = false; events.add('player.stop'); }
  @override Future<void> pause() async { audible = false; events.add('player.pause'); }
  @override Future<void> play(Source source, {double? volume, double? balance, AudioContext? ctx,
    Duration? position, PlayerMode? mode}) async {
    expectSync(ctx!.android.audioFocus, AndroidAudioFocus.none,
      reason: 'audio_session, not audioplayers, owns the Android focus listener.');
    if (failPlayback) throw StateError('native playback failed');
    audible = true; events.add('player.play');
  }
  @override Future<void> dispose() async {
    events.add('player.dispose'); await disposeGate?.future;
    audible = false; positionUpdater?.dispose(); await completed.close();
  }
  @override dynamic noSuchMethod(Invocation invocation) => throw StateError('$invocation');
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  const focusChannel = MethodChannel('com.ryanheise.android_audio_manager');
  final events = <String>[];
  bool grantFocus = true;
  Completer<bool>? activationGate;
  Future<void> emit(String event, Map data) async {
    final done = Completer<void>();
    messenger.handlePlatformMessage(SystemTtsClient.channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(event, data)), (_) => done.complete());
    await done.future;
  }
  Future<bool> activate(bool active) async =>
      await focusChannel.invokeMethod<bool>(active ? 'requestAudioFocus' : 'abandonAudioFocus') ?? false;
  Future<void> flush() async {
    for (var i = 0; i < 20; i++) { await Future<void>.delayed(Duration.zero); }
  }
  Future<void> waitFor(bool Function() ready) async {
    for (var i = 0; i < 100 && !ready(); i++) { await flush(); }
    expect(ready(), isTrue);
  }
  setUp(() {
    events.clear(); grantFocus = true; activationGate = null;
    messenger.setMockMethodCallHandler(focusChannel, (call) async {
      final active = call.method == 'requestAudioFocus';
      events.add('focus.$active');
      if (active && activationGate != null) return await activationGate!.future;
      return active ? grantFocus : true;
    });
    messenger.setMockMethodCallHandler(SystemTtsClient.channel, (call) async {
      if (call.method == 'speak') {
        events.add('system.speak');
        scheduleMicrotask(() => emit('start', {'id': (call.arguments as Map)['id']}));
      }
      if (call.method == 'stop') events.add('system.stop');
      return null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(focusChannel, null);
    messenger.setMockMethodCallHandler(SystemTtsClient.channel, null);
  });

  for (final system in [false, true]) {
    test('focus owns ${system ? 'system' : 'online'} start interruption manual pause resume and stop', () async {
      final player = _FocusPlayer(events);
      final reader = TtsReader(player: player, activateAudioSession: activate,
        synthesize: (text, {required voice, required rate, required onWords, required cancelToken}) async => Uint8List.fromList([1]))
        ..setPrefetchSentences(0);
      if (system) reader.setVoice(TtsReader.systemVoice);
      addTearDown(reader.dispose);
      await reader.start(['甲乙。']);
      expect(reader.lastFailure, isNull, reason: events.join(', '));
      final play = system ? 'system.speak' : 'player.play';
      expect(events.indexOf('focus.true'), lessThan(events.indexOf(play)));
      await reader.pause(interrupted: true);
      expect(reader.state, TtsState.paused);
      expect(events.where((event) => event == 'focus.false'), isEmpty);
      final manualPause = reader.pause();
      reader.setVoice(system ? '${SystemTtsClient.voicePrefix}selected' : 'other-online-voice');
      await manualPause;
      expect(events.last, 'focus.false', reason: 'Manual pause revokes transient ownership even when already paused.');
      events.clear();
      expect(await reader.resume(), isTrue);
      expect(reader.state, TtsState.playing);
      expect(events.indexOf('focus.true'), lessThan(events.indexOf(play)));
      await reader.stop();
      expect(events.last, 'focus.false');
      expect(player.audible, isFalse);
      expect(reader.state, TtsState.stopped);
    });
  }

  test('interrupted resume reacquires focus and denied focus never reports playback', () async {
    final player = _FocusPlayer(events);
    final reader = TtsReader(player: player, activateAudioSession: activate,
      synthesize: (text, {required voice, required rate, required onWords, required cancelToken}) async => Uint8List.fromList([1]));
    addTearDown(reader.dispose);
    await reader.start(['甲。']);
    await reader.pause(interrupted: true);
    grantFocus = false;
    expect(await reader.resume(), isFalse);
    expect(reader.state, TtsState.stopped);
    expect(player.audible, isFalse);
    await flush();
    expect(events.where((event) => event == 'focus.true'), hasLength(2));
    expect(events.last, 'focus.false');
  });

  test('pending focus acquisition is drained and released by stop', () async {
    activationGate = Completer<bool>();
    final player = _FocusPlayer(events);
    final reader = TtsReader(player: player, activateAudioSession: activate,
      synthesize: (text, {required voice, required rate, required onWords, required cancelToken}) async => Uint8List.fromList([1]));
    addTearDown(reader.dispose);
    final starting = reader.start(['甲。']);
    await waitFor(() => events.contains('focus.true'));
    final stopping = reader.stop();
    await flush();
    expect(events, isNot(contains('player.play')));
    activationGate!.complete(true);
    await Future.wait([starting, stopping]);
    expect(events.last, 'focus.false');
    expect(reader.state, TtsState.stopped);
  });

  test('manual pause cancels pending activation and preserves a page-start suffix for resume', () async {
    activationGate = Completer<bool>();
    final requested = <String>[];
    final reader = TtsReader(player: _FocusPlayer(events), activateAudioSession: activate,
      synthesize: (text, {required voice, required rate, required onWords, required cancelToken}) async {
        requested.add(text); return Uint8List.fromList([1]);
      });
    addTearDown(reader.dispose);
    final starting = reader.start(['甲乙丙丁。'], initialTtsOffset: 2);
    await waitFor(() => events.contains('focus.true'));
    final pausing = reader.pause();
    activationGate!.complete(true);
    await Future.wait([starting, pausing]);
    expect(reader.state, TtsState.paused);
    expect(events.last, 'focus.false');
    expect(requested, isEmpty);
    expect(await reader.resume(), isTrue);
    expect(requested, ['丙丁。']);
  });

  test('a stale stop cannot release a newer generation focus', () async {
    activationGate = Completer<bool>();
    final reader = TtsReader(player: _FocusPlayer(events), activateAudioSession: activate,
      synthesize: (text, {required voice, required rate, required onWords, required cancelToken}) async => Uint8List.fromList([1]));
    addTearDown(reader.dispose);
    final first = reader.start(['旧。']);
    await waitFor(() => events.contains('focus.true'));
    final stopping = reader.stop();
    final next = reader.start(['新。']);
    activationGate!.complete(true);
    await Future.wait([first, stopping, next]);
    expect(reader.state, TtsState.playing);
    expect(events, isNot(contains('focus.false')));
    await reader.stop();
    expect(events.last, 'focus.false');
  });

  test('natural chapter handoff keeps focus but playback errors and disposal release it', () async {
    final player = _FocusPlayer(events);
    final reader = TtsReader(player: player, activateAudioSession: activate,
      synthesize: (text, {required voice, required rate, required onWords, required cancelToken}) async => Uint8List.fromList([1]));
    Future<void>? chapter;
    reader.onCompleted = () { chapter = reader.start(['乙。'], chapterIndex: 1); };
    await reader.start(['甲。']);
    player.completed.add(null);
    await waitFor(() => chapter != null);
    await chapter;
    expect(events.where((event) => event == 'focus.true'), hasLength(2));
    expect(events, isNot(contains('focus.false')));
    await reader.pause();
    player.failPlayback = true;
    expect(await reader.resume(), isFalse);
    await flush();
    expect(events.last, 'focus.false');
    player.failPlayback = false;
    await reader.start(['丙。']);
    await reader.dispose();
    expect(events.last, 'focus.false');
    expect(player.audible, isFalse);
  });

  test('late disposal of a previous reader cannot release the replacement reader focus', () async {
    final previousPlayer = _FocusPlayer(events);
    TtsReader makeReader(_FocusPlayer player) => TtsReader(player: player, activateAudioSession: activate,
      synthesize: (text, {required voice, required rate, required onWords, required cancelToken}) async => Uint8List.fromList([1]));
    final previous = makeReader(previousPlayer);
    await previous.start(['旧。']);
    previousPlayer.disposeGate = Completer<void>();
    final disposing = previous.dispose();
    await waitFor(() => events.contains('player.dispose'));
    final next = makeReader(_FocusPlayer(events));
    addTearDown(next.dispose);
    await next.start(['新。']);
    previousPlayer.disposeGate!.complete();
    await disposing;
    expect(events, isNot(contains('focus.false')));
    expect(next.state, TtsState.playing);
    await next.stop();
    expect(events.last, 'focus.false');
  });

  for (var clock = 0; clock < 2; clock++) {
    testWidgets('settled focus queue does not retain widget clock $clock', (tester) async {
      Future<void> settle(Future<void> operation) async {
        var finished = false;
        Object? failure;
        operation.then((_) { finished = true; }, onError: (Object error) { failure = error; finished = true; });
        for (var attempt = 0; attempt < 40 && !finished; attempt++) {
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pump();
        }
        expect(finished, isTrue, reason: 'A settled previous focus queue must not require pumping another test clock.');
        if (failure != null) throw failure!;
      }
      final reader = TtsReader(player: _FocusPlayer(events), activateAudioSession: activate,
        synthesize: (text, {required voice, required rate, required onWords, required cancelToken}) async => Uint8List.fromList([1]));
      try {
        await settle(reader.start(['甲。']));
        expect(reader.lastFailure, isNull, reason: events.join(', '));
        expect(reader.state, TtsState.playing);
      } finally {
        await settle(reader.dispose());
      }
      expect(events.last, 'focus.false');
    });
  }
}
