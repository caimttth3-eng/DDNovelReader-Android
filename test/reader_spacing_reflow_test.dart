import 'dart:async';
import 'dart:io';
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
import 'package:duoduo_langdu/services/reader_page_planner.dart';
import 'package:duoduo_langdu/services/reader_preparation.dart';
import 'package:duoduo_langdu/services/reader_spacing_policy.dart';
import 'package:duoduo_langdu/services/reading_text.dart';
import 'package:duoduo_langdu/services/system_tts.dart';
import 'package:duoduo_langdu/services/tts_audio_handler.dart';
import 'package:duoduo_langdu/services/tts_reader.dart';

typedef _Row = ({String key, Rect rect, List<int> units});
typedef _Event = ({ReaderPagePlan plan, List<String> keys});
typedef _Metrics = ({int rows, double used, double remaining, double bandStart, double bandEnd});
typedef _Observation = ({List<_Row> entry, List<_Row> next, _Metrics metrics, double anchorTop});

final _events = <_Event>[];
ReaderSpacingPlan? _policy;

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  final font = File('${Platform.environment['SystemRoot']}\\Fonts\\msyh.ttc');
  TtsAudioHandler? previous;
  Future<ReaderPagePlan?> Function(ReaderPagePlan? Function())? previousWorker;
  late TtsAudioHandler handler;
  setUpAll(() async {
    if (!font.existsSync()) return;
    await (FontLoader('ReaderSpacingReflowCjk')
      ..addFont(font.readAsBytes().then((bytes) => ByteData.sublistView(bytes)))).load();
  });
  setUp(() async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    SharedPreferences.setMockInitialValues({});
    ReaderPreparation.clearMemoryCache();
    ReaderPreparation.runnerForTesting = (request) async => ReaderPreparation.prepareSynchronously(request);
    AppAppearance.setThemeMode('light');
    previous = globalAudioHandler;
    previousWorker = ReaderScreen.jointWorkerForTesting;
    handler = TtsAudioHandler(); globalAudioHandler = handler;
    ReaderScreen.jointWorkerForTesting = (calculate) async => calculate();
    _events.clear();
    _policy = null;
    ReaderScreen.onSpacingPolicyForTesting = (plan) { _policy = plan; };
    ReaderScreen.onJointPagePlanForTesting = (chapter, plan, keys) {
      _events.add((plan: plan, keys: List.of(keys)));
    };
    messenger.setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('com.ddnovelreader/volume_keys'),
      (call) async => call.method == 'getMediaVolume' ? .5 : null);
    messenger.setMockMethodCallHandler(const MethodChannel('com.ddnovelreader/debug_log'), (_) async => null);
    messenger.setMockMethodCallHandler(DisplayCutoutService.channel, (_) async => null);
    messenger.setMockMethodCallHandler(NetworkConnectivity.channel, (_) async => null);
    messenger.setMockMethodCallHandler(SystemTtsClient.channel, (_) async => null);
    messenger.setMockMethodCallHandler(PlaybackNotifications.channel, (_) async =>
      {'supported': false, 'enabled': false, 'canRequest': false, 'asked': false});
    await Future<void>.delayed(Duration.zero);
  });
  tearDown(() {
    ReaderScreen.onJointPagePlanForTesting = null;
    ReaderScreen.onSpacingPolicyForTesting = null;
    _policy = null;
    ReaderScreen.jointWorkerForTesting = previousWorker;
    ReaderPreparation.runnerForTesting = null;
    ReaderPreparation.clearMemoryCache(); _events.clear();
    globalAudioHandler = previous;
    unawaited(handler.playbackState.close()); unawaited(handler.mediaItem.close());
  });

  testWidgets('spacing round trips and rapid drafts reproduce cold next-page cuts at the same original line', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    const initial = 2;
    final large = ReadingSettings.paragraphSpacingLevels.last;
    final zero = ReadingSettings.paragraphSpacingLevels.first;
    final cold = <int, _Observation>{};
    for (final value in <int>{initial, large, zero}) {
      final fixture = _Fixture('cold-$value');
      await _mountAtSource(tester, fixture, value);
      cold[value] = await _observeNextAndReturn(tester, fixture, 'cold $value');
      await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    }
    for (final observation in cold.values) {
      expect(observation.entry.length, greaterThan(2));
      expect(observation.next.length, greaterThan(2),
        reason: 'The fixture has ample source beyond the entry; a temporary window tail must not become a two-row page');
    }

    final fixture = _Fixture('warm-spacing-cycles');
    final storage = await _mountAtSource(tester, fixture, initial);
    var current = await _observeNextAndReturn(tester, fixture, 'warm initial $initial');
    _sameAsCold(current, cold[initial]!, 'initial cold/warm equivalence');
    final originalAnchor = _units(current.entry).first;
    _Observation? firstLarge;
    for (final value in [large, zero, large]) {
      await _openSettings(tester); await _revealSpacing(tester);
      await tester.tap(_option(value)); await tester.pumpAndSettle();
      expect((await storage.loadReadingSettings(fixture.book.id)).paragraphSpacingLevel, value);
      await _closeSettings(tester);
      expect(_units(_paintedRows(tester, fixture)).first, originalAnchor,
        reason: 'Changing paragraph gaps must retain the same original row anchor');
      current = await _observeNextAndReturn(tester, fixture, 'settled $value');
      _sameAsCold(current, cold[value]!, 'settled spacing $value versus cold open');
      if (value == large) {
        if (firstLarge == null) { firstLarge = current; }
        else { _sameAsCold(current, firstLarge, 'returning to the same large spacing at the same source line'); }
      }
    }

    for (var cycle = 0; cycle < 2; cycle++) {
      await _openSettings(tester); await _revealSpacing(tester);
      final values = [zero, large, initial, zero, large, zero, large];
      final callbacks = [for (final value in values) tester.widget<ChoiceChip>(_option(value)).onSelected!];
      // Deliver real menu callbacks without an intervening frame. They still
      // use the production persistence, settings transaction and cancellation.
      for (final callback in callbacks) { callback(true); }
      await tester.pumpAndSettle();
      expect((await storage.loadReadingSettings(fixture.book.id)).paragraphSpacingLevel, large);
      expect(tester.widget<ChoiceChip>(_option(large)).selected, isTrue);
      await _closeSettings(tester);
      expect(_units(_paintedRows(tester, fixture)).first, originalAnchor,
        reason: 'Rapid superseded spacing drafts must not move the visible source anchor');
      current = await _observeNextAndReturn(tester, fixture, 'rapid cycle $cycle final $large');
      _sameAsCold(current, cold[large]!, 'rapid final draft versus the same cold setting');
      _sameAsCold(current, firstLarge!, 'rapid final draft versus the first settled large setting');
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, skip: !font.existsSync(), timeout: const Timeout(Duration(seconds: 180)));

  testWidgets('an already visited full-capacity page is idempotent after A B A and rapid A B A level changes', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    const a = 3, b = 0;
    // Real paragraph gaps change natural page capacities. They must not
    // introduce path-dependent cuts when the same setting is selected again.
    final fixture = _Fixture('visited-full-joint', lengths: [180, 35, 290, 52, 400, 70, 550]);
    final storage = await _mountAtSource(tester, fixture, a, source: 0, itemIndex: 1);
    var foundVisitedJointPage = false;
    for (var turn = 0; turn < 10; turn++) {
      await _turn(tester, true);
      final actual = _paintedRows(tester, fixture);
      _expectFullCapacity(tester, fixture, actual, 'visited ordinary page');
      final matches = _events.any((event) => event.plan.pages.any((page) =>
        _equal(event.keys.sublist(page.first, page.end), actual.map((row) => row.key).toList())));
      if (matches) {
        foundVisitedJointPage = true;
        break;
      }
    }
    expect(foundVisitedJointPage, isTrue,
      reason: 'This regression starts on a genuinely visited, planned full-capacity page rather than only the entry');
    final original = await _observeNextAndReturn(tester, fixture, 'visited full A=$a before reflow');
    final anchor = _units(original.entry).first;
    await _openSettings(tester);
    final theme = find.byKey(const ValueKey('theme-mode'));
    tester.widget<DropdownButton<String>>(theme).onChanged!('dark');
    await tester.pumpAndSettle(); await _closeSettings(tester);
    expect((await storage.loadReadingSettings(fixture.book.id)).themeMode, 'dark');
    final themed = await _observeNextAndReturn(tester, fixture, 'visited full after theme-only change');
    _sameAsCold(themed, original, 'a theme-only menu edit must retain current full end and following cuts');
    await _openSettings(tester);
    final timeout = find.byKey(const ValueKey('reading-screen-seconds'));
    final scroll = find.descendant(of: find.byType(BottomSheet).last, matching: find.byType(Scrollable)).last;
    await tester.scrollUntilVisible(timeout, 180, scrollable: scroll); await tester.pumpAndSettle();
    final timeoutChoice = tester.widget<DropdownButton<int>>(timeout).value == 60 ? 120 : 60;
    tester.widget<DropdownButton<int>>(timeout).onChanged!(timeoutChoice);
    await tester.pumpAndSettle(); await _closeSettings(tester);
    expect((await storage.loadReadingSettings(fixture.book.id)).readingScreenSeconds, timeoutChoice);
    final timeoutChanged = await _observeNextAndReturn(tester, fixture, 'visited full after timeout-only change');
    _sameAsCold(timeoutChanged, original, 'a non-geometry screen-timeout edit must not reseal the page greedily');
    for (final value in [b, a]) {
      await _openSettings(tester); await _revealSpacing(tester);
      await tester.tap(_option(value)); await tester.pumpAndSettle();
      await _closeSettings(tester);
      expect((await storage.loadReadingSettings(fixture.book.id)).paragraphSpacingLevel, value);
      expect(_units(_paintedRows(tester, fixture)).first, anchor,
        reason: 'The same original first row must survive both legs of A B A');
    }
    final returned = await _observeNextAndReturn(tester, fixture, 'visited full A=$a after settled A B A');
    _sameAsCold(returned, original, 'returning to an already visited exact full page cut');
    await _openSettings(tester); await _revealSpacing(tester);
    final callbacks = [for (final value in [b, a, b, a]) tester.widget<ChoiceChip>(_option(value)).onSelected!];
    for (final callback in callbacks) { callback(true); }
    await tester.pumpAndSettle(); await _closeSettings(tester);
    expect((await storage.loadReadingSettings(fixture.book.id)).paragraphSpacingLevel, a);
    final rapid = await _observeNextAndReturn(tester, fixture, 'visited full A=$a after rapid A B A');
    _sameAsCold(rapid, original, 'coalesced drafts must retain the same committed full current and following cuts');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, skip: !font.existsSync(), timeout: const Timeout(Duration(seconds: 180)));
}

