import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:duoduo_langdu/i18n.dart';
import 'package:duoduo_langdu/models/book.dart';
import 'package:duoduo_langdu/screens/reader_screen.dart';
import 'package:duoduo_langdu/services/app_storage.dart';
import 'package:duoduo_langdu/services/app_appearance.dart';
import 'package:duoduo_langdu/services/book_cache_task.dart';
import 'package:duoduo_langdu/services/display_cutout.dart';
import 'package:duoduo_langdu/services/edge_tts.dart';
import 'package:duoduo_langdu/services/network_connectivity.dart';
import 'package:duoduo_langdu/services/playback_notifications.dart';
import 'package:duoduo_langdu/services/reader_preparation.dart';
import 'package:duoduo_langdu/services/reading_text.dart';
import 'package:duoduo_langdu/services/speech_breaks.dart';
import 'package:duoduo_langdu/services/system_tts.dart';
import 'package:duoduo_langdu/services/tts_reader.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  final preparations = <ReaderPreparationRequest>[];
  setUp(() async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    SharedPreferences.setMockInitialValues({});
    AppI18n.current = AppLang.zhHans;
    AppAppearance.setThemeMode('light');
    preparations.clear();
    ReaderPreparation.runnerForTesting = (request) async {
      preparations.add(request);
      return ReaderPreparation.prepareSynchronously(request);
    };
    messenger.setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('com.ddnovelreader/volume_keys'),
      (call) async => ['getMediaVolume', 'getSystemBrightness'].contains(call.method) ? 0.5 : null);
    messenger.setMockMethodCallHandler(const MethodChannel('com.ddnovelreader/debug_log'), (_) async => null);
    messenger.setMockMethodCallHandler(DisplayCutoutService.channel, (_) async => null);
    messenger.setMockMethodCallHandler(NetworkConnectivity.channel, (_) async => null);
    messenger.setMockMethodCallHandler(PlaybackNotifications.channel, (_) async =>
      {'supported': false, 'enabled': false, 'canRequest': false, 'asked': false});
    messenger.setMockMethodCallHandler(SystemTtsClient.channel, (_) async => null);
    await Future<void>.delayed(Duration.zero);
  });
  tearDown(() { ReaderPreparation.runnerForTesting = null; });

  Book book(String id, String text) => Book(id: id, title: '按音色停顿', filePath: '', format: BookFormat.txt,
    addedAt: DateTime(2026), chapters: [Chapter(title: '第一章', paragraphs: [ReadingText.paragraph(text)])]);

  Future<void> configureView(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
  }

  Future<void> pause(WidgetTester tester) async {
    await tester.tapAt(const Offset(195, 300)); await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reading-voice')), findsOneWidget);
  }

  Future<void> scrollSheetTo(WidgetTester tester, Finder target, {double delta = 150}) async {
    final scrollable = find.descendant(of: find.byType(BottomSheet).last, matching: find.byType(Scrollable)).last;
    await tester.scrollUntilVisible(target, delta, scrollable: scrollable);
    await tester.pumpAndSettle();
  }

  Future<void> expandOnlineVoice(WidgetTester tester, String id) async {
    if (find.byKey(ValueKey('cache-voice-$id')).evaluate().isNotEmpty) return;
    final language = edgeVoices.firstWhere((voice) => voice.id == id).langCode;
    final family = language == 'zh-CN' ? 'zh-Hans' : language == 'zh-TW' ? 'zh-Hant' : language.split('-').first;
    final labels = {'zh-Hans': AppLang.zhHans.nativeName, 'zh-Hant': AppLang.zhHant.nativeName,
      'en': AppLang.en.nativeName, 'ja': AppLang.ja.nativeName, 'ko': AppLang.ko.nativeName};
    final heading = find.descendant(of: find.byKey(ValueKey('voice-group-online-$family')), matching: find.text(labels[family]!));
    final scrollable = find.descendant(of: find.byType(BottomSheet).last, matching: find.byType(Scrollable)).last;
    tester.state<ScrollableState>(scrollable).position.jumpTo(0);
    await tester.pumpAndSettle();
    await scrollSheetTo(tester, heading);
    await tester.tap(heading); await tester.pumpAndSettle();
  }

  Future<void> editComma(WidgetTester tester, String seconds) async {
    final value = find.byKey(const ValueKey('pause-comma'));
    await scrollSheetTo(tester, value);
    await tester.tap(value); await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('pause-number-comma')), seconds);
    await tester.tap(find.text(T('ok'))); await tester.pumpAndSettle();
  }

  Future<void> dismissSheet(WidgetTester tester) async {
    Navigator.of(tester.element(find.byType(BottomSheet).last)).pop();
    await tester.pumpAndSettle();
  }

  Future<void> expectOpenPauses(WidgetTester tester) async {
    expect(find.byKey(const ValueKey('pause-slider-comma')), findsOneWidget);
    expect(find.byKey(const ValueKey('pause-apply')), findsOneWidget);
    expect(find.text('系统的追加停顿'), findsNothing);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('pause-apply'))).onPressed, isNull);
  }

  testWidgets('only the system voice offers paused editing and editing it leaves online playback unchanged', (tester) async {
    await configureView(tester);
    final storage = AppStorage();
    await storage.saveSettings((ReadingSettings()..voice = TtsReader.defaultVoice
      ..firstLineIndent = false..mergeNonSentenceBreaks = false).toJson());
    final speech = _VoiceSpeech();
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: book('voice-menu', '甲乙，丙丁。戊己，庚辛。'),
      storage: storage, ttsReader: speech)));
    await tester.pumpAndSettle();
    expect(preparations, hasLength(1));
    await tester.tap(find.byTooltip(T('read'))); await tester.pumpAndSettle();
    expect(speech.starts, hasLength(1));
    final original = speech.starts.single;
    await pause(tester);
    await tester.tap(find.byKey(const ValueKey('playback-settings'))); await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pause-expand')), findsNothing,
      reason: 'Playback settings no longer expose an additional-pause editor');
    expect(find.byKey(const ValueKey('pause-apply')), findsNothing);
    expect(find.byKey(const ValueKey('pause-apply-global')), findsNothing);
    expect(find.byKey(const ValueKey('pause-reset-global')), findsNothing);
    await dismissSheet(tester);
    await tester.tap(find.byKey(const ValueKey('reading-voice'))); await tester.pumpAndSettle();
    const targetVoice = TtsReader.systemVoice;
    final voicePause = find.byKey(const ValueKey('pause-voice-$targetVoice'));
    await tester.scrollUntilVisible(voicePause, 250, scrollable: find.byType(Scrollable).last);
    expect(voicePause, findsOneWidget);
    expect(find.byKey(const ValueKey('pause-customized-$targetVoice')), findsNothing);
    for (final voice in edgeVoices) {
      await expandOnlineVoice(tester, voice.id);
      final cache = find.byKey(ValueKey('cache-voice-${voice.id}'));
      await scrollSheetTo(tester, cache, delta: voice == edgeVoices.first ? -150 : 150);
      expect(cache, findsOneWidget);
      expect(find.byKey(ValueKey('pause-voice-${voice.id}')), findsNothing,
        reason: 'Online voices have their cache action without an added-pause action');
    }
    await scrollSheetTo(tester, voicePause);
    await tester.tap(voicePause); await tester.pumpAndSettle();
    await expectOpenPauses(tester);
    await editComma(tester, '0.25');
    final apply = find.byKey(const ValueKey('pause-apply'));
    await scrollSheetTo(tester, apply, delta: -150); await tester.tap(apply); await tester.pumpAndSettle();
    expect(speech.voice, TtsReader.defaultVoice); expect(speech.state, TtsState.paused);
    expect(speech.starts, hasLength(1)); expect(speech.starts.single.sentences, original.sentences);
    expect(preparations, hasLength(1), reason: 'Editing an inactive voice must not reformat the displayed book');
    var saved = ReadingSettings.fromJson(await storage.loadSettings());
    expect(saved.voice, TtsReader.defaultVoice); expect(saved.speechPauses.millisecondsFor(SpeechPauseKind.comma), 0);
    expect(saved.speechPausesForVoice(targetVoice).millisecondsFor(SpeechPauseKind.comma), 250);
    expect(saved.effectiveSpeechPauses, const SpeechPauseSettings());
    expect(find.byKey(const ValueKey('pause-customized-$targetVoice')), findsOneWidget);

    await tester.tap(find.ancestor(of: voicePause, matching: find.byType(ListTile)).first); await tester.pumpAndSettle();
    expect(speech.voice, targetVoice); expect(preparations, hasLength(2));
    expect(preparations.last.pauseSettings.millisecondsFor(SpeechPauseKind.comma), 250);
    expect(speech.starts, hasLength(2)); expect(speech.starts.last.sentences, hasLength(4));
    expect(speech.starts.last.system, isTrue);
    expect(speech.starts.last.pauses, contains(250));
    await pause(tester);
    await tester.tap(find.byKey(const ValueKey('playback-settings'))); await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pause-expand')), findsNothing);
    await dismissSheet(tester);
    saved = ReadingSettings.fromJson(await storage.loadSettings());
    expect(saved.speechPauses, const SpeechPauseSettings());
    expect(saved.hasVoiceSpeechPauses(targetVoice), isTrue);
    expect(saved.speechPausesForVoice(targetVoice).millisecondsFor(SpeechPauseKind.comma), 250);
    expect(preparations, hasLength(2)); expect(speech.voice, targetVoice);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(seconds: 45)));

  testWidgets('native voice selection preserves system pauses and caps the saved rate when switching online', (tester) async {
    await configureView(tester);
    messenger.setMockMethodCallHandler(SystemTtsClient.channel, (call) async => call.method == 'voices' ? [
      {'id': 'enhanced-test', 'name': 'Enhanced test voice', 'lang': 'zh-CN', 'quality': 'enhanced'},
      {'id': 'default-test', 'name': 'Default test voice', 'lang': 'zh-CN', 'quality': 'default'},
    ] : null);
    const native = '${SystemTtsClient.voicePrefix}enhanced-test';
    final storage = AppStorage(), speech = _VoiceSpeech();
    final settings = ReadingSettings()..voice = TtsReader.systemVoice..speechRate = 2.8;
    settings.setVoiceSpeechPauses(TtsReader.systemVoice,
      const SpeechPauseSettings().withPause(SpeechPauseKind.comma, 450));
    await storage.saveSettings(settings.toJson());
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: book('native-selection', '甲乙，丙丁。'),
      storage: storage, ttsReader: speech)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(T('read'))); await tester.pumpAndSettle();
    await pause(tester);
    await tester.tap(find.byKey(const ValueKey('reading-voice'))); await tester.pumpAndSettle();
    final tile = find.byKey(const ValueKey('pause-voice-$native'));
    await scrollSheetTo(tester, tile);
    expect(find.byType(SwitchListTile), findsNothing);
    await scrollSheetTo(tester, find.text('Default test voice'));
    expect(find.text('Default test voice'), findsOneWidget);
    await scrollSheetTo(tester, tile, delta: -150);
    expect(find.byKey(const ValueKey('cache-voice-$native')), findsNothing);
    await tester.tap(find.ancestor(of: tile, matching: find.byType(ListTile)).first); await tester.pumpAndSettle();
    expect(speech.voice, native); expect(speech.usesSystemVoice, isTrue); expect(speech.speechRate, 2.8);
    expect(preparations, hasLength(1), reason: 'Specific system voices reuse the existing system pause split');
    expect((await storage.loadReadingSettings('native-selection')).effectiveSpeechPauses
      .millisecondsFor(SpeechPauseKind.comma), 450);
    await pause(tester);
    await tester.tap(find.byKey(const ValueKey('reading-voice'))); await tester.pumpAndSettle();
    final online = find.byKey(const ValueKey('cache-voice-zh-CN-XiaoxiaoNeural'));
    await expandOnlineVoice(tester, TtsReader.defaultVoice);
    await scrollSheetTo(tester, online);
    await tester.tap(find.ancestor(of: online, matching: find.byType(ListTile)).first); await tester.pumpAndSettle();
    expect(speech.voice, TtsReader.defaultVoice); expect(speech.speechRate, 2);
    final saved = await storage.loadReadingSettings('native-selection');
    expect(saved.voice, TtsReader.defaultVoice); expect(saved.speechRate, 2);
    expect(saved.effectiveSpeechPauses, const SpeechPauseSettings());
    expect(preparations, hasLength(2)); expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  testWidgets('online voice selection stays usable while native enumeration is pending', (tester) async {
    await configureView(tester);
    final initialized = Completer<String>();
    addTearDown(() { if (!initialized.isCompleted) initialized.complete('engine'); });
    messenger.setMockMethodCallHandler(SystemTtsClient.channel, (call) async {
      if (call.method == 'initialize') return initialized.future;
      if (call.method == 'voices') return [];
      return null;
    });
    final speech = _VoiceSpeech();
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: book('slow-voice-list', '正文。'),
      storage: AppStorage(), ttsReader: speech)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(T('read'))); await tester.pumpAndSettle();
    await pause(tester);
    await tester.tap(find.byKey(const ValueKey('reading-voice')));
    await tester.pump(); await tester.pump(const Duration(milliseconds: 350));
    await expandOnlineVoice(tester, 'zh-CN-XiaoxiaoNeural');
    expect(find.byKey(const ValueKey('cache-voice-zh-CN-XiaoxiaoNeural')), findsOneWidget);
    await tester.tap(find.text('云希（男·阳光）')); await tester.pumpAndSettle();
    expect(speech.voice, 'zh-CN-YunxiNeural');
    initialized.complete('engine'); await tester.pumpAndSettle();
    expect(speech.voice, 'zh-CN-YunxiNeural'); expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  testWidgets('online cache ignores legacy global and voice-specific pauses without changing the reader', (tester) async {
    await configureView(tester);
    final directory = (await tester.runAsync(() => Directory.systemTemp.createTemp('reader-voice-pause-cache-')))!;
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(pathChannel, (_) async => directory.path);
    const bookId = 'cache-target-voice-pause', targetVoice = 'zh-CN-YunxiNeural';
    addTearDown(() async {
      messenger.setMockMethodCallHandler(pathChannel, null);
      final keys = activeBookCaches.keys.where((key) => key.startsWith('$bookId/')).toList();
      for (final key in keys) { activeBookCaches.remove(key)!.statusNotifier.dispose(); }
      await directory.delete(recursive: true);
    });
    final storage = AppStorage();
    final settings = ReadingSettings()..voice = TtsReader.defaultVoice..speechRate = 1.8
      ..firstLineIndent = false..mergeNonSentenceBreaks = false;
    settings.speechPauses = const SpeechPauseSettings().withPause(SpeechPauseKind.comma, 450);
    settings.setVoiceSpeechPauses(targetVoice, const SpeechPauseSettings().withPause(SpeechPauseKind.comma, 250));
    await storage.saveSettings(settings.toJson());
    final speech = _VoiceSpeech();
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: book(bookId, '甲乙，丙丁。戊己，庚辛。'),
      storage: storage, ttsReader: speech)));
    await tester.pumpAndSettle();
    expect(preparations, hasLength(1));
    expect(preparations.single.pauseSettings, const SpeechPauseSettings(),
      reason: 'Online reading cannot inherit the old globally customized pause');
    final currentFingerprint = ReaderPreparation.prepareSynchronously(preparations.single).fingerprint;
    final body = find.byKey(const ValueKey('reader-body'));
    final signatureBefore = tester.widget<KeyedSubtree>(find.ancestor(of: body, matching: find.byType(KeyedSubtree)).first).key;
    await tester.tap(find.byTooltip(T('read'))); await tester.pumpAndSettle();
    await pause(tester);
    await tester.tap(find.byKey(const ValueKey('reading-voice'))); await tester.pumpAndSettle();
    final cacheButton = find.byKey(const ValueKey('cache-voice-$targetVoice'));
    await scrollSheetTo(tester, cacheButton); await tester.tap(cacheButton);
    // File-system futures are real IO. Drain them outside FakeAsync while
    // pumping frames, rather than waiting on a network or starting a download.
    for (var frame = 0; frame < 120 && find.byKey(const ValueKey('cache-binding')).evaluate().isEmpty; frame++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.byKey(const ValueKey('cache-binding')), findsOneWidget);
    expect(preparations, hasLength(1), reason: 'Both online voices use the same default split, so no reformat is necessary');
    final task = activeBookCaches.values.singleWhere((task) => task.bookId == bookId);
    for (var frame = 0; frame < 120 && (task.status.total == 0 || task.status.isActive); frame++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(task.store.voice, targetVoice); expect(task.store.rate, 1.8);
    expect(task.store.textFingerprint, currentFingerprint);
    expect(task.store.textFingerprint, 'words2-${ReadingText.fingerprint(task.book)}');
    expect(task.book.chapters.single.paragraphs.expand((p) => p.sentences), hasLength(2));
    expect(task.book.chapters.single.paragraphs.expand((p) => p.sentences).map((s) => s.pauseAfterMilliseconds), isNot(contains(250)));
    expect(task.book.chapters.single.paragraphs.expand((p) => p.sentences).map((s) => s.pauseAfterMilliseconds), isNot(contains(450)));
    expect(task.status.total, 2); expect(task.status.done, 0); expect(task.status.isActive, isFalse,
      reason: 'Opening cache settings must not start network synthesis');
    expect(speech.voice, TtsReader.defaultVoice); expect(speech.state, TtsState.paused); expect(speech.starts, hasLength(1));
    final signatureAfter = tester.widget<KeyedSubtree>(find.ancestor(of: body, matching: find.byType(KeyedSubtree)).first).key;
    expect(signatureAfter, signatureBefore, reason: 'Preparing another cache voice cannot replace the displayed split');
    final saved = ReadingSettings.fromJson(await storage.loadSettings());
    expect(saved.voice, TtsReader.defaultVoice); expect(saved.effectiveSpeechPauses.millisecondsFor(SpeechPauseKind.comma), 0);
    expect(saved.speechPauses.millisecondsFor(SpeechPauseKind.comma), 450);
    expect(saved.perVoiceSpeechPauses[targetVoice]!.millisecondsFor(SpeechPauseKind.comma), 250,
      reason: 'Legacy data remains readable while online synthesis ignores its customized values');
    expect(saved.hasVoiceSpeechPauses(targetVoice), isFalse);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    await tester.runAsync(() => task.store.sizeBytes());
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(seconds: 45)));

  testWidgets('online cache clamps its own rate without changing the selected system voice or rate', (tester) async {
    await configureView(tester);
    final directory = (await tester.runAsync(() => Directory.systemTemp.createTemp('reader-target-rate-')))!;
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(pathChannel, (_) async => directory.path);
    const id = 'system-to-online-cache', voice = 'zh-CN-YunxiNeural';
    addTearDown(() async {
      messenger.setMockMethodCallHandler(pathChannel, null);
      for (final key in activeBookCaches.keys.where((key) => key.startsWith('$id/')).toList()) {
        activeBookCaches.remove(key)!.statusNotifier.dispose();
      }
      await directory.delete(recursive: true);
    });
    final storage = AppStorage(), speech = _VoiceSpeech();
    await storage.saveSettings((ReadingSettings()..voice = TtsReader.systemVoice..speechRate = 2.8).toJson());
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: book(id, '甲乙。丙丁。'), storage: storage, ttsReader: speech)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(T('read'))); await tester.pumpAndSettle();
    await pause(tester);
    await tester.tap(find.byKey(const ValueKey('reading-voice'))); await tester.pumpAndSettle();
    final cache = find.byKey(const ValueKey('cache-voice-$voice'));
    await expandOnlineVoice(tester, voice);
    await scrollSheetTo(tester, cache); await tester.tap(cache);
    for (var frame = 0; frame < 120 && find.byKey(const ValueKey('cache-binding')).evaluate().isEmpty; frame++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.byKey(const ValueKey('cache-binding')), findsOneWidget);
    final task = activeBookCaches.values.singleWhere((task) => task.bookId == id);
    for (var frame = 0; frame < 120 && (task.status.total == 0 || task.status.isActive); frame++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(task.store.voice, voice); expect(task.store.rate, 2); expect(task.store.rateKey, '100');
    expect(task.status.isActive, isFalse, reason: 'Inspecting a cache does not start synthesis.');
    expect(speech.voice, TtsReader.systemVoice); expect(speech.speechRate, 2.8);
    expect((await storage.loadSettings())['speechRate'], 2.8);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    await tester.runAsync(() => task.store.sizeBytes());
    expect(tester.takeException(), isNull);
  });

  testWidgets('resetting system pauses clears overrides and leaves online speech unchanged', (tester) async {
    await configureView(tester);
    final storage = AppStorage(), speech = _VoiceSpeech();
    final settings = ReadingSettings()..voice = TtsReader.defaultVoice
      ..firstLineIndent = false..mergeNonSentenceBreaks = false;
    settings.speechPauses = const SpeechPauseSettings().withPause(SpeechPauseKind.comma, 900);
    settings.setVoiceSpeechPauses(TtsReader.systemVoice,
      const SpeechPauseSettings().withPause(SpeechPauseKind.comma, 1200));
    await storage.saveSettings(settings.toJson());
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: book('reset-system', '甲乙，丙丁。'),
      storage: storage, ttsReader: speech)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(T('read'))); await tester.pumpAndSettle(); await pause(tester);
    final original = speech.starts.single;
    await tester.tap(find.byKey(const ValueKey('reading-voice'))); await tester.pumpAndSettle();
    final pauseButton = find.byKey(const ValueKey('pause-voice-${TtsReader.systemVoice}'));
    await scrollSheetTo(tester, pauseButton); await tester.tap(pauseButton); await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pause-reset'))); await tester.pumpAndSettle();
    expect((await storage.loadReadingSettings('reset-system')).speechPausesForVoice(TtsReader.systemVoice)
      .millisecondsFor(SpeechPauseKind.comma), 1200, reason: 'Reset is still a draft until Apply');
    await tester.tap(find.byKey(const ValueKey('pause-apply'))); await tester.pumpAndSettle();
    final saved = ReadingSettings.fromJson(await storage.loadSettings());
    expect(saved.speechPauses, const SpeechPauseSettings());
    expect(saved.hasVoiceSpeechPauses(TtsReader.systemVoice), isFalse);
    expect(saved.effectiveSpeechPauses, const SpeechPauseSettings());
    expect(saved.voice, TtsReader.defaultVoice); expect(speech.voice, TtsReader.defaultVoice);
    expect(preparations, hasLength(1)); expect(speech.starts, hasLength(1));
    expect(speech.starts.single.sentences, original.sentences); expect(speech.starts.single.pauses, original.pauses);
    expect(find.byKey(const ValueKey('pause-customized-${TtsReader.systemVoice}')), findsNothing);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  testWidgets('online groups preserve manual folding while the system catalog loads', (tester) async {
    await configureView(tester);
    final gate = Completer<Map<String, dynamic>>();
    addTearDown(() { if (!gate.isCompleted) gate.complete({'engines': []}); });
    messenger.setMockMethodCallHandler(SystemTtsClient.channel, (call) async {
      if (call.method == 'voiceCatalog') return gate.future;
      return null;
    });
    final storage = AppStorage(), speech = _VoiceSpeech();
    await storage.saveSettings((ReadingSettings()..voice = TtsReader.defaultVoice).toJson());
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: book('folded-voices', '甲乙。'), storage: storage, ttsReader: speech)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(T('read'))); await tester.pumpAndSettle(); await pause(tester);
    await tester.tap(find.byKey(const ValueKey('reading-voice'))); await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cache-voice-zh-CN-XiaoxiaoNeural')), findsOneWidget);
    expect(find.byKey(const ValueKey('cache-voice-en-US-AriaNeural')), findsNothing);
    final chinese = find.descendant(of: find.byKey(const ValueKey('voice-group-online-zh-Hans')),
      matching: find.text(AppLang.zhHans.nativeName));
    await tester.tap(chinese); await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cache-voice-zh-CN-XiaoxiaoNeural')), findsNothing);
    await expandOnlineVoice(tester, 'en-US-AriaNeural');
    expect(find.byKey(const ValueKey('cache-voice-en-US-AriaNeural')), findsOneWidget);
    gate.complete({'defaultEngine': '', 'engines': [{'id': '', 'name': '', 'voices': []}]});
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cache-voice-zh-CN-XiaoxiaoNeural')), findsNothing);
    expect(find.byKey(const ValueKey('cache-voice-en-US-AriaNeural')), findsOneWidget);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  testWidgets('installed providers show all voices and select a concrete engine without the offline placeholder', (tester) async {
    await configureView(tester);
    messenger.setMockMethodCallHandler(SystemTtsClient.channel, (call) async => call.method == 'voiceCatalog' ? {
      'defaultEngine': 'engine.a', 'engines': [
        {'id': 'engine.a', 'name': '引擎甲', 'defaultVoiceId': 'ordinary', 'defaultVoiceName': '普通甲', 'voices': [
          {'id': 'ordinary', 'name': '普通甲', 'lang': 'zh-CN', 'quality': 'default'},
          {'id': 'selected', 'name': '当前甲', 'lang': 'zh-CN', 'quality': 'enhanced'},
          {'id': 'french', 'name': '法语音色', 'lang': 'fr-FR', 'quality': 'default', 'requiresNetwork': true},
        ]},
        {'id': 'engine.b', 'name': '引擎乙', 'defaultVoiceId': '', 'defaultVoiceName': '默认乙', 'voices': []},
      ]} : null);
    final voiceA = '${SystemTtsClient.voicePrefix}${SystemTtsClient.engineVoiceIdentifier('engine.a', 'selected')}';
    final voiceB = '${SystemTtsClient.voicePrefix}${SystemTtsClient.engineVoiceIdentifier('engine.b', '')}';
    final storage = AppStorage(), speech = _VoiceSpeech();
    await storage.saveSettings((ReadingSettings()..voice = voiceA..speechRate = 2.8).toJson());
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: book('engine-menu', '甲乙。'), storage: storage, ttsReader: speech)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(T('read'))); await tester.pumpAndSettle(); await pause(tester);
    await tester.tap(find.byKey(const ValueKey('reading-voice'))); await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cache-voice-zh-CN-XiaoxiaoNeural')), findsNothing);
    expect(find.text(T('systemTtsName')), findsNothing);
    expect(find.text(T('systemTtsDescription')), findsNothing);
    expect(find.byType(SwitchListTile), findsNothing);
    await scrollSheetTo(tester, find.text('当前甲')); expect(find.text('当前甲'), findsOneWidget);
    await scrollSheetTo(tester, find.text('普通甲')); expect(find.text('普通甲'), findsOneWidget);
    await scrollSheetTo(tester, find.text('法语音色')); expect(find.text(T('systemVoiceNeedsNetwork')), findsOneWidget);
    final engineB = find.byKey(const ValueKey('system-engine-engine.b'));
    await scrollSheetTo(tester, engineB);
    expect(find.descendant(of: engineB, matching: find.text('默认乙')), findsOneWidget);
    await tester.tap(engineB); await tester.pumpAndSettle();
    expect(speech.voice, voiceB); expect(speech.usesSystemVoice, isTrue);
    expect((await storage.loadReadingSettings('engine-menu')).voice, voiceB);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  testWidgets('system fallback reparses its own pause policy and keeps the current word anchor', (tester) async {
    await configureView(tester);
    final storage = AppStorage();
    final settings = ReadingSettings()..voice = TtsReader.defaultVoice..systemFallbackEnabled = true
      ..firstLineIndent = false..mergeNonSentenceBreaks = false;
    settings.setVoiceSpeechPauses(TtsReader.systemVoice,
      const SpeechPauseSettings().withPause(SpeechPauseKind.comma, 250));
    await storage.saveSettings(settings.toJson());
    final speech = _VoiceSpeech();
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: book('fallback-pauses', '甲乙丙丁，戊己庚辛。'),
      storage: storage, ttsReader: speech)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(T('read'))); await tester.pumpAndSettle();
    expect(speech.starts, hasLength(1));
    speech.onWordChanged?.call(2, 4); await tester.pumpAndSettle();
    speech.restoreSystemFallback(true); await tester.pumpAndSettle();
    expect(preparations, hasLength(2));
    expect(preparations.last.pauseSettings.millisecondsFor(SpeechPauseKind.comma), 250);
    expect(speech.starts, hasLength(2)); expect(speech.starts.last.system, isTrue);
    expect(speech.starts.last.initialOffset, 2, reason: 'Fallback must resume at the displayed word rather than sentence start');
    final saved = ReadingSettings.fromJson(await storage.loadSettings());
    expect(saved.voice, TtsReader.defaultVoice); expect(saved.systemFallbackActive, isTrue);
    expect(saved.effectiveSpeechPauses.millisecondsFor(SpeechPauseKind.comma), 250);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(seconds: 45)));
}

