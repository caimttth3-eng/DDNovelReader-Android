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
import 'package:duoduo_langdu/services/reading_text.dart';
import 'package:duoduo_langdu/services/system_tts.dart';
import 'package:duoduo_langdu/services/tts_audio_handler.dart';
import 'package:duoduo_langdu/services/tts_reader.dart';

const _spacingValues = <int>[0, 1, 2, 3];
const _spacingKey = ValueKey('reader-paragraph-spacing');

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  TtsAudioHandler? previous;
  late TtsAudioHandler handler;
  setUp(() async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    SharedPreferences.setMockInitialValues({});
    ReaderPreparation.clearMemoryCache();
    ReaderPreparation.runnerForTesting = (request) async => ReaderPreparation.prepareSynchronously(request);
    AppAppearance.setThemeMode('light');
    previous = globalAudioHandler;
    handler = TtsAudioHandler(); globalAudioHandler = handler;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('com.ddnovelreader/volume_keys'),
      (call) async => call.method == 'getMediaVolume' ? 0.5 : null);
    messenger.setMockMethodCallHandler(const MethodChannel('com.ddnovelreader/debug_log'), (_) async => null);
    messenger.setMockMethodCallHandler(DisplayCutoutService.channel, (_) async => null);
    messenger.setMockMethodCallHandler(NetworkConnectivity.channel, (_) async => null);
    messenger.setMockMethodCallHandler(SystemTtsClient.channel, (_) async => null);
    messenger.setMockMethodCallHandler(PlaybackNotifications.channel, (_) async =>
      {'supported': false, 'enabled': false, 'canRequest': false, 'asked': false});
    await Future<void>.delayed(Duration.zero);
  });
  tearDown(() {
    ReaderPreparation.runnerForTesting = null;
    ReaderPreparation.clearMemoryCache(); globalAudioHandler = previous;
    unawaited(handler.playbackState.close()); unawaited(handler.mediaItem.close());
  });

  testWidgets('paragraph spacing defaults to no extra gap and appears directly below line height', (tester) async {
    _setView(tester);
    final storage = AppStorage();
    final legacySettings = _settings().toJson()..remove('paragraphSpacingModel');
    legacySettings['paragraphSpacingLevel'] = 2;
    await storage.saveSettings(legacySettings);
    await _mount(tester, _book('default'), storage);
    await _openSettings(tester);
    await _reveal(tester, find.byKey(_spacingKey));
    _expectSelected(tester, 0);
    // The menu is lazy: revealing the taller spacing tile may evict its
    // preceding slider. Inspect the real ordered menu children rather than
    // assuming both siblings must remain mounted in a small viewport.
    final list = tester.widget<ListView>(find.ancestor(of: find.byKey(_spacingKey), matching: find.byType(ListView)).first);
    final children = (list.childrenDelegate as SliverChildListDelegate).children;
    final spacingIndex = children.indexWhere((child) => child.key == _spacingKey);
    expect(spacingIndex, greaterThan(0));
    expect(children[spacingIndex - 1], isA<ListTile>());
    expect((children[spacingIndex - 1] as ListTile).subtitle, isA<Slider>());
    expect(((children[spacingIndex - 1] as ListTile).subtitle as Slider).key,
      const ValueKey('reader-line-height'),
      reason: 'Paragraph spacing belongs immediately after line height, before the following settings group');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  testWidgets('all four paragraph spacing choices persist across menu and reader reopening', (tester) async {
    _setView(tester);
    final storage = AppStorage(), book = _book('persist');
    await storage.saveSettings(_settings().toJson());
    await _mount(tester, book, storage);
    for (final value in _spacingValues) {
      await _openSettings(tester);
      await _chooseSpacing(tester, value);
      _expectSelected(tester, value);
      expect((await _saved(storage)).paragraphSpacingLevel, value,
        reason: 'The selected spacing must use the existing persisted settings path');
      await _closeSettings(tester);
      await _openSettings(tester);
      await _reveal(tester, find.byKey(_spacingKey));
      _expectSelected(tester, value);
      await _closeSettings(tester);
    }
    // Keep a non-default choice to distinguish restoration from defaulting.
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    final reopenedStorage = AppStorage();
    await _mount(tester, book, reopenedStorage);
    await _openSettings(tester); await _reveal(tester, find.byKey(_spacingKey));
    _expectSelected(tester, 3);
    expect((await _saved(reopenedStorage)).paragraphSpacingLevel, 3);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('spacing remains independent of line height and indentation while retaining the source line', (tester) async {
    _setView(tester);
    final storage = AppStorage(), book = _book('anchor');
    await storage.saveSettings(_settings().toJson());
    await _mount(tester, book, storage);
    final body = find.byKey(const ValueKey('reader-body'));
    final list = tester.widget<ScrollablePositionedList>(body);
    list.itemScrollController!.jumpTo(index: 2);
    await tester.pumpAndSettle();
    unawaited(list.scrollOffsetController!.animateScroll(offset: 650, duration: const Duration(milliseconds: 1)));
    await tester.pumpAndSettle();
    var anchor = _anchor(tester, book);
    unawaited(list.scrollOffsetController!.animateScroll(offset: anchor.top, duration: const Duration(milliseconds: 1)));
    await tester.pumpAndSettle();
    anchor = _anchor(tester, book);
    expect(anchor.source, greaterThan(30), reason: 'The fixture must start well inside a paragraph, not at its beginning');
    await _openSettings(tester);
    await _chooseSpacing(tester, 3);
    _expectAnchor(tester, book, anchor, 'editing paragraph spacing');

    for (final height in [1.2, 2.4]) {
      final slider = find.byKey(const ValueKey('reader-line-height'));
      await _reveal(tester, slider);
      tester.widget<Slider>(slider).onChanged!(height);
      await tester.pumpAndSettle();
      final saved = await _saved(storage);
      expect(saved.lineHeight, height);
      expect(saved.paragraphSpacingLevel, 3, reason: 'Changing line height must not overwrite paragraph spacing level');
      _expectAnchor(tester, book, anchor, 'changing line height to $height');
    }

    final indent = find.byKey(const ValueKey('first-line-indent'));
    for (final enabled in [false, true]) {
      await _reveal(tester, indent);
      expect(tester.widget<SwitchListTile>(indent).value, !enabled);
      await tester.tap(indent); await tester.pumpAndSettle();
      final saved = await _saved(storage);
      expect(saved.firstLineIndent, enabled);
      expect(saved.paragraphSpacingLevel, 3, reason: 'Indentation and paragraph spacing are independent preferences');
      expect(saved.lineHeight, 2.4);
      _expectAnchor(tester, book, anchor, 'changing indentation to $enabled');
    }
    await _chooseSpacing(tester, 1);
    final saved = await _saved(storage);
    expect(saved.paragraphSpacingLevel, 1);
    expect(saved.firstLineIndent, isTrue);
    expect(saved.lineHeight, 2.4);
    _expectAnchor(tester, book, anchor, 'editing spacing after indentation and line-height changes');
    for (final level in [3, 0, 3]) {
      await _chooseSpacing(tester, level);
      expect((await _saved(storage)).paragraphSpacingLevel, level);
      _expectAnchor(tester, book, anchor, 'returning through paragraph spacing level $level');
    }
    await _closeSettings(tester);
    _expectAnchor(tester, book, anchor, 'closing the settings menu');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(seconds: 90)));
}

ReadingSettings _settings() => ReadingSettings()..fontSize = 26..lineHeight = 1.6
  ..firstLineIndent = true..informationFilter = false..mergeNonSentenceBreaks = false
  ..pageTurnMode = 'tap'..pageTurnAnimation = 'off';

void _setView(WidgetTester tester) {
  tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
}

Book _book(String id) => Book(id: 'paragraph-settings-$id', title: '段距与原文位置', filePath: '', format: BookFormat.txt,
  addedAt: DateTime(2026), chapters: [Chapter(title: '第一章', paragraphs: [
    for (var paragraph = 0; paragraph < 4; paragraph++) ReadingText.paragraph((() {
      final count = paragraph == 1 ? 1800 : paragraph == 3 ? 1200 : 70;
      final result = StringBuffer();
      for (var character = 0; character < count; character++) {
        result.writeCharCode(0x4E00 + paragraph * 2000 + character);
        if (character % 35 == 34) { result.write('。'); }
        else if (character % 15 == 14) { result.write('，'); }
      }
      result.write('。');
      return result.toString();
    })()),
  ])]);

Future<void> _mount(WidgetTester tester, Book book, AppStorage storage) async {
  await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: book, storage: storage,
    ttsReader: TtsReader(player: _SilentPlayer()))));
  await tester.pumpAndSettle();
}

