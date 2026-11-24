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
import 'package:duoduo_langdu/models/progress.dart';
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

typedef _PlanEvent = ({int chapter, ReaderPagePlan plan, List<String> keys});
typedef _PaintedRow = ({String key, int item, Rect rect, List<int> units});
ReaderSpacingPlan? _spacingPolicy;

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  TtsAudioHandler? previous;
  Future<ReaderPagePlan?> Function(ReaderPagePlan? Function())? previousWorker;
  late TtsAudioHandler handler;
  setUp(() async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    SharedPreferences.setMockInitialValues({});
    ReaderPreparation.clearMemoryCache();
    _spacingPolicy = null;
    ReaderScreen.onSpacingPolicyForTesting = (plan) => _spacingPolicy = plan;
    ReaderPreparation.runnerForTesting = (request) async => ReaderPreparation.prepareSynchronously(request);
    AppAppearance.setThemeMode('light');
    previousWorker = ReaderScreen.jointWorkerForTesting;
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
    ReaderScreen.onJointPagePlanForTesting = null;
    ReaderScreen.onSpacingPolicyForTesting = null;
    _spacingPolicy = null;
    ReaderScreen.jointWorkerForTesting = previousWorker;
    ReaderPreparation.runnerForTesting = null;
    ReaderPreparation.clearMemoryCache(); globalAudioHandler = previous;
    unawaited(handler.playbackState.close()); unawaited(handler.mediaItem.close());
  });

  for (final fontSize in <double>[20, 39]) {
    testWidgets('real joint page cuts cover source rows forwards and backwards at font $fontSize', (tester) async {
      tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
      final fixture = _Fixture('joint-${fontSize.toInt()}');
      final storage = AppStorage();
      await storage.saveSettings((ReadingSettings()..fontSize = fontSize..lineHeight = 1.6
        ..paragraphSpacingLevel = 2..firstLineIndent = true..informationFilter = false
        ..mergeNonSentenceBreaks = false..pageTurnMode = 'tap'..pageTurnAnimation = 'off').toJson());
      final events = <_PlanEvent>[];
      ReaderScreen.onJointPagePlanForTesting = (chapter, plan, keys) {
        events.add((chapter: chapter, plan: plan, keys: List.of(keys)));
      };
      await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: fixture.book, storage: storage,
        ttsReader: TtsReader(player: _SilentPlayer()))));
      await tester.pumpAndSettle();

      // The already painted entry page remains its old cut by design. The first
      // actual page turn must enter production shaping and the numeric worker.
      final entry = _paintedRows(tester, fixture, fontSize, 1.6);
      final pages = <List<_PaintedRow>>[entry];
      await _turn(tester, 1);
      expect(events, isNotEmpty, reason: 'A real tap must invoke the production joint planner, not merely the standalone solver');
      final event = events.last;
      _expectPlan(event, fontSize);
      expect(event.plan.pages.length, greaterThanOrEqualTo(3), reason: 'Exercise more than a single incoming cut');
      expect(event.plan.measured.length, greaterThanOrEqualTo(2), reason: 'Exercise several complete interior pages');
      final incoming = _paintedRows(tester, fixture, fontSize, 1.6);
      final incomingIndex = _cutIndex(event, incoming);

      // Check the complete painted row list, including cuts across short and
      // long paragraphs. Unique source characters catch missing/repeated text
      // even when the next page happens to begin in the same paragraph.
      final remaining = event.plan.pages.length - incomingIndex;
      final count = remaining < 6 ? remaining : 6;
      final paintedMargins = <double>[];
      for (var page = 0; page < count; page++) {
        if (page > 0) await _turn(tester, 1);
        final actual = _paintedRows(tester, fixture, fontSize, 1.6);
        final cut = event.plan.pages[incomingIndex + page];
        expect(actual.map((row) => row.key).toList(), event.keys.sublist(cut.first, cut.end),
          reason: 'Painted complete glyph rows must exactly implement joint cut $page, including its final row');
        final margin = tester.getRect(find.byKey(const ValueKey('reader-body'))).bottom - actual.last.rect.bottom;
        expect(margin, closeTo(cut.remaining, 0.5), reason: 'The numeric budget must agree with actual rendered glyph occupancy');
        if (!cut.bandExempt) {
          _expectForwardFill(tester, fixture, actual, fontSize, 1.6);
          paintedMargins.add(margin);
        }
        _expectAdjacent(pages.last, actual, 'forward cut $page');
        pages.add(actual);
      }
      paintedMargins.sort();
      expect(paintedMargins, hasLength(greaterThanOrEqualTo(2)));
      expect(pages.expand((page) => page).map((row) => row.item).toSet().length, greaterThan(2),
        reason: 'Coverage must actually cross paragraph boundaries, not only inspect one long paragraph');

      for (var page = pages.length - 2; page >= 0; page--) {
        await _turn(tester, -1);
        final actual = _paintedRows(tester, fixture, fontSize, 1.6);
        expect(actual.map((row) => row.key).toList(), pages[page].map((row) => row.key).toList(),
          reason: 'Backward tap must restore exactly the visited page $page, including the exempt entry cut');
        expect(_units(actual), _units(pages[page]), reason: 'Backward navigation must neither lose nor repeat a source character');
      }
      final saved = ReadingSettings.fromJson(await storage.loadSettings());
      expect(saved.fontSize, fontSize); expect(saved.lineHeight, 1.6); expect(saved.paragraphSpacingLevel, 2);

      // A real settings change invalidates geometry. The following real page
      // turn must publish a new plan, not keep the previous line-height cuts.
      final previousEvents = events.length;
      await _openSettings(tester);
      final slider = find.byKey(const ValueKey('reader-line-height'));
      final scroll = find.descendant(of: find.byType(BottomSheet).last, matching: find.byType(Scrollable)).last;
      tester.state<ScrollableState>(scroll).position.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(slider, 160, scrollable: scroll); await tester.pumpAndSettle();
      tester.widget<Slider>(slider).onChanged!(2.0);
      await tester.pumpAndSettle(); await _closeSettings(tester);
      final changed = ReadingSettings.fromJson(await storage.loadSettings());
      expect(changed.lineHeight, 2.0); expect(changed.paragraphSpacingLevel, 2); expect(changed.fontSize, fontSize);
      final beforeReflowTurn = _paintedRows(tester, fixture, fontSize, 2.0);
      await _turn(tester, 1);
      expect(events.length, greaterThan(previousEvents), reason: 'Changed line height must cause a fresh production plan');
      final reflow = events.last;
      expect(identical(reflow.plan, event.plan), isFalse);
      _expectPlan(reflow, fontSize);
      final actual = _paintedRows(tester, fixture, fontSize, 2.0);
      final cut = reflow.plan.pages[_cutIndex(reflow, actual)];
      expect(actual.map((row) => row.key).toList(), reflow.keys.sublist(cut.first, cut.end));
      _expectAdjacent(beforeReflowTurn, actual, 'first reflowed incoming page');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    }, timeout: const Timeout(Duration(seconds: 120)));
  }

  testWidgets('a real compute worker publishes a cut that is actually painted', (tester) async {
    _setView(tester);
    final fixture = _Fixture('joint-real-worker');
    final events = <_PlanEvent>[];
    ReaderScreen.onJointPagePlanForTesting = (chapter, plan, keys) {
      events.add((chapter: chapter, plan: plan, keys: List.of(keys)));
    };
    // Opt out of flutter_test_config's deterministic numeric runner. This uses
    // the actual production compute callback/transport, without transferring a
    // test closure that could accidentally capture a widget State.
    ReaderScreen.jointWorkerForTesting = null;
    await _mountFixture(tester, fixture);
    final before = _paintedRows(tester, fixture, 20, 1.6);
    final body = tester.getRect(find.byKey(const ValueKey('reader-body')));
    await tester.tapAt(Offset(body.right - 20, body.center.dy));
    // Service real isolate messages between virtual Flutter frames. A pure
    // pumpAndSettle loop can starve compute even though it advances fake time.
    await _pumpUntil(tester, () => events.isNotEmpty);
    await tester.pumpAndSettle();
    final event = events.single;
    _expectPlan(event, 20);
    final actual = _paintedRows(tester, fixture, 20, 1.6);
    final cut = event.plan.pages[_cutIndex(event, actual)];
    expect(actual.map((row) => row.key).toList(), event.keys.sublist(cut.first, cut.end));
    _expectAdjacent(before, actual, 'real isolate incoming page');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('a pending worker cannot publish cuts after synchronized progress navigation', (tester) async {
    _setView(tester);
    final fixture = _Fixture('joint-navigation-cancel');
    final events = <_PlanEvent>[];
    final gate = Completer<ReaderPagePlan?>();
    ReaderPagePlan? Function()? heldSolve;
    addTearDown(() { if (!gate.isCompleted) gate.complete(null); });
    ReaderScreen.onJointPagePlanForTesting = (chapter, plan, keys) {
      events.add((chapter: chapter, plan: plan, keys: List.of(keys)));
    };
    ReaderScreen.jointWorkerForTesting = (solve) {
      heldSolve = solve;
      return gate.future;
    };
    await _mountFixture(tester, fixture);
    final entry = _paintedRows(tester, fixture, 20, 1.6);
    final body = tester.getRect(find.byKey(const ValueKey('reader-body')));
    await tester.tapAt(Offset(body.right - 20, body.center.dy));
    await _pumpUntil(tester, () => heldSolve != null);
    expect(events, isEmpty, reason: 'The old request must still be blocked before publication');
    expect(find.byKey(const ValueKey('page-outgoing-transform')), findsOneWidget);

    // Manual controls are blocked while paging, but an actual synchronized
    // progress event can still supersede navigation. Exercise that public
    // storage event protocol instead of invoking any private reader method.
    AppStorage.publishBookChange(BookStorageChange(bookId: fixture.book.id,
      kind: BookStorageChangeKind.progress, remote: true,
      progress: BookProgress(bookId: fixture.book.id, chapterIndex: 0, paragraphIndex: 3,
        chapterAnchor: ReadingText.anchor(fixture.book, 0, 3, 0),
        updatedAt: DateTime.now().millisecondsSinceEpoch / 1000.0 + 3600)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('page-outgoing-transform')), findsNothing,
      reason: 'The navigation generation change must retire the waiting page transition without releasing its worker');
    final jumped = _paintedRows(tester, fixture, 20, 1.6);
    expect(_units(jumped).first, greaterThan(_units(entry).last), reason: 'The test must really jump into the pending suffix');
    final clipFinder = find.byKey(const ValueKey('reader-page-clip'));
    final clipSize = tester.getSize(clipFinder);
    final beforeClip = tester.widget<ClipRect>(clipFinder).clipper!.getClip(clipSize);
    gate.complete(heldSolve!());
    await tester.pumpAndSettle();
    expect(events, isEmpty, reason: 'A late numeric result must not publish navigation-owned row cuts after its request was retired');
    final after = _paintedRows(tester, fixture, 20, 1.6);
    expect(after.map((row) => row.key).toList(), jumped.map((row) => row.key).toList());
    expect(_units(after), _units(jumped));
    expect(tester.widget<ClipRect>(clipFinder).clipper!.getClip(clipSize), beforeClip,
      reason: 'A background proposal must not silently trim the already displayed jump entry page');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(seconds: 60)));
}

void _setView(WidgetTester tester) {
  tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
}

Future<void> _mountFixture(WidgetTester tester, _Fixture fixture) async {
  final storage = AppStorage();
  await storage.saveSettings((ReadingSettings()..fontSize = 20..lineHeight = 1.6
    ..paragraphSpacingLevel = 2..firstLineIndent = true..informationFilter = false
    ..mergeNonSentenceBreaks = false..pageTurnMode = 'tap'..pageTurnAnimation = 'off').toJson());
  await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: fixture.book, storage: storage,
    ttsReader: TtsReader(player: _SilentPlayer()))));
  await tester.pumpAndSettle();
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 1000 && !ready(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 2)));
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(ready(), isTrue, reason: 'The requested worker/navigation phase must actually be observed');
}

