import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
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

const _fontSize = 39.0, _lineHeight = 1.6;
typedef _Row = ({String key, int item, Rect rect, List<int> units});
typedef _Page = ({List<_Row> rows, List<_Row> all, Rect body, double step});

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  final font = File('${Platform.environment['SystemRoot']}\\Fonts\\msyh.ttc');
  late TtsAudioHandler handler;
  TtsAudioHandler? previous;
  setUpAll(() async {
    if (!font.existsSync()) return;
    await (FontLoader('ContinuousReaderCjk')
      ..addFont(font.readAsBytes().then((bytes) => ByteData.sublistView(bytes)))).load();
  });
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
      (call) async => call.method == 'getMediaVolume' ? .5 : null);
    for (final channel in [const MethodChannel('com.ddnovelreader/debug_log'), DisplayCutoutService.channel,
      NetworkConnectivity.channel, SystemTtsClient.channel]) {
      messenger.setMockMethodCallHandler(channel, (_) async => null);
    }
    messenger.setMockMethodCallHandler(PlaybackNotifications.channel, (_) async =>
      {'supported': false, 'enabled': false, 'canRequest': false, 'asked': false});
    await Future<void>.delayed(Duration.zero);
  });
  tearDown(() {
    ReaderPreparation.runnerForTesting = null;
    ReaderPreparation.clearMemoryCache(); globalAudioHandler = previous;
    unawaited(handler.playbackState.close()); unawaited(handler.mediaItem.close());
  });

  testWidgets('visible fixed gaps preserve requested typography and exact pages after rapid spacing round trips', (tester) async {
    _view(tester);
    expect(ReadingSettings().paragraphSpacingLevel, 0);
    final fixture = _Fixture('spacing', lengths: [55, 420, 18, 38, 300, 22, 450, 17, 500]);
    final storage = await _mount(tester, fixture, item: 2, source: 175);
    final anchor = _units(_page(tester, fixture).rows).first;
    final samples = <int, List<double>>{};
    for (final level in [1, 2, 3, 0, 3, 1, 0]) {
      await _spacing(tester, level);
      final saved = await storage.loadReadingSettings(fixture.book.id);
      expect(saved.paragraphSpacingLevel, level);
      _expectTypography(tester, saved, level);
      var current = _page(tester, fixture);
      expect(_units(current.rows).first, anchor, reason: 'A fixed-gap change preserves the current original first row');
      _expectPage(tester, fixture, current, level: level, samples: samples, forward: true);
      await _turn(tester, true);
      final next = _page(tester, fixture);
      expect(_units(next.rows).first, _units(current.rows).last + 1);
      _expectPage(tester, fixture, next, level: level, samples: samples, forward: true);
      await _turn(tester, false);
      _same(_page(tester, fixture), current, 'visited backward return at level $level');
      // The real page-intent queue must preserve every tap while a preceding
      // turn is finishing. This balanced sequence returns to the same slice.
      await _rapid(tester, [true, true, false, false, true, false]);
      _same(_page(tester, fixture), current, 'rapid balanced turns at level $level');
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, skip: !font.existsSync(), timeout: const Timeout(Duration(seconds: 180)));

  testWidgets('unknown reverse pages fill from the current boundary across technical chunks without two-row fragments', (tester) async {
    _view(tester);
    final fixture = _Fixture('unknown-reverse', chapters: 12, lengths: [220]);
    final storage = await _mount(tester, fixture, item: 15, source: 7 * 220 + 180);
    final samples = <int, List<double>>{};
    var independentSuffixChecks = 0;
    for (final level in [3, 0, 2]) {
      await _spacing(tester, level);
      _expectTypography(tester, await storage.loadReadingSettings(fixture.book.id), level);
      for (var count = 0; count < 4; count++) {
        final before = _page(tester, fixture);
        final oldFirst = _units(before.rows).first;
        expect(oldFirst, greaterThan(250));
        await _turn(tester, false);
        final previousPage = _page(tester, fixture);
        expect(_units(previousPage.rows).last, oldFirst - 1,
          reason: 'A newly discovered reverse page ends immediately before the current source boundary');
        if (_expectPage(tester, fixture, previousPage, level: level, samples: samples, forward: false)) {
          independentSuffixChecks++;
        }
        expect(previousPage.rows.length, greaterThan(2),
          reason: 'A middle-of-book window prefix is not a real two-row source tail');
        await _turn(tester, true);
        _same(_page(tester, fixture), before, 'forward return to an already visited page');
        await _turn(tester, false);
        _same(_page(tester, fixture), previousPage, 'revisited exact reverse slice');
      }
    }
    expect(independentSuffixChecks, greaterThanOrEqualTo(4),
      reason: 'Multiple unknown previous pages must be checked against a real preceding native row, not only their row count');
    // A true whole-book tail is deliberately short and must remain readable;
    // the regression above must not ban every two-row page indiscriminately.
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    final tail = _Fixture('true-two-row-tail', lengths: [12]);
    await _mount(tester, tail, item: 1, source: 0);
    final actualTail = _page(tester, tail);
    expect(actualTail.rows, hasLength(2));
    expect(_units(actualTail.rows), orderedEquals(List.generate(12, (index) => index)));
    _expectPage(tester, tail, actualTail, level: 0, samples: {}, forward: true);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, skip: !font.existsSync(), timeout: const Timeout(Duration(seconds: 180)));

  testWidgets('three filter levels and toggle cycles keep body source continuous during quick bidirectional turns', (tester) async {
    _view(tester);
    final fixture = _Fixture('filter', lengths: [280, 380, 260, 420, 350], addNoise: true);
    // Each preceding body block has three noise paragraphs. The second body
    // item is 5, while its unique source characters still start at 280.
    final storage = await _mount(tester, fixture, item: 5, source: 400);
    final samples = <int, List<double>>{};
    await _spacing(tester, 2);
    final anchor = _units(_page(tester, fixture).rows).first;
    for (final level in ['links', 'ads', 'extra']) {
      for (final enabled in [true, false, true]) {
        await _filter(tester, level, enabled);
        final saved = await storage.loadReadingSettings(fixture.book.id);
        expect(saved.informationFilter, enabled);
        if (enabled) expect(saved.informationFilterLevel, level);
        _expectTypography(tester, saved, 2);
        final current = _page(tester, fixture);
        expect(_units(current.rows).first, anchor,
          reason: 'Filtering noise around the current body must preserve its original source anchor');
        _expectPage(tester, fixture, current, level: 2, samples: samples, forward: true);
        await _turn(tester, true);
        final next = _page(tester, fixture);
        expect(_units(next.rows).first, _units(current.rows).last + 1,
          reason: 'Filtering may remove noise, but never a unique body source character');
        _expectPage(tester, fixture, next, level: 2, samples: samples, forward: true);
        await _turn(tester, false);
        _same(_page(tester, fixture), current, '$level/$enabled exact visited return');
        await _rapid(tester, [true, false, true, false]);
        _same(_page(tester, fixture), current, '$level/$enabled rapid page queue');
      }
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, skip: !font.existsSync(), timeout: const Timeout(Duration(seconds: 180)));
}

void _view(WidgetTester tester) {
  tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
}

Future<AppStorage> _mount(WidgetTester tester, _Fixture fixture, {required int item, required int source}) async {
  ReaderPreparation.clearMemoryCache();
  final storage = AppStorage();
  await storage.saveSettings((ReadingSettings()..fontSize = _fontSize..lineHeight = _lineHeight
    ..fontFamily = 'ContinuousReaderCjk'..paragraphSpacingLevel = 0..firstLineIndent = false
    ..mergeNonSentenceBreaks = false..informationFilter = false..retainPageLine = false
    ..pageTurnMode = 'tap'..pageTurnAnimation = 'off').toJson());
  await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: fixture.book, storage: storage,
    ttsReader: TtsReader(player: _SilentPlayer()))));
  await tester.pumpAndSettle();
  final finder = find.byKey(const ValueKey('reader-body'));
  final list = tester.widget<ScrollablePositionedList>(finder);
  list.itemScrollController!.jumpTo(index: item); await tester.pumpAndSettle();
  final row = _allRows(tester, fixture).firstWhere((row) => row.units.contains(source));
  final delta = row.rect.top - tester.getTopLeft(finder).dy;
  unawaited(list.scrollOffsetController!.animateScroll(offset: delta, duration: const Duration(milliseconds: 1)));
  await tester.pumpAndSettle();
  expect(_units(_page(tester, fixture).rows), contains(source));
  return storage;
}

Map<int, RenderParagraph> _renders(WidgetTester tester) {
  final body = find.byKey(const ValueKey('reader-body'));
  final positions = tester.widget<ScrollablePositionedList>(body).itemPositionsNotifier!.itemPositions.value;
  final visible = positions.where((position) => position.itemTrailingEdge > 0 && position.itemLeadingEdge < 1)
    .map((position) => position.index).toSet();
  final result = <int, RenderParagraph>{};
  for (final element in find.descendant(of: body, matching: find.byType(RichText)).evaluate()) {
    final render = element.findRenderObject();
    if (render is! RenderParagraph || !render.attached || !render.hasSize) continue;
    int? item;
    element.visitAncestorElements((ancestor) {
      if (ancestor.widget.key case ValueKey<int>(value: final index)) { item = index; return false; }
      return true;
    });
    if (item != null && visible.contains(item)) result[item!] = render;
  }
  return result;
}

List<_Row> _allRows(WidgetTester tester, _Fixture fixture) {
  final result = <_Row>[];
  for (final entry in _renders(tester).entries) {
    final render = entry.value, text = render.text.toPlainText(), origin = render.localToGlobal(Offset.zero);
    final grouped = <int, Rect>{};
    for (final box in render.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: text.length),
      boxHeightStyle: ui.BoxHeightStyle.tight)) {
      final rect = box.toRect();
      if (rect.width < .01 || rect.height < 2) continue;
      final left = render.getPositionForOffset(Offset(-1, rect.center.dy)).offset;
      final right = render.getPositionForOffset(Offset(render.size.width + 1, rect.center.dy)).offset;
      grouped.update(math.min(left, right), (old) => old.expandToInclude(rect), ifAbsent: () => rect);
    }
    for (final line in grouped.entries) {
      final right = render.getPositionForOffset(Offset(render.size.width + 1, line.value.center.dy)).offset;
      final from = math.min(line.key, right), to = math.max(line.key, right);
      final units = text.substring(from, to).runes.where(fixture.ids.containsKey).map((rune) => fixture.ids[rune]!).toList();
      result.add((key: '${entry.key}/${line.key}', item: entry.key, rect: line.value.shift(origin), units: units));
    }
  }
  result.sort((a, b) => a.item == b.item
    ? int.parse(a.key.split('/').last).compareTo(int.parse(b.key.split('/').last)) : a.item.compareTo(b.item));
  return result;
}

