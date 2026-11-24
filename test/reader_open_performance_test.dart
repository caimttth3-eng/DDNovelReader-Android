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
import 'package:duoduo_langdu/services/reader_preparation.dart';
import 'package:duoduo_langdu/services/reading_text.dart';
import 'package:duoduo_langdu/services/system_tts.dart';
import 'package:duoduo_langdu/services/tts_audio_handler.dart';
import 'package:duoduo_langdu/services/tts_reader.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  late TtsAudioHandler handler;
  TtsAudioHandler? previous;
  setUp(() async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    SharedPreferences.setMockInitialValues({});
    ReaderPreparation.clearMemoryCache();
    ReaderPreparation.runnerForTesting = (request) async => ReaderPreparation.prepareSynchronously(request);
    AppAppearance.setThemeMode('light');
    previous = globalAudioHandler; handler = TtsAudioHandler(); globalAudioHandler = handler;
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
    ReaderScreen.onLayoutWorkForTesting = null;
    ReaderPreparation.runnerForTesting = null; ReaderPreparation.clearMemoryCache();
    globalAudioHandler = previous;
    unawaited(handler.playbackState.close()); unawaited(handler.mediaItem.close());
  });

  for (final mode in ['tap', 'scroll']) {
    testWidgets('opening a 30k paragraph limits geometry work to nearby rows $mode', (tester) async {
      final work = _LayoutWork();
      final revision = await _mount(tester, mode, work);
      addTearDown(revision.dispose);
      debugPrint('OPEN_WORK $mode ${work.counts}');
      expect(work['preparationRuns'], 1, reason: 'Opening must not prepare the same book repeatedly');
      // At 39px and the default 1.6 line spacing, this viewport has about
      // twelve visible rows. A nearby-row window can allow several startup
      // convergence passes without selecting thousands of offscreen rows.
      expect(work['selectionBoxes'], lessThanOrEqualTo(600),
        reason: 'Initial display must not select every row of the 30k-character paragraph');
      expect(work['caretHits'], lessThanOrEqualTo(1200),
        reason: 'Native caret queries must scale with the nearby page window, not total paragraph length');
      expect(find.byKey(const ValueKey('reader-body')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    }, timeout: const Timeout(Duration(seconds: 90)));

    testWidgets('unchanged row metrics are reused and font width changes invalidate them $mode', (tester) async {
      final work = _LayoutWork();
      final revision = await _mount(tester, mode, work);
      addTearDown(revision.dispose);
      work.clear();
      await _rebuild(tester, revision, 20);
      debugPrint('IDLE_WORK $mode ${work.counts}');
      _expectNoNativeMeasure(work, 'twenty parent rebuilds');
      expect(work['preparationRuns'], 0);

      // Explicit scroll notifications exercise geometry consumers even when
      // identical TextSpan comparisons avoid a new paragraph layout. The
      // twenty-pixel range stays within the same already measured row window.
      work.clear();
      final body = find.byKey(const ValueKey('reader-body'));
      for (var step = 0; step < 20; step++) {
        unawaited(tester.widget<ScrollablePositionedList>(body).scrollOffsetController!.animateScroll(
          offset: step.isEven ? 1 : -1, duration: const Duration(milliseconds: 1)));
        await tester.pumpAndSettle();
      }
      debugPrint('SCROLL_WORK $mode ${work.counts}');
      _expectNoNativeMeasure(work, 'scroll projections over unchanged local rows');
      expect(work['preparationRuns'], 0);

      work.clear();
      tester.view.physicalSize = const Size(430, 844);
      await tester.pumpAndSettle();
      debugPrint('WIDTH_INVALIDATION_WORK $mode ${work.counts}');
      expect(work['selectionBoxes'], greaterThan(0), reason: 'A new text width must invalidate cached row metrics');
      expect(work['caretHits'], greaterThan(0));
      expect(work['preparationRuns'], 0, reason: 'Changing only layout width must not rerun text preparation');
      work.clear(); await _rebuild(tester, revision, 20);
      _expectNoNativeMeasure(work, 'twenty rebuilds after a width change');

      if (find.byKey(const ValueKey('reader-menu')).evaluate().isEmpty) {
        await tester.tapAt(const Offset(215, 300)); await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('font-fine-tune'))); await tester.pumpAndSettle();
      work.clear();
      await tester.tap(find.byKey(const ValueKey('font-increase'))); await tester.pumpAndSettle();
      debugPrint('FONT_INVALIDATION_WORK $mode ${work.counts}');
      expect(work['selectionBoxes'], greaterThan(0), reason: 'A real font-size edit must invalidate cached row metrics');
      expect(work['caretHits'], greaterThan(0));
      expect(work['preparationRuns'], 0, reason: 'Changing font size must preserve the prepared text');
      await tester.tapAt(const Offset(215, 50)); await tester.pumpAndSettle();
      work.clear(); await _rebuild(tester, revision, 20);
      _expectNoNativeMeasure(work, 'twenty rebuilds after a font-size change');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    }, timeout: const Timeout(Duration(seconds: 120)));
  }

  testWidgets('long paragraph crosses and revisits row windows without losing source characters', (tester) async {
    final work = _LayoutWork();
    final revision = await _mount(tester, 'tap', work);
    expect(work['jointChapterRows'], 0, reason: 'Opening must not wait for complete chapter shaping');
    addTearDown(revision.dispose);
    tester.widget<ScrollablePositionedList>(find.byKey(const ValueKey('reader-body')))
      .itemScrollController!.jumpTo(index: 1);
    await tester.pumpAndSettle();
    // Leave the paragraph's padding behind, so every stored page begins on a
    // complete row rather than an arbitrary initial sliver alignment.
    await _page(tester, 1, work);
    expect(work['jointChapterRows'], greaterThan(0), reason: 'The first planned turn measures its actual chapter');
    final pages = <List<_SourceRow>>[_sourceRows(tester)];
    for (var page = 0; page < 12; page++) {
      await _page(tester, 1, work);
      expect(work['jointChapterRows'], 0, reason: 'Following cuts must reuse the measured chapter');
      final rows = _sourceRows(tester);
      expect(rows.first.start, pages.last.last.end,
        reason: 'Cross-window forward page $page must not lose or repeat a source character');
      pages.add(rows);
    }
    // Twelve pages also exceed the bounded per-paragraph window cache. These
    // reverse turns must recover remembered offsets after older windows leave.
    for (var page = pages.length - 2; page >= 0; page--) {
      await _page(tester, -1, work);
      _expectRows(_sourceRows(tester), pages[page], 'remembered backward page $page');
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(seconds: 120)));

  testWidgets('far source progress and filter restoration retain bounded row work and exact pages', (tester) async {
    final work = _LayoutWork();
    const target = 20000;
    final revision = await _mount(tester, 'tap', work, progress: BookProgress(
      bookId: 'open-performance-tap', chapterIndex: 0, paragraphIndex: 0,
      offsetInParagraph: target, charOffsetInChapter: target, layoutSignature: 'legacy-layout'));
    addTearDown(revision.dispose);
    final restored = _sourceRows(tester);
    expect(restored.first.start, lessThanOrEqualTo(target));
    expect(restored.first.end, greaterThan(target),
      reason: 'A signature-mismatched saved source offset must restore its actual visible row');
    _expectBoundedFarWork(work, 'opening at source offset $target');
    await _page(tester, 1, work);
    expect(_sourceRows(tester).first.start, restored.last.end);
    await _page(tester, -1, work);
    _expectRows(_sourceRows(tester), restored, 'far remembered back');

    if (find.byKey(const ValueKey('reader-menu')).evaluate().isEmpty) {
      await tester.tapAt(const Offset(195, 300)); await tester.pumpAndSettle();
    }
    await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('阅读设置')); await tester.pumpAndSettle();
    final filter = find.byKey(const ValueKey('information-filter'));
    await tester.scrollUntilVisible(filter, 220,
      scrollable: find.descendant(of: find.byType(BottomSheet).last, matching: find.byType(Scrollable)).last);
    await tester.pumpAndSettle();
    work.clear();
    await tester.tap(filter); await tester.pumpAndSettle();
    _expectRows(_sourceRows(tester), restored, 'far source anchor after filter reformat');
    _expectBoundedFarWork(work, 'filter reformat at source offset $target');
    await tester.tapAt(const Offset(195, 60)); await tester.pumpAndSettle();
    if (find.byTooltip('阅读设置').evaluate().isNotEmpty) {
      await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
    }
    await _page(tester, 1, work);
    expect(_sourceRows(tester).first.start, restored.last.end);
    await _page(tester, -1, work);
    _expectRows(_sourceRows(tester), restored, 'far filtered remembered back');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(seconds: 120)));
}