class _VoiceStart {
  final List<String> sentences;
  final List<int> pauses;
  final int initialOffset;
  final bool system;
  _VoiceStart(List<String> sentences, List<int>? pauses, this.initialOffset, this.system)
    : sentences = List.of(sentences), pauses = List.of(pauses ?? []);
}

class _VoiceSpeech extends TtsReader {
  _VoiceSpeech() : super(player: _UnusedAudioPlayer());
  final starts = <_VoiceStart>[];
  TtsState status = TtsState.idle;
  int sentenceIndex = -1, initialOffset = 0;
  @override TtsState get state => status;
  @override int get currentIndex => sentenceIndex;
  @override int get currentTtsOffset => initialOffset;
  void changeState(TtsState value) { status = value; onStateChanged?.call(); }
  @override Future<void> start(List<String> sentences, {List<int>? offsets, List<int>? pauseAfterMilliseconds,
    int chapterIndex = 0, int from = 0, int initialTtsOffset = 0}) async {
    starts.add(_VoiceStart(sentences, pauseAfterMilliseconds, initialTtsOffset, usesSystemVoice));
    sentenceIndex = from; initialOffset = initialTtsOffset;
    changeState(TtsState.playing); onSentenceChanged?.call(from);
  }
  @override Future<void> pause({bool interrupted = false}) async { changeState(TtsState.paused); }
  @override Future<bool> resume() async { changeState(TtsState.playing); return true; }
  @override Future<void> stop() async { changeState(TtsState.stopped); }
}

class _UnusedAudioPlayer implements AudioPlayer {
  @override PositionUpdater? positionUpdater;
  @override Stream<void> get onPlayerComplete => const Stream<void>.empty();
  @override Stream<Duration> get onPositionChanged => const Stream<Duration>.empty();
  @override Future<Duration?> getCurrentPosition() async => Duration.zero;
  @override Future<void> stop() async {}
  @override Future<void> pause() async {}
  @override Future<void> dispose() async { positionUpdater?.dispose(); }
  @override dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected audio operation: ${invocation.memberName}');
}
