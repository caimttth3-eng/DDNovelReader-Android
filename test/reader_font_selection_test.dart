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

const _family = 'ReaderFontSelectionProbe';
const _fontSlider = ValueKey('quick-font-size');
ReaderSpacingPlan? _policy;
typedef _Row = ({Rect glyph, List<int> units});

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  final font = File('${Platform.environment['SystemRoot']}\\Fonts\\msyh.ttc');
  setUpAll(() async {
    if (!font.existsSync()) return;
    await (FontLoader(_family)..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
  });
  TtsAudioHandler? previous;
  late TtsAudioHandler handler;
  setUp(() async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    SharedPreferences.setMockInitialValues({});
    ReaderPreparation.clearMemoryCache();
    ReaderPreparation.runnerForTesting = (request) async => ReaderPreparation.prepareSynchronously(request);
    ReaderScreen.onSpacingPolicyForTesting = (plan) => _policy = plan;
    _policy = null;
    AppAppearance.setThemeMode('light');
    previous = globalAudioHandler; handler = TtsAudioHandler(); globalAudioHandler = handler;
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
    ReaderPreparation.runnerForTesting = null; ReaderPreparation.clearMemoryCache();
    ReaderScreen.onSpacingPolicyForTesting = null; _policy = null;
    globalAudioHandler = previous;
    unawaited(handler.playbackState.close()); unawaited(handler.mediaItem.close());
  });

  testWidgets('viewport resizing retains the exact requested font and line height', (tester) async {
    final storage = await _mount(tester, 'resize');
    final observations = <String>[];
    final actuals = <double>[];
    for (final height in [844.0, 848.0, 844.0]) {
      tester.view.physicalSize = Size(390, height); await tester.pumpAndSettle();
      await _openQuick(tester);
      final actual = _actual(tester);
      expect(actual, 14.0, reason: 'Viewport changes must not snap the requested font to another size');
      final rows = await _rows(tester, actual);
      _expectQuick(tester, actual);
      final saved = await storage.loadSettings();
      expect(saved['fontSize'], 14.0, reason: 'Resizing must retain the requested size');
      expect(saved['lineHeight'], 1.2);
      expect(rows.first.units.first, 0, reason: 'A geometry change at book start must not skip source characters');
      observations.add('H=$height body=${tester.getSize(find.byKey(const ValueKey('reader-body'))).height} actualF=$actual K=${_policy!.rows} W=${_policy!.hardWidth}');
      actuals.add(actual);
      await _closeQuick(tester);
    }
    debugPrint('FONT_SELECTION_RESIZE ${observations.join('; ')}');
    expect(actuals, everyElement(14.0), reason: observations.join('; '));
    expect(actuals.last, actuals.first, reason: 'Returning to identical geometry must reproduce the same actual size');
    await _expectPageCoverage(tester, actuals.last);
    expect((await storage.loadSettings())['fontSize'], 14.0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, skip: !font.existsSync());

  testWidgets('quick font drag is a preview until release then persists the actual supported font', (tester) async {
    final storage = await _mount(tester, 'slider');
    await _openQuick(tester);
    final before = _actual(tester), beforeUnits = _units(await _rows(tester, _actual(tester)));
    final rect = tester.getRect(find.byKey(_fontSlider));
    double x(double size) => rect.left + 12 + (rect.width - 24) * (size - 14) / 50;
    final gesture = await tester.startGesture(Offset(x(before), rect.center.dy));
    await gesture.moveTo(Offset(x(23), rect.center.dy)); await tester.pumpAndSettle();
    final draft = tester.widget<Slider>(find.byKey(_fontSlider)).value;
    expect(draft, 23.0);
    expect((await storage.loadSettings())['fontSize'], 14.0, reason: 'Dragging alone must not commit typography');
    expect(_actual(tester), before);
    expect(_units(await _rows(tester, before)), beforeUnits, reason: 'Holding the thumb must not reflow visible text');
    await gesture.up(); await tester.pumpAndSettle();
    final actual = _actual(tester), saved = await storage.loadSettings();
    expect(actual, 23.0);
    expect(saved['fontSize'], 23.0, reason: 'Release persists exactly the selected size');
    _expectQuick(tester, actual); await _rows(tester, actual);
    await _closeQuick(tester); await _expectPageCoverage(tester, actual);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, skip: !font.existsSync());

  testWidgets('font fine tune displays actual size and rapid increments retain every user intent', (tester) async {
    final storage = await _mount(tester, 'fine-tune');
    await _openQuick(tester);
    final before = _actual(tester);
    await tester.tap(find.byKey(const ValueKey('font-fine-tune'))); await tester.pumpAndSettle();
    void expectLabel(double actual) {
      final label = find.descendant(of: find.byType(BottomSheet).last,
        matching: find.byWidgetPredicate((widget) => widget is Text && (widget.data?.endsWith(' ${actual.toStringAsFixed(0)}') ?? false)));
      expect(label, findsOneWidget, reason: 'The modal must display actual native font size');
    }
    expectLabel(before);
    // Deliberately do not settle the first asynchronous reflow before later
    // button taps. A stale absolute fontSize+1 must not collapse three intents.
    for (var i = 0; i < 3; i++) await tester.tap(find.byKey(const ValueKey('font-increase')));
    await tester.pumpAndSettle();
    final larger = _actual(tester);
    expect(larger, before + 3);
    expectLabel(larger);
    expect((await storage.loadSettings())['fontSize'], larger);
    await tester.tap(find.byKey(const ValueKey('font-decrease'))); await tester.pumpAndSettle();
    final smaller = _actual(tester);
    expect(smaller, larger - 1, reason: 'Minus decrements exactly one requested font size');
    expectLabel(smaller);
    expect((await storage.loadSettings())['fontSize'], smaller);
    await tester.tapAt(const Offset(195, 60)); await tester.pumpAndSettle();
    await _openQuick(tester); _expectQuick(tester, smaller); await _rows(tester, smaller);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, skip: !font.existsSync());
}

Future<AppStorage> _mount(WidgetTester tester, String id) async {
  tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
  final storage = AppStorage();
  await storage.saveSettings((ReadingSettings()..fontFamily = _family..fontSize = 14..lineHeight = 1.2
    ..paragraphSpacingLevel = 2..firstLineIndent = false..informationFilter = false..mergeNonSentenceBreaks = false
    ..autoExtractToc = false..automaticBrightness = false..brightness = .8
    ..pageTurnMode = 'tap'..pageTurnAnimation = 'off').toJson());
  final book = Book(id: 'font-selection-$id', title: '字号原文验证', filePath: '', format: BookFormat.txt,
    addedAt: DateTime(2026), chapters: [Chapter(title: '', paragraphs: [
      for (var p = 0; p < 10; p++) ReadingText.paragraph(String.fromCharCodes(List.generate(500, (i) => 0x4e00 + p * 500 + i))),
    ])]);
  await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: book, storage: storage, ttsReader: TtsReader(player: _SilentPlayer()))));
  await tester.pumpAndSettle();
  expect(_policy, isNotNull, reason: 'The actual font inventory and viewport must produce a supported native policy');
  return storage;
}

