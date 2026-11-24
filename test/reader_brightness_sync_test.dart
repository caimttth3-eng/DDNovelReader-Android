import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
import 'package:duoduo_langdu/services/tts_audio_handler.dart';
import 'package:duoduo_langdu/services/tts_reader.dart';
import 'package:duoduo_langdu/widgets/reader_brightness_control.dart';

const _slider = ValueKey('quick-brightness');

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  TtsAudioHandler? previous;
  late TtsAudioHandler handler;
  late Future<Object?> Function(MethodCall) brightnessCall;
  late List<MethodCall> calls;
  setUp(() async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    SharedPreferences.setMockInitialValues({});
    ReaderPreparation.clearMemoryCache();
    ReaderPreparation.runnerForTesting = (request) async => ReaderPreparation.prepareSynchronously(request);
    AppAppearance.setThemeMode('light');
    previous = globalAudioHandler; handler = TtsAudioHandler(); globalAudioHandler = handler;
    calls = [];
    brightnessCall = (_) async => null;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('com.ddnovelreader/volume_keys'), (call) async {
      if (call.method == 'getMediaVolume') return .5;
      if (['setScreenBrightness', 'resetScreenBrightness', 'getSystemBrightness'].contains(call.method)) {
        calls.add(call); return brightnessCall(call);
      }
      return null;
    });
    messenger.setMockMethodCallHandler(const MethodChannel('com.ddnovelreader/debug_log'), (_) async => null);
    messenger.setMockMethodCallHandler(DisplayCutoutService.channel, (_) async => null);
    messenger.setMockMethodCallHandler(NetworkConnectivity.channel, (_) async => null);
    messenger.setMockMethodCallHandler(SystemTtsClient.channel, (_) async => null);
    messenger.setMockMethodCallHandler(PlaybackNotifications.channel, (_) async =>
      {'supported': false, 'enabled': false, 'canRequest': false, 'asked': false});
    await Future<void>.delayed(Duration.zero);
  });
  tearDown(() {
    ReaderPreparation.runnerForTesting = null; ReaderPreparation.clearMemoryCache();
    globalAudioHandler = previous;
    unawaited(handler.playbackState.close()); unawaited(handler.mediaItem.close());
  });

  testWidgets('A waits for native reset and its bounded reread moves the thumb to current system brightness', (tester) async {
    final reset = Completer<Object?>();
    addTearDown(() { if (!reset.isCompleted) reset.complete(null); });
    var reads = 0;
    brightnessCall = (call) async {
      if (call.method == 'resetScreenBrightness') return reset.future;
      if (call.method == 'getSystemBrightness') return ++reads == 1 ? .24 : .64;
      return null;
    };
    final storage = await _mount(tester, 'reset-before-read');
    await _manual(tester, .125);
    expect(find.byKey(const ValueKey('reader-dim-mask')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('brightness-auto'))); await tester.pump();
    expect(calls.where((call) => call.method == 'resetScreenBrightness'), hasLength(1));
    expect(reads, 0, reason: 'Reading before native reset completes can retain the old application brightness');
    reset.complete(null);
    await tester.pump(); await tester.pumpAndSettle();
    // A system reset can settle after the first read. Explicitly service the
    // single bounded 300ms retry instead of assuming pumpAndSettle waits for it.
    await tester.pump(const Duration(milliseconds: 350)); await tester.pumpAndSettle();
    expect(reads, greaterThanOrEqualTo(2));
    expect(_value(tester), closeTo(ReaderBrightnessControl.fromSystemBrightness(.64), 1e-6));
    expect(find.byKey(const ValueKey('reader-dim-mask')), findsNothing);
    final saved = await storage.loadSettings();
    expect(saved['automaticBrightness'], isTrue);
    expect(saved['brightness'], closeTo(ReaderBrightnessControl.fromSystemBrightness(.64), 1e-6));
    expect(calls.lastWhere((call) => ['setScreenBrightness', 'resetScreenBrightness'].contains(call.method)).method,
      'resetScreenBrightness');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  testWidgets('an old A read cannot overwrite a newer A after an intervening manual drag', (tester) async {
    final oldRead = Completer<Object?>();
    addTearDown(() { if (!oldRead.isCompleted) oldRead.complete(.08); });
    var reads = 0;
    brightnessCall = (call) async {
      if (call.method == 'getSystemBrightness') return ++reads == 1 ? oldRead.future : .88;
      return null;
    };
    final storage = await _mount(tester, 'two-auto-generations');
    await tester.tap(find.byKey(const ValueKey('brightness-auto'))); await tester.pumpAndSettle();
    expect(reads, 1);
    await _manual(tester, .15);
    expect((await storage.loadSettings())['automaticBrightness'], isFalse);
    await tester.tap(find.byKey(const ValueKey('brightness-auto'))); await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 350)); await tester.pumpAndSettle();
    final expected = ReaderBrightnessControl.fromSystemBrightness(.88);
    expect(_value(tester), closeTo(expected, 1e-6));
    oldRead.complete(.08);
    await tester.pump(); await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 350)); await tester.pumpAndSettle();
    expect(_value(tester), closeTo(expected, 1e-6), reason: 'Automatic=true again does not make a previous read generation current');
    final saved = await storage.loadSettings();
    expect(saved['automaticBrightness'], isTrue); expect(saved['brightness'], closeTo(expected, 1e-6));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  testWidgets('a pending A read cannot replace a newer extra-dim manual selection', (tester) async {
    final oldRead = Completer<Object?>();
    addTearDown(() { if (!oldRead.isCompleted) oldRead.complete(.92); });
    brightnessCall = (call) async => call.method == 'getSystemBrightness' ? oldRead.future : null;
    final storage = await _mount(tester, 'manual-revokes-auto');
    await tester.tap(find.byKey(const ValueKey('brightness-auto'))); await tester.pumpAndSettle();
    await _manual(tester, .12);
    final selected = _value(tester);
    oldRead.complete(.92);
    await tester.pump(); await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 350)); await tester.pumpAndSettle();
    expect(_value(tester), selected);
    expect(find.byKey(const ValueKey('reader-dim-mask')), findsOneWidget);
    final saved = await storage.loadSettings();
    expect(saved['automaticBrightness'], isFalse); expect(saved['brightness'], closeTo(selected, 1e-6));
    expect(calls.lastWhere((call) => call.method == 'setScreenBrightness').arguments, .01,
      reason: 'Extra dimming keeps the existing minimum hardware brightness and reader overlay policy');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  for (final automatic in [false, true]) {
    testWidgets('queued filter and typography drafts preserve newer ${automatic ? 'automatic' : 'manual'} brightness', (tester) async {
      brightnessCall = (call) async => call.method == 'getSystemBrightness' ? .76 : null;
      final storage = await _mount(tester, 'filter-draft-$automatic');
      final entered = Completer<void>(), gate = Completer<void>();
      addTearDown(() { if (!gate.isCompleted) gate.complete(); });
      ReaderPreparation.clearMemoryCache();
      ReaderPreparation.runnerForTesting = (request) async {
        if (request.filter != 'none') {
          if (!entered.isCompleted) entered.complete();
          await gate.future;
        }
        return ReaderPreparation.prepareSynchronously(request);
      };
      await tester.tap(find.byTooltip('阅读设置')); await tester.pumpAndSettle();
      await _revealSetting(tester, const ValueKey('information-filter'), 160);
      await tester.tap(find.byKey(const ValueKey('information-filter'))); await tester.pumpAndSettle();
      expect(entered.isCompleted, isTrue, reason: 'The real filter transaction must be suspended before its final settings assignment');
      await _revealSetting(tester, const ValueKey('reader-line-height'), -160);
      await _setLineHeight(tester, 2.0);
      expect((await storage.loadSettings())['lineHeight'], 1.6,
        reason: 'Typography must still be queued behind the held preparation');
      await _dismissSettingsAndOpenQuick(tester);
      if (automatic) {
        await tester.tap(find.byKey(const ValueKey('brightness-auto'))); await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 350)); await tester.pumpAndSettle();
      } else {
        await _manual(tester, .12);
      }
      final selected = _value(tester);
      expect(selected, automatic ? closeTo(ReaderBrightnessControl.fromSystemBrightness(.76), 1e-6) : closeTo(.12, .015));
      gate.complete(); await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 350)); await tester.pumpAndSettle();
      final saved = await storage.loadSettings();
      expect(saved['informationFilter'], isTrue, reason: 'Do not pass by silently abandoning the held filter change');
      expect(saved['lineHeight'], closeTo(2.0, 1e-6), reason: 'The pending typography draft must really commit');
      expect(saved['automaticBrightness'], automatic);
      expect(saved['brightness'], closeTo(selected, 1e-6));
      expect(_value(tester), closeTo(selected, 1e-6), reason: 'A late reformat draft must not own brightness');
      expect(find.byKey(const ValueKey('reader-dim-mask')), automatic ? findsNothing : findsOneWidget);
      final lastNative = calls.lastWhere((call) => ['setScreenBrightness', 'resetScreenBrightness'].contains(call.method));
      expect(lastNative.method, automatic ? 'resetScreenBrightness' : 'setScreenBrightness');
      if (!automatic) expect(lastNative.arguments, .01);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    });
  }

  testWidgets('a stale open typography sheet preserves system brightness refreshed on resume', (tester) async {
    var system = .2;
    brightnessCall = (call) async => call.method == 'getSystemBrightness' ? system : null;
    final storage = await _mount(tester, 'resume-during-open-draft');
    await tester.tap(find.byKey(const ValueKey('brightness-auto'))); await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 350)); await tester.pumpAndSettle();
    expect(_value(tester), closeTo(ReaderBrightnessControl.fromSystemBrightness(.2), 1e-6));
    await tester.tap(find.byTooltip('阅读设置')); await tester.pumpAndSettle();
    system = .84;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    final expected = ReaderBrightnessControl.fromSystemBrightness(.84);
    expect((await storage.loadSettings())['brightness'], closeTo(expected, 1e-6),
      reason: 'The lifecycle refresh must really update live settings while the old sheet remains open');
    await _revealSetting(tester, const ValueKey('reader-line-height'), 160);
    await _setLineHeight(tester, 2.0);
    await _dismissSettingsAndOpenQuick(tester);
    final saved = await storage.loadSettings();
    expect(saved['lineHeight'], closeTo(2.0, 1e-6));
    expect(saved['informationFilter'], isFalse, reason: 'This exercises direct geometry assignment without text preparation');
    expect(saved['automaticBrightness'], isTrue);
    expect(saved['brightness'], closeTo(expected, 1e-6));
    expect(_value(tester), closeTo(expected, 1e-6));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });
}

