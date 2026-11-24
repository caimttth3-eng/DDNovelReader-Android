import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
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

const _surface = ValueKey('stress-painted-surface');

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
    ReaderPreparation.runnerForTesting = null;
    ReaderPreparation.clearMemoryCache(); globalAudioHandler = previous;
    unawaited(handler.playbackState.close()); unawaited(handler.mediaItem.close());
  });

  for (final animation in ['off', 'slide']) {
    testWidgets('mixed paragraph filter stress preserves full source coverage $animation', (tester) async {
      final fixture = _Fixture();
      await _mount(tester, fixture, animation);
      for (final level in ['ads', 'extra', 'links', 'extra']) {
        final gate = Completer<void>(), entered = Completer<void>();
        addTearDown(() { if (!gate.isCompleted) gate.complete(); });
        ReaderPreparation.clearMemoryCache();
        ReaderPreparation.runnerForTesting = (request) async {
          if (request.filter != 'none') { if (!entered.isCompleted) entered.complete(); await gate.future; }
          return ReaderPreparation.prepareSynchronously(request);
        };
        await _openSettings(tester);
        await _setFiltering(tester, true);
        await _until(tester, () => entered.isCompleted);
        await _selectLevel(tester, level);
        await _setFiltering(tester, false);
        await _setFiltering(tester, true);
        await _closeSettings(tester);
        // Move on the old text while the newest filter is still being built.
        // This turn crosses short paragraphs and removable blocks, rather than
        // staying inside the same very long paragraph as earlier regressions.
        final before = _visibleUnits(tester, fixture);
        await _turn(tester, 1);
        final during = _visibleUnits(tester, fixture);
        _expectForwardCoverage(before, during, '$level before installation');
        gate.complete(); await tester.pumpAndSettle();
        final installed = _visibleUnits(tester, fixture);
        expect(installed.first, during.first, reason: 'Installing $level must retain the actual source page start');
        _expectContiguous(installed, 'after installing $level');
        // Compare every source character of pages, including both endpoints.
        // Repeated prose and a matching first line cannot conceal a lost row.
        final pages = <List<int>>[installed];
        for (var page = 0; page < 5; page++) {
          await _turn(tester, 1);
          final next = _visibleUnits(tester, fixture, phase: '$level forward $page');
          _expectForwardCoverage(pages.last, next, '$level forward $page');
          pages.add(next);
        }
        for (var page = pages.length - 2; page >= 0; page--) {
          await _turn(tester, -1);
          expect(_visibleUnits(tester, fixture), pages[page],
            reason: '$level backward $page must restore the entire preceding source range');
        }
        await _openSettings(tester); await _setFiltering(tester, false); await _closeSettings(tester);
        await tester.pumpAndSettle();
        expect(_visibleUnits(tester, fixture).first, installed.first,
          reason: 'Disabling $level must not project onto a different surviving body character');
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    }, timeout: const Timeout(Duration(seconds: 120)));

    for (final visibleFilter in [false, true]) {
    testWidgets('filter restore and page turn paint only stable full pages $animation visibleFilter=$visibleFilter', (tester) async {
      final fixture = _Fixture();
      await _mount(tester, fixture, animation, firstItem: visibleFilter ? 1 : 6, advance: !visibleFilter);
      final gate = Completer<void>(), entered = Completer<void>();
      addTearDown(() { if (!gate.isCompleted) gate.complete(); });
      ReaderPreparation.clearMemoryCache();
      ReaderPreparation.runnerForTesting = (request) async {
        if (request.filter == 'ads') { if (!entered.isCompleted) entered.complete(); await gate.future; }
        return ReaderPreparation.prepareSynchronously(request);
      };
      await _openSettings(tester); await _setFiltering(tester, true);
      await _until(tester, () => entered.isCompleted);
      await _closeSettings(tester);
      final before = await _paintedBody(tester);
      final reformatFrames = <Uint8List>[];
      gate.complete();
      for (final milliseconds in [1, 7, 11, 3, 17, 23, 5, 13, 19, 31, 2, 16]) {
        await tester.pump(Duration(milliseconds: milliseconds));
        reformatFrames.add(await _paintedBody(tester));
      }
      await tester.pumpAndSettle();
      final after = await _paintedBody(tester);
      if (visibleFilter) {
        expect(_samePaint(before, after), isFalse,
          reason: 'The filter must actually change visible page content in this variant');
      }
      for (var frame = 0; frame < reformatFrames.length; frame++) {
        if (!_samePaint(reformatFrames[frame], before) && !_samePaint(reformatFrames[frame], after)) {
          debugPrint('PIXEL_DIFF restore $animation frame=$frame old=${_pixelDifference(reformatFrames[frame], before)} '
            'final=${_pixelDifference(reformatFrames[frame], after)}');
        }
        expect(_samePaint(reformatFrames[frame], before) || _samePaint(reformatFrames[frame], after), isTrue,
          reason: '$animation restore frame $frame painted a temporary paragraph/clip instead of either complete stable page');
      }
      final firstRange = _visibleUnits(tester, fixture);
      final pageFrames = <({Uint8List pixels, double incoming, double? outgoing})>[];
      await tester.tapAt(const Offset(370, 380));
      for (var frame = 0; frame < 32; frame++) {
        await tester.pump(Duration(milliseconds: [7, 13, 17, 11][frame % 4]));
        final incoming = tester.widget<FractionalTranslation>(find.byKey(const ValueKey('page-incoming-transform')));
        final outgoingFinder = find.byKey(const ValueKey('page-outgoing-transform'));
        final outgoing = outgoingFinder.evaluate().isEmpty ? null : tester.widget<FractionalTranslation>(outgoingFinder).translation.dx;
        pageFrames.add((pixels: await _paintedBody(tester), incoming: incoming.translation.dx, outgoing: outgoing));
      }
      await tester.pumpAndSettle();
      final destination = await _paintedBody(tester);
      _expectForwardCoverage(firstRange, _visibleUnits(tester, fixture), '$animation painted turn');
      ui.Image? oldSlide, newSlide;
      try {
        if (animation == 'slide') {
          oldSlide = await _decodeBodyImage(tester, after);
          newSlide = await _decodeBodyImage(tester, destination);
        }
        for (var frame = 0; frame < pageFrames.length; frame++) {
          final painted = pageFrames[frame];
          if (painted.outgoing == null || animation == 'off') {
            expect(_samePaint(painted.pixels, after) || _samePaint(painted.pixels, destination), isTrue,
              reason: '$animation turn frame $frame exposed an intermediate layout');
          } else {
            await _expectSlidePixels(tester, painted.pixels, oldSlide!, newSlide!,
              Color.fromARGB(after[3], after[0], after[1], after[2]), painted.incoming, painted.outgoing!, frame);
          }
        }
      } finally {
        oldSlide?.dispose(); newSlide?.dispose();
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    }, timeout: const Timeout(Duration(seconds: 120)));
    }
  }

  testWidgets('backward paging returns the committed short page before a paragraph gap', (tester) async {
    var fixedRows = true;
    var spacing = 0.0;
    final previousPolicy = ReaderScreen.onSpacingPolicyForTesting;
    ReaderScreen.onSpacingPolicyForTesting = (policy) {
      previousPolicy?.call(policy);
      fixedRows = policy.fixedRows; spacing = policy.spacing;
    };
    addTearDown(() => ReaderScreen.onSpacingPolicyForTesting = previousPolicy);
    final fixture = _Fixture.paragraphGap();
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(352, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    final storage = AppStorage();
    await storage.saveSettings((ReadingSettings()..informationFilter = false..pageTurnMode = 'tap'
      ..pageTurnAnimation = 'off'..fontSize = 40..lineHeight = 1
      ..paragraphSpacingLevel = 2
      ..firstLineIndent = false..mergeNonSentenceBreaks = false).toJson());
    final theme = ThemeData();
    // Default Material body tracking is 0.25px. Remove that fixture-only
    // tracking so the known 320px body fits exactly eight 40px glyphs.
    await tester.pumpWidget(RepaintBoundary(key: _surface, child: MaterialApp(debugShowCheckedModeBanner: false,
      theme: theme.copyWith(textTheme: theme.textTheme.copyWith(
        bodyMedium: theme.textTheme.bodyMedium!.copyWith(letterSpacing: 0))), home: ReaderScreen(
      book: fixture.book, storage: storage, ttsReader: TtsReader(player: _SilentPlayer())))));
    await tester.pumpAndSettle();
    final body = find.byKey(const ValueKey('reader-body'));
    tester.widget<ScrollablePositionedList>(body).itemScrollController!.jumpTo(index: 1);
    await tester.pumpAndSettle();
    final render = find.byWidgetPredicate((widget) => widget is Text && widget.textAlign == TextAlign.justify).evaluate()
      .map((element) => element.findRenderObject()).whereType<RenderParagraph>()
      .firstWhere((paragraph) => paragraph.text.toPlainText().runes.any((rune) => fixture.ids[rune] == 0));
    final text = render.text.toPlainText();
    final firstCharacter = text.runes.firstWhere((rune) => fixture.ids[rune] == 0);
    final secondLineCharacter = text.runes.firstWhere((rune) => fixture.ids[rune] == 8);
    final firstOffset = text.indexOf(String.fromCharCode(firstCharacter));
    final secondOffset = text.indexOf(String.fromCharCode(secondLineCharacter));
    final firstRect = render.getBoxesForSelection(TextSelection(baseOffset: firstOffset, extentOffset: firstOffset + 1),
      boxHeightStyle: ui.BoxHeightStyle.tight).first.toRect();
    final secondRect = render.getBoxesForSelection(TextSelection(baseOffset: secondOffset, extentOffset: secondOffset + 1),
      boxHeightStyle: ui.BoxHeightStyle.tight).first.toRect();
    final pitch = secondRect.top - firstRect.top;
    // Five native rows fit within one paragraph. After its nine rows, the
    // following paragraph's visible S would make a fifth row fail to fit.
    // This produces a genuine four-row B without imposing a policy row cap.
    expect(spacing, closeTo(20, .01));
    final desiredHeight = 4 * pitch + firstRect.height + spacing / 2;
    final oldBodyHeight = tester.getSize(body).height;
    tester.view.physicalSize = Size(352, 844 + desiredHeight - oldBodyHeight);
    await tester.pumpAndSettle();
    tester.widget<ScrollablePositionedList>(body).itemScrollController!.jumpTo(index: 1);
    await tester.pumpAndSettle();
    final origin = render.localToGlobal(Offset.zero).dy;
    final delta = origin + firstRect.top - tester.getTopLeft(body).dy;
    unawaited(tester.widget<ScrollablePositionedList>(body).scrollOffsetController!.animateScroll(
      offset: delta, duration: const Duration(milliseconds: 1)));
    await tester.pumpAndSettle();
    expect(fixedRows, isFalse);
    final committed = <int, List<int>>{};
    List<int> expectPage(String phase) {
      final units = _visibleUnits(tester, fixture, phase: phase);
      final viewport = tester.getRect(body);
      final rows = _gapNativeRows(tester, fixture);
      final painted = rows.where((row) => row.units.first >= units.first && row.units.last <= units.last).toList();
      expect(painted, isNotEmpty);
      expect(painted.expand((row) => row.units), orderedEquals(units),
        reason: 'The visible source slice must contain complete eight-character native rows');
      for (final row in painted) {
        expect(row.units, hasLength(8));
        expect(row.rect.top, greaterThanOrEqualTo(viewport.top - .25));
        expect(row.rect.bottom, lessThanOrEqualTo(viewport.bottom + .25));
      }
      final clipFinder = find.byKey(const ValueKey('reader-page-clip'));
      final clip = tester.widget<ClipRect>(clipFinder).clipper!.getClip(tester.getSize(clipFinder));
      expect(tester.getTopLeft(clipFinder).dy + clip.bottom, closeTo(painted.last.rect.bottom, .25),
        reason: 'The clip ends on the complete actual terminal glyph row');
      final old = committed[units.first];
      if (old != null) {
        expect(units, old, reason: 'History must retain both exact source endpoints, not only a start key');
      } else {
        final fitting = rows.where((row) => row.units.first >= units.first &&
          row.rect.top >= viewport.top - .25 && row.rect.bottom <= viewport.bottom + .25).toList();
        expect(fitting.expand((row) => row.units), orderedEquals(units),
          reason: 'A new page must include every complete source row that physically fits');
        final next = rows.firstWhere((row) => row.units.first == units.last + 1);
        expect(next.rect.bottom, greaterThan(viewport.bottom + .25), reason: 'The next complete row really cannot fit');
        final remainder = viewport.bottom - painted.last.rect.bottom;
        expect(remainder, inInclusiveRange(-.25, next.rect.bottom - painted.last.rect.bottom + .25),
          reason: 'The remainder is bounded by the next native row advance, including S across a paragraph boundary');
        committed[units.first] = List.of(units);
      }
      return units;
    }
    final pageA = expectPage('A');
    expect(pageA, List.generate(pageA.length, (index) => index),
      reason: 'The first page starts at the exact original source beginning');
    await _turn(tester, 1);
    final pageB = expectPage('B');
    _expectForwardCoverage(pageA, pageB, 'A to B across paragraph padding');
    expect(pageB.length, lessThan(pageA.length),
      reason: 'The measured paragraph gap must actually change capacity instead of testing an invisible default gap');
    // Keep observing actual paragraph padding; no old fixed 12px gap or
    // four-row page is assumed by this source-continuity regression.
    final nextParagraph = find.byWidgetPredicate((widget) => widget is Text && widget.textAlign == TextAlign.justify).evaluate()
      .map((element) => element.findRenderObject()).whereType<RenderParagraph>()
      .firstWhere((paragraph) => paragraph.text.toPlainText().runes.any((rune) => fixture.ids[rune] == 72));
    RenderObject? padding = nextParagraph.parent;
    while (padding != null && padding is! RenderPadding) { padding = padding.parent; }
    expect(padding, isA<RenderPadding>());
    expect(nextParagraph.localToGlobal(Offset.zero).dy - (padding! as RenderPadding).localToGlobal(Offset.zero).dy,
      closeTo(spacing, .01));
    await _turn(tester, 1);
    final pageC = expectPage('C');
    _expectForwardCoverage(pageB, pageC, 'B to C');
    await _turn(tester, -1);
    expect(expectPage('back to B'), pageB,
      reason: 'Backward pagination returns precisely the same source characters across the fixed paragraph gap');
    await _turn(tester, -1);
    expect(expectPage('back to A'), pageA, reason: 'A second backward turn retains the original source prefix without duplication');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(seconds: 45)));
}

List<({Rect rect, List<int> units})> _gapNativeRows(WidgetTester tester, _Fixture fixture) {
  final body = find.byKey(const ValueKey('reader-body'));
  final active = tester.widget<ScrollablePositionedList>(body).itemPositionsNotifier!.itemPositions.value
    .where((item) => item.itemLeadingEdge < 1 && item.itemTrailingEdge > 0).map((item) => item.index).toSet();
  final renders = <int, RenderParagraph>{};
  for (final element in find.descendant(of: body, matching: find.byType(RichText)).evaluate()) {
    int? index;
    element.visitAncestorElements((ancestor) {
      if (ancestor.widget.key case ValueKey<int>(value: final value)) { index = value; return false; }
      return true;
    });
    final render = element.findRenderObject();
    if (index != null && render is RenderParagraph && render.attached && render.hasSize &&
        render.text.toPlainText().runes.any(fixture.ids.containsKey)) renders[index!] = render;
  }
  final activeIndices = renders.keys.where(active.contains).toList()..sort();
  expect(activeIndices, isNotEmpty);
  final anchor = renders[activeIndices.first]!;
  final viewport = RenderAbstractViewport.of(anchor);
  final origin = anchor.localToGlobal(Offset.zero).dy - viewport.getOffsetToReveal(anchor, 0).offset;
  final rows = <({Rect rect, List<int> units})>[];
  for (final render in renders.values) {
    if (RenderAbstractViewport.maybeOf(render) != viewport) continue;
    final text = render.text.toPlainText(), grouped = <int, Rect>{};
    for (final box in render.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: text.length),
      boxHeightStyle: ui.BoxHeightStyle.tight)) {
      final rect = box.toRect();
      if (rect.width < .01 || rect.height < 2) continue;
      final a = render.getPositionForOffset(Offset(-1, rect.center.dy)).offset;
      final b = render.getPositionForOffset(Offset(render.size.width + 1, rect.center.dy)).offset;
      final start = a < b ? a : b;
      grouped.update(start, (old) => old.expandToInclude(rect), ifAbsent: () => rect);
    }
    final shift = Offset(render.localToGlobal(Offset.zero).dx, viewport.getOffsetToReveal(render, 0).offset + origin);
    for (final row in grouped.entries) {
      final end = render.getPositionForOffset(Offset(render.size.width + 1, row.value.center.dy)).offset;
      final units = text.substring(row.key, end).runes.where(fixture.ids.containsKey).map((rune) => fixture.ids[rune]!).toList();
      if (units.isNotEmpty) rows.add((rect: row.value.shift(shift), units: units));
    }
  }
  rows.sort((a, b) => a.units.first.compareTo(b.units.first));
  return rows;
}

