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

final _plannedSlices = <String, List<String>>{};
final _observedSlices = <Object, List<String>>{};
ReaderSpacingPlan? _spacingPolicy;

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  late TtsAudioHandler handler;
  TtsAudioHandler? previous;
  setUp(() async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    SharedPreferences.setMockInitialValues({});
    _plannedSlices.clear();
    _spacingPolicy = null; _observedSlices.clear();
    ReaderScreen.onSpacingPolicyForTesting = (policy) => _spacingPolicy = policy;
    ReaderScreen.onJointPagePlanForTesting = (chapter, plan, keys) {
      for (final page in plan.pages) {
        _plannedSlices[keys[page.first]] = keys.sublist(page.first, page.end);
      }
    };
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
    ReaderScreen.onJointPagePlanForTesting = null;
    ReaderScreen.onSpacingPolicyForTesting = null;
    _spacingPolicy = null; _observedSlices.clear();
    _plannedSlices.clear();
    ReaderPreparation.runnerForTesting = null; globalAudioHandler = previous;
    unawaited(handler.playbackState.close()); unawaited(handler.mediaItem.close());
  });

  for (final mode in ['tap', 'swipe', 'scroll']) {
    for (final state in ['normal', 'playing', 'paused']) {
      testWidgets('filter cycles preserve complete rows and page anchors $mode $state', (tester) async {
        tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
        addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
        final storage = AppStorage(), speech = _FilterSpeech();
        await storage.saveSettings((ReadingSettings()..pageTurnMode = mode..pageTurnAnimation = 'off'
          ..fontSize = 24..lineHeight = 1.8..firstLineIndent = false..informationFilter = false).toJson());
        final source = _fixture('$mode-$state');
        await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: source, storage: storage, ttsReader: speech)));
        await tester.pumpAndSettle();
        final body = find.byKey(const ValueKey('reader-body'));
        // Start inside an unchanged body paragraph, with filtered material
        // before it. A source anchor can survive every filter level here.
        tester.widget<ScrollablePositionedList>(body).itemScrollController!.jumpTo(index: 5);
        await tester.pumpAndSettle();
        unawaited(tester.widget<ScrollablePositionedList>(body).scrollOffsetController!.animateScroll(
          offset: 190, duration: const Duration(milliseconds: 1)));
        await tester.pumpAndSettle();
        final rowTop = _completeLines(tester).first.rect.top - tester.getTopLeft(body).dy;
        unawaited(tester.widget<ScrollablePositionedList>(body).scrollOffsetController!.animateScroll(
          offset: rowTop, duration: const Duration(milliseconds: 1)));
        await tester.pumpAndSettle();

        for (final level in ['links', 'ads', 'extra']) {
          if (find.byKey(const ValueKey('reader-menu')).evaluate().isEmpty) {
            await tester.tapAt(const Offset(195, 300)); await tester.pumpAndSettle();
          }
          await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('阅读设置')); await tester.pumpAndSettle();
          // Starting from the notification while this real modal is open is a
          // supported route to changing text options during speech playback.
          if (state != 'normal') {
            await _complete(tester, handler.play()); await tester.pumpAndSettle();
            if (state == 'paused') { await _complete(tester, handler.pause()); await tester.pumpAndSettle(); }
          }
          final anchor = _completeLines(tester).first;
          final filter = find.byKey(const ValueKey('information-filter'));
          final scroll = find.descendant(of: find.byType(BottomSheet).last, matching: find.byType(Scrollable)).last;
          await tester.scrollUntilVisible(filter, 200, scrollable: scroll); await tester.pumpAndSettle();
          _plannedSlices.clear(); _observedSlices.clear(); // Text installation invalidates the old row table.
          await tester.tap(filter); await _settleFrames(tester);
          final radio = find.byWidgetPredicate((widget) => widget is RadioListTile<String> && widget.value == level);
          await tester.scrollUntilVisible(radio, 160, scrollable: scroll); await tester.pumpAndSettle();
          if (tester.widget<RadioListTile<String>>(radio).groupValue != level) {
            _plannedSlices.clear(); _observedSlices.clear();
          }
          await tester.tap(radio); await _settleFrames(tester);
          _expectAnchor(tester, anchor, '$level enabled in $state');
          _expectNoUnpaintedCompleteRow(tester);
          expect(speech.state == TtsState.playing, state == 'playing');
          await tester.scrollUntilVisible(filter, -160, scrollable: scroll); await tester.pumpAndSettle();
          _plannedSlices.clear(); _observedSlices.clear();
          await tester.tap(filter); await _settleFrames(tester);
          _expectAnchor(tester, anchor, '$level disabled in $state');
          _expectNoUnpaintedCompleteRow(tester);
          await tester.tapAt(const Offset(195, 60)); await tester.pumpAndSettle();
          if (find.byTooltip('阅读设置').evaluate().isNotEmpty) {
            await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
          }

          final beforePage = _completeLines(tester), beforeTurn = beforePage.first;
          final sourceRows = _completeLines(tester, includeUnpainted: true, includeOutsideViewport: true);
          final sourceLast = sourceRows.indexWhere((line) => line.key == beforePage.last.key);
          expect(sourceLast, greaterThanOrEqualTo(0));
          await _turn(tester, mode, state != 'normal', forward: true);
          _expectNoUnpaintedCompleteRow(tester);
          final afterTurn = _completeLines(tester).first;
          expect(afterTurn.text, isNot(beforeTurn.text), reason: 'The forward gesture must actually move the page');
          if (mode != 'scroll' || state != 'normal') {
            expect(afterTurn.key, sourceRows[sourceLast + 1].key,
              reason: 'Forward pagination starts at the exact next native source row without omission or repetition');
          }
          await _turn(tester, mode, state != 'normal', forward: false);
          _expectNoUnpaintedCompleteRow(tester);
          if (mode != 'scroll' || state != 'normal') {
            _expectAnchor(tester, beforeTurn, '$level forward/backward page round trip');
            expect(_completeLines(tester).map((line) => line.key), orderedEquals(beforePage.map((line) => line.key)),
              reason: 'Returning retains the complete original source-row slice');
          }
          if (state != 'normal') {
            if (speech.state == TtsState.playing) {
              await _complete(tester, handler.pause()); await tester.pumpAndSettle();
            }
            await tester.tap(find.byKey(const ValueKey('reading-exit'))); await tester.pumpAndSettle();
          }
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
      }, timeout: const Timeout(Duration(seconds: 90)));
    }
  }

  testWidgets('subpixel page alignment keeps the last complete line inside the page clip', (tester) async {
    var planCalls = 0;
    final precedingPlanHook = ReaderScreen.onJointPagePlanForTesting;
    ReaderScreen.onJointPagePlanForTesting = (chapter, plan, keys) {
      precedingPlanHook?.call(chapter, plan, keys); planCalls++;
      debugPrint('SUBPIXEL_PLAN K=${_spacingPolicy?.rows} pages=${plan.pages.length} '
        'band=${plan.bandStart}..${plan.bandEnd} first=${keys.first} last=${keys.last}');
    };
    addTearDown(() => ReaderScreen.onJointPagePlanForTesting = precedingPlanHook);
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    final storage = AppStorage();
    await storage.saveSettings((ReadingSettings()..pageTurnMode = 'tap'..pageTurnAnimation = 'off'
      ..fontSize = 24..lineHeight = 1.8..firstLineIndent = false..informationFilter = false).toJson());
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: _fixture('subpixel'), storage: storage,
      ttsReader: _FilterSpeech())));
    await tester.pumpAndSettle();
    final body = find.byKey(const ValueKey('reader-body'));
    Future<void> align(double residual) async {
      tester.widget<ScrollablePositionedList>(body).itemScrollController!.jumpTo(index: 5);
      await tester.pumpAndSettle();
      final first = _completeLines(tester).first;
      final delta = first.rect.top - tester.getTopLeft(body).dy - residual;
      unawaited(tester.widget<ScrollablePositionedList>(body).scrollOffsetController!.animateScroll(
        offset: delta, duration: const Duration(milliseconds: 1)));
      await tester.pumpAndSettle();
    }
    await align(0);
    final measured = _completeLines(tester);
    expect(measured.length, greaterThanOrEqualTo(8));
    final rowExtent = measured[7].rect.bottom - measured.first.rect.top;
    final nativePitch = measured[1].rect.top - measured.first.rect.top;
    expect(rowExtent, closeTo(measured.first.rect.height + 7 * nativePitch, 0.02));
    // Calibrate capacity from actual native rows, without a policy K cap.
    // The requested font and line height must survive the viewport change.
    const budget = 24 / 2 + 1.0;
    final calibratedHeight = rowExtent + budget;
    final originalBodyHeight = tester.getSize(body).height;
    tester.view.physicalSize = Size(390, 844 + calibratedHeight - originalBodyHeight);
    _plannedSlices.clear(); _observedSlices.clear();
    await tester.pumpAndSettle();
    await align(0.1);
    final viewport = tester.getRect(body), complete = _completeLines(tester);
    expect(_spacingPolicy!.fixedRows, isFalse);
    expect(_spacingPolicy!.rows, 0, reason: 'Flow rows=0 means no artificial row-count cap');
    expect(complete.map((line) => line.key), orderedEquals(
      _completeLines(tester, includeUnpainted: true).map((line) => line.key)),
      reason: 'The subpixel page must contain the actual maximal complete native prefix');
    expect(complete.first.rect.top - viewport.top, closeTo(0.1, 0.02));
    final sourceRows = _completeLines(tester, includeUnpainted: true, includeOutsideViewport: true);
    final firstSource = sourceRows.indexWhere((line) => line.key == complete.first.key);
    expect(firstSource, greaterThanOrEqualTo(0));
    final resolvedPitch = sourceRows[firstSource + 1].rect.top - sourceRows[firstSource].rect.top;
    expect(resolvedPitch, closeTo(nativePitch, .02), reason: 'Resizing must not adapt the selected line height');
    final resolvedExtent = sourceRows[firstSource].rect.height + (complete.length - 1) * resolvedPitch;
    expect(complete.last.rect.bottom - viewport.top, closeTo(resolvedExtent + 0.1, 0.02),
      reason: 'The final row uses the independently measured post-resize native pitch, including the exact subpixel offset');
    final actualRender = find.byWidgetPredicate((widget) => widget is Text && widget.textAlign == TextAlign.justify &&
      widget.textSpan?.toPlainText().replaceAll('\u200B', '').contains('第1段第0句') == true)
      .evaluate().single.findRenderObject()! as RenderParagraph;
    expect(actualRender.strutStyle!.fontSize, 24);
    expect(actualRender.strutStyle!.height, 1.8);
    final next = sourceRows[firstSource + complete.length];
    expect(next.rect.bottom, greaterThan(viewport.bottom + .25),
      reason: 'The next complete native row really cannot fit');
    expect(viewport.bottom - complete.last.rect.bottom,
      inInclusiveRange(-.25, next.rect.bottom - complete.last.rect.bottom + .25),
      reason: 'Natural remainder is bounded by the next actual row advance, not half a font');
    final clipFinder = find.byKey(const ValueKey('reader-page-clip'));
    final clip = tester.widget<ClipRect>(clipFinder).clipper!.getClip(tester.getSize(clipFinder));
    expect(tester.getTopLeft(clipFinder).dy + clip.bottom, closeTo(complete.last.rect.bottom, 0.02),
      reason: 'The clip ends exactly on the actual final row, including its subpixel alignment');
    _expectNoUnpaintedCompleteRow(tester);
    final before = complete.map((line) => line.key).toList();
    final end = sourceRows.indexWhere((line) => line.key == complete.last.key);
    Future<void> turn(bool forward) async {
      final bounds = tester.getRect(body);
      final plansBeforeTap = planCalls;
      await tester.tapAt(Offset(forward ? bounds.right - 20 : bounds.left + 20, bounds.center.dy));
      await tester.pump();
      expect(find.byKey(const ValueKey('page-outgoing-transform')), findsOneWidget,
        reason: 'The resized fixture must enter the real page-turn path instead of tapping the bottom toolbar');
      await _settleFrames(tester);
      if (forward) {
        expect(planCalls, greaterThan(plansBeforeTap),
          reason: 'The forward source row must be resolved by the real longest-fit planner');
      }
    }
    final button = find.byKey(const ValueKey('next-chapter'));
    final policy = _spacingPolicy!;
    debugPrint('SUBPIXEL_BEFORE body=$viewport screen=${tester.view.physicalSize} '
      'legacyTap=${const Offset(370, 380)} actualTap=${Offset(viewport.right - 20, viewport.center.dy)} '
      'nextButton=${button.evaluate().isEmpty ? null : tester.getRect(button)} '
      'K=${policy.rows} used=${policy.usedMin}..${policy.usedMax} '
      'actual=${complete.first.rect.top - viewport.top}..${complete.last.rect.bottom - viewport.top} '
      'source=${before.first}..${before.last} expectedNext=${sourceRows[end + 1].key} plans=$planCalls');
    await turn(true);
    debugPrint('SUBPIXEL_AFTER source=${_completeLines(tester).first.key} plans=$planCalls '
      'outgoing=${find.byKey(const ValueKey('page-outgoing-transform')).evaluate().length} '
      'geometryMessages=${find.byWidgetPredicate((widget) => widget is Text && (widget.data?.contains('半字分页') ?? false)).evaluate().length}');
    expect(_completeLines(tester).first.key, sourceRows[end + 1].key);
    _expectNoUnpaintedCompleteRow(tester);
    await turn(false);
    expect(_completeLines(tester).map((line) => line.key), orderedEquals(before));
    _expectNoUnpaintedCompleteRow(tester);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });
}