Future<void> _openQuick(WidgetTester tester) async {
  if (find.byKey(_fontSlider).evaluate().isNotEmpty) return;
  if (find.byKey(const ValueKey('reader-menu')).evaluate().isEmpty) {
    await tester.tapAt(const Offset(195, 300)); await tester.pumpAndSettle();
  }
  await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
  expect(find.byKey(_fontSlider), findsOneWidget);
}
Future<void> _closeQuick(WidgetTester tester) async {
  if (find.byKey(_fontSlider).evaluate().isNotEmpty) {
    await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
  }
}
void _expectQuick(WidgetTester tester, double actual) {
  expect(tester.widget<Slider>(find.byKey(_fontSlider)).value, actual);
  expect(find.descendant(of: find.byKey(const ValueKey('font-fine-tune')), matching: find.text('T${actual.toStringAsFixed(0)}')), findsOneWidget);
}

bool _bodyRune(int rune) => rune >= 0x4e00 && rune < 0x4e00 + 5000;
double _actual(WidgetTester tester) {
  final fonts = <double>{};
  final bodyFinder = find.byKey(const ValueKey('reader-body'));
  final body = tester.getRect(bodyFinder);
  final active = tester.widget<ScrollablePositionedList>(bodyFinder).itemPositionsNotifier!.itemPositions.value
    .where((item) => item.itemLeadingEdge < 1 && item.itemTrailingEdge > 0).map((item) => item.index).toSet();
  for (final element in find.descendant(of: bodyFinder, matching: find.byType(RichText)).evaluate()) {
    int? item;
    element.visitAncestorElements((ancestor) {
      if (ancestor.widget.key case ValueKey<int>(value: final index)) { item = index; return false; }
      return true;
    });
    final render = element.findRenderObject();
    if (!active.contains(item) || render is! RenderParagraph || !render.attached || !render.hasSize ||
        !render.text.toPlainText().runes.any(_bodyRune)) continue;
    final top = render.localToGlobal(Offset.zero).dy;
    if (top >= body.bottom || top + render.size.height <= body.top) continue;
    void collect(InlineSpan span, TextStyle parent) {
      if (span is! TextSpan) return;
      final style = parent.merge(span.style);
      if (span.text?.runes.any(_bodyRune) ?? false) {
        expect(style.fontFamily, _family); fonts.add(style.fontSize!);
        expect(style.height, 1.2, reason: 'Font selection and viewport changes preserve requested line height');
        expect(render.strutStyle!.fontSize, style.fontSize);
        expect(render.strutStyle!.height, style.height);
      }
      for (final child in span.children ?? const <InlineSpan>[]) collect(child, style);
    }
    collect(render.text, const TextStyle());
  }
  expect(fonts, hasLength(1), reason: 'Inspect actual body spans, rather than the inherited RichText wrapper');
  final actual = fonts.single;
  expect(_policy, isNotNull);
  expect(_policy!.fixedRows, isFalse);
  expect(_policy!.spacing, actual / 2, reason: 'Level two is a fixed half-font paragraph gap');
  return actual;
}

