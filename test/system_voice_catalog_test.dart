import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/services/system_tts.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  Future<void> startEvent(String id) async {
    final done = Completer<void>();
    messenger.handlePlatformMessage(SystemTtsClient.channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall('start', {'id': id})), (_) => done.complete());
    await done.future;
  }
  tearDown(() => messenger.setMockMethodCallHandler(SystemTtsClient.channel, null));

  test('engine-scoped voice identifiers round-trip and do not collide', () {
    const voice = 'zh:音色/%';
    final a = SystemTtsClient.engineVoiceIdentifier('engine.a', voice);
    final b = SystemTtsClient.engineVoiceIdentifier('engine.b', voice);
    expect(a, isNot(b));
    expect(SystemTtsClient.decodeIdentifier(a), (engine: 'engine.a', voice: voice));
    expect(SystemTtsClient.decodeIdentifier(SystemTtsClient.engineVoiceIdentifier('engine.a', '')),
      (engine: 'engine.a', voice: null));
    expect(SystemTtsClient.decodeIdentifier('legacy-voice'), (engine: null, voice: 'legacy-voice'));
  });

  test('catalog keeps ordinary, network and other-language voices without switching playback', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(SystemTtsClient.channel, (call) async {
      calls.add(call.method);
      return {'defaultEngine': 'engine.a', 'engines': [
        {'id': 'engine.a', 'name': 'Engine A', 'defaultVoiceId': 'same', 'defaultVoiceName': '普通音色',
          'voices': [{'id': 'same', 'name': '普通音色', 'lang': 'fr-FR', 'quality': 'default', 'requiresNetwork': true}]},
        {'id': 'engine.b', 'name': 'Engine B', 'defaultVoiceId': 'same', 'defaultVoiceName': '另一音色',
          'voices': [{'id': 'same', 'name': '另一音色', 'lang': 'zh-CN', 'quality': 'default'}]},
      ]};
    });
    final client = SystemTtsClient();
    final catalog = await client.catalog();
    expect(catalog.engines.map((engine) => engine.name), ['Engine A', 'Engine B']);
    expect(catalog.voices, hasLength(2));
    expect(catalog.voices.first.requiresNetwork, isTrue);
    expect(catalog.voices.first.lang, 'fr-FR');
    expect(catalog.voices.map((voice) => voice.identifier).toSet(), hasLength(2));
    expect(calls, ['voiceCatalog']);
    await client.dispose();
  });

  test('selecting another provider sends its engine and voice, legacy default remains compatible', () async {
    final initialized = <Object?>[], spoken = <Map>[];
    messenger.setMockMethodCallHandler(SystemTtsClient.channel, (call) async {
      if (call.method == 'initialize') { initialized.add(call.arguments); return {'voiceName': 'Default'}; }
      if (call.method == 'speak') {
        final args = call.arguments as Map; spoken.add(args);
        scheduleMicrotask(() => startEvent(args['id'] as String));
      }
      return null;
    });
    final client = SystemTtsClient();
    for (final engine in ['engine.a', 'engine.b']) {
      await client.speak('甲乙。', 1, voiceId: SystemTtsClient.engineVoiceIdentifier(engine, 'same'),
        onDone: () {}, onRange: (_, _) {}, onError: (_) {});
    }
    expect(initialized, [{'engine': 'engine.a'}, {'engine': 'engine.b'}]);
    expect(spoken.map((args) => args['engine']), ['engine.a', 'engine.b']);
    expect(spoken.map((args) => args['voice']), ['same', 'same']);
    await client.speak('默认。', 1, onDone: () {}, onRange: (_, _) {}, onError: (_) {});
    expect(initialized.last, isNull);
    expect(spoken.last.containsKey('engine'), isFalse);
    expect(spoken.last.containsKey('voice'), isFalse);
    await client.dispose();
  });

  test('late initialization from a previous provider cannot replace the current voice', () async {
    final a = Completer<Object?>(), b = Completer<Object?>();
    final aStarted = Completer<void>(), bStarted = Completer<void>();
    messenger.setMockMethodCallHandler(SystemTtsClient.channel, (call) async {
      if (call.method == 'initialize') {
        if ((call.arguments as Map)['engine'] == 'engine.a') { aStarted.complete(); return a.future; }
        bStarted.complete(); return b.future;
      }
      if (call.method == 'speak') {
        final args = call.arguments as Map;
        scheduleMicrotask(() => startEvent(args['id'] as String));
      }
      return null;
    });
    final client = SystemTtsClient();
    final first = client.speak('旧。', 1, voiceId: SystemTtsClient.engineVoiceIdentifier('engine.a', 'A'),
      onDone: () {}, onRange: (_, _) {}, onError: (_) {});
    final firstResult = expectLater(first, throwsA(isA<SystemSpeechCancelled>()));
    await aStarted.future;
    final second = client.speak('新。', 1, voiceId: SystemTtsClient.engineVoiceIdentifier('engine.b', 'B'),
      onDone: () {}, onRange: (_, _) {}, onError: (_) {});
    await bStarted.future;
    b.complete({'voiceName': 'B'}); await second;
    a.complete({'voiceName': 'A'}); await firstResult;
    expect(client.currentVoiceName, 'B');
    await client.dispose();
  });
}
