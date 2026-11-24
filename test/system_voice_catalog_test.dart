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

  test('compact labels retain the identifying name without inventing translations', () {
    const labels = {
      'iOS-婷婷': '婷婷',
      'iOS—婷婷': '婷婷',
      'AiService TTS': 'AiService',
      'Android - AiService TTS': 'AiService',
      'iOS - tingting_zh_CN TTS': 'tingting',
      'tingting_zh_CN': 'tingting',
      'Voice_en-US': 'Voice',
      'Voice_zh_Hant_TW': 'Voice',
      '甲语音引擎': '甲',
      '乙 文本转语音': '乙',
      '丙文本转语音引擎': '丙',
      'Example Text-to-Speech': 'Example',
      'Matts': 'Matts',
      'Acme_Studio': 'Acme_Studio',
      'Unchanged name': 'Unchanged name',
      'iOS TTS': 'iOS TTS',
      '': '',
      '   ': '',
    };
    for (final entry in labels.entries) {
      expect(SystemTtsClient.compactVoiceLabel(entry.key), entry.value, reason: entry.key);
    }
  });

  test('explicit language identifiers preserve engine ownership without a concrete voice', () {
    final selection = SystemTtsClient.engineLanguageIdentifier('engine:一/%', 'zh-Hans-CN');
    expect(SystemTtsClient.decodeIdentifier(selection), (engine: 'engine:一/%', voice: null));
    expect(SystemTtsClient.languageFromIdentifier(selection), 'zh-Hans-CN');
    expect(SystemTtsClient.languageFromIdentifier(SystemTtsClient.engineVoiceIdentifier('engine.a', 'old_voice')), isNull);
    expect(SystemTtsClient.languageFromIdentifier(null), isNull);
    expect(() => SystemTtsClient.decodeIdentifier('@language:engine.a:'), throwsFormatException);
  });

  test('installed-language checks only request the selected engine without catalog or initialization fallback', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(SystemTtsClient.channel, (call) async {
      calls.add(call);
      if (call.method != 'checkLanguages') throw StateError('Installed-language checks must not inspect synthetic voice lists');
      return [
        {'id': 'en-US', 'name': '英语（美国）'},
        {'id': 'zh-CN', 'name': '中文（中国）'},
        {'id': 'en-US', 'name': '英语（美国）'},
        {'id': 'fr-FR', 'name': ''},
        {'id': 'und', 'name': 'Unknown'},
        {'id': 'en_US', 'name': 'Not a normalized tag'},
        {'id': 42},
      ];
    });
    final client = SystemTtsClient();
    final languages = await client.checkLanguages('engine.a');
    expect(languages.map((language) => language.id), ['en-US', 'zh-CN', 'fr-FR']);
    expect(languages.map((language) => language.name), ['英语（美国）', '中文（中国）', 'fr-FR']);
    expect(calls.single.method, 'checkLanguages');
    expect((calls.single.arguments as Map)['engine'], 'engine.a');
    expect((calls.single.arguments as Map)['id'], isA<String>());
    await client.dispose();
  });

  for (final response in ['null', 'empty', 'unsupported', 'failed']) {
    test('installed-language $response returns empty without falling back to getVoices', () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(SystemTtsClient.channel, (call) async {
        calls.add(call.method);
        if (call.method != 'checkLanguages') throw StateError('No fallback to advertised locales');
        if (response == 'unsupported') throw MissingPluginException();
        if (response == 'failed') throw PlatformException(code: 'check_failed');
        return response == 'empty' ? [] : null;
      });
      final client = SystemTtsClient();
      expect(await client.checkLanguages('engine.a'), isEmpty);
      expect(calls, ['checkLanguages']);
      await client.dispose();
    });
  }

  testWidgets('installed-language checks are single-flight and disposal immediately cancels their deadline', (tester) async {
    final reply = Completer<List<dynamic>>();
    final calls = <String>[];
    messenger.setMockMethodCallHandler(SystemTtsClient.channel, (call) async {
      calls.add(call.method);
      if (call.method == 'checkLanguages') return reply.future;
      return null;
    });
    final client = SystemTtsClient();
    var completed = false;
    final pending = client.checkLanguages('engine.a').then((value) { completed = true; return value; });
    await tester.pump();
    expect(completed, isFalse);
    expect(await client.checkLanguages('engine.b'), isEmpty);
    expect(calls, ['checkLanguages']);
    await client.dispose();
    await tester.pump();
    expect(completed, isTrue, reason: 'Reader disposal must cancel the 15-second deadline without advancing the clock');
    expect(await pending, isEmpty);
    expect(calls, ['checkLanguages', 'cancelLanguageCheck']);
    reply.complete([{'id': 'en-US', 'name': 'Late English'}]);
    await tester.pump();
    expect(await client.checkLanguages('engine.a'), isEmpty);
  });

  testWidgets('an unresponsive installed-language Activity times out and receives cancellation', (tester) async {
    final reply = Completer<List<dynamic>>();
    final calls = <MethodCall>[];
    var checks = 0;
    messenger.setMockMethodCallHandler(SystemTtsClient.channel, (call) async {
      calls.add(call);
      if (call.method == 'checkLanguages') {
        if (++checks == 1) return reply.future;
        return [{'id': 'en-US', 'name': 'English'}];
      }
      return null;
    });
    final client = SystemTtsClient();
    final pending = client.checkLanguages('engine.a');
    await tester.pump();
    await tester.pump(const Duration(seconds: 15));
    expect(await pending, isEmpty);
    expect(calls.map((call) => call.method), ['checkLanguages', 'cancelLanguageCheck']);
    final originalId = (calls.first.arguments as Map)['id'];
    expect((calls.last.arguments as Map)['id'], originalId);
    expect((await client.checkLanguages('engine.b')).single.id, 'en-US');
    expect((calls.last.arguments as Map)['id'], isNot(originalId),
      reason: 'An old cancellation can only settle its own native request, even after a new check starts');
    reply.complete([]);
    await tester.pump();
    await client.dispose();
  });

  test('language selection sends its engine and language, then follow-system clears the explicit language', () async {
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
    await client.speak('English text.', 1, voiceId: SystemTtsClient.engineLanguageIdentifier('engine.a', 'en-US'),
      onDone: () {}, onRange: (_, _) {}, onError: (_) {});
    expect(spoken.single['engine'], 'engine.a');
    expect(spoken.single['language'], 'en-US');
    expect(spoken.single.containsKey('voice'), isFalse);
    await client.speak('跟随系统。', 1, voiceId: SystemTtsClient.engineVoiceIdentifier('engine.a', ''),
      onDone: () {}, onRange: (_, _) {}, onError: (_) {});
    expect(initialized, [{'engine': 'engine.a'}]);
    expect(spoken.last['engine'], 'engine.a');
    expect(spoken.last.containsKey('language'), isFalse);
    expect(spoken.last.containsKey('voice'), isFalse);
    await client.dispose();
  });

  test('names-only catalog requests display metadata without voice inspection or playback initialization', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(SystemTtsClient.channel, (call) async {
      calls.add(call);
      if (call.method != 'voiceCatalog') throw StateError('Names must not initialize speech');
      return {'defaultEngine': 'engine.b', 'engines': [
        {'id': 'engine.a', 'name': 'AiService TTS', 'voices': 'not a voice list'},
        {'id': 'engine.b', 'name': 'iOS-婷婷'},
      ]};
    });
    final client = SystemTtsClient();
    final catalog = await client.catalog(enginesOnly: true, namesOnly: true);
    expect(catalog.engines.map((engine) => engine.name), ['AiService TTS', 'iOS-婷婷']);
    expect(catalog.defaultEngine, 'engine.b'); expect(catalog.voices, isEmpty);
    expect(calls.single.method, 'voiceCatalog');
    expect(calls.single.arguments, {'enginesOnly': true, 'namesOnly': true});
    await client.dispose();
  });

  for (final response in ['null', 'empty', 'unsupported']) {
    test('names-only catalog safely returns no names for $response without initializing legacy hosts', () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(SystemTtsClient.channel, (call) async {
        calls.add(call.method);
        if (call.method != 'voiceCatalog') throw StateError('Name fallback cannot initialize playback');
        if (response == 'unsupported') throw MissingPluginException();
        return response == 'empty' ? {'defaultEngine': '', 'engines': []} : null;
      });
      final client = SystemTtsClient();
      final catalog = await client.catalog(enginesOnly: true, namesOnly: true);
      expect(catalog.engines, isEmpty); expect(catalog.voices, isEmpty);
      expect(calls, ['voiceCatalog']);
      expect(SystemTtsClient.compactVoiceLabel('Unchanged engine'), 'Unchanged engine');
      await client.dispose();
    });
  }

  for (final namesOnly in [true, false]) {
    testWidgets('disposing a hanging catalog namesOnly=$namesOnly cancels its deadline without waiting for native reply', (tester) async {
      final reply = Completer<Map<String, dynamic>?>();
      final calls = <String>[];
      messenger.setMockMethodCallHandler(SystemTtsClient.channel, (call) async {
        calls.add(call.method);
        if (call.method != 'voiceCatalog') throw StateError('Disposed catalog must not initialize speech');
        return reply.future;
      });
      final client = SystemTtsClient();
      var completed = false;
      final pending = client.catalog(enginesOnly: true, namesOnly: namesOnly).then((value) {
        completed = true;
        return value;
      });
      await tester.pump();
      expect(completed, isFalse);
      await client.dispose();
      await tester.pump();
      expect(completed, isTrue, reason: 'Disposal must settle the catalog without advancing the 15-second deadline');
      final result = await pending;
      expect(result.engines, isEmpty);
      expect(calls, ['voiceCatalog']);
      reply.complete({'defaultEngine': 'late', 'engines': [{'id': 'late', 'name': 'Late engine'}]});
      await tester.pump();
      expect(result.engines, isEmpty, reason: 'A native reply after disposal cannot publish new display metadata');
    });
  }

  testWidgets('cancelling a pending names catalog preserves the native stop for active speech', (tester) async {
    final reply = Completer<Map<String, dynamic>?>();
    final calls = <String>[];
    messenger.setMockMethodCallHandler(SystemTtsClient.channel, (call) async {
      calls.add(call.method);
      if (call.method == 'initialize') return {'voiceName': 'Current'};
      if (call.method == 'speak') scheduleMicrotask(() => startEvent((call.arguments as Map)['id'] as String));
      if (call.method == 'voiceCatalog') return reply.future;
      return null;
    });
    final client = SystemTtsClient();
    await client.speak('正文。', 1, onDone: () {}, onRange: (_, _) {}, onError: (_) {});
    final pending = client.catalog(enginesOnly: true, namesOnly: true);
    await tester.pump();
    await client.dispose();
    await tester.pump();
    expect((await pending).engines, isEmpty);
    expect(calls.where((method) => method == 'stop'), hasLength(1));
    expect(calls.where((method) => method == 'initialize'), hasLength(1));
    reply.complete(null); await tester.pump();
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

  test('engine-only catalog requests names without consuming advertised language or voice lists', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(SystemTtsClient.channel, (call) async {
      calls.add(call);
      if (call.method != 'voiceCatalog') throw StateError('Engine browsing must not initialize speech');
      return {'defaultEngine': 'engine.b', 'engines': [
        {'id': 'engine.a', 'name': 'AiService TTS', 'defaultVoiceQuality': 'default', 'voices': 'untrusted-language-list'},
        {'id': 'engine.b', 'name': 'iOS-婷婷', 'defaultVoiceQuality': 'enhanced',
          'voices': [{'id': 'tingting_zh_CN', 'lang': 'zh-CN'}]},
      ]};
    });
    final client = SystemTtsClient();
    final catalog = await client.catalog(enginesOnly: true);
    expect(catalog.engines.map((engine) => engine.name), ['AiService TTS', 'iOS-婷婷']);
    expect(catalog.voices, isEmpty); expect(catalog.defaultEngine, 'engine.b');
    expect(catalog.engines.map((engine) => engine.hasEnhancedDefaultVoice), [false, true]);
    expect(calls.single.method, 'voiceCatalog'); expect(calls.single.arguments, {'enginesOnly': true});
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