Future<AppStorage> _mountAtSource(WidgetTester tester, _Fixture fixture, int level,
  {int source = 200, int itemIndex = 2}) async {
  ReaderPreparation.clearMemoryCache(); _events.clear(); _policy = null;
  final storage = AppStorage();
  await storage.saveSettings((ReadingSettings()..fontSize = 39..lineHeight = 1.6
    ..fontFamily = 'ReaderSpacingReflowCjk'..paragraphSpacingLevel = level..firstLineIndent = true
    ..mergeNonSentenceBreaks = false..informationFilter = false..retainPageLine = false
    ..pageTurnMode = 'tap'..pageTurnAnimation = 'off').toJson());
  await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: fixture.book, storage: storage,
    ttsReader: TtsReader(player: _SilentPlayer()))));
  await tester.pumpAndSettle();
  final body = find.byKey(const ValueKey('reader-body'));
  final list = tester.widget<ScrollablePositionedList>(body);
  list.itemScrollController!.jumpTo(index: itemIndex); await tester.pumpAndSettle();
  final render = _renders(tester)[itemIndex]!;
  final target = _localRows(render, fixture).firstWhere((row) => row.units.contains(source));
  final delta = render.localToGlobal(Offset(0, target.rect.top)).dy - tester.getTopLeft(body).dy;
  unawaited(list.scrollOffsetController!.animateScroll(offset: delta, duration: const Duration(milliseconds: 1)));
  await tester.pumpAndSettle();
  if (source > 150) {
    expect(_units(_paintedRows(tester, fixture)).first, greaterThan(150),
      reason: 'The comparison entry must be well inside the same original paragraph');
  } else {
    expect(_units(_paintedRows(tester, fixture)).first, source);
  }
  return storage;
}