Future<List<_Row>> _rows(WidgetTester tester, double actual) async {
  expect(_actual(tester), actual);
  final bodyFinder = find.byKey(const ValueKey('reader-body')), body = tester.getRect(bodyFinder);
  final clipFinder = find.byKey(const ValueKey('reader-page-clip'));
  final clipper = tester.widget<ClipRect>(clipFinder).clipper;
  final clip = (clipper?.getClip(tester.getSize(clipFinder)) ?? (Offset.zero & tester.getSize(clipFinder)))
    .shift(tester.getTopLeft(clipFinder)).intersect(body);
  final active = tester.widget<ScrollablePositionedList>(bodyFinder).itemPositionsNotifier!.itemPositions.value
    .where((item) => item.itemLeadingEdge < 1 && item.itemTrailingEdge > 0).map((item) => item.index).toSet();
  final renders = <int, RenderParagraph>{};
  for (final element in find.descendant(of: bodyFinder, matching: find.byType(RichText)).evaluate()) {
    int? item;
    element.visitAncestorElements((ancestor) {
      if (ancestor.widget.key case ValueKey<int>(value: final index)) { item = index; return false; }
      return true;
    });
    final render = element.findRenderObject();
    if (item != null && active.contains(item) && render is RenderParagraph && render.attached && render.hasSize && render.text.toPlainText().runes.any(_bodyRune)) renders[item!] = render;
  }
  final result = <_Row>[], fitting = <_Row>[];
  var nativeStep = 0.0;
  for (final render in renders.values) {
    final text = render.text.toPlainText(), grouped = <int, Rect>{};
    for (final box in render.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: text.length), boxHeightStyle: ui.BoxHeightStyle.tight)) {
      final rect = box.toRect(); if (rect.width < .01 || rect.height < 2) continue;
      final start = render.getPositionForOffset(Offset(-1, rect.center.dy)).offset;
      grouped.update(start, (old) => old.expandToInclude(rect), ifAbsent: () => rect);
    }
    double? previousBottom;
    for (final entry in grouped.entries) {
      final glyph = entry.value.shift(render.localToGlobal(Offset.zero));
      if (previousBottom != null && entry.value.bottom - previousBottom > nativeStep) {
        nativeStep = entry.value.bottom - previousBottom;
      }
      previousBottom = entry.value.bottom;
      final end = render.getPositionForOffset(Offset(render.size.width + 1, entry.value.center.dy)).offset;
      final units = text.substring(entry.key, end).runes.where(_bodyRune).map((rune) => rune - 0x4e00).toList();
      if (glyph.top >= body.top - .25 && glyph.bottom <= body.bottom + .25) fitting.add((glyph: glyph, units: units));
      if (glyph.bottom <= clip.top + .25 || glyph.top >= clip.bottom - .25) continue;
      if (glyph.top < clip.top - .25 || glyph.bottom > clip.bottom + .25) {
        // A font-run tight box can be taller than the strut pitch at L=1.2.
        // Do not silently discard that intersecting box: independently paint
        // only its exact source row, preserving all shaping/layout characters,
        // and prove none of its real ink enters the published clip.
        final ink = await tester.runAsync(() => _rowInk(render, entry.key, end, entry.value));
        expect(ink, isNotNull, reason: 'The unique Han source row must contain real painted ink');
        final belongsBefore = glyph.top < clip.top - .25;
        if (belongsBefore) {
          expect(ink!.bottom, lessThanOrEqualTo(clip.top),
            reason: 'No ink from the preceding excluded source row may leak into the page');
        } else {
          expect(ink!.top, greaterThanOrEqualTo(clip.bottom),
            reason: 'No ink from the next excluded source row may leak through the final clip');
        }
        continue;
      }
      expect(glyph.top, greaterThanOrEqualTo(clip.top - .25));
      expect(glyph.bottom, lessThanOrEqualTo(clip.bottom + .25), reason: 'The entire final native glyph row must be visible');
      result.add((glyph: glyph, units: units));
    }
  }
  result.sort((a, b) => a.glyph.top.compareTo(b.glyph.top));
  expect(result, isNotEmpty);
  fitting.sort((a, b) => a.glyph.top.compareTo(b.glyph.top));
  expect(_units(result), orderedEquals(_units(fitting)), reason: 'No physically fitting complete source row is hidden');
  final units = _units(result);
  expect(units, isNotEmpty);
  for (var i = 1; i < units.length; i++) expect(units[i], units[i - 1] + 1, reason: 'No source unit may repeat or disappear within a visible page');
  expect(body.bottom - result.last.glyph.bottom, inInclusiveRange(-.25, nativeStep + _policy!.spacing + .5));
  expect(clip.bottom, closeTo(result.last.glyph.bottom, .25), reason: 'The clip still ends exactly at the actual complete native row');
  return result;
}