Book _fixture(String id) => Book(id: 'filter-pages-$id', title: '过滤分页', filePath: '', format: BookFormat.txt,
  addedAt: DateTime(2026), chapters: [Chapter(title: '第一章', paragraphs: [
    for (var block = 0; block < 4; block++) ...[
      ReadingText.paragraph(List.generate(90, (line) =>
        '第${block}段第${line}句，山间的风吹过树林，远处的小路延伸到村庄。').join()),
      ReadingText.paragraph('网址 https://example.invalid/$block 与邮箱 reader$block@example.invalid 后仍有正文。'),
      ReadingText.paragraph('请访问本站 www.example.invalid 获取更多小说。'),
      ReadingText.paragraph('作者有话说：今天继续写故事。'),
    ],
  ])]);

typedef _Line = ({String key, String text, Rect rect});

List<_Line> _completeLines(WidgetTester tester, {bool includeUnpainted = false, bool includeOutsideViewport = false}) {
  final viewport = tester.getRect(find.byKey(const ValueKey('reader-body')));
  final clipFinder = find.byKey(const ValueKey('reader-page-clip'));
  final clipWidget = tester.widget<ClipRect>(clipFinder), clipSize = tester.getSize(clipFinder);
  final clip = (clipWidget.clipper?.getClip(clipSize) ?? (Offset.zero & clipSize))
    .shift(tester.getTopLeft(clipFinder)).intersect(viewport);
  final rows = <_Line>[];
  for (final element in find.byWidgetPredicate((widget) => widget is Text && widget.textAlign == TextAlign.justify).evaluate()) {
    final render = element.findRenderObject();
    if (render is! RenderParagraph || !render.attached) continue;
    int? itemIndex;
    element.visitAncestorElements((ancestor) {
      final key = ancestor.widget.key;
      if (key is ValueKey<int>) { itemIndex = key.value; return false; }
      return true;
    });
    expect(itemIndex, isNotNull, reason: 'A source row must retain its actual indexed reader item identity');
    final full = render.text.toPlainText(), origin = render.localToGlobal(Offset.zero);
    // All navigation stays inside this long paragraph. Ignore cached indexed
    // slivers whose offscreen paint transforms may be clamped by the viewport.
    if (!full.replaceAll('\u200B', '').contains('第1段第0句')) continue;
    final boxes = render.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: full.length),
      boxHeightStyle: ui.BoxHeightStyle.tight);
    final grouped = <int, Rect>{};
    for (final box in boxes) {
      final rect = box.toRect();
      if (rect.width < 0.01 || rect.height < 2) continue;
      final a = render.getPositionForOffset(Offset(-1, rect.center.dy)).offset;
      final b = render.getPositionForOffset(Offset(render.size.width + 1, rect.center.dy)).offset;
      final start = a < b ? a : b;
      grouped.update(start, (previous) => previous.expandToInclude(rect), ifAbsent: () => rect);
    }
    for (final entry in grouped.entries) {
      final local = entry.value;
      final rect = local.shift(origin);
      if (!includeOutsideViewport && (rect.top < viewport.top - 0.25 || rect.bottom > viewport.bottom + 0.25)) continue;
      if (!includeUnpainted && (rect.top < clip.top - .25 || rect.bottom > clip.bottom + .25)) continue;
      final a = render.getPositionForOffset(Offset(-1, local.center.dy)).offset;
      final b = render.getPositionForOffset(Offset(render.size.width + 1, local.center.dy)).offset;
      final text = full.substring(a < b ? a : b, a < b ? b : a)
        .replaceAll(RegExp('[\u200B\n\uFFFC]'), '');
      if (text.trim().isNotEmpty) rows.add((key: '$itemIndex/${entry.key}', text: text, rect: rect));
    }
  }
  rows.sort((a, b) => a.rect.top.compareTo(b.rect.top));
  expect(rows, isNotEmpty);
  return rows;
}

