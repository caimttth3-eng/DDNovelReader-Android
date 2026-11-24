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

const _fontSize = 26.0, _lineHeight = 1.6;
typedef _Row = ({String key, int item, Rect rect, List<int> source});
typedef _Window = ({String first, String last});

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  final font = File('${Platform.environment['SystemRoot']}\\Fonts\\msyh.ttc');
  ReaderSpacingPlan? policy;
  final windows = <_Window>[];
  TtsAudioHandler? previous;
  Future<ReaderPagePlan?> Function(ReaderPagePlan? Function())? previousWorker;
  late TtsAudioHandler handler;
  setUpAll(() async {
    if (!font.existsSync()) return;
    await (FontLoader('ReaderGlobalBandCjk')
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
    policy = null; windows.clear();
    ReaderScreen.onSpacingPolicyForTesting = (plan) { policy = plan; };
    ReaderScreen.onJointPagePlanForTesting = (chapter, plan, keys) {
      if (keys.isNotEmpty) windows.add((first: keys.first, last: keys.last));
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
    ReaderScreen.onSpacingPolicyForTesting = null;
    ReaderScreen.onJointPagePlanForTesting = null;
    ReaderScreen.jointWorkerForTesting = previousWorker;
    ReaderPreparation.runnerForTesting = null;
    ReaderPreparation.clearMemoryCache();
    globalAudioHandler = previous;
    unawaited(handler.playbackState.close()); unawaited(handler.mediaItem.close());
  });

  testWidgets('all levels fill actual native rows continuously across windows and restore exact history', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    final allRemainders = <double>[];
    double? commonHeight;
    double? commonScaledFont;
    for (final level in ReadingSettings.paragraphSpacingLevels) {
      final fixture = _Fixture('global-band-$level');
      policy = null; windows.clear(); ReaderPreparation.clearMemoryCache();
      final storage = AppStorage();
      await storage.saveSettings((ReadingSettings()..fontSize = _fontSize..lineHeight = _lineHeight
        ..fontFamily = 'ReaderGlobalBandCjk'..paragraphSpacingLevel = level..firstLineIndent = true
        ..mergeNonSentenceBreaks = false..informationFilter = false..retainPageLine = false
        ..pageTurnMode = 'tap'..pageTurnAnimation = 'off').toJson());
      await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: fixture.book, storage: storage,
        ttsReader: TtsReader(player: _SilentPlayer()))));
      await tester.pumpAndSettle();
      final bodyFinder = find.byKey(const ValueKey('reader-body'));
      final list = tester.widget<ScrollablePositionedList>(bodyFinder);
      list.itemScrollController!.jumpTo(index: 0); await tester.pumpAndSettle();
      final first = _paintedRows(tester, fixture).first;
      final delta = first.rect.top - tester.getTopLeft(bodyFinder).dy;
      unawaited(list.scrollOffsetController!.animateScroll(offset: delta, duration: const Duration(milliseconds: 1)));
      await tester.pumpAndSettle();
      expect(policy, isNotNull, reason: 'The real reader must publish its fixed paragraph-spacing setting');
      final initialPolicy = policy!;
      final scaledFont = MediaQuery.textScalerOf(bodyFinder.evaluate().single).scale(_fontSize);
      if (commonScaledFont == null) { commonScaledFont = scaledFont; }
      else { expect(scaledFont, commonScaledFont, reason: 'A global band comparison cannot mix text scalers'); }
      expect(initialPolicy.fixedRows, isFalse);
      expect(initialPolicy.rows, 0);
      expect(initialPolicy.spacing, closeTo(scaledFont * level / 4, 1e-6));
      final height = tester.getSize(bodyFinder).height;
      if (commonHeight == null) { commonHeight = height; }
      else { expect(height, closeTo(commonHeight!, 1e-6), reason: 'Never mix different body geometries in a global-margin comparison'); }
      final levelRemainders = <double>[];
      final visited = <List<_Row>>[];
      final seenHeadingItems = <int>{};
      var reachedEnd = false;
      for (var page = 0; page < 100; page++) {
        final rows = _paintedRows(tester, fixture);
        final source = _source(rows);
        expect(source, isNotEmpty);
        if (visited.isEmpty) {
          expect(source.first, 0, reason: 'The complete-book traversal must include the first original source character');
        } else {
          expect(source.first, _source(visited.last).last + 1,
            reason: 'Each new page must immediately continue the previous original CJK/Latin/punctuation stream');
        }
        final currentPolicy = policy!;
        expect(currentPolicy.fixedRows, isFalse);
        expect(currentPolicy.spacing, closeTo(scaledFont * level / 4, 1e-6));
        final used = rows.last.rect.bottom - rows.first.rect.top;
        final remaining = tester.getRect(bodyFinder).bottom - rows.last.rect.bottom;
        final tail = source.last == fixture.totalSourceCharacters - 1;
        expect(used, greaterThan(0));
        expect(used, lessThanOrEqualTo(height + .25));
        if (!tail) {
          _expectForwardFill(tester, fixture, rows);
          levelRemainders.add(remaining); allRemainders.add(remaining);
          final maximum = _paintedRows(tester, fixture, includeUnpainted: true);
          expect(maximum.map((row) => row.key), orderedEquals(rows.map((row) => row.key)),
            reason: 'No additional complete native row may fit inside the real body while the page stops early');
        } else {
          expect(source.last, fixture.totalSourceCharacters - 1,
            reason: 'Only the real full-book tail ends the traversal');
        }
        seenHeadingItems.addAll(rows.map((row) => row.item).where(fixture.headingItems.contains));
        visited.add(rows);
        if (tail) { reachedEnd = true; break; }
        await _turn(tester, true);
      }
      expect(reachedEnd, isTrue);
      expect(levelRemainders.length, greaterThanOrEqualTo(24), reason: 'Compare dozens of ordinary pages, including first and final ordinary pages');
      expect(seenHeadingItems, containsAll(fixture.headingItems), reason: 'The measured margin set must include actual bold Latin and CJK metadata headings');
      expect(windows.map((window) => '${window.first}..${window.last}').toSet().length, greaterThanOrEqualTo(4),
        reason: 'The traversal must expand several finite lookahead windows');
      expect(int.parse(windows.first.last.split('/').first), lessThan(fixture.lastBodyItem),
        reason: 'The initial production plan must not have measured the whole book as one window');
      for (var page = visited.length - 2; page >= 0; page--) {
        await _turn(tester, false);
        final actual = _paintedRows(tester, fixture);
        expect(actual.map((row) => row.key), orderedEquals(visited[page].map((row) => row.key)));
        expect(_source(actual), orderedEquals(_source(visited[page])),
          reason: 'Reverse traversal must restore every complete original page, even beyond the three-window cache');
        if (_source(actual).last != fixture.totalSourceCharacters - 1) {
          final remaining = tester.getRect(bodyFinder).bottom - actual.last.rect.bottom;
          _expectForwardFill(tester, fixture, actual);
          expect(_paintedRows(tester, fixture, includeUnpainted: true).length, actual.length,
            reason: 'Reverse ordinary pages must also consume every physically fitting complete row');
          levelRemainders.add(remaining); allRemainders.add(remaining);
        }
      }
      debugPrint('SPACING_GLOBAL level=$level S=${policy!.spacing} '
        'pages=${visited.length} ordinarySamples=${levelRemainders.length} '
        'spread=${_spread(levelRemainders)} windows=${windows.length}');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    }
  }, skip: !font.existsSync(), timeout: const Timeout(Duration(seconds: 300)));
}