class _Fixture {
  final ids = <int, int>{};
  late final Book book;
  _Fixture() {
    const rubbish = '网址https://example.invalid/与邮箱reader@example.invalid请下载APP阅读更多小说作者有话说今天求收藏';
    final reserved = rubbish.runes.toSet();
    var character = 0x4e00, id = 0;
    String body(int length) {
      final result = StringBuffer();
      for (var i = 0; i < length; i++) {
        while (reserved.contains(character)) { character++; }
        ids[character] = id++;
        result.writeCharCode(character++);
        if (i % 17 == 16) result.write('，');
        if (i % 39 == 38) result.write('。');
      }
      return result.toString();
    }
    final paragraphs = <String>[];
    for (var block = 0; block < 30; block++) {
      paragraphs.add(body([53, 111, 79, 137, 37][block % 5]));
      if (block % 3 == 0) paragraphs.add('网址 https://example.invalid/$block 与邮箱 reader$block@example.invalid。');
      if (block % 4 == 0) paragraphs.add('请下载APP阅读更多小说。');
      if (block % 5 == 0) paragraphs.add('作者有话说：今天求收藏。');
    }
    book = Book(id: 'filter-full-range-stress', title: '整页坐标压力测试', filePath: '', format: BookFormat.txt,
      addedAt: DateTime(2026), chapters: [Chapter(title: '第一章', paragraphs: paragraphs.map(ReadingText.paragraph).toList())]);
  }
  _Fixture.paragraphGap() {
    var code = 0x5200, id = 0;
    // The 352px viewport leaves exactly 320px of body width: eight 40px
    // characters per wrapped row. Explicit newlines would be converted to
    // separate paragraphs by ReadingText.format and invalidate this fixture.
    String paragraph(int count) => List.generate(count, (_) => List.generate(8, (_) {
      ids[code] = id++; return String.fromCharCode(code++);
    }).join()).join();
    book = Book(id: 'filter-paragraph-gap', title: '段间距页界', filePath: '', format: BookFormat.txt,
      addedAt: DateTime(2026), chapters: [Chapter(title: '第一章', paragraphs: [
        ReadingText.paragraph(paragraph(9)), ReadingText.paragraph(paragraph(15)),
      ])]);
  }
}