void _expectPlan(_PlanEvent event, double fontSize) {
  expect(event.chapter, 0);
  expect(event.keys, isNotEmpty);
  expect(event.keys.toSet().length, event.keys.length, reason: 'Each real shaped row must have a unique source row key');
  expect(event.plan.capacityFallback, isFalse);
  expect(_spacingPolicy, isNotNull);
  expect(_spacingPolicy!.fixedRows, isFalse);
  expect(_spacingPolicy!.rows, 0);
  expect(_spacingPolicy!.spacing, closeTo(fontSize / 2, 1e-6));
  var end = 0;
  for (final page in event.plan.pages) {
    expect(page.first, end); expect(page.end, greaterThan(page.first));
    expect(page.remaining, greaterThanOrEqualTo(-1e-6));
    if (!page.bandExempt) {
      expect(page.rows, greaterThan(0));
      expect(page.used, greaterThan(0));
      expect(page.used, lessThanOrEqualTo(_spacingPolicy!.usedMax + 1e-3));
    }
    end = page.end;
  }
  expect(end, event.keys.length, reason: 'The plan must cover the complete chapter row table, including fixed entry pages');
}

int _cutIndex(_PlanEvent event, List<_PaintedRow> actual) {
  final index = event.plan.pages.indexWhere((page) => event.keys[page.first] == actual.first.key);
  expect(index, greaterThanOrEqualTo(0),
    reason: 'The incoming painted first row must be a real full-chapter plan boundary');
  return index;
}

