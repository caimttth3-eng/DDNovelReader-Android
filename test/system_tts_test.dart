import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/services/reading_text.dart';
import 'package:duoduo_langdu/services/speech_breaks.dart';
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
    expect(spoken.last['text'], '下一句。', reason: 'Without a range callback, resume honestly restarts the sentence');
    await emit('start', {'id': spoken.last['id']}); expect(await resumed, isTrue);
    await reader.stop(); expect(reader.state, TtsState.stopped);
    await reader.dispose();
  });
  test('configured comma extra silence is honored after native natural completion', () async {
    final p = ReadingText.paragraph('甲，乙。', pauseSettings:
      const SpeechPauseSettings().withPause(SpeechPauseKind.comma, 150));
    final reader = TtsReader()..setVoice(TtsReader.systemVoice);
    addTearDown(reader.dispose);
    queued = Completer<void>(); final initialQueued = queued!.future;
    final initial = reader.start(p.sentences.map((s) => s.tts).toList(),
      pauseAfterMilliseconds: p.sentences.map((s) => s.pauseAfterMilliseconds).toList());
    await initialQueued;
    expect(spoken.single['text'], '甲，', reason: 'The punctuation remains available for natural engine prosody');
    await emit('start', {'id': spoken.single['id']}); await initial;
    final next = Completer<void>(); queued = next;
    await emit('done', {'id': spoken.single['id']});
    expect(next.isCompleted, isFalse);
    expect(reader.currentIndex, 0);
    await next.future.timeout(const Duration(seconds: 3));
    expect(spoken.last['text'], '乙。');
    await emit('start', {'id': spoken.last['id']});
  });
  test('default dash and ellipsis delays precede continuation and paragraph delay precedes completion', () async {
    final p = ReadingText.paragraph('甲——乙……丙。');
    expect(p.sentences.map((s) => s.pauseAfterMilliseconds), [200, 200, 300]);
    final reader = TtsReader()..setVoice(TtsReader.systemVoice);
    addTearDown(reader.dispose);
    final completed = Completer<void>(); reader.onCompleted = completed.complete;
    queued = Completer<void>(); final firstQueued = queued!.future;
    final initial = reader.start(p.sentences.map((s) => s.tts).toList(),
      pauseAfterMilliseconds: p.sentences.map((s) => s.pauseAfterMilliseconds).toList());
    await firstQueued; await emit('start', {'id': spoken.last['id']}); await initial;
    for (var index = 0; index < 2; index++) {
      final next = Completer<void>(); queued = next;
      final clock = Stopwatch()..start();
      await emit('done', {'id': spoken.last['id']});
      expect(next.isCompleted, isFalse); expect(reader.currentIndex, index);
      await next.future.timeout(const Duration(seconds: 3));
      expect(clock.elapsedMilliseconds, greaterThanOrEqualTo(190));
      expect(reader.currentIndex, index + 1);
      await emit('start', {'id': spoken.last['id']});
    }
    final clock = Stopwatch()..start();
    await emit('done', {'id': spoken.last['id']});
    expect(completed.isCompleted, isFalse); expect(reader.state, TtsState.playing);
    await completed.future.timeout(const Duration(seconds: 3));
    expect(clock.elapsedMilliseconds, greaterThanOrEqualTo(290));
    expect(reader.state, TtsState.stopped);
  });
  test('stopping during engine initialization cannot start delayed speech', () async {
    final initialized = Completer<void>();
    final initializing = Completer<void>();
    messenger.setMockMethodCallHandler(SystemTtsClient.channel, (call) async {
      if (call.method == 'initialize') { initializing.complete(); await initialized.future; return 'engine'; }
      calls.add(call); return null;
    });
    final client = SystemTtsClient();
    final speaking = client.speak('不要延迟播放', 1, onDone: () {}, onRange: (_,__) {}, onError: (_) {});
    final expected = expectLater(speaking, throwsA(isA<SystemSpeechCancelled>()));
    await initializing.future;
    await client.stop(); initialized.complete(); await expected;
    expect(calls.where((c) => c.method == 'speak'), isEmpty);
    await client.dispose();
  });
  test('system pause continues at the latest word and resets its offset for the next sentence', () async {
    final reader = TtsReader()..setVoice(TtsReader.systemVoice);
    final words = <(int, int)>[];
    reader.onWordChanged = (s, e) => words.add((s, e));
    queued = Completer<void>(); final firstQueued = queued!.future;
    final playback = reader.start(['甲乙丙丁。', '下一句。']);
    await firstQueued;
    final firstId = spoken.last['id'];
    await emit('start', {'id': firstId}); await playback;
    await emit('range', {'id': firstId, 'start': 2, 'end': 4});
    expect(words.last, (2, 4));
    await reader.pause();
    await emit('range', {'id': firstId, 'start': 0, 'end': 2});
    queued = Completer<void>(); final resumedQueued = queued!.future;
    final resumed = reader.resume(); await resumedQueued;
    expect(spoken.last['text'], '丙丁。');
    final resumedId = spoken.last['id'];
    await emit('start', {'id': resumedId}); expect(await resumed, isTrue);
    await emit('range', {'id': resumedId, 'start': 1, 'end': 2});
    expect(words.last, (3, 4), reason: 'Resumed callbacks still address the original sentence');
    await reader.pause();
    queued = Completer<void>(); final againQueued = queued!.future;
    final again = reader.resume(); await againQueued;
    expect(spoken.last['text'], '丁。', reason: 'A second pause must preserve the accumulated offset');
    final againId = spoken.last['id'];
    await emit('start', {'id': againId}); expect(await again, isTrue);
    queued = Completer<void>(); final nextQueued = queued!.future;
    await emit('done', {'id': againId}); await nextQueued;
    expect(reader.currentIndex, 1);
    expect(spoken.last['text'], '下一句。', reason: 'A new sentence starts at its own beginning');
    await emit('start', {'id': spoken.last['id']});
    await reader.dispose();
  });
  test('system sentence cursor starts at visible text and survives pause, jump and next sentence', () async {
    final reader = TtsReader()..setVoice(TtsReader.systemVoice);
    addTearDown(reader.dispose);
    final ranges = <(int, int)>[];
    final announced = <(int, int)>[];
    reader.onWordChanged = (start, end) { if (start >= 0) ranges.add((start, end)); };
    reader.onSentenceChanged = (index) => announced.add((index, reader.currentTtsOffset));
    queued = Completer<void>(); var pending = queued!.future;
    final initial = reader.start(['前一句。', '甲乙丙丁戊己。', '下一句。'], from: 1, initialTtsOffset: 2);
    await pending;
    expect(spoken.last['text'], '丙丁戊己。');
    expect(announced, [(1, 2)], reason: 'UI must know the cursor before following the sentence.');
    var id = spoken.last['id']; await emit('start', {'id': id}); await initial;
    await reader.pause();
    queued = Completer<void>(); pending = queued!.future;
    final resumed = reader.resume(); await pending;
    expect(spoken.last['text'], '丙丁戊己。', reason: 'An engine without ranges must retain the explicitly requested cursor.');
    final stale = id; id = spoken.last['id']; await emit('start', {'id': id}); expect(await resumed, isTrue);
    await emit('range', {'id': id, 'start': 1, 'end': 3});
    expect(ranges.last, (3, 5)); expect(reader.currentTtsOffset, 3);
    await reader.pause();
    await reader.jumpTo(1, ttsOffset: 4);
    expect(reader.currentTtsOffset, 4);
    queued = Completer<void>(); pending = queued!.future;
    final afterJump = reader.resume(); await pending;
    expect(spoken.last['text'], '戊己。');
    id = spoken.last['id']; await emit('start', {'id': id}); expect(await afterJump, isTrue);
    await emit('range', {'id': stale, 'start': 0, 'end': 1});
    expect(reader.currentTtsOffset, 4, reason: 'An old utterance cannot replace the new cursor.');
    await emit('range', {'id': id, 'start': 0, 'end': 2}); expect(ranges.last, (4, 6));
    queued = Completer<void>(); pending = queued!.future;
    await emit('done', {'id': id}); await pending;
    expect(reader.currentIndex, 2); expect(reader.currentTtsOffset, 0);
    expect(spoken.last['text'], '下一句。');
    await emit('start', {'id': spoken.last['id']});
    queued = Completer<void>(); pending = queued!.future;
    final playingJump = reader.jumpTo(1, ttsOffset: 1); await pending;
    expect(spoken.last['text'], '乙丙丁戊己。');
    await emit('start', {'id': spoken.last['id']}); await playingJump;
    expect(reader.currentTtsOffset, 1);
  });
  test('a system visible cursor never starts inside a UTF-16 surrogate pair', () async {
    final reader = TtsReader()..setVoice(TtsReader.systemVoice);
    addTearDown(reader.dispose);
    queued = Completer<void>(); final pending = queued!.future;
    final started = reader.start(['甲😀乙。'], initialTtsOffset: 2);
    await pending;
    expect(reader.currentTtsOffset, 1); expect(spoken.last['text'], '😀乙。');
    await emit('start', {'id': spoken.last['id']}); await started;
  });
  test('chapter title numbers and spaces survive synthesis and stale cursors never select its last digit', () async {
    const title = '第 3 章 一寸金03';
    final p = ReadingText.paragraph(title);
    expect(p.sentences, hasLength(1)); expect(p.sentences.single.tts, title);
    expect(p.sentences.single.display, title); expect(p.sentenceStartTts, [0]);
    final reader = TtsReader()..setVoice(TtsReader.systemVoice);
    addTearDown(reader.dispose);
    for (final offset in [0, title.length, title.length + 20, -1]) {
      queued = Completer<void>(); final pending = queued!.future;
      final starting = reader.start([p.sentences.single.tts, '正文从这里开始。'], initialTtsOffset: offset);
      await pending;
      expect(spoken.last['text'], title, reason: 'Invalid cursor $offset must not become just the final digit');
      expect(reader.currentTtsOffset, 0); expect(reader.currentIndex, 0);
      await emit('start', {'id': spoken.last['id']}); await starting;
    }
    final middle = title.indexOf('一');
    queued = Completer<void>(); final pending = queued!.future;
    final starting = reader.start([title], initialTtsOffset: middle); await pending;
    expect(spoken.last['text'], '一寸金03'); expect(reader.currentTtsOffset, middle);
    final id = spoken.last['id']; await emit('start', {'id': id}); await starting;
    await emit('range', {'id': id, 'start': 3, 'end': 5});
    expect(reader.currentWordStart, title.indexOf('0')); expect(reader.currentWordEnd, title.length);
    await reader.pause();
    queued = Completer<void>(); final resumedQueued = queued!.future;
    final resumed = reader.resume(); await resumedQueued;
    expect(spoken.last['text'], '03', reason: 'A real reported digit-word cursor remains a valid resume position');
    await emit('start', {'id': spoken.last['id']}); expect(await resumed, isTrue);
    queued = Completer<void>(); final previousQueued = queued!.future;
    final previous = reader.start(['前一段。', title, '正文从这里开始。']); await previousQueued;
    final previousId = spoken.last['id']; await emit('start', {'id': previousId}); await previous;
    await emit('range', {'id': previousId, 'start': 2, 'end': 3});
    queued = Completer<void>(); final titleQueued = queued!.future;
    await emit('done', {'id': previousId}); await titleQueued;
    expect(spoken.last['text'], title); expect(reader.currentTtsOffset, 0);
    expect(reader.currentIndex, 1, reason: 'Natural advancement must not inherit the previous word cursor');
    await emit('start', {'id': spoken.last['id']});
  });
  test('native rejection returns promptly instead of waiting for the start timeout', () async {
    messenger.setMockMethodCallHandler(SystemTtsClient.channel, (call) async {
      if (call.method == 'initialize') return 'engine';
      if (call.method == 'speak') throw PlatformException(code: 'speak_failed');
      if (call.method == 'stop') throw PlatformException(code: 'engine_disappeared');
      return null;
    });
    final client = SystemTtsClient();
    await expectLater(client.speak('立即报告错误', 1, onDone: () {}, onRange: (_,__) {}, onError: (_) {})
      .timeout(const Duration(seconds: 1)), throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'speak_failed')));
    await client.dispose();
  });
  test('replacement speech cancels its predecessor and ignores stale ranges', () async {
    final client = SystemTtsClient();
    var rangeCalls = 0;
    queued = Completer<void>(); final firstQueued = queued!.future;
    final first = client.speak('旧请求', 1, onDone: () {}, onRange: (_,__) {}, onError: (_) {});
    final cancelled = expectLater(first, throwsA(isA<SystemSpeechCancelled>()));
    await firstQueued; final oldId = spoken.last['id'];
    queued = Completer<void>(); final secondQueued = queued!.future;
    final second = client.speak('新请求', 1, onDone: () {}, onRange: (_,__) => rangeCalls++, onError: (_) {});
    await secondQueued; await cancelled;
    final id = spoken.last['id'];
    await emit('range', {'id': oldId, 'start': 0, 'end': 1});
    await emit('range', {'id': id, 'start': -1, 'end': 1});
    expect(rangeCalls, 0);
    // Some engines provide a range callback before onStart. The range itself
    // is evidence that audio has begun and must release the loading state.
    await emit('range', {'id': id, 'start': 0, 'end': 1}); await second;
    expect(rangeCalls, 1);
    await client.dispose();
  });
  test('resumed system speech uses a suffix and reports original UTF-16 ranges', () async {
    final client = SystemTtsClient();
    final ranges = <(int, int)>[];
    queued = Completer<void>(); final firstQueued = queued!.future;
    final first = client.speak('甲😀乙。', 1, startOffset: 1,
      onDone: () {}, onRange: (s, e) => ranges.add((s, e)), onError: (_) {});
    await firstQueued;
    final oldId = spoken.last['id'];
    expect(spoken.last['text'], '😀乙。');
    await emit('range', {'id': oldId, 'start': 0, 'end': 2}); await first;
    expect(ranges, [(1, 3)]);
    await emit('range', {'id': oldId, 'start': 3, 'end': 5});
    expect(ranges, [(1, 3)], reason: 'Ranges are bounded by the suffix, not the original sentence');
    await client.stop();
    queued = Completer<void>(); final secondQueued = queued!.future;
    final second = client.speak('甲😀乙。', 1, startOffset: 3,
      onDone: () {}, onRange: (s, e) => ranges.add((s, e)), onError: (_) {});
    await secondQueued;
    final id = spoken.last['id'];
    expect(spoken.last['text'], '乙。');
    await emit('range', {'id': oldId, 'start': 0, 'end': 2});
    expect(ranges, [(1, 3)], reason: 'An earlier resumed request cannot change the new position');
    await emit('range', {'id': id, 'start': 0, 'end': 1}); await second;
    expect(ranges.last, (3, 4));
    await client.dispose();
  });
  test('system speech rejects invalid resume offsets before sending text', () async {
    final client = SystemTtsClient();
    for (final offset in [-1, 3]) {
      await expectLater(client.speak('一句。', 1, startOffset: offset,
        onDone: () {}, onRange: (_, __) {}, onError: (_) {}), throwsRangeError);
    }
    expect(spoken, isEmpty);
    await client.dispose();
  });
  test('punctuation-only ranges never turn a resume or rate change into a punctuation utterance', () async {
    final reader = TtsReader()..setVoice(TtsReader.systemVoice);
    addTearDown(reader.dispose);
    final words = <(int, int)>[]; reader.onWordChanged = (s, e) => words.add((s, e));
    queued = Completer<void>(); final firstQueued = queued!.future;
    final first = reader.start(['甲乙，丙丁。']);
    await firstQueued; final firstId = spoken.last['id'];
    await emit('start', {'id': firstId}); await first;
    await emit('range', {'id': firstId, 'start': 0, 'end': 2});
    await emit('range', {'id': firstId, 'start': 2, 'end': 3});
    expect(reader.currentTtsOffset, 0); expect(words.last, (0, 2));
    await reader.pause(); await reader.setSpeechRate(1.1);
    queued = Completer<void>(); final againQueued = queued!.future;
    final again = reader.resume(); await againQueued;
    expect(spoken.last['text'], '甲乙，丙丁。',
      reason: 'Keep punctuation inside its original word context, without deleting it');
    expect(spoken.last['rate'], 1.1);
    final againId = spoken.last['id'];
    await emit('start', {'id': againId}); expect(await again, isTrue);
    await emit('range', {'id': againId, 'start': 3, 'end': 5});
    await emit('range', {'id': againId, 'start': 5, 'end': 6});
    expect(reader.currentTtsOffset, 3); expect(words.last, (3, 5));
    await reader.pause();
    queued = Completer<void>(); final finalQueued = queued!.future;
    final resumed = reader.resume(); await finalQueued;
    expect(spoken.last['text'], '丙丁。', reason: 'Do not synthesize the final period by itself');
    await emit('start', {'id': spoken.last['id']}); expect(await resumed, isTrue);
  });
  test('pause and resume while a rate replacement is stopping retain the word cursor and reject old ranges', () async {
    Completer<void>? stopGate;
    final stopEntered = Completer<void>();
    messenger.setMockMethodCallHandler(SystemTtsClient.channel, (call) async {
      calls.add(call);
      if (call.method == 'initialize') return 'phone-default-engine';
      if (call.method == 'stop' && stopGate != null) {
        if (!stopEntered.isCompleted) stopEntered.complete();
        await stopGate!.future;
      }
      if (call.method == 'speak') { spoken.add(call.arguments as Map); queued?.complete(); queued = null; }
      return null;
    });
    final reader = TtsReader()..setVoice(TtsReader.systemVoice);
    addTearDown(reader.dispose);
    queued = Completer<void>(); final firstQueued = queued!.future;
    final first = reader.start(['甲乙丙丁戊己。']);
    await firstQueued; final oldId = spoken.last['id'];
    await emit('start', {'id': oldId}); await first;
    await emit('range', {'id': oldId, 'start': 2, 'end': 4});
    stopGate = Completer<void>();
    final changingRate = reader.setSpeechRate(1.1); await stopEntered.future;
    final pausing = reader.pause();
    queued = Completer<void>(); final resumedQueued = queued!.future;
    final resuming = reader.resume();
    await emit('range', {'id': oldId, 'start': 0, 'end': 2});
    stopGate!.complete(); await changingRate; await pausing; await resumedQueued;
    expect(spoken.last['rate'], 1.1); expect(spoken.last['text'], '丙丁戊己。');
    expect(reader.currentTtsOffset, 2);
    await emit('start', {'id': spoken.last['id']}); expect(await resuming, isTrue);
    await emit('range', {'id': oldId, 'start': 4, 'end': 6});
    expect(reader.currentTtsOffset, 2, reason: 'A cancelled utterance cannot relocate resumed playback');
    await emit('range', {'id': spoken.last['id'], 'start': 2, 'end': 4});
    expect(reader.currentTtsOffset, 4); expect(reader.state, TtsState.playing);
  });
  test('mixed punctuation and content ranges resume at content after rate and screen-style pause', () async {
    final reader = TtsReader()..setVoice(TtsReader.systemVoice);
    addTearDown(reader.dispose);
    final words = <(int, int)>[]; reader.onWordChanged = (s, e) => words.add((s, e));
    queued = Completer<void>(); final firstQueued = queued!.future;
    final first = reader.start(['甲，乙。']); await firstQueued;
    final oldId = spoken.last['id']; await emit('start', {'id': oldId}); await first;
    await emit('range', {'id': oldId, 'start': 1, 'end': 3});
    expect(reader.currentTtsOffset, 2); expect(words.last, (2, 3));
    queued = Completer<void>(); final rateQueued = queued!.future;
    final changed = reader.setSpeechRate(1.1); await rateQueued;
    expect(spoken.last['text'], '乙。'); expect(spoken.last['rate'], 1.1);
    final id = spoken.last['id']; await emit('start', {'id': id}); await changed;
    await emit('range', {'id': oldId, 'start': 0, 'end': 1});
    expect(reader.currentTtsOffset, 2);
    await reader.pause();
    queued = Completer<void>(); final resumedQueued = queued!.future;
    final resumed = reader.resume(); await resumedQueued;
    expect(spoken.last['text'], '乙。'); expect(spoken.last['rate'], 1.1);
    await emit('start', {'id': spoken.last['id']}); expect(await resumed, isTrue);
  });
  test('mixed range content normalization preserves UTF16 boundaries and ignores split surrogate ranges', () async {
    final reader = TtsReader()..setVoice(TtsReader.systemVoice);
    addTearDown(reader.dispose);
    queued = Completer<void>(); final firstQueued = queued!.future;
    final first = reader.start(['甲， \u{20000}乙。']); await firstQueued;
    final id = spoken.last['id']; await emit('start', {'id': id}); await first;
    await emit('range', {'id': id, 'start': 1, 'end': 6});
    expect(reader.currentTtsOffset, 3); expect(reader.currentWordStart, 3); expect(reader.currentWordEnd, 6);
    await emit('range', {'id': id, 'start': 4, 'end': 5});
    await emit('range', {'id': id, 'start': 3, 'end': 4});
    expect(reader.currentTtsOffset, 3); expect(reader.currentWordEnd, 6);
    await reader.pause();
    queued = Completer<void>(); final resumedQueued = queued!.future;
    final resumed = reader.resume(); await resumedQueued;
    expect(spoken.last['text'], '\u{20000}乙。');
    await emit('start', {'id': spoken.last['id']}); expect(await resumed, isTrue);
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