Future<_Observation> _observeNextAndReturn(WidgetTester tester, _Fixture fixture, String phase) async {
  final body = tester.getRect(find.byKey(const ValueKey('reader-body')));
  final entry = _paintedRows(tester, fixture);
  _expectFullCapacity(tester, fixture, entry, '$phase entry');
  await _turn(tester, true);
  final next = _paintedRows(tester, fixture);
  expect(_units(next).first, _units(entry).last + 1, reason: '$phase must not lose or repeat a source character at its next cut');
  final policy = _currentPolicy();
  expect(policy.fixedRows, isFalse);
  expect(policy.rows, 0);
  _expectFullCapacity(tester, fixture, next, '$phase next');
  _Metrics? metrics;
  for (final event in _events) {
    for (final page in event.plan.pages) {
      if (!_equal(event.keys.sublist(page.first, page.end), next.map((row) => row.key).toList()) ||
          (page.used - (next.last.rect.bottom - next.first.rect.top)).abs() > .05) continue;
      metrics = (rows: page.rows, used: page.used, remaining: page.remaining,
        bandStart: event.plan.bandStart, bandEnd: event.plan.bandEnd);
    }
  }
  expect(metrics, isNotNull, reason: '$phase must paint an exact slice produced by the production planner');
  await _turn(tester, false);
  final back = _paintedRows(tester, fixture);
  expect(_units(back), orderedEquals(_units(entry)), reason: '$phase backward must restore the original entry characters');
  expect(back.map((row) => row.key), orderedEquals(entry.map((row) => row.key)));
  final measuredCut = metrics!;
  final observation = (entry: entry, next: next, metrics: measuredCut, anchorTop: entry.first.rect.top - body.top);
  debugPrint('SPACING_REFLOW $phase anchor=${_units(entry).first} '
    'entryRows=${entry.length} nextRows=${next.length} next=${_units(next).first}..${_units(next).last} '
    'S=${policy.spacing} used=${measuredCut.used} remaining=${measuredCut.remaining} '
    'band=${measuredCut.bandStart}..${measuredCut.bandEnd}');
  return observation;
}

