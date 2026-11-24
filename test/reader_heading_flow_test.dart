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
import 'package:duoduo_langdu/services/chapterizer.dart' show fallbackSplit;
import 'package:duoduo_langdu/services/display_cutout.dart';
import 'package:duoduo_langdu/services/network_connectivity.dart';
import 'package:duoduo_langdu/services/playback_notifications.dart';
import 'package:duoduo_langdu/services/reader_preparation.dart';
import 'package:duoduo_langdu/services/reader_spacing_policy.dart';
import 'package:duoduo_langdu/services/reading_text.dart';
import 'package:duoduo_langdu/services/system_tts.dart';
import 'package:duoduo_langdu/services/tts_audio_handler.dart';
import 'package:duoduo_langdu/services/tts_reader.dart';

const _fontSize = 26.0, _lineHeight = 1.6;
ReaderSpacingPlan? _spacingPolicy;
typedef _Row = ({String key, int item, Rect rect, List<int> units});

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  final font = File('${Platform.environment['SystemRoot']}\\Fonts\\msyh.ttc');
  TtsAudioHandler? previous;
  late TtsAudioHandler handler;
  setUpAll(() async {
    if (!font.existsSync()) return;
    await (FontLoader('ReaderHeadingCjk')
      ..addFont(font.readAsBytes().then((bytes) => ByteData.sublistView(bytes)))).load();
  });
  setUp(() async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    SharedPreferences.setMockInitialValues({});
    ReaderPreparation.clearMemoryCache();
    _spacingPolicy = null;
    ReaderScreen.onSpacingPolicyForTesting = (plan) => _spacingPolicy = plan;
    ReaderPreparation.runnerForTesting = (request) async => ReaderPreparation.prepareSynchronously(request);
    AppAppearance.setThemeMode('light');
    previous = globalAudioHandler;
    handler = TtsAudioHandler(); globalAudioHandler = handler;
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
    ReaderScreen.onSpacingPolicyForTesting = null;
    _spacingPolicy = null;
    ReaderPreparation.runnerForTesting = null;
    ReaderPreparation.clearMemoryCache();
    globalAudioHandler = previous;
    unawaited(handler.playbackState.close()); unawaited(handler.mediaItem.close());
  });

  testWidgets('real chapter and section headings appear once, blank chunk metadata adds no heading, and metadata uses body typography', (tester) async {
    _view(tester);
    const original = '第38章 二色莲10', section = '第39节', metadata = '第40章 山中来客';
    final book = Book(id: 'heading-original-and-metadata', title: '标题排版', filePath: '',
      format: BookFormat.txt, addedAt: DateTime(2026), chapters: [
        Chapter(title: original, paragraphs: [ReadingText.paragraph(original),
          ReadingText.paragraph('溪水绕过石桥，山间的风吹过树梢。'), ReadingText.paragraph('短段落。')]),
        Chapter(title: '', paragraphs: [ReadingText.paragraph('路旁有人停下脚步。')]),
        Chapter(title: section, paragraphs: [ReadingText.paragraph(section),
          ReadingText.paragraph('山坡上行人缓缓走近。')]),
        Chapter(title: metadata, paragraphs: [ReadingText.paragraph('远处灯火渐渐明亮。')]),
      ]);
    await _mount(tester, book, indent: true);
    final body = find.byKey(const ValueKey('reader-body'));
    final renders = _renders(tester);
    final originals = renders.values.where((render) => _plain(render.text) == original).toList();
    final sections = renders.values.where((render) => _plain(render.text) == section).toList();
    final metadataTitles = renders.values.where((render) => _plain(render.text) == metadata).toList();
    expect(originals, hasLength(1), reason: 'The original heading and identical chapter metadata must not be duplicated');
    expect(sections, hasLength(1), reason: 'A real source section heading must never be guessed to be a generated label');
    expect(metadataTitles, hasLength(1), reason: 'A genuine metadata-only chapter title remains readable');
    expect(book.chapters[1].title, isEmpty, reason: 'A technical chunk has no invented metadata heading');
    final short = renders.values.firstWhere((render) => _plain(render.text) == '短段落。');
    _expectStyles(short, bold: false);
    final center = tester.getRect(body).center.dx;
    for (final heading in [...originals, ...sections, ...metadataTitles]) {
      expect(heading.textAlign, TextAlign.center);
      _expectStyles(heading, bold: true);
      expect(heading.size.height, closeTo(short.size.height, .1),
        reason: 'A one-line heading uses the same fixed line allocation as one ordinary body line');
      Rect? glyphs;
      for (final box in heading.getBoxesForSelection(TextSelection(baseOffset: 0,
        extentOffset: heading.text.toPlainText().length), boxHeightStyle: ui.BoxHeightStyle.tight)) {
        final rect = box.toRect();
        if (rect.width < .01 || rect.height < 2) continue;
        glyphs = glyphs == null ? rect : glyphs.expandToInclude(rect);
      }
      expect(glyphs, isNotNull);
      expect(heading.localToGlobal(glyphs!.center).dx, closeTo(center, 1),
        reason: 'A zero-width source-mapping placeholder must not shift centered heading glyphs');
      final padding = _padding(heading);
      expect(padding.padding.resolve(TextDirection.ltr).bottom, closeTo(0, .01));
      expect(_spacingPolicy, isNotNull);
      expect(padding.padding.resolve(TextDirection.ltr).top, lessThanOrEqualTo(_spacingPolicy!.spacing + .01),
        reason: 'Heading separation uses the ordinary paragraph setting, not an additional 16 pixels');
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, skip: !font.existsSync());

  testWidgets('four short physical chapters share an ordinary page without metadata or chapter-tail gaps', (tester) async {
    _view(tester);
    final fixture = _FlowFixture('four-short-chunks', [8, 8, 8, 8], fallbackTarget: 8);
    expect(fixture.book.chapters, hasLength(4));
    expect(fixture.book.chapters.every((chapter) => chapter.title.isEmpty), isTrue,
      reason: 'Production fallback must generate untitled chunks, not labels that are merely hidden later');
    expect(fixture.book.chapters.map((chapter) => chapter.paragraphs.single.display).join(),
      String.fromCharCodes(List.generate(32, (index) => 0x6000 + index)),
      reason: 'Splitting must preserve source characters without injecting section text');
    await _mount(tester, fixture.book, indent: false);
    final rows = _rows(tester, fixture);
    expect(rows.map((row) => row.item).toSet(), {1, 3, 5, 7},
      reason: 'All four short paragraphs must share the same actual reading page');
    expect(_units(rows), orderedEquals(List.generate(32, (index) => index)));
    for (var i = 1; i < rows.length; i++) {
      final nativePitch = _renders(tester)[rows[i - 1].item]!.size.height;
      expect(rows[i].rect.top - rows[i - 1].rect.top, closeTo(nativePitch + _spacingPolicy!.spacing, .01),
        reason: 'Crossing a physical chapter adds only the fixed ordinary paragraph gap');
    }
    expect(_renders(tester).values.where((render) => RegExp(r'^第\s*\d+\s*节$').hasMatch(_plain(render.text))), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, skip: !font.existsSync());

  testWidgets('maximal continuous pages cross four physical chapters and preserve every source row in both directions', (tester) async {
    _view(tester);
    // Calibrate capacity with the real registered font, not assumed CJK widths.
    final calibration = _FlowFixture('flow-capacity', [1800]);
    await _mount(tester, calibration.book, indent: false);
    final entryCapacity = _rows(tester, calibration);
    expect(entryCapacity.length, greaterThan(5));
    final columns = entryCapacity.first.units.length;
    expect(columns, greaterThan(5));
    final firstLength = (entryCapacity.length + 1) * columns;
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    ReaderPreparation.clearMemoryCache();
    // The entry leaves one row in its long first chunk; four one-line chunks
    // follow, then enough uninterrupted text to exercise further real pages.
    final fixture = _FlowFixture('cross-chunk-joint', [firstLength, 8, 8, 8, 8, 1200]);
    await _mount(tester, fixture.book, indent: false);
    final pages = <List<_Row>>[_rows(tester, fixture)];
    for (var turn = 0; turn < 3; turn++) {
      await _turn(tester, true);
      final actual = _rows(tester, fixture);
      _expectOrdinaryPage(tester, fixture, actual);
      expect(_units(actual).first, _units(pages.last).last + 1,
        reason: 'Forward paging must continue with the immediately following source character');
      if (turn == 0) {
        expect(actual.map((row) => row.item).toSet(), containsAll([3, 5, 7, 9]),
          reason: 'The incoming page must consume all four short physical chapters rather than stop at a chunk boundary');
      }
      pages.add(actual);
    }
    expect(pages.any((page) => page.map((row) => row.item).toSet().length >= 4), isTrue,
      reason: 'Real painted pages span physical chapter identities');
    for (var page = pages.length - 2; page >= 0; page--) {
      await _turn(tester, false);
      final actual = _rows(tester, fixture);
      expect(actual.map((row) => row.key), orderedEquals(pages[page].map((row) => row.key)));
      expect(_units(actual), orderedEquals(_units(pages[page])),
        reason: 'Backward paging restores the exact visited source slice across untitled metadata items');
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, skip: !font.existsSync(), timeout: const Timeout(Duration(seconds: 120)));

  testWidgets('bounded materialization crosses multiple chapter windows without sparse tails or detached headings', (tester) async {
    _view(tester);
    const length = 480, chapterCount = 12;
    final fixture = _FlowFixture('bounded-multi-window', List.filled(chapterCount, length),
      realHeadings: {2, 5, 8});
    expect(fixture.book.chapters.asMap().entries.where((entry) => !{2, 5, 8}.contains(entry.key))
      .every((entry) => entry.value.title.isEmpty), isTrue,
      reason: 'Technical chunks remain untitled in the source model, not just in their widgets');
    await _mount(tester, fixture.book, indent: false);
    final entry = _rows(tester, fixture), pages = <List<_Row>>[entry];
    final firstParagraph = _renders(tester)[1]!;
    final chapterRows = <int>{};
    for (final box in firstParagraph.getBoxesForSelection(TextSelection(baseOffset: 0,
      extentOffset: firstParagraph.text.toPlainText().length), boxHeightStyle: ui.BoxHeightStyle.tight)) {
      final rect = box.toRect();
      if (rect.width < .01 || rect.height < 2) continue;
      final left = firstParagraph.getPositionForOffset(Offset(-1, rect.center.dy)).offset;
      final right = firstParagraph.getPositionForOffset(Offset(firstParagraph.size.width + 1, rect.center.dy)).offset;
      chapterRows.add(left < right ? left : right);
    }
    expect(chapterRows.length / entry.length, inInclusiveRange(1.7, 2.5),
      reason: 'The fixture must really contain about two physical pages per chapter');
    final windowEnds = <int>[];
    var ordinaryTitlePages = 0;
    final ordinaryMargins = <double>[];
    var crossedTwoWindows = false;
    for (var turn = 0; turn < 16; turn++) {
      await _turn(tester, true);
      final actual = _rows(tester, fixture);
      ordinaryMargins.add(_expectOrdinaryPage(tester, fixture, actual));
      expect(_units(actual).first, _units(pages.last).last + 1,
        reason: 'Crossing a lookahead boundary must continue with the immediate source successor');
      expect(actual.length, greaterThanOrEqualTo(entry.length - 2),
        reason: 'A temporary window tail must not produce a sparse chapter-end page');
      final materialized = _renders(tester).keys.toList()..sort();
      final lastItem = materialized.last;
      if (windowEnds.isEmpty || lastItem > windowEnds.last) windowEnds.add(lastItem);
      if (turn == 0) {
        expect(lastItem, lessThan(chapterCount * 2 - 1),
          reason: 'The first tap materializes nearby source items, not the whole twelve-chapter book');
      }
      if (actual.any((row) => fixture.headingItems.contains(row.item))) {
        ordinaryTitlePages++;
        expect(actual.length, greaterThan(2), reason: 'A heading must not detach into an artificial short ordinary page');
      }
      pages.add(actual);
      if (windowEnds.length >= 3) {
        final secondBoundaryChapter = (windowEnds[1] - 1) ~/ 2;
        final secondBoundaryUnit = (secondBoundaryChapter + 1) * length - 1;
        if (_units(actual).last > secondBoundaryUnit) {
          crossedTwoWindows = true;
          break;
        }
      }
    }
    expect(windowEnds.length, greaterThanOrEqualTo(3), reason: 'At least two distinct finite lookahead windows must be expanded');
    expect(crossedTwoWindows, isTrue, reason: 'The painted source must actually pass both earlier window ends');
    expect(ordinaryTitlePages, greaterThan(0), reason: 'Exercise a real heading after the entry page, not only untitled technical chunks');
    ordinaryMargins.sort();
    expect(ordinaryMargins.last - ordinaryMargins.first,
      lessThanOrEqualTo(_spacingPolicy!.rowPitch + _spacingPolicy!.spacing + .5),
      reason: 'Across source windows the page-bottom variation stays within one complete line/paragraph advance');
    for (var page = pages.length - 2; page >= 0; page--) {
      await _turn(tester, false);
      final actual = _rows(tester, fixture);
      expect(actual.map((row) => row.key), orderedEquals(pages[page].map((row) => row.key)),
        reason: 'Window-cache expansion must preserve every visited page cut in reverse');
      expect(_units(actual), orderedEquals(_units(pages[page])),
        reason: 'No unique source character may disappear or repeat after passing multiple windows');
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, skip: !font.existsSync(), timeout: const Timeout(Duration(seconds: 120)));
}

void _view(WidgetTester tester) {
  tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
}

Future<void> _mount(WidgetTester tester, Book book, {required bool indent}) async {
  final storage = AppStorage();
  await storage.saveSettings((ReadingSettings()..fontSize = _fontSize..lineHeight = _lineHeight
    ..fontFamily = 'ReaderHeadingCjk'..paragraphSpacingLevel = 2..firstLineIndent = indent
    ..mergeNonSentenceBreaks = false..informationFilter = false..autoExtractToc = true
    ..retainPageLine = false..pageTurnMode = 'tap'..pageTurnAnimation = 'off').toJson());
  await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: book, storage: storage,
    ttsReader: TtsReader(player: _SilentPlayer()))));
  await tester.pumpAndSettle();
  expect(_spacingPolicy, isNotNull, reason: 'The native font geometry must resolve a real spacing policy');
}

String _plain(InlineSpan span) => span.toPlainText().replaceAll(RegExp('[\u200B\uFFFC]'), '').trim();

Map<int, RenderParagraph> _renders(WidgetTester tester) {
  final result = <int, RenderParagraph>{};
  for (final element in find.descendant(of: find.byKey(const ValueKey('reader-body')), matching: find.byType(RichText)).evaluate()) {
    final render = element.findRenderObject();
    if (render is! RenderParagraph || !render.attached || !render.hasSize) continue;
    int? index;
    element.visitAncestorElements((ancestor) {
      final key = ancestor.widget.key;
      if (key is ValueKey<int>) { index = key.value; return false; }
      return true;
    });
    if (index != null) result[index!] = render;
  }
  return result;
}

void _expectStyles(RenderParagraph render, {required bool bold}) {
  final effectiveHeight = render.strutStyle!.height!;
  expect(effectiveHeight, _lineHeight, reason: 'Body and heading line height stay at the requested multiplier');
  void visit(InlineSpan span, TextStyle inherited) {
    if (span is! TextSpan) return;
    final style = inherited.merge(span.style);
    if (span.text?.trim().isNotEmpty ?? false) {
      expect(style.fontSize, _fontSize); expect(style.height, effectiveHeight);
      expect(style.fontWeight, bold ? FontWeight.bold : FontWeight.normal);
    }
    for (final child in span.children ?? const <InlineSpan>[]) { visit(child, style); }
  }
  visit(render.text, const TextStyle());
  expect(render.strutStyle?.fontSize, _fontSize);
  expect(render.strutStyle?.height, effectiveHeight);
  expect(render.strutStyle?.forceStrutHeight, isTrue);
}

RenderPadding _padding(RenderParagraph render) {
  RenderObject? parent = render.parent;
  while (parent != null && parent is! RenderPadding) { parent = parent.parent; }
  expect(parent, isA<RenderPadding>());
  return parent! as RenderPadding;
}

List<_Row> _rows(WidgetTester tester, _FlowFixture fixture,
  {bool includeUnpainted = false, bool includeOutsideViewport = false}) {
  final bodyFinder = find.byKey(const ValueKey('reader-body')), body = tester.getRect(bodyFinder);
  final clipFinder = find.byKey(const ValueKey('reader-page-clip'));
  final clipWidget = tester.widget<ClipRect>(clipFinder), size = tester.getSize(clipFinder);
  final clip = (clipWidget.clipper?.getClip(size) ?? (Offset.zero & size)).shift(tester.getTopLeft(clipFinder)).intersect(body);
  final positions = tester.widget<ScrollablePositionedList>(bodyFinder).itemPositionsNotifier!.itemPositions.value;
  final visibleItems = positions.where((position) => position.itemTrailingEdge > 0 && position.itemLeadingEdge < 1)
    .map((position) => position.index).toSet();
  final rows = <_Row>[];
  for (final entry in _renders(tester).entries) {
    if (!visibleItems.contains(entry.key)) continue;
    final render = entry.value, text = render.text.toPlainText();
    if (!text.runes.any(fixture.ids.containsKey) && !fixture.headingItems.contains(entry.key)) continue;
    final origin = render.localToGlobal(Offset.zero), grouped = <int, Rect>{};
    for (final box in render.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: text.length),
      boxHeightStyle: ui.BoxHeightStyle.tight)) {
      final rect = box.toRect();
      if (rect.width < .01 || rect.height < 2) continue;
      final left = render.getPositionForOffset(Offset(-1, rect.center.dy)).offset;
      final right = render.getPositionForOffset(Offset(render.size.width + 1, rect.center.dy)).offset;
      final start = left < right ? left : right;
      grouped.update(start, (previous) => previous.expandToInclude(rect), ifAbsent: () => rect);
    }
    for (final line in grouped.entries) {
      final rect = line.value.shift(origin);
      final bounds = includeUnpainted ? body : clip;
      if (!includeOutsideViewport && (rect.top < bounds.top - .25 || rect.bottom > bounds.bottom + .25)) continue;
      final end = render.getPositionForOffset(Offset(render.size.width + 1, line.value.center.dy)).offset;
      final start = line.key < end ? line.key : end, finish = line.key < end ? end : line.key;
      final units = text.substring(start, finish).runes.where(fixture.ids.containsKey).map((rune) => fixture.ids[rune]!).toList();
      if (units.isNotEmpty || fixture.headingItems.contains(entry.key)) {
        rows.add((key: '${entry.key}/${line.key}', item: entry.key, rect: rect, units: units));
      }
    }
  }
  rows.sort((a, b) => a.rect.top.compareTo(b.rect.top));
  expect(rows, isNotEmpty);
  final units = _units(rows);
  for (var i = 1; i < units.length; i++) {
    expect(units[i], units[i - 1] + 1, reason: 'All complete painted source characters remain in order without omissions or repetition');
  }
  return rows;
}

List<int> _units(List<_Row> rows) => rows.expand((row) => row.units).toList();

double _expectOrdinaryPage(WidgetTester tester, _FlowFixture fixture, List<_Row> rows) {
  expect(_spacingPolicy, isNotNull);
  expect(_spacingPolicy!.fixedRows, isFalse);
  final physical = _rows(tester, fixture, includeUnpainted: true);
  expect(rows.map((row) => row.key), orderedEquals(physical.map((row) => row.key)),
    reason: 'Headings and chapter boundaries do not hide any physically fitting complete source row');
  final body = tester.getRect(find.byKey(const ValueKey('reader-body')));
  final all = _rows(tester, fixture, includeOutsideViewport: true);
  final last = all.indexWhere((row) => row.key == rows.last.key);
  if (last + 1 < all.length) expect(all[last + 1].rect.bottom - rows.first.rect.top, greaterThan(body.height - .25),
    reason: 'A complete successor cannot fit the maximal continuous page');
  final finder = find.byKey(const ValueKey('reader-page-clip'));
  final clip = tester.widget<ClipRect>(finder).clipper!.getClip(tester.getSize(finder));
  expect(tester.getTopLeft(finder).dy + clip.bottom, closeTo(rows.last.rect.bottom, .25));
  final remaining = body.bottom - rows.last.rect.bottom;
  expect(remaining, inInclusiveRange(-.25, _spacingPolicy!.rowPitch + _spacingPolicy!.spacing + .5));
  return remaining;
}

Future<void> _turn(WidgetTester tester, bool forward) async {
  final body = tester.getRect(find.byKey(const ValueKey('reader-body')));
  await tester.tapAt(Offset(forward ? body.right - 20 : body.left + 20, body.center.dy));
  await tester.pumpAndSettle();
}

class _FlowFixture {
  _FlowFixture(String id, List<int> lengths, {Set<int> realHeadings = const {}, int? fallbackTarget}) {
    var next = 0;
    final chapters = <Chapter>[];
    final source = <String>[];
    for (var chapter = 0; chapter < lengths.length; chapter++) {
      final text = StringBuffer();
      for (var i = 0; i < lengths[chapter]; i++) {
        final rune = 0x6000 + next;
        ids[rune] = next++; text.writeCharCode(rune);
      }
      source.add(text.toString());
    }
    if (fallbackTarget != null) {
      final chunks = fallbackSplit(source.join('\n\n'), paraTarget: fallbackTarget, preserveLayout: true);
      expect(chunks, hasLength(lengths.length));
      for (final chunk in chunks) {
        expect(chunk.$1, isEmpty, reason: 'The real fallback generator must not invent a section title');
        chapters.add(Chapter(title: chunk.$1,
          paragraphs: chunk.$2.split('\n\n').map(ReadingText.paragraph).toList()));
      }
    } else {
      for (var chapter = 0; chapter < source.length; chapter++) {
        if (realHeadings.contains(chapter)) headingItems.add(chapter * 2);
        chapters.add(Chapter(title: realHeadings.contains(chapter) ? 'Chapter ${37 + chapter}' : '',
          paragraphs: [ReadingText.paragraph(source[chapter])]));
      }
    }
    book = Book(id: id, title: '跨分块连续阅读', filePath: '', format: BookFormat.txt,
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