Future<void> _mount(WidgetTester tester, _Fixture fixture, String animation, {int firstItem = 6, bool advance = true}) async {
  tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
  final storage = AppStorage();
  await storage.saveSettings((ReadingSettings()..informationFilter = false..informationFilterLevel = 'ads'
    ..pageTurnMode = 'tap'..pageTurnAnimation = animation..fontSize = 36..lineHeight = 1.8
    ..firstLineIndent = true..mergeNonSentenceBreaks = false).toJson());
  await tester.pumpWidget(RepaintBoundary(key: _surface, child: MaterialApp(debugShowCheckedModeBanner: false, home: ReaderScreen(
    book: fixture.book, storage: storage, ttsReader: TtsReader(player: _SilentPlayer())))));
  await tester.pumpAndSettle();
  final body = find.byKey(const ValueKey('reader-body'));
  tester.widget<ScrollablePositionedList>(body).itemScrollController!.jumpTo(index: firstItem);
  await tester.pumpAndSettle();
  if (advance) await _turn(tester, 1);
}

Future<void> _openSettings(WidgetTester tester) async {
  if (find.byKey(const ValueKey('reader-menu')).evaluate().isEmpty) {
    await tester.tapAt(const Offset(195, 300)); await tester.pumpAndSettle();
  }
  await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('阅读设置')); await tester.pumpAndSettle();
}
Future<void> _setFiltering(WidgetTester tester, bool enabled) async {
  final target = find.byKey(const ValueKey('information-filter'));
  final scroll = find.descendant(of: find.byType(BottomSheet).last, matching: find.byType(Scrollable)).last;
  final position = tester.state<ScrollableState>(scroll).position;
  await tester.scrollUntilVisible(target, position.pixels < 1 ? 160 : -160, scrollable: scroll); await tester.pumpAndSettle();
  final control = tester.widget<SwitchListTile>(target);
  if (control.value != enabled) { await tester.tap(target); await tester.pumpAndSettle(); }
}
Future<void> _selectLevel(WidgetTester tester, String level) async {
  final target = find.byWidgetPredicate((widget) => widget is RadioListTile<String> && widget.value == level);
  final scroll = find.descendant(of: find.byType(BottomSheet).last, matching: find.byType(Scrollable)).last;
  await tester.scrollUntilVisible(target, 160, scrollable: scroll); await tester.pumpAndSettle();
  await tester.tap(target); await tester.pumpAndSettle();
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
Future<void> _turn(WidgetTester tester, int direction) async {
  final body = tester.getRect(find.byKey(const ValueKey('reader-body')));
  await tester.tapAt(Offset(direction > 0 ? body.right - 20 : body.left + 20, body.center.dy)); await tester.pumpAndSettle();
}
Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var frame = 0; frame < 180 && !ready(); frame++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 11));
  }
  expect(ready(), isTrue);
}