void _expectFullCapacity(WidgetTester tester, _Fixture fixture, List<_Row> painted, String phase) {
  final physical = _paintedRows(tester, fixture, includeUnpainted: true);
  expect(painted.map((row) => row.key), orderedEquals(physical.map((row) => row.key)),
    reason: '$phase: no additional complete native row fitting the body may be hidden');
  final item = int.parse(painted.first.key.split('/').first);
  final render = _renders(tester)[item]!;
  expect(render.strutStyle!.fontSize, 39);
  expect(render.strutStyle!.height, 1.6);
  expect(_currentPolicy().fixedRows, isFalse);
  final body = tester.getRect(find.byKey(const ValueKey('reader-body')));
  expect(painted.first.rect.top, closeTo(body.top, .25));
  final clipFinder = find.byKey(const ValueKey('reader-page-clip'));
  final clip = tester.widget<ClipRect>(clipFinder).clipper!.getClip(tester.getSize(clipFinder));
  expect(clip.bottom + tester.getTopLeft(clipFinder).dy, closeTo(painted.last.rect.bottom, .25),
    reason: '$phase: clip the complete current source slice precisely at its last glyph row');
  if (_units(painted).last == fixture.ids.length - 1) return;
  final all = _paintedRows(tester, fixture, includeOutside: true);
  final last = all.indexWhere((row) => row.key == painted.last.key);
  expect(last, greaterThanOrEqualTo(0));
  expect(last + 1, lessThan(all.length), reason: '$phase: the next source row must be available to prove natural capacity');
  final next = all[last + 1];
  expect(next.rect.bottom, greaterThan(body.bottom + .25), reason: '$phase: the next full glyph row must physically fail to fit');
  final remainder = body.bottom - painted.last.rect.bottom;
  expect(remainder, greaterThanOrEqualTo(-.25));
  expect(remainder, lessThan(next.rect.bottom - painted.last.rect.bottom + .25),
    reason: '$phase: actual remainder is smaller than the next native row advance, including the unchanged paragraph gap');
}

