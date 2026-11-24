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
import 'package:duoduo_langdu/services/reader_preparation.dart';
import 'package:duoduo_langdu/services/reader_spacing_policy.dart';
import 'package:duoduo_langdu/services/reading_text.dart';
import 'package:duoduo_langdu/services/system_tts.dart';
import 'package:duoduo_langdu/services/tts_audio_handler.dart';
import 'package:duoduo_langdu/services/tts_reader.dart';

const _markers = ['甲段', '乙段', '丙段'];
ReaderSpacingPlan? _policy;

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  final cjkFont = File('${Platform.environment['SystemRoot']}\\Fonts\\msyh.ttc');
  late TtsAudioHandler handler;
  TtsAudioHandler? previous;

  setUpAll(() async {
    if (!cjkFont.existsSync()) return;
    // Register an existing OS resource only in memory, without redistributing it.
    await (FontLoader('ParagraphSpacingCjk')
      ..addFont(cjkFont.readAsBytes().then((bytes) => ByteData.sublistView(bytes)))).load();
  });
  setUp(() async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    SharedPreferences.setMockInitialValues({});
    ReaderPreparation.clearMemoryCache();
    _policy = null;
    ReaderScreen.onSpacingPolicyForTesting = (plan) { _policy = plan; };
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
    ReaderScreen.onSpacingPolicyForTesting = null;
    _policy = null;
    ReaderPreparation.runnerForTesting = null;
    ReaderPreparation.clearMemoryCache(); globalAudioHandler = previous;
    unawaited(handler.playbackState.close()); unawaited(handler.mediaItem.close());
  });

  for (final fontSize in [20.0, 39.0, 64.0]) {
    for (final lineHeight in [1.2, 1.6, 2.4]) {
    for (final level in ReadingSettings.paragraphSpacingLevels) {
      for (final indent in [false, true]) {
        testWidgets('size $fontSize, line height $lineHeight, spacing level $level, indent $indent: physical policy gap and complete rows', (tester) async {
          await _mount(tester, indent: indent, fontSize: fontSize, lineHeight: lineHeight, level: level,
            id: '$fontSize-$lineHeight-$level-$indent');
          final measured = _measure(tester, indent: indent);
          final policy = _currentPolicy();
          _expectPolicy(tester, policy, fontSize: fontSize, lineHeight: lineHeight, level: level);
          _expectAdvances(measured, lineHeight: lineHeight, fontSize: fontSize, gap: policy.spacing);
          _expectParagraphEdges(tester, gap: policy.spacing);
          await _expectPageBudgetAndCoverage(tester, measured, indent: indent,
            fontSize: fontSize, lineHeight: lineHeight, level: level);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
        }, skip: !cjkFont.existsSync());
      }
    }
    }
  }

  testWidgets('scaled font preserves native line pitch and uses the actual level policy without trailing gap', (tester) async {
    await _mount(tester, indent: true, fontSize: 39, lineHeight: 1.6, level: 3,
      textScale: 1.25, id: 'scaled-paragraph-edges');
    final policy = _currentPolicy();
    _expectPolicy(tester, policy, fontSize: 39 * 1.25, lineHeight: 1.6, level: 3);
    _expectAdvances(_measure(tester, indent: true), lineHeight: 1.6,
      fontSize: 39 * 1.25, gap: policy.spacing);
    _expectParagraphEdges(tester, gap: policy.spacing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, skip: !cjkFont.existsSync());
}

Future<void> _mount(WidgetTester tester, {required bool indent, required double fontSize,
  required double lineHeight, required int level, required String id, double textScale = 1}) async {
  // Initially expose all three body paragraphs so native baseline measurements
  // and item edges do not depend on an offscreen cache. The page test then
  // returns to a normal phone viewport and checks its newly resolved policy.
  tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 4000);
  addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
  final storage = AppStorage();
  await storage.saveSettings((ReadingSettings()..fontSize = fontSize..fontFamily = 'ParagraphSpacingCjk'
    ..lineHeight = lineHeight..paragraphSpacingLevel = level
    ..firstLineIndent = indent..mergeNonSentenceBreaks = false..informationFilter = false
    ..retainPageLine = false..pageTurnMode = 'tap'..pageTurnAnimation = 'off').toJson());
  // Entirely synthetic text: a short paragraph followed by long body paragraphs.
  final book = Book(id: 'paragraph-space-$id', title: '段落行距', filePath: '', format: BookFormat.txt,
    addedAt: DateTime(2026), chapters: [Chapter(title: '第一章', paragraphs: [
      ReadingText.paragraph('甲段晨光照在山坡上，微风吹过树梢。'),
      ReadingText.paragraph('乙段' + List.filled(3, '山间的小路通向村庄，远处有人慢慢走来。').join()),
      ReadingText.paragraph('丙段' + List.filled(60, '溪水绕过石桥流向远方，岸边草木随风轻摆。').join()),
    ])]);
  await tester.pumpWidget(MaterialApp(builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)), child: child!),
    home: ReaderScreen(book: book, storage: storage, ttsReader: TtsReader(player: _SilentPlayer()))));
  await tester.pumpAndSettle(); await _alignFirst(tester, indent: indent);
}