double _spread(List<double> values) => values.isEmpty ? 0 :
  values.reduce((a, b) => a > b ? a : b) - values.reduce((a, b) => a < b ? a : b);

void _expectForwardFill(WidgetTester tester, _Fixture fixture, List<_Row> actual) {
  final body = tester.getRect(find.byKey(const ValueKey('reader-body')));
  expect(actual.first.rect.top, closeTo(body.top, .25));
  final clipFinder = find.byKey(const ValueKey('reader-page-clip'));
  final clip = tester.widget<ClipRect>(clipFinder).clipper!.getClip(tester.getSize(clipFinder));
  expect(clip.bottom + tester.getTopLeft(clipFinder).dy, closeTo(actual.last.rect.bottom, .25),
    reason: 'The published clip must end at the actual final complete glyph row');
  final all = _paintedRows(tester, fixture, includeOutside: true);
  final last = all.indexWhere((row) => row.key == actual.last.key);
  expect(last, greaterThanOrEqualTo(0));
  expect(last + 1, lessThan(all.length), reason: 'Observe the real next glyph row, including headings and mixed-font runs');
  final next = all[last + 1];
  expect(next.rect.bottom, greaterThan(body.bottom + .25), reason: 'Maximum fill cannot hide the next complete native row');
  final remainder = body.bottom - actual.last.rect.bottom;
  expect(remainder, greaterThanOrEqualTo(-.25));
  expect(remainder, lessThan(next.rect.bottom - actual.last.rect.bottom + .25),
    reason: 'The natural remainder is smaller than the real next-row advance, including paragraph spacing and mixed glyph bounds');
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

final _ignored = RegExp(r'[\s\u200B\u200C\u200D\u2060\uFEFF\uFFFC]');
String _canonical(String text) => text.replaceAll(_ignored, '');

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
    final render = entry.value, full = render.text.toPlainText(), sourceText = fixture.sourceByItem[entry.key];
    final heading = fixture.headingItems.contains(entry.key);
    if (sourceText == null && !heading) continue;
    _expectStyles(render, heading: heading);
    final prefix = List<int>.filled(full.length + 1, 0);
    if (sourceText != null) {
      expect(_canonical(full), sourceText, reason: 'Actual display must preserve every original nonspace CJK, Latin and punctuation character');
      for (var i = 0; i < full.length; i++) {
        prefix[i + 1] = prefix[i] + (_ignored.hasMatch(full[i]) ? 0 : 1);
      }
    }
    final grouped = <int, Rect>{};
    for (final box in render.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: full.length),
      boxHeightStyle: ui.BoxHeightStyle.tight)) {
      final rect = box.toRect();
      if (rect.width < .01 || rect.height < 2) continue;
      final left = render.getPositionForOffset(Offset(-1, rect.center.dy)).offset;
      final right = render.getPositionForOffset(Offset(render.size.width + 1, rect.center.dy)).offset;
      final start = left < right ? left : right;
      grouped.update(start, (previous) => previous.expandToInclude(rect), ifAbsent: () => rect);
    }
    final origin = render.localToGlobal(Offset.zero);
    for (final line in grouped.entries) {
      final rect = line.value.shift(origin);
      if (!includeOutside && (rect.top < bounds.top - .25 || rect.bottom > bounds.bottom + .25)) continue;
      final end = render.getPositionForOffset(Offset(render.size.width + 1, line.value.center.dy)).offset;
      final from = line.key < end ? line.key : end, to = line.key < end ? end : line.key;
      final source = sourceText == null ? <int>[] : List.generate(prefix[to] - prefix[from],
        (index) => fixture.sourceBaseByItem[entry.key]! + prefix[from] + index);
      rows.add((key: '${entry.key}/${line.key}', item: entry.key, rect: rect, source: source));
    }
  }
  rows.sort((a, b) => a.rect.top.compareTo(b.rect.top));
  expect(rows, isNotEmpty);
  final source = _source(rows);
  expect(source, isNotEmpty);
  for (var i = 1; !includeOutside && i < source.length; i++) {
    expect(source[i], source[i - 1] + 1, reason: 'Every complete original character appears in order exactly once');
  }
  return rows;
}