List<int> _units(List<_PaintedRow> rows) => rows.expand((row) => row.units).toList();

void _expectAdjacent(List<_PaintedRow> before, List<_PaintedRow> after, String phase) {
  expect(_units(after).first, _units(before).last + 1,
    reason: '$phase must continue at the immediate source successor without skipping or repeating a character');
}

class _Fixture {
  _Fixture(String id) {
    var next = 0;
    final paragraphs = <Paragraph>[];
    for (final length in <int>[37, 420, 93, 620, 55, 700]) {
      final text = StringBuffer();
      for (var i = 0; i < length; i++) {
        final rune = 0x4E00 + next;
        ids[rune] = next++; text.writeCharCode(rune);
      }
      paragraphs.add(ReadingText.paragraph(text.toString()));
    }
    book = Book(id: id, title: '联合分页', filePath: '', format: BookFormat.txt,
      addedAt: DateTime(2026), chapters: [Chapter(title: '联合分页第一章', paragraphs: paragraphs)]);
  }
  final ids = <int, int>{};
  late final Book book;
}

List<_PaintedRow> _paintedRows(WidgetTester tester, _Fixture fixture, double fontSize, double lineHeight,
    {bool includeOutside = false}) {
  expect(_spacingPolicy, isNotNull, reason: 'Observe the actual geometry-derived spacing policy before inspecting rendered padding');
  final bodyFinder = find.byKey(const ValueKey('reader-body'));
  final body = tester.getRect(bodyFinder);
  final clipFinder = find.byKey(const ValueKey('reader-page-clip'));
  final clipWidget = tester.widget<ClipRect>(clipFinder), clipSize = tester.getSize(clipFinder);
  final clip = (clipWidget.clipper?.getClip(clipSize) ?? (Offset.zero & clipSize))
    .shift(tester.getTopLeft(clipFinder)).intersect(body);
  final paragraphs = <int, ({RenderParagraph render, Element element})>{};
  for (final element in find.descendant(of: bodyFinder, matching: find.byType(RichText)).evaluate()) {
    int? item;
    element.visitAncestorElements((ancestor) {
      final key = ancestor.widget.key;
      if (key is ValueKey<int>) { item = key.value; return false; }
      return true;
    });
    final render = element.findRenderObject();
    if (item != null && render is RenderParagraph && render.attached && render.hasSize) {
      paragraphs[item!] = (render: render, element: element);
    }
  }
  final positions = tester.widget<ScrollablePositionedList>(bodyFinder).itemPositionsNotifier!.itemPositions.value
    .where((item) => item.itemTrailingEdge > 0 && item.itemLeadingEdge < 1 && paragraphs.containsKey(item.index)).toList();
  expect(positions, isNotEmpty);
  final anchor = paragraphs[positions.first.index]!.render;
  final viewport = RenderAbstractViewport.of(anchor);
  final visibleItems = positions.map((item) => item.index).toSet();
  final rows = <_PaintedRow>[];
  for (final entry in paragraphs.entries) {
    // Item zero is metadata hidden by this fixture's unrecognized title.
    // The first visible body paragraph therefore has no preceding text gap.
    if (entry.key == 0 || !includeOutside && !visibleItems.contains(entry.key)) continue;
    final render = entry.value.render;
    if (RenderAbstractViewport.maybeOf(render) != viewport) continue;
    final top = render.localToGlobal(Offset.zero).dy;
    if (!includeOutside && (top > clip.bottom || top + render.size.height < clip.top)) continue;
    final effectiveHeight = render.strutStyle!.height!;
    expect(effectiveHeight, greaterThan(0));
    expect(_expectEffectiveBodyStyles(render.text, const TextStyle(), fixture, fontSize, effectiveHeight), greaterThan(0),
      reason: 'Validate the effective style of actual body text, not the inherited outer Text.rich wrapper');
    Padding? padding;
    entry.value.element.visitAncestorElements((ancestor) {
      if (ancestor.widget is Padding) { padding = ancestor.widget as Padding; return false; }
      return true;
    });
    expect(padding, isNotNull);
    expect(padding!.padding.resolve(TextDirection.ltr).top, closeTo(entry.key == 1 ? 0 : _spacingPolicy!.spacing, 1e-6),
      reason: 'Page cuts must not change the actual fixed paragraph padding');
    final text = render.text.toPlainText();
    final grouped = <int, Rect>{};
    for (final box in render.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: text.length),
      boxHeightStyle: ui.BoxHeightStyle.tight)) {
      final rect = box.toRect();
      if (rect.width < 0.01 || rect.height < 2) continue;
      final a = render.getPositionForOffset(Offset(-1, rect.center.dy)).offset;
      final b = render.getPositionForOffset(Offset(render.size.width + 1, rect.center.dy)).offset;
      final start = a < b ? a : b;
      grouped.update(start, (previous) => previous.expandToInclude(rect), ifAbsent: () => rect);
    }
    final local = grouped.entries.toList()..sort((a, b) => a.value.top.compareTo(b.value.top));
    final nativePitch = local.length < 2 ? null : local[1].value.top - local[0].value.top;
    expect(render.strutStyle?.fontSize, fontSize);
    expect(render.strutStyle?.height, lineHeight);
    expect(render.strutStyle?.forceStrutHeight, isTrue);
    for (var i = 1; i < local.length; i++) {
      final pitch = local[i].value.top - local[i - 1].value.top;
      expect(pitch, greaterThan(0), reason: 'Native pitch is measured, not assumed to equal fontSize times the height multiplier');
      expect(pitch, closeTo(nativePitch!, 0.05),
        reason: 'Joint planning must keep one constant physical line pitch within each paragraph');
    }
    if (nativePitch != null) {
      expect(nativePitch, closeTo(render.textScaler.scale(fontSize) * effectiveHeight, 1),
        reason: 'Native pitch follows resolved effective typography, not requested line-height $lineHeight');
    }
    for (final row in local) {
      final rect = row.value.shift(Offset(render.localToGlobal(Offset.zero).dx, top));
      if (!includeOutside) {
        if (rect.bottom <= clip.top + 0.25 || rect.top >= clip.bottom - 0.25) continue;
        expect(rect.top, greaterThanOrEqualTo(clip.top - 0.25), reason: 'No partial first glyph row may be painted');
        expect(rect.bottom, lessThanOrEqualTo(clip.bottom + 0.25), reason: 'No partial final glyph row may be painted');
      }
      final end = render.getPositionForOffset(Offset(render.size.width + 1, row.value.center.dy)).offset;
      final a = row.key < end ? row.key : end, b = row.key < end ? end : row.key;
      final units = text.substring(a, b).runes.where(fixture.ids.containsKey).map((rune) => fixture.ids[rune]!).toList();
      expect(units, isNotEmpty);
      rows.add((key: '${entry.key}/${row.key}', item: entry.key, rect: rect, units: units));
    }
  }
  rows.sort((a, b) => a.rect.top.compareTo(b.rect.top));
  expect(rows, isNotEmpty);
  final units = _units(rows);
  for (var i = 1; !includeOutside && i < units.length; i++) {
    expect(units[i], units[i - 1] + 1, reason: 'Every painted source character must appear exactly once and in original order');
  }
  return rows;
}