void _expectAnchor(WidgetTester tester, _Line expected, String reason) {
  final actual = _completeLines(tester).first;
  expect(actual.text, expected.text, reason: reason);
  expect(actual.rect.top, closeTo(expected.rect.top, 0.5), reason: reason);
}

void _expectNoUnpaintedCompleteRow(WidgetTester tester) {
  final finder = find.byKey(const ValueKey('reader-page-clip'));
  final clip = tester.widget<ClipRect>(finder), size = tester.getSize(finder);
  final visible = clip.clipper?.getClip(size) ?? (Offset.zero & size);
  final bottom = tester.getTopLeft(finder).dy + visible.bottom;
  final painted = _completeLines(tester);
  expect(painted.last.rect.bottom, lessThanOrEqualTo(bottom + .25),
    reason: 'The actual clipped slice must finish on a complete body row');
  final planned = _plannedSlices[painted.first.key];
  if (planned != null) {
    expect(painted.map((line) => line.key), orderedEquals(planned),
      reason: 'A joint page must paint exactly its planned contiguous rows and terminal key');
  }
  final bodyFinder = find.byKey(const ValueKey('reader-body'));
  final list = tester.widget<ScrollablePositionedList>(bodyFinder);
  final physical = _completeLines(tester, includeUnpainted: true);
  if (list.physics is! NeverScrollableScrollPhysics) {
    expect(physical.map((line) => line.key), orderedEquals(painted.map((line) => line.key)),
      reason: 'Ordinary free scrolling still paints every fully visible row');
    return;
  }
  final policy = _spacingPolicy;
  expect(policy, isNotNull);
  expect(policy!.fixedRows, isFalse);
  expect(policy.rows, 0);
  expect(painted.map((line) => line.key), orderedEquals(physical.take(painted.length).map((line) => line.key)),
    reason: 'Every published slice is a contiguous complete native source prefix');
  final viewport = tester.getRect(bodyFinder);
  final identity = (painted.first.key, viewport.size, policy.spacing, policy.rowPitch);
  final observed = _observedSlices[identity];
  if (observed != null) {
    expect(painted.map((line) => line.key), orderedEquals(observed),
      reason: 'Returning to an observed page retains both exact history endpoints');
  } else {
    expect(physical.map((line) => line.key), orderedEquals(painted.map((line) => line.key)),
      reason: 'A newly established page may not hide any further physically fitting complete row');
    _observedSlices[identity] = painted.map((line) => line.key).toList();
  }
  final margin = viewport.bottom - painted.last.rect.bottom;
  expect(margin, greaterThanOrEqualTo(-.25));
  if (observed == null) {
    final all = _completeLines(tester, includeUnpainted: true, includeOutsideViewport: true);
    final end = all.indexWhere((line) => line.key == painted.last.key);
    expect(end, greaterThanOrEqualTo(0));
    expect(end + 1, lessThan(all.length), reason: 'The fixture stays inside a long paragraph, away from the real book tail');
    final next = all[end + 1];
    expect(next.rect.bottom, greaterThan(viewport.bottom + .25));
    expect(margin, lessThan(next.rect.bottom - painted.last.rect.bottom + .25),
      reason: 'A new full page remainder is below the next complete row advance, including any paragraph spacing');
  }
}