List<int> _visibleUnits(WidgetTester tester, _Fixture fixture, {String phase = ''}) {
  final body = find.byKey(const ValueKey('reader-body')), viewport = tester.getRect(body);
  final clipFinder = find.byKey(const ValueKey('reader-page-clip'));
  final clip = tester.widget<ClipRect>(clipFinder), clipSize = tester.getSize(clipFinder);
  final clipRect = (clip.clipper?.getClip(clipSize) ?? (Offset.zero & clipSize)).shift(tester.getTopLeft(clipFinder));
  final visible = tester.widget<ScrollablePositionedList>(body).itemPositionsNotifier!.itemPositions.value
    .where((item) => item.itemTrailingEdge > 0 && item.itemLeadingEdge < 1).map((item) => item.index).toSet();
  final renders = <int, RenderParagraph>{};
  final rows = <({double top, int start, List<int> units})>[];
  for (final element in find.descendant(of: body, matching: find.byType(RichText)).evaluate()) {
    int? itemIndex;
    element.visitAncestorElements((ancestor) {
      final key = ancestor.widget.key;
      if (key is ValueKey<int>) { itemIndex = key.value; return false; }
      return true;
    });
    if (!visible.contains(itemIndex)) continue;
    final render = element.findRenderObject();
    if (render is! RenderParagraph || !render.attached || !render.hasSize) continue;
    renders[itemIndex!] = render;
  }
  expect(renders, isNotEmpty);
  final firstItem = renders.keys.reduce((a, b) => a < b ? a : b);
  final anchor = renders[firstItem]!;
  final renderViewport = RenderAbstractViewport.of(anchor);
  final coordinateOrigin = anchor.localToGlobal(Offset.zero).dy - renderViewport.getOffsetToReveal(anchor, 0).offset;
  final diagnostics = <String>[];
  for (final renderEntry in renders.entries) {
    final render = renderEntry.value;
    if (RenderAbstractViewport.maybeOf(render) != renderViewport) continue;
    final text = render.text.toPlainText();
    final raw = render.localToGlobal(Offset.zero);
    final origin = Offset(raw.dx, renderViewport.getOffsetToReveal(render, 0).offset + coordinateOrigin);
    diagnostics.add('item=${renderEntry.key} raw=${raw.dy} reveal=${origin.dy} size=${render.size} '
      'text=${text.substring(0, text.length < 100 ? text.length : 100)}');
    final generated = text.runes.where(fixture.ids.containsKey).toList();
    if (generated.isEmpty) continue;
    final firstId = fixture.ids[generated.first]!;
    // The indexed list's public ValueKey/visibility pair excludes cached
    // slivers whose paint transforms may be clamped into the visible area.
    // Reveal coordinates also avoid clamped transforms of preceding active
    // cached paragraphs. The actual item-position list still owns visibility.
    if (origin.dy + render.size.height < viewport.top || origin.dy > viewport.bottom) continue;
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
    for (final entry in grouped.entries) {
      final rect = entry.value.shift(origin);
      if (rect.top < viewport.top - 0.25 || rect.bottom > clipRect.bottom + 0.25 || rect.top >= viewport.bottom) continue;
      final end = render.getPositionForOffset(Offset(render.size.width + 1, entry.value.center.dy)).offset;
      final units = text.substring(entry.key, end < entry.key ? entry.key : end).runes
        .where(fixture.ids.containsKey).map((rune) => fixture.ids[rune]!).toList();
      if (units.isNotEmpty) rows.add((top: rect.top, start: firstId, units: units));
    }
  }
  // Keep references to the true item visibility notifier in this assertion;
  // an empty/disconnected list must never be interpreted as a blank good page.
  expect(visible, isNotEmpty);
  rows.sort((a, b) => (a.top - b.top).abs() > 0.25 ? a.top.compareTo(b.top) : a.start.compareTo(b.start));
  final units = rows.expand((row) => row.units).toList();
  if (units.isEmpty) {
    debugPrint('FILTER_SOURCE_EMPTY phase=$phase visible=$visible viewport=$viewport clip=$clipRect '
      'fixtureLast=${fixture.ids.values.reduce((a, b) => a > b ? a : b)} renders=$diagnostics');
  }
  expect(units, isNotEmpty);
  _expectContiguous(units, 'current painted source rows');
  return units;
}
void _expectContiguous(List<int> units, String phase) {
  for (var index = 1; index < units.length; index++) {
    expect(units[index], units[index - 1] + 1,
      reason: '$phase: body source character ${units[index - 1]} must be followed exactly once by its successor');
  }
}
void _expectForwardCoverage(List<int> before, List<int> after, String phase) {
  _expectContiguous(after, phase);
  expect(after.first, before.last + 1, reason: '$phase must neither skip nor repeat a surviving source character at the page boundary');
}

