import 'dart:async';
import 'dart:ui' as ui;
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:duoduo_langdu/models/book.dart';
import 'package:duoduo_langdu/screens/reader_screen.dart';
import 'package:duoduo_langdu/services/app_appearance.dart';
import 'package:duoduo_langdu/services/app_storage.dart';
import 'package:duoduo_langdu/services/display_cutout.dart';
import 'package:duoduo_langdu/services/network_connectivity.dart';
import 'package:duoduo_langdu/services/playback_notifications.dart';
import 'package:duoduo_langdu/services/reader_preparation.dart';
import 'package:duoduo_langdu/services/reader_typography.dart';
import 'package:duoduo_langdu/services/reading_text.dart';
import 'package:duoduo_langdu/services/system_tts.dart';
import 'package:duoduo_langdu/services/text_cleaner.dart';
import 'package:duoduo_langdu/services/tts_audio_handler.dart';
import 'package:duoduo_langdu/services/tts_reader.dart';

Future<void> _until(WidgetTester tester, bool Function() ready, String reason) async {
  for (var i = 0; i < 120 && !ready(); i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(ready(), isTrue, reason: reason);
}
Future<void> _action(WidgetTester tester, Future<void> action) async {
  var finished = false;
  Object? failure;
  action.then((_) { finished = true; }, onError: (Object error) { failure = error; finished = true; });
  await _until(tester, () => finished, 'A public controller/platform action must finish');
  if (failure != null) throw failure!;
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  late List<Map> spoken;
  TtsAudioHandler? previousHandler;
  setUp(() async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    SharedPreferences.setMockInitialValues({});
    AppAppearance.setThemeMode('light');
    previousHandler = globalAudioHandler; globalAudioHandler = null;
    ReaderPreparation.runnerForTesting = (request) async => ReaderPreparation.prepareSynchronously(request);
    spoken = [];
    messenger.setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('com.ddnovelreader/volume_keys'),
      (call) async => call.method == 'getMediaVolume' ? 0.5 : null);
    messenger.setMockMethodCallHandler(const MethodChannel('com.ddnovelreader/debug_log'), (_) async => null);
    messenger.setMockMethodCallHandler(DisplayCutoutService.channel, (_) async => null);
    messenger.setMockMethodCallHandler(NetworkConnectivity.channel, (_) async => null);
    messenger.setMockMethodCallHandler(PlaybackNotifications.channel, (_) async =>
      {'supported': false, 'enabled': false, 'canRequest': false, 'asked': false});
    messenger.setMockMethodCallHandler(SystemTtsClient.channel, (call) async {
      if (call.method == 'initialize') return 'test-system-engine';
      if (call.method == 'speak') {
        final request = call.arguments as Map;
        spoken.add(request);
        scheduleMicrotask(() => messenger.handlePlatformMessage(SystemTtsClient.channel.name,
          const StandardMethodCodec().encodeMethodCall(MethodCall('start', {'id': request['id']})), (_) {}));
      }
      return null;
    });
    await Future<void>.delayed(Duration.zero);
  });
  tearDown(() {
    ReaderPreparation.runnerForTesting = null; globalAudioHandler = previousHandler;
    messenger.setMockMethodCallHandler(SystemTtsClient.channel, null);
  });
  Future<void> emit(WidgetTester tester, String event, Map arguments) async {
    final completed = Completer<void>();
    messenger.handlePlatformMessage(SystemTtsClient.channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(event, arguments)), (_) => completed.complete());
    await _action(tester, completed.future);
  }
  Book source(String id, List<String> paragraphs) => Book(id: id, title: '短标题系统朗读', filePath: '',
    format: BookFormat.txt, addedAt: DateTime(2026), chapters: [Chapter(title: '开篇',
      paragraphs: paragraphs.map((text) => ReadingText.paragraph(text)).toList())]);
  Future<TtsReader> open(WidgetTester tester, Book book, {TextDirection direction = TextDirection.ltr}) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    final storage = AppStorage();
    await storage.saveSettings((ReadingSettings()..voice = TtsReader.systemVoice..pageTurnMode = 'scroll'
      ..firstLineIndent = false..mergeNonSentenceBreaks = false..informationFilter = false
      ..informationFilterLevel = 'links').toJson());
    final speech = TtsReader(player: _NoBytesPlayer());
    await tester.pumpWidget(MaterialApp(builder: (context, child) => Directionality(textDirection: direction, child: child!),
      home: ReaderScreen(book: book, storage: storage, ttsReader: speech)));
    await _until(tester, () => find.byKey(const ValueKey('reader-body')).evaluate().isNotEmpty, 'The reader must open');
    await tester.pumpAndSettle();
    return speech;
  }
  ScrollablePositionedList list(WidgetTester tester) => tester.widget<ScrollablePositionedList>(find.byKey(const ValueKey('reader-body')));
  RenderParagraph paragraph(WidgetTester tester, String startsWith) => tester.renderObjectList<RenderParagraph>(
    find.descendant(of: find.byKey(const ValueKey('reader-body')), matching: find.byType(RichText)))
      .firstWhere((render) => render.text.toPlainText().replaceAll('\u200B', '').replaceAll('\uFFFC', '').startsWith(startsWith));
  Future<void> start(WidgetTester tester) async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.tap(find.byTooltip('朗读'));
    await _until(tester, () => spoken.isNotEmpty, 'A foreground read action must reach the real native system engine');
    await tester.pumpAndSettle();
  }

  for (final scenario in [('short', '第 3 章 一寸金03', TextDirection.ltr),
    ('rtl', 'אבגדהוזח', TextDirection.rtl), ('bottom-padding', '第 3 章 一寸金03', TextDirection.ltr)]) {
    testWidgets('visible short title starts at its first logical character: ${scenario.$1}', (tester) async {
      final speech = await open(tester, source(scenario.$1, [scenario.$2, List.filled(50, '后续正文持续显示。').join()]), direction: scenario.$3);
      list(tester).itemScrollController!.jumpTo(index: 1, alignment: 0); await tester.pumpAndSettle();
      if (scenario.$1 == 'bottom-padding') {
        final render = paragraph(tester, scenario.$2), body = tester.getRect(find.byKey(const ValueKey('reader-body')));
        final delta = render.localToGlobal(Offset.zero).dy + render.size.height - body.top + 0.5;
        await _action(tester, list(tester).scrollOffsetController!.animateScroll(offset: delta, duration: const Duration(milliseconds: 1)));
        await tester.pumpAndSettle();
        final positions = list(tester).itemPositionsNotifier!.itemPositions.value.where((p) => p.itemLeadingEdge < 1 && p.itemTrailingEdge > 0).toList()
          ..sort((a, b) => a.index.compareTo(b.index));
        expect(positions.first.index, 1, reason: 'Only paragraph padding should remain at the top, before the following paragraph');
        expect(paragraph(tester, scenario.$2).localToGlobal(Offset(0, render.size.height)).dy,
          lessThan(tester.getRect(find.byKey(const ValueKey('reader-body'))).top));
      }
      await start(tester);
      expect(spoken.single['text'], const TextCleaner().clean(scenario.$2).tts,
        reason: 'A short title or its trailing padding must not become its final character');
      expect(speech.currentTtsOffset, 0);
      await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    }, timeout: const Timeout(Duration(seconds: 45)));
  }

  testWidgets('a valid multiline visible row keeps its actual sentence offset', (tester) async {
    final text = List.filled(60, '甲乙丙丁戊己庚辛壬癸').join() + '。';
    final speech = await open(tester, source('multiline', [text]));
    list(tester).itemScrollController!.jumpTo(index: 1, alignment: 0); await tester.pumpAndSettle();
    final render = paragraph(tester, '甲乙'), plain = render.text.toPlainText();
    final rows = <Rect>[];
    for (final box in render.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: plain.length), boxHeightStyle: ui.BoxHeightStyle.includeLineSpacingMiddle)) {
      final rect = box.toRect();
      if (rect.width > 0.01 && rect.height > 2 && rows.every((row) => (row.top - rect.top).abs() > 0.5)) rows.add(rect);
    }
    rows.sort((a, b) => a.top.compareTo(b.top)); expect(rows.length, greaterThan(5));
    final row = rows[3];
    final layoutOffset = render.getPositionForOffset(Offset(row.left - 1, row.center.dy)).offset;
    final offset = ReaderTypography.sourceOffset(text, layoutOffset); expect(offset, greaterThan(0));
    final body = tester.getRect(find.byKey(const ValueKey('reader-body')));
    await _action(tester, list(tester).scrollOffsetController!.animateScroll(
      offset: render.localToGlobal(Offset(0, row.top)).dy - body.top, duration: const Duration(milliseconds: 1)));
    await tester.pumpAndSettle(); await start(tester);
    expect(spoken.single['text'], const TextCleaner().clean(text.substring(offset)).tts);
    expect(speech.currentTtsOffset, offset, reason: 'Fixing invalid end offsets must preserve a valid mid-paragraph starting row');
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(seconds: 45)));

  for (final oldOffset in [9, 596]) {
  testWidgets('natural chapter completion clears old word offset ' + oldOffset.toString() + ' before a new short title', (tester) async {
    final before = List.filled(60, '甲乙丙丁戊己庚辛壬癸').join() + '。';
    const title = '第 3 章 一寸金03';
    final book = Book(id: 'natural-cross-chapter-title', title: '自然跨章', filePath: '', format: BookFormat.txt,
      addedAt: DateTime(2026), chapters: [
        Chapter(title: '第二章', paragraphs: [ReadingText.paragraph(before)]),
        Chapter(title: '第三章', paragraphs: [ReadingText.paragraph(title), ReadingText.paragraph('新章节后续正文。')]),
      ]);
    final speech = await open(tester, book);
    await start(tester); expect(spoken, hasLength(1));
    final oldId = spoken.single['id'];
    await emit(tester, 'range', {'id': oldId, 'start': oldOffset, 'end': oldOffset + 2});
    await tester.pumpAndSettle();
    expect(speech.currentTtsOffset, oldOffset); expect(speech.currentWordStart, oldOffset);
    if (oldOffset == 9) {
      expect(oldOffset, lessThan(title.length), reason: 'A valid old offset must expose stale cross-chapter reuse independently of invalid-offset protection');
    } else {
      expect(oldOffset, greaterThan(title.length), reason: 'Also retain the invalid old-offset boundary regression');
    }
    await emit(tester, 'done', {'id': oldId});
    await _until(tester, () => spoken.length >= 2, 'The previous chapter must naturally complete into the new title');
    await tester.pumpAndSettle();
    expect(spoken, hasLength(2), reason: 'Automatic chapter follow must synthesize the new title once');
    expect(spoken.last['text'], const TextCleaner().clean(title).tts,
      reason: 'The previous chapter final word must never be reused as the new title starting offset');
    expect(speech.currentIndex, 0); expect(speech.currentTtsOffset, 0);
    await emit(tester, 'range', {'id': oldId, 'start': 0, 'end': 1});
    await tester.pumpAndSettle(); expect(spoken, hasLength(2)); expect(speech.currentTtsOffset, 0);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(seconds: 45)));
  }

  testWidgets('natural paragraph completion reads an entire short title once while following scroll', (tester) async {
    final before = List.filled(60, '甲乙丙丁戊己庚辛壬癸').join() + '。';
    const title = '第 3 章 一寸金03';
    final speech = await open(tester, source('natural-title', [before, title, '这是标题之后的正文。']));
    await start(tester); expect(spoken, hasLength(1));
    final oldId = spoken.single['id'];
    await emit(tester, 'range', {'id': oldId, 'start': before.length - 5, 'end': before.length - 1});
    await tester.pumpAndSettle();
    await emit(tester, 'done', {'id': oldId});
    await _until(tester, () => spoken.length >= 2, 'Completing the first paragraph must naturally advance to the title');
    await tester.pumpAndSettle();
    expect(spoken, hasLength(2), reason: 'Viewport follow must not issue an extra seek/restart on the title');
    expect(spoken.last['text'], const TextCleaner().clean(title).tts);
    expect(speech.currentTtsOffset, 0);
    await emit(tester, 'range', {'id': oldId, 'start': 0, 'end': 1});
    await tester.pumpAndSettle(); expect(spoken, hasLength(2));
    final titleId = spoken.last['id'];
    await emit(tester, 'done', {'id': titleId});
    await _until(tester, () => spoken.length >= 3, 'The title must continue to the following paragraph');
    await tester.pumpAndSettle();
    expect(spoken, hasLength(3)); expect(spoken.last['text'], '这是标题之后的正文。');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(seconds: 45)));
}

class _NoBytesPlayer implements AudioPlayer {
  @override PositionUpdater? positionUpdater;
  @override Stream<void> get onPlayerComplete => const Stream<void>.empty();
  @override Stream<Duration> get onPositionChanged => const Stream<Duration>.empty();
  @override Future<Duration?> getCurrentPosition() async => Duration.zero;
  @override Future<void> stop() async {}
  @override Future<void> pause() async {}
  @override Future<void> dispose() async { positionUpdater?.dispose(); }
  @override Future<void> play(Source source, {double? volume, double? balance, AudioContext? ctx, Duration? position, PlayerMode? mode}) async =>
    throw StateError('System speech must not use BytesSource playback');
  @override dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected player operation ${invocation.memberName}');
}