_Page _page(WidgetTester tester, _Fixture fixture) {
  final body = tester.getRect(find.byKey(const ValueKey('reader-body')));
  final clipFinder = find.byKey(const ValueKey('reader-page-clip'));
  final clipWidget = tester.widget<ClipRect>(clipFinder), size = tester.getSize(clipFinder);
  final clip = (clipWidget.clipper?.getClip(size) ?? (Offset.zero & size)).shift(tester.getTopLeft(clipFinder)).intersect(body);
  final all = _allRows(tester, fixture);
  final rows = all.where((row) => row.rect.top >= clip.top - .25 && row.rect.bottom <= clip.bottom + .25).toList();
  expect(rows, isNotEmpty);
  final units = _units(rows);
  expect(units, isNotEmpty);
  for (var i = 1; i < units.length; i++) {
    expect(units[i], units[i - 1] + 1, reason: 'Every visible original body character occurs once in source order');
  }
  var step = 0.0;
  for (var i = 1; i < all.length; i++) {
    if (all[i].item == all[i - 1].item) step = math.max(step, all[i].rect.bottom - all[i - 1].rect.bottom);
  }
  return (rows: rows, all: all, body: body, step: step);
}

bool _expectPage(WidgetTester tester, _Fixture fixture, _Page page,
  {required int level, required Map<int, List<double>> samples, required bool forward}) {
  final clipFinder = find.byKey(const ValueKey('reader-page-clip'));
  final clip = tester.widget<ClipRect>(clipFinder).clipper!.getClip(tester.getSize(clipFinder));
  expect(tester.getTopLeft(clipFinder).dy + clip.bottom, closeTo(page.rows.last.rect.bottom, .25));
  expect(page.rows.first.rect.top, closeTo(page.body.top, .25));
  final first = page.all.indexWhere((row) => row.key == page.rows.first.key);
  final last = page.all.indexWhere((row) => row.key == page.rows.last.key);
  expect(page.rows.map((row) => row.key), orderedEquals(page.all.sublist(first, last + 1).map((row) => row.key)));
  var checked = false;
  if (forward && last + 1 < page.all.length) {
    expect(page.all[last + 1].rect.bottom - page.rows.first.rect.top, greaterThan(page.body.height - .25),
      reason: 'The actual next complete source row must not fit the maximal forward prefix');
    checked = true;
  } else if (!forward && first > 0) {
    expect(page.rows.last.rect.bottom - page.all[first - 1].rect.top, greaterThan(page.body.height - .25),
      reason: 'An unknown previous page is the maximal suffix immediately before the current boundary');
    checked = true;
  }
  final units = _units(page.rows);
  if (units.first > 0 && units.last < fixture.ids.length - 1) {
    expect(page.rows.length, greaterThan(2), reason: 'A cached measurement-window fragment cannot masquerade as an ordinary short page');
    final remainder = page.body.bottom - page.rows.last.rect.bottom;
    final gap = _fontSize * level / 4;
    final maxStep = (page.step > 0 ? page.step : _fontSize * _lineHeight) + gap;
    expect(remainder, inInclusiveRange(-.25, maxStep + .5),
      reason: 'Ordinary blank space is smaller than one complete native advance, including the selected paragraph gap');
    final values = samples.putIfAbsent(level, () => [])..add(remainder);
    expect(values.reduce((a, b) => a > b ? a : b) - values.reduce((a, b) => a < b ? a : b), lessThanOrEqualTo(maxStep + .5),
      reason: 'Within one fixed-gap geometry, cumulative page-bottom variation stays within a complete native row advance');
  }
  return checked;
}