// Actual pixels are compared entirely in memory. No UI screenshots, image
// files or transmission artifacts are created or retained by these tests.
Future<Uint8List> _paintedBody(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_surface));
  final body = tester.getRect(find.byKey(const ValueKey('reader-body')));
  return (await tester.runAsync(() async {
    final image = boundary.toImageSync(pixelRatio: 1);
    try {
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      final full = bytes.buffer.asUint8List();
      final width = image.width, startY = body.top.ceil(), endY = body.bottom.floor();
      final result = Uint8List((endY - startY) * width * 4);
      result.setRange(0, result.length, full, startY * width * 4);
      return result;
    } finally { image.dispose(); }
  }))!;
}
bool _samePaint(Uint8List actual, Uint8List expected) {
  if (actual.length != expected.length) return false;
  // The fixed local raster baseline measured maxRGBA=[1,1,1,0], no channels
  // differing by >2 and bestShift=[0,0] when an unchanged page passed through
  // an opaque RawImage. Permit only this one-level offscreen blend rounding;
  // compare every channel at the same coordinate, without spatial matching.
  for (var index = 0; index < actual.length; index++) {
    if ((actual[index] - expected[index]).abs() > 1) return false;
  }
  return true;
}
String _pixelDifference(Uint8List actual, Uint8List expected) {
  const width = 390;
  var count = 0, left = width, top = actual.length ~/ (width * 4), right = -1, bottom = -1;
  final bands = <int, int>{};
  final maxima = [0, 0, 0, 0], sums = [0, 0, 0, 0];
  var over2 = 0, over12 = 0;
  final pairs = <String>[];
  for (var index = 0; index < actual.length; index += 4) {
    for (var channel = 0; channel < 4; channel++) {
      final difference = (actual[index + channel] - expected[index + channel]).abs();
      sums[channel] += difference;
      if (difference > maxima[channel]) maxima[channel] = difference;
      if (difference > 2) over2++;
      if (difference > 12) over12++;
    }
    if (actual[index] == expected[index] && actual[index + 1] == expected[index + 1] &&
        actual[index + 2] == expected[index + 2] && actual[index + 3] == expected[index + 3]) continue;
    count++;
    final x = index ~/ 4 % width, y = index ~/ (width * 4);
    if (pairs.length < 8) pairs.add('($x,$y):${actual.sublist(index, index + 4)}/${expected.sublist(index, index + 4)}');
    if (x < left) left = x; if (x > right) right = x;
    if (y < top) top = y; if (y > bottom) bottom = y;
    bands.update(y ~/ 40, (previous) => previous + 1, ifAbsent: () => 1);
  }
  final height = actual.length ~/ (width * 4);
  var bestError = double.infinity, bestX = 0, bestY = 0;
  final shiftErrors = <String, double>{};
  for (var dy = -2; dy <= 2; dy++) {
    for (var dx = -2; dx <= 2; dx++) {
      var error = 0, samples = 0;
      for (var y = 3; y < height - 3; y += 3) {
        for (var x = 3; x < width - 3; x += 3) {
          final a = (y * width + x) * 4, b = ((y + dy) * width + x + dx) * 4;
          for (var channel = 0; channel < 3; channel++) {
            error += (actual[a + channel] - expected[b + channel]).abs(); samples++;
          }
        }
      }
      final mean = error / samples;
      shiftErrors['$dx,$dy'] = mean;
      if (mean < bestError) { bestError = mean; bestX = dx; bestY = dy; }
    }
  }
  return 'pixels=$count/${actual.length ~/ 4}(${(count * 400 / actual.length).toStringAsFixed(3)}%) '
    'bbox=[$left,$top,$right,$bottom] bands40=$bands maxRGBA=$maxima '
    'meanRGBA=${sums.map((sum) => (sum * 4 / actual.length).toStringAsFixed(5)).toList()} '
    'channelsOver2=$over2 over12=$over12 bestShift=[$bestX,$bestY] '
    'bestShiftMeanRGB=${bestError.toStringAsFixed(5)} noShiftMeanRGB=${shiftErrors['0,0']!.toStringAsFixed(5)} pairs=$pairs';
}
Future<ui.Image> _decodeBodyImage(WidgetTester tester, Uint8List pixels) async =>
  (await tester.runAsync(() {
    final decoded = Completer<ui.Image>();
    ui.decodeImageFromPixels(pixels, 390, pixels.length ~/ (390 * 4), ui.PixelFormat.rgba8888, decoded.complete);
    return decoded.future;
  }))!;