typedef _SourceRow = ({int start, int end, double top});

List<_SourceRow> _sourceRows(WidgetTester tester) {
  final body = tester.getRect(find.byKey(const ValueKey('reader-body')));
  final clipFinder = find.byKey(const ValueKey('reader-page-clip'));
  final clip = tester.widget<ClipRect>(clipFinder), clipSize = tester.getSize(clipFinder);
  final clipBottom = tester.getTopLeft(clipFinder).dy + (clip.clipper?.getClip(clipSize).bottom ?? clipSize.height);
  final render = find.byWidgetPredicate((widget) => widget is Text && widget.textAlign == TextAlign.justify).evaluate()
    .map((element) => element.findRenderObject()).whereType<RenderParagraph>()
    .firstWhere((paragraph) => paragraph.text.toPlainText().contains('清晨的风吹过树林'));
  final text = render.text.toPlainText(), origin = render.localToGlobal(Offset.zero);
  final groups = <int, Rect>{};
  // The oracle deliberately asks for all boxes, independently of the product
  // window/cache, but performs caret queries only on the painted vicinity.
  // Every repeated phrase is identified by its exact source position.
  for (final box in render.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: text.length),
    boxHeightStyle: ui.BoxHeightStyle.tight)) {
    final rect = box.toRect(), global = rect.shift(origin);
    if (rect.width < 0.01 || rect.height < 2 || global.bottom < body.top - 100 || global.top > clipBottom + 100) continue;
    final a = render.getPositionForOffset(Offset(-1, rect.center.dy)).offset;
    final b = render.getPositionForOffset(Offset(render.size.width + 1, rect.center.dy)).offset;
    final start = a < b ? a : b;
    groups.update(start, (row) => row.expandToInclude(rect), ifAbsent: () => rect);
  }
  final spaces = RegExp('[\\s\u200B\uFFFC]');
  int canonical(int offset) => text.substring(0, offset).replaceAll(spaces, '').length;
  final rows = <_SourceRow>[];
  for (final entry in groups.entries) {
    final rect = entry.value.shift(origin);
    if (rect.top < body.top - 0.25 || rect.bottom > clipBottom + 0.25) continue;
    final end = render.getPositionForOffset(Offset(render.size.width + 1, entry.value.center.dy)).offset;
    final startSource = canonical(entry.key), endSource = canonical(end);
    if (endSource > startSource) rows.add((start: startSource, end: endSource, top: rect.top - body.top));
  }
  rows.sort((a, b) => a.top.compareTo(b.top));
  expect(rows, isNotEmpty);
  for (var row = 1; row < rows.length; row++) {
    expect(rows[row].start, rows[row - 1].end, reason: 'Every painted row must follow the preceding source range');
  }
  return rows;
}
void _expectRows(List<_SourceRow> actual, List<_SourceRow> expected, String phase) {
  expect(actual.map((row) => (row.start, row.end)).toList(), expected.map((row) => (row.start, row.end)).toList(), reason: phase);
  for (var index = 0; index < actual.length; index++) {
    expect(actual[index].top, closeTo(expected[index].top, 0.5), reason: '$phase row $index pixel alignment');
  }
}
Future<void> _page(WidgetTester tester, int direction, _LayoutWork work) async {
  work.clear();
  final body = tester.getRect(find.byKey(const ValueKey('reader-body')));
  await tester.tapAt(Offset(direction > 0 ? body.right - 20 : body.left + 20, body.center.dy));
  await tester.pumpAndSettle();
  expect(work['selectionBoxes'], lessThanOrEqualTo(600), reason: 'A page turn must not query every row of the long paragraph');
  expect(work['caretHits'], lessThanOrEqualTo(1200));
}
void _expectBoundedFarWork(_LayoutWork work, String phase) {
  debugPrint('FAR_WORK $phase ${work.counts}');
  expect(work['selectionBoxes'], lessThanOrEqualTo(1200),
    reason: '$phase may inspect initial and target windows, but must not query all 30k paragraph characters');
  expect(work['caretHits'], lessThanOrEqualTo(2400));
}

