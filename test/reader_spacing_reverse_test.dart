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

typedef _Row = ({String key, int item, Rect rect, List<int> units});
typedef _Event = ({ReaderPagePlan plan, List<String> keys});
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
    await (FontLoader('ReaderReverseCjk')
      ..addFont(font.readAsBytes().then((bytes) => ByteData.sublistView(bytes)))).load();
  });
  setUp(() async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    SharedPreferences.setMockInitialValues({});
    ReaderPreparation.clearMemoryCache();
    ReaderPreparation.runnerForTesting = (request) async => ReaderPreparation.prepareSynchronously(request);
    AppAppearance.setThemeMode('light');
    previous = globalAudioHandler; previousWorker = ReaderScreen.jointWorkerForTesting;
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

  for (final entry in [(chapter: 7, local: 90, label: 'technical chunk interior'),
                       (chapter: 8, local: 0, label: 'genuine metadata heading boundary')]) {
    testWidgets('spacing reflow preserves dense ordinary pages in both directions from unseen ${entry.label}', (tester) async {
      tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
      final fixture = _Fixture('reverse-${entry.chapter}');
      final storage = AppStorage();
      await storage.saveSettings((ReadingSettings()..fontSize = 39..lineHeight = 1.6
        ..fontFamily = 'ReaderReverseCjk'..paragraphSpacingLevel = 2..firstLineIndent = true
        ..mergeNonSentenceBreaks = false..informationFilter = false..retainPageLine = false
        ..pageTurnMode = 'tap'..pageTurnAnimation = 'off').toJson());
      await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: fixture.book, storage: storage,
        ttsReader: TtsReader(player: _SilentPlayer()))));
      await tester.pumpAndSettle();
      final bodyFinder = find.byKey(const ValueKey('reader-body'));
      final list = tester.widget<ScrollablePositionedList>(bodyFinder);
      final item = entry.chapter * 2 + 1, wanted = entry.chapter * _Fixture.length + entry.local;
      list.itemScrollController!.jumpTo(index: item); await tester.pumpAndSettle();
      final render = _renders(tester)[item]!;
      final local = _localRows(render, fixture, item).firstWhere((row) => row.units.contains(wanted));
      final delta = render.localToGlobal(Offset(0, local.rect.top)).dy - tester.getTopLeft(bodyFinder).dy;
      unawaited(list.scrollOffsetController!.animateScroll(offset: delta, duration: const Duration(milliseconds: 1)));
      await tester.pumpAndSettle();
      final sourceAnchor = _units(_paintedRows(tester, fixture)).first;
      expect(sourceAnchor, greaterThan(_Fixture.length * 6), reason: 'Previous-page discovery must start far from the book beginning');
      // No page has been visited via either turn direction. The first reverse
      // tap must discover an unknown predecessor rather than use page history.
      final remainderSamples = <String, List<double>>{};
      for (final lineHeight in [1.6, 1.2, 2.4]) {
       if (lineHeight != 1.6) await _setLineHeight(tester, lineHeight);
       for (final level in <int>[2, 3, 0, 2, 3, 0]) {
        await _setSpacing(tester, level);
        final saved = await storage.loadReadingSettings(fixture.book.id);
        expect(saved.paragraphSpacingLevel, level);
        expect(saved.lineHeight, lineHeight);
        final current = _paintedRows(tester, fixture);
        expect(_units(current).first, sourceAnchor, reason: 'Changing spacing must retain the displayed original source line');

        await _turn(tester, false);
        final previousPage = _paintedRows(tester, fixture);
        expect(_units(previousPage).last, sourceAnchor - 1,
          reason: 'Unknown reverse pagination must finish immediately before the old entry without a lost or repeated character');
        _expectReadable(tester, fixture, previousPage, 'reverse level=$level L=$lineHeight ${entry.label}',
          remainderSamples: remainderSamples, level: level, lineHeight: lineHeight, before: true);
        await _turn(tester, true);
        _samePage(_paintedRows(tester, fixture), current, 'returning forward to the reflowed entry');

        await _turn(tester, true);
        final nextPage = _paintedRows(tester, fixture);
        expect(_units(nextPage).first, _units(current).last + 1,
          reason: 'Forward pagination after reflow must use the immediate source successor');
        _expectReadable(tester, fixture, nextPage, 'forward level=$level L=$lineHeight ${entry.label}',
          remainderSamples: remainderSamples, level: level, lineHeight: lineHeight);
        await _turn(tester, false);
        _samePage(_paintedRows(tester, fixture), current, 'returning backward to the same reflowed entry');
       }
      }
      for (final values in remainderSamples.values) {
        expect(values.length, greaterThanOrEqualTo(4), reason: 'Compare cumulative ordinary pages across repeated reflow and both directions');
      }
      expect(_events, isNotEmpty, reason: 'Real gestures must exercise production shaping and planning');
      expect(_events.any((event) => int.parse(event.keys.last.split('/').first) < 23), isTrue,
        reason: 'The fixture must exercise an unfinished nearby window, not only a complete-book tail');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    }, skip: !font.existsSync(), timeout: const Timeout(Duration(seconds: 180)));
  }
}