Future<void> _alignFirst(WidgetTester tester, {required bool indent}) async {
  final body = find.byKey(const ValueKey('reader-body'));
  final list = tester.widget<ScrollablePositionedList>(body);
  list.itemScrollController!.jumpTo(index: 1); await tester.pumpAndSettle();
  final delta = _measure(tester, indent: indent).first.glyph.top - tester.getTopLeft(body).dy;
  unawaited(list.scrollOffsetController!.animateScroll(offset: delta, duration: const Duration(milliseconds: 1)));
  await tester.pumpAndSettle();
}

typedef _Row = ({String key, int paragraph, Rect glyph, double baseline});

ReaderSpacingPlan _currentPolicy() {
  expect(_policy, isNotNull, reason: 'The real single-CJK-font fixture must complete production font/spacing preparation');
  return _policy!;
}

void _expectPolicy(WidgetTester tester, ReaderSpacingPlan policy,
  {required double fontSize, required double lineHeight, required int level}) {
  expect(policy.fixedRows, isFalse);
  expect(policy.rows, 0, reason: 'Flow pages have no fixed row-count cap');
  expect(policy.spacing, closeTo(fontSize * level / 4, 1e-9));
  expect(policy.rowPitch, greaterThan(0));
  expect(policy.remainingMax, closeTo(policy.rowPitch + policy.spacing, 1e-6));
}

({List<double> within, List<double> between}) _advances(List<_Row> rows) {
  final within = <double>[], between = <double>[];
  for (var i = 1; i < rows.length; i++) {
    (rows[i].paragraph == rows[i - 1].paragraph ? within : between).add(rows[i].baseline - rows[i - 1].baseline);
  }
  return (within: within, between: between);
}

void _expectAdvances(List<_Row> rows, {required double lineHeight, required double gap, double fontSize = 39}) {
  expect(rows.map((row) => row.paragraph).toSet(), hasLength(3));
  expect(rows.where((row) => row.paragraph == 1).length, greaterThanOrEqualTo(3));
  final advances = _advances(rows), normal = advances.within.first;
  final renders = _paragraphRenders();
  final actualHeight = renders.values.first.strutStyle!.height!;
  expect(actualHeight, lineHeight, reason: 'The requested line-height multiplier is used unchanged');
  for (final render in renders.values) {
    expect(_effectiveBodyStyle(render.text).height, actualHeight,
      reason: 'Every actual body span must use the same resolved native line-height multiplier');
    expect(render.strutStyle?.height, actualHeight);
  }
  expect(normal, closeTo(fontSize * actualHeight, 1),
    reason: 'Measure native baseline pitch from effective render style, not the requested slider value $lineHeight');
  for (final advance in advances.within) {
    expect(advance, closeTo(normal, 0.1), reason: 'Paragraph spacing must not change ordinary line pitch');
  }
  expect(advances.between, hasLength(2));
  for (final advance in advances.between) {
    expect(advance - normal, closeTo(gap, 1),
      reason: 'Exactly one measured policy gap applies regardless of first-line indentation');
  }
}

TextStyle _effectiveBodyStyle(InlineSpan span, [TextStyle inherited = const TextStyle()]) {
  if (span is! TextSpan) return inherited;
  final style = inherited.merge(span.style);
  if (span.text?.trim().isNotEmpty ?? false) return style;
  for (final child in span.children ?? const <InlineSpan>[]) {
    final result = _effectiveBodyStyle(child, style);
    if (result.fontSize != null && result.height != null && child is TextSpan) return result;
  }
  return style;
}