void _expectTypography(WidgetTester tester, ReadingSettings saved, int level) {
  expect(saved.fontSize, _fontSize); expect(saved.lineHeight, _lineHeight);
  for (final entry in _renders(tester).entries) {
    final render = entry.value;
    expect(render.strutStyle?.fontSize, _fontSize);
    expect(render.strutStyle?.height, _lineHeight, reason: 'Requested line height must not be silently coordinated to another value');
    RenderObject? ancestor = render.parent;
    while (ancestor != null && ancestor is! RenderPadding) { ancestor = ancestor.parent; }
    expect(ancestor, isA<RenderPadding>());
    final gap = (ancestor! as RenderPadding).padding.resolve(TextDirection.ltr).top;
    // The first source item has no preceding paragraph. Every later item has
    // a fixed meaningful gap, irrespective of the number of rows on the page.
    expect(gap, closeTo(entry.key == 1 ? 0 : _fontSize * level / 4, 1e-6));
    if (level > 0 && entry.key > 1) expect(gap, greaterThan(1));
  }
}

List<int> _units(List<_Row> rows) => rows.expand((row) => row.units).toList();
void _same(_Page actual, _Page expected, String phase) {
  expect(actual.rows.map((row) => row.key), orderedEquals(expected.rows.map((row) => row.key)), reason: phase);
  expect(_units(actual.rows), orderedEquals(_units(expected.rows)), reason: '$phase original characters');
}