void _expectReadable(WidgetTester tester, _Fixture fixture, List<_Row> actual, String phase,
  {required Map<String, List<double>> remainderSamples, required int level,
   required double lineHeight, bool before = false}) {
  final full = _paintedRows(tester, fixture, includeUnpainted: true);
  expect(_policy, isNotNull);
  final policy = _policy!;
  final body = tester.getRect(find.byKey(const ValueKey('reader-body')));
  final scaledFont = MediaQuery.textScalerOf(find.byKey(const ValueKey('reader-body')).evaluate().single).scale(39);
  final used = actual.last.rect.bottom - actual.first.rect.top;
  final remaining = body.bottom - actual.last.rect.bottom;
  expect(policy.fixedRows, isFalse);
  expect(policy.rows, 0);
  expect(policy.spacing, closeTo(scaledFont * level / 4, 1e-6));
  expect(used, inInclusiveRange(0, body.height + .25));
  expect(actual.first.rect.top, closeTo(body.top, .25));
  final clipFinder = find.byKey(const ValueKey('reader-page-clip'));
  final clip = tester.widget<ClipRect>(clipFinder).clipper!.getClip(tester.getSize(clipFinder));
  expect(clip.bottom + tester.getTopLeft(clipFinder).dy, closeTo(actual.last.rect.bottom, .25),
    reason: '$phase: preserve the sealed final row even when reverse and forward greedy cuts differ');
  final all = _paintedRows(tester, fixture, includeOutside: true);
  final boundary = all.indexWhere((row) => row.key == (before ? actual.first.key : actual.last.key));
  expect(boundary, greaterThanOrEqualTo(0));
  final neighbor = before ? boundary - 1 : boundary + 1;
  expect(neighbor, inInclusiveRange(0, all.length - 1),
    reason: '$phase: use the actual neighboring glyph row rather than a fixed K or window-tail assumption');
  final advance = before ? actual.first.rect.top - all[neighbor].rect.top
    : all[neighbor].rect.bottom - actual.last.rect.bottom;
  if (before) {
    expect(actual.last.rect.bottom - all[neighbor].rect.top, greaterThan(body.height + .25),
      reason: '$phase: adding the actual preceding row must exceed the viewport');
  } else {
    expect(all[neighbor].rect.bottom, greaterThan(body.bottom + .25),
      reason: '$phase: adding the actual following row must exceed the viewport');
    expect(actual.map((row) => row.key), orderedEquals(full.map((row) => row.key)),
      reason: '$phase: a new forward page must consume every complete fitting row');
  }
  expect(remaining, greaterThanOrEqualTo(-.25));
  expect(remaining, lessThan(advance + .5),
    reason: '$phase: natural leftover is bounded by the real directional row advance, including any paragraph gap');
  final candidates = <String>[];
  for (final event in _events) {
    for (var index = 0; index < event.plan.pages.length; index++) {
      final page = event.plan.pages[index];
      if (!_equal(event.keys.sublist(page.first, page.end), actual.map((row) => row.key).toList())) continue;
      candidates.add('$index/${event.plan.pages.length},exempt=${page.bandExempt},'
        'window=${event.keys.first}..${event.keys.last},band=${event.plan.bandStart}..${event.plan.bandEnd}');
    }
  }
  debugPrint('SPACING_REVERSE $phase rows=${actual.length} fitting=${full.length} '
    'source=${_units(actual).first}..${_units(actual).last} keys=${actual.first.key}..${actual.last.key} '
    'S=${policy.spacing} actualR=$remaining candidates=$candidates');
  expect(actual.first.rect.top, closeTo(full.first.rect.top, .25));
  final geometry = 'F$scaledFont/L$lineHeight/H${body.height.toStringAsFixed(6)}';
  for (final key in ['$geometry/level$level', '$geometry/all-levels']) {
    remainderSamples.putIfAbsent(key, () => [])..add(remaining);
  }
}

void _samePage(List<_Row> actual, List<_Row> expected, String phase) {
  expect(_units(actual), orderedEquals(_units(expected)), reason: '$phase: original source coverage');
  expect(actual.map((row) => row.key), orderedEquals(expected.map((row) => row.key)), reason: '$phase: exact visited row slice');
}

Map<int, RenderParagraph> _renders(WidgetTester tester) {
  final result = <int, RenderParagraph>{};
  for (final element in find.descendant(of: find.byKey(const ValueKey('reader-body')), matching: find.byType(RichText)).evaluate()) {
    final render = element.findRenderObject();
    if (render is! RenderParagraph || !render.attached || !render.hasSize) continue;
    int? item;
    element.visitAncestorElements((ancestor) {
      if (ancestor.widget.key case ValueKey<int>(value: final index)) { item = index; return false; }
      return true;
    });
    if (item != null) result[item!] = render;
  }
  return result;
}