ReaderSpacingPlan _currentPolicy() {
  expect(_policy, isNotNull, reason: 'The real CJK layout must publish its fixed paragraph spacing');
  return _policy!;
}

void _sameAsCold(_Observation actual, _Observation expected, String reason) {
  expect(_units(actual.entry), orderedEquals(_units(expected.entry)), reason: '$reason: current visible source slice');
  expect(actual.entry.length, expected.entry.length, reason: '$reason: current row count');
  expect(actual.anchorTop, closeTo(expected.anchorTop, .75), reason: '$reason: visible anchor position');
  expect(_units(actual.next), orderedEquals(_units(expected.next)), reason: '$reason: next-page original source slice');
  expect(actual.next.length, expected.next.length, reason: '$reason: next-page row count');
  expect(actual.metrics.rows, expected.metrics.rows, reason: '$reason: planned row count');
  expect(actual.metrics.used, closeTo(expected.metrics.used, .05), reason: '$reason: planned occupied height');
  expect(actual.metrics.remaining, closeTo(expected.metrics.remaining, .05), reason: '$reason: planned bottom remainder');
}

Map<int, RenderParagraph> _renders(WidgetTester tester) {
  final renders = <int, RenderParagraph>{};
  for (final element in find.descendant(of: find.byKey(const ValueKey('reader-body')), matching: find.byType(RichText)).evaluate()) {
    final render = element.findRenderObject();
    if (render is! RenderParagraph || !render.attached || !render.hasSize) continue;
    int? item;
    element.visitAncestorElements((ancestor) {
      if (ancestor.widget.key case ValueKey<int>(value: final index)) { item = index; return false; }
      return true;
    });
    if (item != null) renders[item!] = render;
  }
  return renders;
}

List<_Row> _localRows(RenderParagraph render, _Fixture fixture) {
  final text = render.text.toPlainText(), grouped = <int, Rect>{};
  for (final box in render.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: text.length),
    boxHeightStyle: ui.BoxHeightStyle.tight)) {
    final rect = box.toRect();
    if (rect.width < .01 || rect.height < 2) continue;
    final left = render.getPositionForOffset(Offset(-1, rect.center.dy)).offset;
    final right = render.getPositionForOffset(Offset(render.size.width + 1, rect.center.dy)).offset;
    final start = left < right ? left : right;
    grouped.update(start, (previous) => previous.expandToInclude(rect), ifAbsent: () => rect);
  }
  final rows = <_Row>[];
  for (final line in grouped.entries) {
    final end = render.getPositionForOffset(Offset(render.size.width + 1, line.value.center.dy)).offset;
    final from = line.key < end ? line.key : end, to = line.key < end ? end : line.key;
    final units = text.substring(from, to).runes.where(fixture.ids.containsKey).map((rune) => fixture.ids[rune]!).toList();
    if (units.isNotEmpty) rows.add((key: '${line.key}', rect: line.value, units: units));
  }
  rows.sort((a, b) => a.rect.top.compareTo(b.rect.top));
  return rows;
}

