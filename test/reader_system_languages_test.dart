import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:duoduo_langdu/i18n.dart';
import 'package:duoduo_langdu/models/book.dart';
import 'package:duoduo_langdu/screens/reader_screen.dart';
import 'package:duoduo_langdu/services/app_appearance.dart';
import 'package:duoduo_langdu/services/app_storage.dart';
import 'package:duoduo_langdu/services/display_cutout.dart';
import 'package:duoduo_langdu/services/network_connectivity.dart';
import 'package:duoduo_langdu/services/playback_notifications.dart';
import 'package:duoduo_langdu/services/reader_preparation.dart';
import 'package:duoduo_langdu/services/reading_text.dart';
import 'package:duoduo_langdu/services/system_tts.dart';
import 'package:duoduo_langdu/services/tts_reader.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  const aiEngine = 'example.ai';
  const tingtingEngine = 'example.tingting';
  const aiDefault = '__system_tts__:@engine:example.ai:';
  const aiEnglish = '__system_tts__:@language:example.ai:en-US';
  const tingtingChinese = '__system_tts__:@language:example.tingting:zh-CN';
  final checks = <String>[];
  var settingsOpens = 0;
  final installed = <String, Object?>{};

  setUp(() async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    SharedPreferences.setMockInitialValues({});
    AppI18n.current = AppLang.zhHans;
    AppAppearance.setThemeMode('light');
    checks.clear();
    settingsOpens = 0;
    installed
      ..clear()
      ..addAll({
        aiEngine: [
          {'id': 'zh-CN', 'name': '中文'},
          {'id': 'en-US', 'name': 'English'},
        ],
        tingtingEngine: [
          {'id': 'zh-CN', 'name': '中文'},
        ],
      });
    ReaderPreparation.runnerForTesting = (request) async => ReaderPreparation.prepareSynchronously(request);
    messenger.setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('com.ddnovelreader/volume_keys'),
      (call) async => ['getMediaVolume', 'getSystemBrightness'].contains(call.method) ? 0.5 : null);
    messenger.setMockMethodCallHandler(const MethodChannel('com.ddnovelreader/debug_log'), (_) async => null);
    messenger.setMockMethodCallHandler(DisplayCutoutService.channel, (_) async => null);
    messenger.setMockMethodCallHandler(NetworkConnectivity.channel, (_) async => null);
    messenger.setMockMethodCallHandler(PlaybackNotifications.channel, (_) async =>
      {'supported': false, 'enabled': false, 'canRequest': false, 'asked': false});
    messenger.setMockMethodCallHandler(SystemTtsClient.channel, (call) async {
      if (call.method == 'openSettings') { settingsOpens++; return true; }
      if (call.method == 'voiceCatalog') {
        return {'defaultEngine': aiEngine, 'engines': [
          {'id': aiEngine, 'name': 'AiService TTS', 'defaultVoiceQuality': 'enhanced', 'voices': [
            {'id': 'fr-FR', 'name': 'Advertised French', 'lang': 'fr-FR', 'quality': 'enhanced'},
          ]},
          {'id': tingtingEngine, 'name': 'iOS-婷婷', 'defaultVoiceQuality': 'enhanced', 'voices': [
            {'id': 'tingting_zh_CN', 'name': 'tingting_zh_CN', 'lang': 'zh-CN', 'quality': 'enhanced'},
          ]},
        ]};
      }
      if (call.method == 'checkLanguages') {
        final engine = (call.arguments as Map)['engine'] as String;
        checks.add(engine);
        final response = installed[engine];
        if (response is Exception) throw response;
        return response ?? [];
      }
      return null;
    });
    await Future<void>.delayed(Duration.zero);
  });

  tearDown(() { ReaderPreparation.runnerForTesting = null; });

  Future<({AppStorage storage, _LanguageSpeech speech, String bookId})> openReader(WidgetTester tester, String bookId) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final storage = AppStorage(), speech = _LanguageSpeech();
    await storage.saveSettings((ReadingSettings()..voice = aiDefault..systemVoiceEnhancedOnly = true).toJson());
    final book = Book(id: bookId, title: '系统语言选择', filePath: '', format: BookFormat.txt,
      addedAt: DateTime(2026), chapters: [Chapter(title: '第一章', paragraphs: [ReadingText.paragraph('甲乙丙丁。')])]);
    await tester.pumpWidget(MaterialApp(theme: AppAppearance.theme(false),
      home: ReaderScreen(book: book, storage: storage, ttsReader: speech)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(T('read')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(195, 300));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reading-voice')), findsOneWidget);
    return (storage: storage, speech: speech, bookId: bookId);
  }

  Future<void> openVoiceSelector(WidgetTester tester) async {
    final button = find.byKey(const ValueKey('reading-voice'));
    if (button.evaluate().isEmpty) {
      await tester.tapAt(const Offset(195, 300));
      await tester.pumpAndSettle();
    }
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  Future<void> openLanguages(WidgetTester tester, String engine) async {
    final button = find.byKey(ValueKey('system-engine-languages-$engine'));
    final scrollable = find.descendant(of: find.byType(BottomSheet).last, matching: find.byType(Scrollable)).last;
    await tester.scrollUntilVisible(button, 150, scrollable: scrollable);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  Future<void> disposeReader(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }

  testWidgets('voice selection markers precede names in a fixed column regardless of action count', (tester) async {
    await openReader(tester, 'voice-choice-leading');
    await openVoiceSelector(tester);
    final gear = find.byKey(const ValueKey('system-voice-settings'));
    final header = find.byKey(const ValueKey('reader-menu-section-voiceSectionLocal'));
    await tester.ensureVisible(gear); await tester.pumpAndSettle();
    expect(tester.widget(gear), isA<IconButton>());
    expect(tester.getCenter(gear).dy, closeTo(tester.getCenter(header).dy, .5));
    expect(find.widgetWithText(ListTile, T('voiceManageSettings')), findsNothing);
    await tester.tap(gear); await tester.pumpAndSettle();
    expect(settingsOpens, 1);
    await tester.tap(find.byKey(const ValueKey('voice-group-online-zh-Hans')));
    await tester.pumpAndSettle();
    final scrollable = find.descendant(of: find.byType(BottomSheet).last, matching: find.byType(Scrollable)).last;
    final onlineAction = find.byKey(const ValueKey('cache-voice-zh-CN-XiaoxiaoNeural'));
    await tester.scrollUntilVisible(onlineAction, 150, scrollable: scrollable);
    await tester.pumpAndSettle();
    final online = tester.widget<ListTile>(find.ancestor(of: onlineAction, matching: find.byType(ListTile)).first);
    final onlineMarker = tester.getRect(find.byWidget(online.leading!));
    final onlineTitle = tester.getRect(find.byWidget(online.title!));
    expect(onlineMarker.right, lessThan(onlineTitle.left));
    expect((online.leading as Icon).icon, Icons.radio_button_off);
    final localTile = find.byKey(const ValueKey('system-engine-example.ai'));
    await tester.scrollUntilVisible(localTile, 250, scrollable: scrollable);
    await tester.pumpAndSettle();
    final local = tester.widget<ListTile>(localTile);
    final localMarker = tester.getRect(find.byWidget(local.leading!));
    final localTitle = tester.getRect(find.byWidget(local.title!));
    expect(localMarker.left, closeTo(onlineMarker.left, .5));
    expect(localTitle.left, closeTo(onlineTitle.left, .5));
    expect(localMarker.right, lessThan(localTitle.left));
    expect((local.leading as Icon).icon, Icons.radio_button_checked);
    expect(find.descendant(of: find.byWidget(local.trailing!), matching: find.byIcon(Icons.radio_button_checked)), findsNothing);
    final languageButton = find.byKey(const ValueKey('system-engine-languages-example.ai'));
    final pauseButton = find.byKey(const ValueKey('pause-voice-$aiDefault'));
    expect(tester.getCenter(pauseButton).dx - tester.getCenter(languageButton).dx, closeTo(40, .5));
    expect(tester.takeException(), isNull);
    await disposeReader(tester);
  });

  testWidgets('installed language check is explicit and the selected language survives reopening until the engine row resets it', (tester) async {
    final reader = await openReader(tester, 'installed-language-choice');
    expect(checks, isEmpty);
    await openVoiceSelector(tester);
    expect(checks, isEmpty, reason: 'Browsing engines must not trigger the installed-data activity');
    expect(find.text('Advertised French'), findsNothing);
    await openLanguages(tester, aiEngine);
    expect(checks, [aiEngine]);
    expect(find.text('AiService TTS · 语言'), findsOneWidget);
    expect(find.byKey(const ValueKey('system-language-zh-CN')), findsOneWidget);
    expect(find.byKey(const ValueKey('system-language-en-US')), findsOneWidget);
    expect(find.byKey(const ValueKey('system-language-fr-FR')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('system-language-en-US')));
    await tester.pumpAndSettle();
    expect(reader.speech.voice, aiEnglish);
    expect((await reader.storage.loadReadingSettings(reader.bookId)).voice, aiEnglish);

    await openVoiceSelector(tester);
    expect(checks, [aiEngine], reason: 'Reopening the selector does not rerun the installed-data check');
    await openLanguages(tester, aiEngine);
    final english = tester.widget<ListTile>(find.byKey(const ValueKey('system-language-en-US')));
    expect((english.leading as Icon).icon, Icons.radio_button_checked);
    expect((tester.widget<ListTile>(find.byKey(const ValueKey('system-language-default'))).leading as Icon).icon,
      Icons.radio_button_off);
    await tester.tap(find.text(T('cancel')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('system-engine-example.ai')));
    await tester.pumpAndSettle();
    expect(reader.speech.voice, aiDefault);
    expect((await reader.storage.loadReadingSettings(reader.bookId)).voice, aiDefault);
    await openVoiceSelector(tester);
    await openLanguages(tester, aiEngine);
    expect((tester.widget<ListTile>(find.byKey(const ValueKey('system-language-default'))).leading as Icon).icon,
      Icons.radio_button_checked);
    expect(tester.takeException(), isNull);
    await disposeReader(tester);
  });

  testWidgets('installed language options and persisted selection stay inside the requested engine', (tester) async {
    final reader = await openReader(tester, 'installed-language-scopes');
    await openVoiceSelector(tester);
    await openLanguages(tester, aiEngine);
    await tester.tap(find.byKey(const ValueKey('system-language-en-US')));
    await tester.pumpAndSettle();
    expect(reader.speech.voice, aiEnglish);
    await openVoiceSelector(tester);
    await openLanguages(tester, tingtingEngine);
    expect(checks, [aiEngine, tingtingEngine]);
    expect(find.text('iOS-婷婷 · 语言'), findsOneWidget);
    expect(find.byKey(const ValueKey('system-language-zh-CN')), findsOneWidget);
    expect(find.byKey(const ValueKey('system-language-en-US')), findsNothing,
      reason: 'AiService installed languages cannot become Tingting options');
    expect(find.text('Advertised French'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('system-language-zh-CN')));
    await tester.pumpAndSettle();
    expect(reader.speech.voice, tingtingChinese);
    expect((await reader.storage.loadReadingSettings(reader.bookId)).voice, tingtingChinese);
    expect(tester.takeException(), isNull);
    await disposeReader(tester);
  });

  for (final failed in [false, true]) {
    testWidgets('an unavailable installed-language result never expands advertised voices (failure=$failed)', (tester) async {
      installed[aiEngine] = failed ? PlatformException(code: 'check_unavailable') : <Object>[];
      final reader = await openReader(tester, 'installed-language-empty-$failed');
      await openVoiceSelector(tester);
      expect(checks, isEmpty);
      await openLanguages(tester, aiEngine);
      expect(checks, [aiEngine]);
      expect(find.text(T('systemVoiceLanguagesUnavailable')), findsOneWidget);
      expect(find.byKey(const ValueKey('system-language-default')), findsNothing);
      expect(find.byKey(const ValueKey('system-language-zh-CN')), findsNothing);
      expect(find.byKey(const ValueKey('system-language-en-US')), findsNothing);
      expect(find.text('Advertised French'), findsNothing);
      expect(find.descendant(of: find.byType(AlertDialog), matching: find.byType(ExpansionTile)), findsNothing);
      await tester.tap(find.text(T('cancel')));
      await tester.pumpAndSettle();
      expect(reader.speech.voice, aiDefault);
      expect((await reader.storage.loadReadingSettings(reader.bookId)).voice, aiDefault);
      expect(tester.takeException(), isNull);
      await disposeReader(tester);
    });
  }
}

class _LanguageSpeech extends TtsReader {
  _LanguageSpeech() : super(player: _UnusedAudioPlayer());
  TtsState status = TtsState.idle;
  int sentenceIndex = -1, initialOffset = 0;
  @override TtsState get state => status;
  @override int get currentIndex => sentenceIndex;
  @override int get currentTtsOffset => initialOffset;
  void changeState(TtsState value) { status = value; onStateChanged?.call(); }
  @override Future<void> start(List<String> sentences, {List<int>? offsets, List<int>? pauseAfterMilliseconds,
    int chapterIndex = 0, int from = 0, int initialTtsOffset = 0}) async {
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