Future<void> _turn(WidgetTester tester, bool forward) async {
  final body = tester.getRect(find.byKey(const ValueKey('reader-body')));
  await tester.tapAt(Offset(forward ? body.right - 20 : body.left + 20, body.center.dy));
  await tester.pumpAndSettle();
}
Future<void> _rapid(WidgetTester tester, List<bool> directions) async {
  for (final forward in directions) {
    final body = tester.getRect(find.byKey(const ValueKey('reader-body')));
    await tester.tapAt(Offset(forward ? body.right - 20 : body.left + 20, body.center.dy));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pumpAndSettle();
}

Future<void> _open(WidgetTester tester) async {
  if (find.byKey(const ValueKey('reader-menu')).evaluate().isEmpty) {
    await tester.tapAt(const Offset(195, 300)); await tester.pumpAndSettle();
  }
  await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('阅读设置')); await tester.pumpAndSettle();
}
Future<void> _close(WidgetTester tester) async {
  await tester.tapAt(const Offset(195, 60)); await tester.pumpAndSettle();
  if (find.byTooltip('阅读设置').evaluate().isNotEmpty) {
    await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
  }
  if (find.byKey(const ValueKey('reader-menu')).evaluate().isNotEmpty) {
    await tester.tapAt(const Offset(195, 300)); await tester.pumpAndSettle();
  }
}
Future<void> _spacing(WidgetTester tester, int level) async {
  await _open(tester);
  final scroll = find.descendant(of: find.byType(BottomSheet).last, matching: find.byType(Scrollable)).last;
  await tester.scrollUntilVisible(find.byKey(const ValueKey('reader-paragraph-spacing')), 180, scrollable: scroll);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('reader-paragraph-spacing-$level'))); await tester.pumpAndSettle();
  await _close(tester);
}
Future<void> _filter(WidgetTester tester, String level, bool enabled) async {
  await _open(tester);
  final scroll = find.descendant(of: find.byType(BottomSheet).last, matching: find.byType(Scrollable)).last;
  final switchFinder = find.byKey(const ValueKey('information-filter'));
  await tester.scrollUntilVisible(switchFinder, 180, scrollable: scroll); await tester.pumpAndSettle();
  if (tester.widget<SwitchListTile>(switchFinder).value != enabled) {
    await tester.tap(switchFinder); await tester.pumpAndSettle();
  }
  if (enabled) {
    final radio = find.byWidgetPredicate((widget) => widget is RadioListTile<String> && widget.value == level);
    await tester.scrollUntilVisible(radio, 100, scrollable: scroll); await tester.pumpAndSettle();
    await tester.tap(radio); await tester.pumpAndSettle();
  }
  await _close(tester);
}