class _LayoutWork {
  final counts = <String, int>{};
  void record(String event, int count) => counts.update(event, (previous) => previous + count, ifAbsent: () => count);
  int operator [](String event) => counts[event] ?? 0;
  void clear() => counts.clear();
}
void _expectNoNativeMeasure(_LayoutWork work, String phase) {
  expect(work['selectionBoxes'], 0, reason: '$phase must reuse local selection boxes');
  expect(work['caretHits'], 0, reason: '$phase must reuse local row caret offsets');
  expect(work['TextPainterFallback'], 0, reason: '$phase must not lay out a second long paragraph');
}
Future<void> _rebuild(WidgetTester tester, ValueNotifier<int> revision, int times) async {
  for (var index = 0; index < times; index++) {
    revision.value++; await tester.pumpAndSettle();
  }
}
Future<ValueNotifier<int>> _mount(WidgetTester tester, String mode, _LayoutWork work, {BookProgress? progress}) async {
  tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
  final storage = AppStorage();
  // User reproduction: size 39, default line height and default font.
  await storage.saveSettings((ReadingSettings()..fontSize = 39..pageTurnMode = mode..pageTurnAnimation = 'off').toJson());
  if (progress != null) await storage.saveProgress(progress);
  const phrase = '清晨的风吹过树林，远方的小路一直延伸到村庄。';
  final text = List.filled(1600, phrase).join().substring(0, 30000);
  final source = Book(id: 'open-performance-$mode', title: '长段打开', filePath: '', format: BookFormat.txt,
    addedAt: DateTime(2026), chapters: [Chapter(title: '第一章', paragraphs: [
      ReadingText.paragraph(text),
      for (var paragraph = 0; paragraph < 24; paragraph++)
        ReadingText.paragraph('后续第$paragraph段，山间的小路很长，远处仍有村庄。'),
    ])]);
  final speech = TtsReader(player: _SilentPlayer());
  final revision = ValueNotifier<int>(0);
  ReaderScreen.onLayoutWorkForTesting = work.record;
  await tester.pumpWidget(MaterialApp(home: ValueListenableBuilder<int>(valueListenable: revision,
    builder: (context, _, __) => ReaderScreen(key: const ValueKey('performance-reader'),
      book: source, storage: storage, ttsReader: speech))));
  await tester.pumpAndSettle();
  return revision;
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