List<_Row> _paintedRows(WidgetTester tester, _Fixture fixture,
    {bool includeUnpainted = false, bool includeOutside = false}) {
  final bodyFinder = find.byKey(const ValueKey('reader-body')), body = tester.getRect(bodyFinder);
  final clipFinder = find.byKey(const ValueKey('reader-page-clip'));
  final clipWidget = tester.widget<ClipRect>(clipFinder), size = tester.getSize(clipFinder);
  final clip = (clipWidget.clipper?.getClip(size) ?? (Offset.zero & size)).shift(tester.getTopLeft(clipFinder)).intersect(body);
  final positions = tester.widget<ScrollablePositionedList>(bodyFinder).itemPositionsNotifier!.itemPositions.value;
  final visibleItems = positions.where((position) => position.itemTrailingEdge > 0 && position.itemLeadingEdge < 1)
    .map((position) => position.index).toSet();
  final rows = <_Row>[];
  for (final entry in _renders(tester).entries) {
    if (!includeOutside && !visibleItems.contains(entry.key)) continue;
    final origin = entry.value.localToGlobal(Offset.zero);
    for (final line in _localRows(entry.value, fixture)) {
      final rect = line.rect.shift(origin);
      final bounds = includeUnpainted ? body : clip;
      if (!includeOutside && (rect.top < bounds.top - .25 || rect.bottom > bounds.bottom + .25)) continue;
      rows.add((key: '${entry.key}/${line.key}', rect: rect, units: line.units));
    }
  }
  rows.sort((a, b) => a.rect.top.compareTo(b.rect.top));
  expect(rows, isNotEmpty);
  final units = _units(rows);
  for (var i = 1; !includeOutside && i < units.length; i++) { expect(units[i], units[i - 1] + 1, reason: 'Painted rows must cover uninterrupted original source'); }
  return rows;
}

List<int> _units(List<_Row> rows) => rows.expand((row) => row.units).toList();
bool _equal(List<String> a, List<String> b) => a.length == b.length && List.generate(a.length, (i) => a[i] == b[i]).every((same) => same);

Finder _option(int value) => find.byKey(ValueKey('reader-paragraph-spacing-$value'));

Future<void> _openSettings(WidgetTester tester) async {
  if (find.byKey(const ValueKey('reader-menu')).evaluate().isEmpty) {
    await tester.tapAt(const Offset(195, 300)); await tester.pumpAndSettle();
  }
  await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('阅读设置')); await tester.pumpAndSettle();
}

Future<void> _revealSpacing(WidgetTester tester) async {
  final scroll = find.descendant(of: find.byType(BottomSheet).last, matching: find.byType(Scrollable)).last;
  tester.state<ScrollableState>(scroll).position.jumpTo(0); await tester.pumpAndSettle();
  await tester.scrollUntilVisible(find.byKey(const ValueKey('reader-paragraph-spacing')), 180, scrollable: scroll);
  await tester.pumpAndSettle();
}

Future<void> _closeSettings(WidgetTester tester) async {
  await tester.tapAt(const Offset(195, 60)); await tester.pumpAndSettle();
  if (find.byTooltip('阅读设置').evaluate().isNotEmpty) {
    await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
  }
  if (find.byKey(const ValueKey('reader-menu')).evaluate().isNotEmpty) {
    await tester.tapAt(const Offset(195, 300)); await tester.pumpAndSettle();
  }
}

Future<void> _turn(WidgetTester tester, bool forward) async {
  final body = tester.getRect(find.byKey(const ValueKey('reader-body')));
  await tester.tapAt(Offset(forward ? body.right - 20 : body.left + 20, body.center.dy));
  await tester.pumpAndSettle();
}

class _Fixture {
  _Fixture(String id, {List<int>? lengths}) {
    var next = 0;
    final paragraphs = <Paragraph>[];
    for (final length in lengths ?? [45, 290, 18, 52, 27, 390, 14, 70, 550]) {
      final text = StringBuffer();
      for (var i = 0; i < length; i++) {
        final rune = 0x6000 + next;
        ids[rune] = next++; text.writeCharCode(rune);
      }
      paragraphs.add(ReadingText.paragraph(text.toString()));
    }
    book = Book(id: 'spacing-reflow-$id', title: '段距冷开与热切换', filePath: '', format: BookFormat.txt,
      addedAt: DateTime(2026), chapters: [Chapter(title: '', paragraphs: paragraphs)]);
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