Future<void> _openSettings(WidgetTester tester) async {
  if (find.byKey(const ValueKey('reader-menu')).evaluate().isEmpty) {
    await tester.tapAt(const Offset(195, 300)); await tester.pumpAndSettle();
  }
  await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('阅读设置')); await tester.pumpAndSettle();
}

Future<void> _closeSettings(WidgetTester tester) async {
  await tester.tapAt(const Offset(195, 60)); await tester.pumpAndSettle();
  if (find.byTooltip('阅读设置').evaluate().isNotEmpty) {
    await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
  }
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  final scroll = find.descendant(of: find.byType(BottomSheet).last, matching: find.byType(Scrollable)).last;
  tester.state<ScrollableState>(scroll).position.jumpTo(0);
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(finder, 180, scrollable: scroll);
  await tester.pumpAndSettle();
}

Finder _option(int value) => find.byKey(ValueKey('reader-paragraph-spacing-$value'));

Future<void> _chooseSpacing(WidgetTester tester, int value) async {
  await _reveal(tester, _option(value));
  await tester.tap(_option(value)); await tester.pumpAndSettle();
}

void _expectSelected(WidgetTester tester, int value) {
  for (final option in _spacingValues) {
    expect(_option(option), findsOneWidget);
    final chip = tester.widget<ChoiceChip>(_option(option));
    expect(chip.selected, option == value);
    expect(chip.label, isA<Text>().having((label) => label.data, 'level label', ['0', '¼字号', '½字号', '¾字号'][option]));
  }
}

