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

  Future<void> expandPauses(WidgetTester tester) async {
    expect(find.byKey(const ValueKey('pause-slider-comma')), findsNothing);
    expect(find.byKey(const ValueKey('pause-apply')), findsNothing);
    final expand = find.byKey(const ValueKey('pause-expand'));
    await scrollSheetTo(tester, expand); await tester.tap(expand); await tester.pumpAndSettle();
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
    expect(voicePause, findsOneWidget);
    expect(find.byKey(const ValueKey('pause-customized-$targetVoice')), findsNothing);
    for (final voice in edgeVoices) {
      final cache = find.byKey(ValueKey('cache-voice-${voice.id}'));
      await scrollSheetTo(tester, cache);
      expect(cache, findsOneWidget);
      expect(find.byKey(ValueKey('pause-voice-${voice.id}')), findsNothing,
        reason: 'Online voices have their cache action without an added-pause action');
    }
    await scrollSheetTo(tester, voicePause, delta: -150);
    await tester.tap(voicePause); await tester.pumpAndSettle();
    await expandPauses(tester);
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
    expect(task.store.voice, targetVoice); expect(task.store.rate, 1.8);
    expect(task.store.textFingerprint, currentFingerprint);
    expect(task.store.textFingerprint, 'words1-${ReadingText.fingerprint(task.book)}');
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

  testWidgets('system fallback reparses its own pause policy and keeps the current word anchor', (tester) async {
    await configureView(tester);
    final storage = AppStorage();
    final settings = ReadingSettings()..voice = TtsReader.defaultVoice
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
  @override Future<void> pause() async { changeState(TtsState.paused); }
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