Future<void> _revealSetting(WidgetTester tester, ValueKey<String> key, double step) async {
  final scroll = find.descendant(of: find.byType(BottomSheet).last, matching: find.byType(Scrollable)).last;
  await tester.scrollUntilVisible(find.byKey(key), step, scrollable: scroll); await tester.pumpAndSettle();
}

Future<void> _setLineHeight(WidgetTester tester, double value) async {
  final slider = find.byKey(const ValueKey('reader-line-height'));
  // This case targets asynchronous settings ownership. Slider hit testing is
  // independently covered by reader_touch_slider_test, so use its public
  // callback to select an exact supported line-height step here.
  tester.widget<Slider>(slider).onChanged!(value);
  await tester.pumpAndSettle();
  expect(tester.widget<Slider>(slider).value, closeTo(value, 1e-6));
}

Future<void> _dismissSettingsAndOpenQuick(WidgetTester tester) async {
  await tester.tapAt(const Offset(195, 60)); await tester.pumpAndSettle();
  expect(find.byType(BottomSheet), findsNothing);
  await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
  expect(find.byKey(_slider), findsOneWidget);
}

double _value(WidgetTester tester) => tester.widget<Slider>(find.byKey(_slider)).value;

Future<void> _manual(WidgetTester tester, double fraction) async {
  final rect = tester.getRect(find.byKey(_slider));
  await tester.tapAt(Offset(rect.left + 12 + (rect.width - 24) * fraction, rect.top + 2));
  await tester.pumpAndSettle();
  expect(_value(tester), closeTo(fraction, .015), reason: 'Manual interaction must use the enlarged actual slider hit target');
}