Future<ReadingSettings> _saved(AppStorage storage) async => ReadingSettings.fromJson(await storage.loadSettings());

typedef _SourceAnchor = ({int source, double top});

_SourceAnchor _anchor(WidgetTester tester, Book book) {
  final display = book.chapters.single.paragraphs[1].display;
  final marker = String.fromCharCode(0x4E00 + 2000);
  final texts = find.byWidgetPredicate((widget) => widget is Text && widget.textAlign == TextAlign.justify &&
    widget.textSpan!.toPlainText().contains(marker));
  expect(texts, findsOneWidget);
  final render = tester.renderObject<RenderParagraph>(texts);
  final full = render.text.toPlainText(), body = tester.getRect(find.byKey(const ValueKey('reader-body')));
  final origin = render.localToGlobal(Offset.zero);
  final rows = <({String character, double top})>[];
  for (final box in render.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: full.length),
    boxHeightStyle: ui.BoxHeightStyle.tight)) {
    final rect = box.toRect().shift(origin);
    if (rect.width < 0.01 || rect.height < 2 || rect.top < body.top - 0.25 || rect.bottom > body.bottom + 0.25) continue;
    final a = render.getPositionForOffset(Offset(-1, box.toRect().center.dy)).offset;
    final b = render.getPositionForOffset(Offset(render.size.width + 1, box.toRect().center.dy)).offset;
    final text = full.substring(a < b ? a : b, a < b ? b : a);
    final character = RegExp('[\u4E00-\u9FFF]').firstMatch(text)?.group(0);
    if (character != null) rows.add((character: character, top: rect.top - body.top));
  }
  rows.sort((a, b) => a.top.compareTo(b.top));
  expect(rows, isNotEmpty);
  final first = rows.first;
  return (source: display.indexOf(first.character), top: first.top);
}

void _expectAnchor(WidgetTester tester, Book book, _SourceAnchor expected, String operation) {
  final actual = _anchor(tester, book);
  expect(actual.source, expected.source, reason: '$operation must retain the actual first visible source character');
  expect(actual.top, closeTo(expected.top, 0.75), reason: '$operation must not move the restored source row');
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