Future<void> _expectSlidePixels(WidgetTester tester, Uint8List actual, ui.Image oldPage, ui.Image newPage,
    Color background, double incoming, double outgoing, int frame) async {
  const width = 390;
  final height = actual.length ~/ (width * 4);
  // Compose independent stable before/after captures with the same raster
  // backend and filter as RenderImage. This avoids approximating Skia's
  // medium-quality sampling with a handwritten bilinear formula. No actual
  // transition snapshot is read to construct the expected page.
  final expected = (await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    ui.Picture? picture;
    ui.Image? image;
    try {
      final canvas = ui.Canvas(recorder);
      final bounds = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
      canvas.clipRect(bounds, doAntiAlias: false);
      canvas.drawColor(background, ui.BlendMode.src);
      final paint = Paint()..filterQuality = ui.FilterQuality.medium..isAntiAlias = false;
      canvas.drawImageRect(newPage, bounds, bounds.shift(Offset(incoming * width, 0)), paint);
      canvas.drawImageRect(oldPage, bounds, bounds.shift(Offset(outgoing * width, 0)), paint);
      picture = recorder.endRecording();
      image = await picture.toImage(width, height);
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      return Uint8List.fromList(bytes.buffer.asUint8List());
    } finally {
      if (recorder.isRecording) recorder.endRecording().dispose();
      image?.dispose(); picture?.dispose();
    }
  }))!;
  if (!_samePaint(actual, expected)) {
    debugPrint('SLIDE_REFERENCE frame=$frame incoming=$incoming outgoing=$outgoing ${_pixelDifference(actual, expected)}');
  }
  expect(_samePaint(actual, expected), isTrue,
    reason: 'Slide frame $frame must match the stable source/destination composition at every pixel within one channel level');
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