Future<AppStorage> _mount(WidgetTester tester, String id) async {
  tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
  final storage = AppStorage();
  await storage.saveSettings((ReadingSettings()..automaticBrightness = false..brightness = .1
    ..fontSize = 20..informationFilter = false..mergeNonSentenceBreaks = false
    ..pageTurnMode = 'tap'..pageTurnAnimation = 'off').toJson());
  final book = Book(id: 'brightness-sync-$id', title: '亮度触摸验证', filePath: '', format: BookFormat.txt,
    addedAt: DateTime(2026), chapters: [Chapter(title: '第一章', paragraphs: [
      ReadingText.paragraph(List.filled(20, '山间的清风吹过树梢，远处的小路通向村庄。').join()),
    ])]);
  await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: book, storage: storage,
    ttsReader: TtsReader(player: _SilentPlayer()))));
  await tester.pumpAndSettle();
  if (find.byKey(const ValueKey('reader-menu')).evaluate().isEmpty) {
    await tester.tapAt(const Offset(195, 300)); await tester.pumpAndSettle();
  }
  await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
  expect(find.byKey(_slider), findsOneWidget);
  return storage;
}

class _SilentPlayer implements AudioPlayer {
  @override PositionUpdater? positionUpdater;
  @override Stream<void> get onPlayerComplete => const Stream.empty();
  @override Stream<Duration> get onPositionChanged => const Stream.empty();
  @override Future<Duration?> getCurrentPosition() async => Duration.zero;
  @override Future<void> stop() async {}
  @override Future<void> pause() async {}
  @override Future<void> dispose() async { positionUpdater?.dispose(); }
  @override dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected player operation: ${invocation.memberName}');
}