Future<Rect?> _rowInk(RenderParagraph render, int from, int end, Rect nativeRow) async {
  var offset = 0;
  InlineSpan isolated(InlineSpan span) {
    if (span is! TextSpan) throw StateError('This no-indent fixture must use only native TextSpan content');
    final parts = <InlineSpan>[];
    final text = span.text;
    if (text != null) {
      final nodeStart = offset; offset += text.length;
      final cuts = <int>{0, text.length, (from - nodeStart).clamp(0, text.length).toInt(), (end - nodeStart).clamp(0, text.length).toInt()}.toList()..sort();
      for (var i = 1; i < cuts.length; i++) {
        final start = cuts[i - 1], finish = cuts[i];
        if (finish == start) continue;
        final visible = nodeStart + start >= from && nodeStart + finish <= end;
        parts.add(TextSpan(text: text.substring(start, finish), style: TextStyle(
          foreground: Paint()..color = visible ? Colors.white : Colors.transparent,
          background: Paint()..color = Colors.transparent, shadows: const [])));
      }
    }
    for (final child in span.children ?? const <InlineSpan>[]) parts.add(isolated(child));
    return TextSpan(style: span.style, children: parts);
  }
  final painter = TextPainter(text: isolated(render.text), textAlign: render.textAlign,
    textDirection: render.textDirection, textScaler: render.textScaler, locale: render.locale,
    strutStyle: render.strutStyle, textHeightBehavior: render.textHeightBehavior,
    textWidthBasis: render.textWidthBasis, maxLines: render.maxLines,
    ellipsis: render.overflow == TextOverflow.ellipsis ? '\u2026' : null)
    ..layout(minWidth: render.constraints.minWidth, maxWidth: render.constraints.maxWidth);
  ui.Picture? picture;
  ui.Image? image;
  try {
    expect(painter.width, closeTo(render.size.width, .01));
    expect(painter.height, closeTo(render.size.height, .01),
      reason: 'Making other source rows transparent must not change native line layout');
    final origin = render.localToGlobal(Offset.zero), globalRow = nativeRow.shift(origin);
    final left = origin.dx.floor() - 4, top = globalRow.top.floor() - 4;
    final width = (origin.dx + render.size.width).ceil() + 4 - left;
    final height = globalRow.bottom.ceil() + 4 - top;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..translate(origin.dx - left, origin.dy - top);
    painter.paint(canvas, Offset.zero);
    picture = recorder.endRecording(); image = await picture.toImage(width, height);
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    int? minX, minY, maxX, maxY;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (bytes.getUint8((y * width + x) * 4 + 3) == 0) continue;
        if (minX == null || x < minX) minX = x;
        if (minY == null || y < minY) minY = y;
        if (maxX == null || x > maxX) maxX = x;
        if (maxY == null || y > maxY) maxY = y;
      }
    }
    return minX == null ? null : Rect.fromLTRB((left + minX).toDouble(), (top + minY!).toDouble(),
      (left + maxX! + 1).toDouble(), (top + maxY! + 1).toDouble());
  } finally {
    image?.dispose(); picture?.dispose(); painter.dispose();
  }
}
List<int> _units(List<_Row> rows) => rows.expand((row) => row.units).toList();
Future<void> _expectPageCoverage(WidgetTester tester, double actual) async {
  final pages = <List<int>>[_units(await _rows(tester, actual))];
  for (var i = 0; i < 2; i++) {
    final body = tester.getRect(find.byKey(const ValueKey('reader-body')));
    await tester.tapAt(Offset(body.right - 20, body.center.dy)); await tester.pumpAndSettle();
    final next = _units(await _rows(tester, actual));
    expect(next.first, pages.last.last + 1, reason: 'A new native font layout must preserve exact source coverage across page cuts');
    pages.add(next);
  }
  for (var i = pages.length - 2; i >= 0; i--) {
    final body = tester.getRect(find.byKey(const ValueKey('reader-body')));
    await tester.tapAt(Offset(body.left + 20, body.center.dy)); await tester.pumpAndSettle();
    expect(_units(await _rows(tester, actual)), pages[i], reason: 'Backward navigation must reproduce the entire exact source slice');
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