void _expectParagraphEdges(WidgetTester tester, {required double gap, bool requireAll = true}) {
  final renders = _paragraphRenders();
  expect(renders, requireAll ? hasLength(3) : isNotEmpty);
  for (final entry in renders.entries) {
    final render = entry.value;
    RenderObject? ancestor = render.parent;
    while (ancestor != null && ancestor is! RenderPadding) { ancestor = ancestor.parent; }
    expect(ancestor, isA<RenderPadding>());
    final padding = ancestor! as RenderPadding;
    expect(padding.padding.resolve(TextDirection.ltr).top, closeTo(gap, 1e-6),
      reason: 'Even subpixel policy spacing must reach the real rendered paragraph padding');
    // Read actual parent/child geometry. ItemPositions normalizes and rounds
    // sliver edges; its reconstructed coordinates are not a padding oracle.
    final before = render.localToGlobal(Offset.zero).dy - padding.localToGlobal(Offset.zero).dy;
    final after = padding.localToGlobal(Offset(0, padding.size.height)).dy -
      render.localToGlobal(Offset(0, render.size.height)).dy;
    expect(before, closeTo(gap, 0.1),
      reason: 'The visible chapter title is an ordinary paragraph boundary and contributes the same fixed gap');
    expect(after, closeTo(0, 0.1),
      reason: 'No paragraph, including the last one, adds trailing paragraph padding');
  }
}

Future<void> _expectPageBudgetAndCoverage(WidgetTester tester, List<_Row> measured,
  {required bool indent, required double fontSize, required double lineHeight, required int level}) async {
  final body = find.byKey(const ValueKey('reader-body'));
  // Resizing changes page capacity, never the requested font/line/gap values.
  tester.view.physicalSize = const Size(390, 844);
  await tester.pumpAndSettle(); await _alignFirst(tester, indent: indent);
  final policy = _currentPolicy();
  _expectPolicy(tester, policy, fontSize: fontSize, lineHeight: lineHeight, level: level);
  _expectParagraphEdges(tester, gap: policy.spacing, requireAll: false);
  final rows = _measure(tester, indent: indent), viewport = tester.getRect(body);
  final visible = _visibleRows(tester, rows);
  expect(visible, isNotEmpty);
  _expectCompleteTerminal(tester, visible);
  final fitting = rows.where((row) => row.glyph.top >= viewport.top - .25 && row.glyph.bottom <= viewport.bottom + .25);
  expect(visible.map((row) => row.key), orderedEquals(fitting.map((row) => row.key)),
    reason: 'A native complete row fitting the real body may not be hidden solely by a fixed K cap');
  // The resized sliver need not materialize the following paragraph yet. The
  // initial full-layout snapshot is the immutable source-row order oracle.
  final sourceIndex = measured.indexWhere((row) => row.key == visible.last.key);
  expect(sourceIndex, greaterThanOrEqualTo(0));
  expect(sourceIndex + 1, lessThan(measured.length), reason: 'This fixture has a following body paragraph');
  final next = measured[sourceIndex + 1];
  final remaining = viewport.bottom - visible.last.glyph.bottom;
  expect(remaining, inInclusiveRange(-.25, policy.rowPitch + policy.spacing + .5),
    reason: 'The remaining space is less than a complete native advance, including a paragraph boundary');
  final nextInRender = rows.where((row) => row.key == next.key);
  if (nextInRender.isNotEmpty) expect(nextInRender.first.glyph.bottom, greaterThan(viewport.bottom - .25),
    reason: 'The next complete native source row must not fit');

  await tester.tapAt(Offset(viewport.right - 20, viewport.center.dy));
  await tester.pumpAndSettle();
  final following = _visibleRows(tester, _measure(tester, indent: indent));
  expect(following, isNotEmpty);
  expect(following.first.key, next.key, reason: 'Forward paging must preserve the next complete row without repetition or loss');
  _expectCompleteTerminal(tester, following);
  final nextViewport = tester.getRect(body);
  final nextRows = _measure(tester, indent: indent);
  final nextFitting = nextRows.where((row) => row.glyph.top >= nextViewport.top - .25 && row.glyph.bottom <= nextViewport.bottom + .25);
  expect(following.map((row) => row.key), orderedEquals(nextFitting.map((row) => row.key)),
    reason: 'The ordinary incoming page cannot discard even one additional fitting native row');
  expect(nextViewport.bottom - following.last.glyph.bottom,
    inInclusiveRange(-.25, policy.rowPitch + policy.spacing + .5));
  final firstSource = measured.indexWhere((row) => row.key == following.first.key);
  expect(firstSource, greaterThanOrEqualTo(0));
  expect(following.map((row) => row.key), orderedEquals(measured.skip(firstSource).take(following.length).map((row) => row.key)),
    reason: 'Every shaped source row in the ordinary slice must occur exactly once, including paragraph boundaries');
  await tester.tapAt(Offset(viewport.left + 20, viewport.center.dy));
  await tester.pumpAndSettle();
  expect(_visibleRows(tester, _measure(tester, indent: indent)).map((row) => row.key),
    orderedEquals(visible.map((row) => row.key)), reason: 'Returning must preserve the original fixed-gap page slice');
}