List<_Row> _localRows(RenderParagraph render, _Fixture fixture, int item) {
  final text = render.text.toPlainText(), grouped = <int, Rect>{};
  final rows = <_Row>[];
  for (final box in render.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: text.length),
    boxHeightStyle: ui.BoxHeightStyle.tight)) {
    final rect = box.toRect();
    if (rect.width < .01 || rect.height < 2) continue;
    final left = render.getPositionForOffset(Offset(-1, rect.center.dy)).offset;
    final right = render.getPositionForOffset(Offset(render.size.width + 1, rect.center.dy)).offset;
    final start = left < right ? left : right;
    grouped.update(start, (previous) => previous.expandToInclude(rect), ifAbsent: () => rect);
  }
  for (final entry in grouped.entries) {
    final end = render.getPositionForOffset(Offset(render.size.width + 1, entry.value.center.dy)).offset;
    final start = entry.key < end ? entry.key : end, finish = entry.key < end ? end : entry.key;
    final units = text.substring(start, finish).runes.where(fixture.ids.containsKey).map((rune) => fixture.ids[rune]!).toList();
    if (units.isNotEmpty || fixture.headingItems.contains(item)) {
      rows.add((key: '$item/${entry.key}', item: item, rect: entry.value, units: units));
    }
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
  final bounds = includeUnpainted ? body : clip;
  final positions = tester.widget<ScrollablePositionedList>(bodyFinder).itemPositionsNotifier!.itemPositions.value;
  final visible = positions.where((position) => position.itemTrailingEdge > 0 && position.itemLeadingEdge < 1)
    .map((position) => position.index).toSet();
  final rows = <_Row>[];
  for (final entry in _renders(tester).entries) {
    if (!includeOutside && !visible.contains(entry.key)) continue;
    final origin = entry.value.localToGlobal(Offset.zero);
    for (final line in _localRows(entry.value, fixture, entry.key)) {
      final rect = line.rect.shift(origin);
      if (!includeOutside && (rect.top < bounds.top - .25 || rect.bottom > bounds.bottom + .25)) continue;
      rows.add((key: line.key, item: line.item, rect: rect, units: line.units));
    }
  }
  rows.sort((a, b) => a.rect.top.compareTo(b.rect.top));
  expect(rows, isNotEmpty);
  final units = _units(rows);
  expect(units, isNotEmpty, reason: 'A middle-of-book reading page must contain actual source text');
  for (var i = 1; !includeOutside && i < units.length; i++) {
    expect(units[i], units[i - 1] + 1, reason: 'Complete painted source characters must remain contiguous across real and technical chapters');
  }
  return rows;
}

List<int> _units(List<_Row> rows) => rows.expand((row) => row.units).toList();
bool _equal(List<String> a, List<String> b) => a.length == b.length && List.generate(a.length, (i) => a[i] == b[i]).every((value) => value);

Future<void> _openSettings(WidgetTester tester) async {
  if (find.byKey(const ValueKey('reader-menu')).evaluate().isEmpty) {
    await tester.tapAt(const Offset(195, 300)); await tester.pumpAndSettle();
  }
  await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('阅读设置')); await tester.pumpAndSettle();
}

Future<void> _setSpacing(WidgetTester tester, int value) async {
  await _openSettings(tester);
  final scroll = find.descendant(of: find.byType(BottomSheet).last, matching: find.byType(Scrollable)).last;
  final option = find.byKey(ValueKey('reader-paragraph-spacing-$value'));
  await tester.scrollUntilVisible(option, 180, scrollable: scroll); await tester.pumpAndSettle();
  await tester.tap(option); await tester.pumpAndSettle();
  await _closeSettings(tester);
}

Future<void> _setLineHeight(WidgetTester tester, double value) async {
  await _openSettings(tester);
  final scroll = find.descendant(of: find.byType(BottomSheet).last, matching: find.byType(Scrollable)).last;
  final slider = find.byKey(const ValueKey('reader-line-height'));
  await tester.scrollUntilVisible(slider, 180, scrollable: scroll); await tester.pumpAndSettle();
  tester.widget<Slider>(slider).onChanged!(value);
  await tester.pumpAndSettle(); await _closeSettings(tester);
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
  static const length = 220;
  _Fixture(String id) {
    var next = 0;
    final chapters = <Chapter>[];
    for (var chapter = 0; chapter < 12; chapter++) {
      final text = StringBuffer();
      for (var i = 0; i < length; i++) {
        final rune = 0x6000 + next;
        ids[rune] = next++; text.writeCharCode(rune);
      }
      final heading = {4, 6, 8}.contains(chapter);
      if (heading) headingItems.add(chapter * 2);
      chapters.add(Chapter(title: heading ? 'Chapter ${37 + chapter}' : '',
        paragraphs: [ReadingText.paragraph(text.toString())]));
    }
    book = Book(id: id, title: '段距与未知反向分页', filePath: '', format: BookFormat.txt,
      addedAt: DateTime(2026), chapters: chapters);
  }
  final ids = <int, int>{};
  final headingItems = <int>{};
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