Future<void> _settleFrames(WidgetTester tester) async {
  var stableFrames = 0;
  for (var frame = 0; frame < 180; frame++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 16));
    if (find.byType(RawImage).evaluate().isEmpty && find.byType(CircularProgressIndicator).evaluate().isEmpty) {
      _expectNoUnpaintedCompleteRow(tester);
    }
    stableFrames = tester.binding.hasScheduledFrame ? 0 : stableFrames + 1;
    if (stableFrames >= 2) {
      _expectNoUnpaintedCompleteRow(tester);
      return;
    }
  }
  fail('The filter/navigation frame sequence did not settle');
}

Future<void> _turn(WidgetTester tester, String mode, bool reading, {required bool forward}) async {
  final body = find.byKey(const ValueKey('reader-body'));
  if (mode == 'tap') {
    await tester.tapAt(Offset(forward ? 370 : 20, 380));
  } else if (mode == 'swipe' || reading) {
    await tester.drag(body, Offset(forward ? -240 : 240, 0));
  } else {
    await tester.drag(body, Offset(0, forward ? -460 : 460));
  }
  await _settleFrames(tester);
}

Future<void> _complete(WidgetTester tester, Future<void> action) async {
  var done = false; Object? error;
  action.then((_) { done = true; }, onError: (Object failure) { error = failure; done = true; });
  for (var i = 0; i < 180 && !done; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(done, isTrue); if (error != null) throw error!;
}

class _FilterSpeech extends TtsReader {
  _FilterSpeech() : super(player: _SilentPlayer());
  TtsState status = TtsState.idle;
  int index = -1, offset = 0;
  @override TtsState get state => status;
  @override int get currentIndex => index;
  @override int get currentTtsOffset => offset;
  void _state(TtsState value) { status = value; onStateChanged?.call(); }
  @override Future<void> start(List<String> sentences, {List<int>? offsets, List<int>? pauseAfterMilliseconds,
    int chapterIndex = 0, int from = 0, int initialTtsOffset = 0}) async {
    index = from; offset = initialTtsOffset; _state(TtsState.playing); onSentenceChanged?.call(from);
  }
  @override Future<void> jumpTo(int sentenceIndex, {int ttsOffset = 0}) async {
    index = sentenceIndex; offset = ttsOffset; onSentenceChanged?.call(index);
  }
  @override Future<void> pause({bool interrupted = false}) async { _state(TtsState.paused); }
  @override Future<bool> resume() async { _state(TtsState.playing); return true; }
  @override Future<void> stop() async { _state(TtsState.stopped); }
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