void _expectForwardFill(WidgetTester tester, _Fixture fixture, List<_PaintedRow> actual,
    double fontSize, double lineHeight) {
  final body = tester.getRect(find.byKey(const ValueKey('reader-body')));
  expect(actual.first.rect.top, closeTo(body.top, .25));
  final all = _paintedRows(tester, fixture, fontSize, lineHeight, includeOutside: true);
  final last = all.indexWhere((row) => row.key == actual.last.key);
  expect(last, greaterThanOrEqualTo(0));
  expect(last + 1, lessThan(all.length), reason: 'An ordinary page needs its actual next native row for the maximum-fill oracle');
  final next = all[last + 1];
  expect(next.rect.bottom, greaterThan(body.bottom + .25), reason: 'The next complete native row must not fit');
  final remainder = body.bottom - actual.last.rect.bottom;
  expect(remainder, greaterThanOrEqualTo(-.25));
  expect(remainder, lessThan(next.rect.bottom - actual.last.rect.bottom + .25),
    reason: 'Whitespace is bounded by the actual next-row advance, including any fixed paragraph spacing');
}

int _expectEffectiveBodyStyles(InlineSpan span, TextStyle inherited, _Fixture fixture, double fontSize, double lineHeight) {
  if (span is! TextSpan) return 0; // The indentation WidgetSpan is not a body glyph.
  final effective = inherited.merge(span.style);
  var checked = 0;
  if (span.text?.runes.any(fixture.ids.containsKey) ?? false) {
    expect(effective.fontSize, fontSize); expect(effective.height, lineHeight);
    checked++;
  }
  for (final child in span.children ?? const <InlineSpan>[]) {
    checked += _expectEffectiveBodyStyles(child, effective, fixture, fontSize, lineHeight);
  }
  return checked;
}

Future<void> _turn(WidgetTester tester, int direction) async {
  final body = tester.getRect(find.byKey(const ValueKey('reader-body')));
  await tester.tapAt(Offset(direction > 0 ? body.right - 20 : body.left + 20, body.center.dy));
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
  if (find.byKey(const ValueKey('reader-menu')).evaluate().isNotEmpty) {
    await tester.tapAt(const Offset(195, 300)); await tester.pumpAndSettle();
  }
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