void _expectStyles(RenderParagraph render, {required bool heading}) {
  final effectiveHeight = render.strutStyle!.height!;
  expect(effectiveHeight, _lineHeight);
  void visit(InlineSpan span, TextStyle inherited) {
    if (span is! TextSpan) return;
    final style = inherited.merge(span.style);
    if (span.text?.trim().isNotEmpty ?? false) {
      expect(style.fontSize, _fontSize); expect(style.height, effectiveHeight);
      expect(style.fontWeight, heading ? FontWeight.bold : FontWeight.normal);
    }
    for (final child in span.children ?? const <InlineSpan>[]) { visit(child, style); }
  }
  visit(render.text, const TextStyle());
  expect(render.strutStyle?.forceStrutHeight, isTrue);
}

List<int> _source(List<_Row> rows) => rows.expand((row) => row.source).toList();

Future<void> _turn(WidgetTester tester, bool forward) async {
  final body = tester.getRect(find.byKey(const ValueKey('reader-body')));
  await tester.tapAt(Offset(forward ? body.right - 20 : body.left + 20, body.center.dy));
  await tester.pumpAndSettle();
}

class _Fixture {
  _Fixture(String id) {
    var cjk = 0, source = 0;
    final chapters = <Chapter>[];
    for (var chapter = 0; chapter < 18; chapter++) {
      final text = StringBuffer();
      for (var index = 0; index < 360; index++) {
        text.writeCharCode(0x4E00 + cjk++);
        if (index % 23 == 22) text.write(' Alpha beta Z9，');
      }
      final item = chapter * 2 + 1, canonical = _canonical(text.toString());
      sourceByItem[item] = canonical; sourceBaseByItem[item] = source; source += canonical.length;
      final heading = chapter % 3 == 0;
      if (heading) headingItems.add(chapter * 2);
      chapters.add(Chapter(title: heading ? (chapter.isEven ? '第${38 + chapter}章 山海' : 'Chapter ${38 + chapter} Latin') : '',
        paragraphs: [ReadingText.paragraph(text.toString())]));
    }
    totalSourceCharacters = source;
    book = Book(id: id, title: '全局页底余白与跨窗口', filePath: '', format: BookFormat.txt,
      addedAt: DateTime(2026), chapters: chapters);
  }
  final sourceByItem = <int, String>{};
  final sourceBaseByItem = <int, int>{};
  final headingItems = <int>{};
  late final int totalSourceCharacters;
  late final Book book;
  int get lastBodyItem => book.chapters.length * 2 - 1;
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