class _Fixture {
  _Fixture(String id, {required List<int> lengths, int chapters = 1, bool addNoise = false}) {
    var next = 0, nextRune = 0x6000;
    final noiseRunes = '网址 与邮箱 后仍有正文。请访问本站 获取更多小说。作者有话说：今天继续写故事。'.runes.toSet();
    final result = <Chapter>[];
    for (var chapter = 0; chapter < chapters; chapter++) {
      final paragraphs = <Paragraph>[];
      for (final length in lengths) {
        final text = StringBuffer();
        for (var index = 0; index < length; index++) {
          // Noise text must never accidentally reuse a unique body ID: some
          // ordinary Chinese noise characters share this CJK Unicode range.
          while (noiseRunes.contains(nextRune)) { nextRune++; }
          final rune = nextRune++; ids[rune] = next++; text.writeCharCode(rune);
        }
        paragraphs.add(ReadingText.paragraph(text.toString()));
        if (addNoise) paragraphs.addAll([
          ReadingText.paragraph('网址 https://example.invalid/$next 与邮箱 reader@example.invalid。'),
          ReadingText.paragraph('请访问本站 www.example.invalid 获取更多小说。'),
          ReadingText.paragraph('作者有话说：今天继续写故事。'),
        ]);
      }
      result.add(Chapter(title: '', paragraphs: paragraphs));
    }
    book = Book(id: 'continuous-$id', title: '连续分页回归', filePath: '', format: BookFormat.txt,
      addedAt: DateTime(2026), chapters: result);
  }
  final ids = <int, int>{};
  late final Book book;
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
