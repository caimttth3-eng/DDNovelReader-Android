import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/services/system_tts.dart';
import 'package:duoduo_langdu/services/tts_reader.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  final spoken = <Map>[];
  Completer<void>? queued;
  Future<void> emit(String event, Map data) async {
    final done = Completer<void>();
    messenger.handlePlatformMessage(SystemTtsClient.channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(event, data)), (_) => done.complete());
    await done.future;
  }
  setUp(() {
    calls.clear(); spoken.clear(); queued = null;
    messenger.setMockMethodCallHandler(SystemTtsClient.channel, (call) async {
      calls.add(call);
      if (call.method == 'initialize') return 'phone-default-engine';
      if (call.method == 'speak') { spoken.add(call.arguments as Map); queued?.complete(); queued = null; }
      return null;
    });
    messenger.setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers.global'), (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers.global/events'), (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers'), (call) async {
      if (call.method == 'create') {
        messenger.setMockMethodCallHandler(MethodChannel('xyz.luan/audioplayers/events/${(call.arguments as Map)['playerId']}'), (_) async => null);
      }
      return null;
    });
  });
  test('system voice uses phone engine, range callbacks, pause and sentence continuation', () async {
    final reader = TtsReader()..setVoice(TtsReader.systemVoice);
    final words = <(int,int)>[];
    reader.onWordChanged = (s,e) => words.add((s,e));
    queued = Completer<void>(); final firstQueued = queued!.future;
    final playback = reader.start(['你好世界。', '下一句。']);
    await firstQueued;
    final firstId = spoken.first['id'];
    expect(spoken.first['text'], '你好世界。');
    await emit('start', {'id': firstId}); await playback;
    await emit('range', {'id': firstId, 'start': 0, 'end': 2});
    expect(words.last, (0,2));
    queued = Completer<void>(); final secondQueued = queued!.future;
    await emit('done', {'id': firstId}); await secondQueued;
    expect(reader.currentIndex, 1); expect(spoken.last['text'], '下一句。');
    await emit('done', {'id': firstId});
    expect(reader.currentIndex, 1, reason: 'Stale utterance callbacks must be ignored');
    await emit('start', {'id': spoken.last['id']});
    await reader.pause(); expect(reader.state, TtsState.paused);
    expect(calls.where((c) => c.method == 'stop'), isNotEmpty);
    queued = Completer<void>(); final resumedQueued = queued!.future;
    final resumed = reader.resume(); await resumedQueued;
    expect(spoken.last['text'], '下一句。');
    await emit('start', {'id': spoken.last['id']}); expect(await resumed, isTrue);
    await reader.stop(); expect(reader.state, TtsState.stopped);
    await reader.dispose();
  });
  test('stopping during engine initialization cannot start delayed speech', () async {
    final initialized = Completer<void>();
    messenger.setMockMethodCallHandler(SystemTtsClient.channel, (call) async {
      if (call.method == 'initialize') { await initialized.future; return 'engine'; }
      calls.add(call); return null;
    });
    final client = SystemTtsClient();
    final speaking = client.speak('不要延迟播放', 1, onDone: () {}, onRange: (_,__) {}, onError: (_) {});
    final expected = expectLater(speaking, throwsA(isA<SystemSpeechCancelled>()));
    await client.stop(); initialized.complete(); await expected;
    expect(calls.where((c) => c.method == 'speak'), isEmpty);
    await client.dispose();
  });
  test('unconfigured system engine reports engine failure without skipping text', () async {
    messenger.setMockMethodCallHandler(SystemTtsClient.channel, (call) async {
      throw PlatformException(code: 'no_engine');
    });
    final reader = TtsReader()..setVoice(TtsReader.systemVoice);
    var failures = 0; final loading = <bool>[];
    reader.onError = () => failures++;
    reader.onLoadingChanged = loading.add;
    await reader.start(['第一句。', '第二句。']);
    expect(failures, 1); expect(reader.currentIndex, 0);
    expect(reader.lastFailure, isA<PlatformException>());
    expect(reader.state, TtsState.stopped); expect(loading.last, isFalse);
    await reader.dispose();
  });
}