void _expectCompleteTerminal(WidgetTester tester, List<_Row> visible) {
  final clipFinder = find.byKey(const ValueKey('reader-page-clip'));
  final size = tester.getSize(clipFinder), origin = tester.getTopLeft(clipFinder);
  final clip = tester.widget<ClipRect>(clipFinder).clipper!.getClip(size);
  final viewport = tester.getRect(find.byKey(const ValueKey('reader-body')));
  final bottom = (origin.dy + clip.bottom).clamp(viewport.top, viewport.bottom);
  expect(bottom, closeTo(visible.last.glyph.bottom, .25),
    reason: 'The actual page clip ends at a complete glyph row, with no trailing line/paragraph gap or partial terminal row');
}

List<_Row> _visibleRows(WidgetTester tester, List<_Row> rows) {
  final viewport = tester.getRect(find.byKey(const ValueKey('reader-body')));
  final clipFinder = find.byKey(const ValueKey('reader-page-clip'));
  final clip = tester.widget<ClipRect>(clipFinder).clipper!.getClip(tester.getSize(clipFinder));
  final bottom = tester.getTopLeft(clipFinder).dy + clip.bottom;
  // Tight font-metric boxes can overlap at line height 1.2 even when native ink
  // does not. Use the same complete-box policy as production; intersection of
  // the next row's conservative leading is not evidence of a half-painted row.
  // Source adjacency and the exact planned end below detect omitted full rows.
  return rows.where((row) => row.glyph.top >= viewport.top - .25 && row.glyph.bottom <= bottom + .25).toList();
}

Map<int, RenderParagraph> _paragraphRenders() {
  final renders = <int, RenderParagraph>{};
  for (final element in find.byWidgetPredicate((widget) => widget is Text && widget.textAlign == TextAlign.justify).evaluate()) {
    final render = element.findRenderObject();
    if (render is! RenderParagraph) continue;
    final plain = render.text.toPlainText().replaceAll(RegExp('[\\u200B\\uFFFC\\s]'), '');
    final index = _markers.indexWhere(plain.startsWith);
    if (index >= 0) renders[index + 1] = render;
  }
  return renders;
}

List<_Row> _measure(WidgetTester tester, {required bool indent}) {
  final renders = _paragraphRenders();
  final list = tester.widget<ScrollablePositionedList>(find.byKey(const ValueKey('reader-body')));
  final visible = list.itemPositionsNotifier!.itemPositions.value.firstWhere((position) =>
    position.itemTrailingEdge > 0 && position.itemLeadingEdge < 1 && renders.containsKey(position.index));
  final anchor = renders[visible.index]!, viewport = RenderAbstractViewport.of(anchor);
  final result = <_Row>[];
  for (final entry in renders.entries) {
    final render = entry.value;
    if (RenderAbstractViewport.maybeOf(render) != viewport) continue;
    // Observe the actual painted transform after resize/jump. Reveal offsets
    // reconstruct sliver scroll coordinates, not necessarily this frame's
    // paint coordinates while the indexed viewport is changing its anchor.
    final top = render.localToGlobal(Offset.zero).dy;
    final grouped = <int, Rect>{};
    for (final box in render.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: render.text.toPlainText().length),
      boxHeightStyle: ui.BoxHeightStyle.tight)) {
      final rect = box.toRect();
      if (rect.width < .01 || rect.height < 2) continue;
      final a = render.getPositionForOffset(Offset(-1, rect.center.dy)).offset;
      final b = render.getPositionForOffset(Offset(render.size.width + 1, rect.center.dy)).offset;
      final start = a < b ? a : b;
      grouped.update(start, (previous) => previous.expandToInclude(rect), ifAbsent: () => rect);
    }
    final lines = grouped.entries.toList()..sort((a, b) => a.value.top.compareTo(b.value.top));
    if (lines.isEmpty) continue;
    final firstBaseline = render.getDryBaseline(render.constraints, TextBaseline.alphabetic)!;
    double caretTop(Rect rect) {
      // Hit a real glyph rather than the short WidgetSpan indentation marker.
      final position = render.getPositionForOffset(Offset(rect.left + .01, rect.center.dy));
      return render.getOffsetForCaret(position, Rect.zero).dy;
    }
    final firstCaretTop = caretTop(lines.first.value);
    for (var i = 0; i < lines.length; i++) {
      result.add((key: '${entry.key}/${lines[i].key}', paragraph: entry.key - 1,
        glyph: lines[i].value.shift(Offset(0, top)),
        // This fixture uses one CJK font and size throughout. Its real caret
        // line displacement therefore equals baseline displacement, including
        // native rounding and the rendered placeholder's final dimensions.
        baseline: top + firstBaseline + caretTop(lines[i].value) - firstCaretTop));
    }
  }
  result.sort((a, b) => a.baseline.compareTo(b.baseline));
  return result;
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
