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

ReaderSpacingPlan? _spacingPolicy;

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  // Use the installed OS CJK resource only inside the test process; no copy or redistribution.
  final cjkFont = File('${Platform.environment['SystemRoot']}\\Fonts\\msyh.ttc');
  setUpAll(() async {
    if (!cjkFont.existsSync()) return;
    final loader = FontLoader('ReaderCjkProbe')
      ..addFont(cjkFont.readAsBytes().then((bytes) => ByteData.sublistView(bytes)));
    await loader.load();
  });
  late TtsAudioHandler handler;
  TtsAudioHandler? previous;

  setUp(() async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    SharedPreferences.setMockInitialValues({});
    _spacingPolicy = null;
    ReaderScreen.onSpacingPolicyForTesting = (plan) => _spacingPolicy = plan;
    ReaderPreparation.runnerForTesting = (request) async => ReaderPreparation.prepareSynchronously(request);
    AppAppearance.setThemeMode('light');
    previous = globalAudioHandler;
    handler = TtsAudioHandler();
    globalAudioHandler = handler;
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
    ReaderScreen.onSpacingPolicyForTesting = null;
    _spacingPolicy = null;
    globalAudioHandler = previous;
    unawaited(handler.playbackState.close());
    unawaited(handler.mediaItem.close());
  });

  for (final fontSize in [40.0, 64.0]) {
    for (final mixedParagraphs in [false, true]) {
    testWidgets('real CJK glyph row fits without requiring a full typographic line box $fontSize mixed=$mixedParagraphs', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final storage = AppStorage();
      await storage.saveSettings((ReadingSettings()..pageTurnMode = 'tap'..pageTurnAnimation = 'off'
        ..fontFamily = 'ReaderCjkProbe'..fontSize = fontSize..lineHeight = 1.8..firstLineIndent = false..informationFilter = false).toJson());
      final book = Book(id: 'bottom-$fontSize', title: '页底行距', filePath: '', format: BookFormat.txt,
        addedAt: DateTime(2026), chapters: [Chapter(title: '第一章', paragraphs: [
          for (var p = 0; p < (mixedParagraphs ? 12 : 1); p++)
            ReadingText.paragraph('页底测试${p}段' + List.generate(mixedParagraphs ? 2 : 100,
              (i) => '第${i}句山间清风吹过树林远处小路延伸到村庄。').join()),
        ])]);
      await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: book, storage: storage,
        ttsReader: TtsReader(player: _SilentPlayer()))));
      await tester.pumpAndSettle();
      final body = find.byKey(const ValueKey('reader-body'));

      Future<void> alignFirstRow() async {
        final list = tester.widget<ScrollablePositionedList>(body);
        list.itemScrollController!.jumpTo(index: 1);
        await tester.pumpAndSettle();
        final first = _rows(tester).first;
        unawaited(list.scrollOffsetController!.animateScroll(
          offset: first.glyph.top - tester.getTopLeft(body).dy, duration: const Duration(milliseconds: 1)));
        await tester.pumpAndSettle();
      }

      await alignFirstRow();
      final original = _rows(tester);
      final target = original.skip(7).firstWhere((row) => row.spacing.bottom - row.glyph.bottom > 1);
      expect(target.spacing.bottom - target.glyph.bottom, greaterThan(1),
        reason: 'This fixture must have real extra line leading below the glyph row');
      final desiredHeight = target.glyph.bottom - tester.getTopLeft(body).dy + 0.5;
      tester.view.physicalSize = Size(390, 844 + desiredHeight - tester.getSize(body).height);
      await tester.pumpAndSettle();
      await alignFirstRow();

      // Observe real glyph coordinates after the viewport/anchor settles.
      // Fixed font, line height and paragraph gaps do not depend on H.
      for (var attempt = 0; attempt < 5; attempt++) {
        final actualTarget = _rows(tester).firstWhere((row) => row.key == target.key);
        final delta = actualTarget.glyph.bottom + .5 - tester.getRect(body).bottom;
        if (delta.abs() < .01) break;
        final view = tester.view.physicalSize;
        tester.view.physicalSize = Size(view.width, view.height + delta);
        await tester.pumpAndSettle();
        await alignFirstRow();
      }
      final viewport = tester.getRect(body), rows = _rows(tester);
      expect(rows.firstWhere((row) => row.key == target.key).glyph.bottom,
        closeTo(viewport.bottom - .5, .05),
        reason: 'Calibrate the physical glyph budget after the new viewport spacing policy settles');
      final lastFitting = rows.lastWhere((row) => row.glyph.bottom <= viewport.bottom + 0.25);
      expect(lastFitting.spacing.bottom, greaterThan(viewport.bottom + 1),
        reason: 'The last glyph row fits, but its lower half-leading falls beyond the body');
      // The last physically fitting row must be displayed even when its
      // typographic trailing leading extends below the viewport.
      final firstPage = _expectCertifiedPage(tester, rows);
      final first = firstPage.first;
      final next = rows[rows.indexWhere((row) => row.key == firstPage.last.key) + 1];
      _expectSourceSuccessor(firstPage.last, next);
      await tester.tapAt(Offset(370, viewport.center.dy));
      await tester.pumpAndSettle();
      final forward = _expectCertifiedPage(tester, _rows(tester));
      expect(forward.first.key, next.key, reason: 'The source successor of the actual final row must not repeat or disappear on the next page');
      expect((forward.first.item, forward.first.sourceStart), (next.item, next.sourceStart));
      final firstUsed = firstPage.last.glyph.bottom - firstPage.first.glyph.top;
      final nextUsed = forward.last.glyph.bottom - forward.first.glyph.top;
      expect((firstUsed - nextUsed).abs(), lessThanOrEqualTo(_spacingPolicy!.rowPitch + _spacingPolicy!.spacing + .5),
        reason: 'Page-bottom variation is bounded by one complete native line/paragraph advance');
      await tester.tapAt(Offset(20, viewport.center.dy));
      await tester.pumpAndSettle();
      final backward = _expectCertifiedPage(tester, _rows(tester));
      expect(backward.map((row) => row.key), orderedEquals(firstPage.map((row) => row.key)),
        reason: 'Forward/backward paging must restore the entire committed source slice');
      expect(backward.first.glyph.top, closeTo(first.glyph.top, 0.5));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    }, skip: !cjkFont.existsSync());
    }
  }
}

typedef _Row = ({String key, int item, int sourceStart, int sourceEnd, Rect glyph, Rect spacing});

List<_Row> _expectCertifiedPage(WidgetTester tester, List<_Row> rows) {
  expect(_spacingPolicy, isNotNull, reason: 'The test must observe the native geometry-derived spacing plan');
  final policy = _spacingPolicy!;
  final body = tester.getRect(find.byKey(const ValueKey('reader-body')));
  final clipFinder = find.byKey(const ValueKey('reader-page-clip'));
  final clip = tester.widget<ClipRect>(clipFinder), size = tester.getSize(clipFinder);
  final clipBottom = tester.getTopLeft(clipFinder).dy + (clip.clipper?.getClip(size).bottom ?? size.height);
  final physical = rows.where((row) => row.glyph.top >= body.top - .25 && row.glyph.bottom <= body.bottom + .25).toList();
  final actual = physical.where((row) => row.glyph.bottom <= clipBottom + .25).toList();
  expect(policy.fixedRows, isFalse);
  expect(actual, isNotEmpty);
  expect(actual.map((row) => row.key), orderedEquals(physical.map((row) => row.key)),
    reason: 'Every physically fitting complete native row must be displayed');
  expect(clipBottom, closeTo(actual.last.glyph.bottom, .25),
    reason: 'The actual clip ends at the final tight glyph, without charging its trailing line leading');
  final nextIndex = rows.indexWhere((row) => row.key == actual.last.key) + 1;
  if (nextIndex < rows.length) {
    expect(rows[nextIndex].glyph.bottom - actual.first.glyph.top, greaterThan(body.height - .25),
      reason: 'The next complete source glyph row cannot fit the actual body');
  }
  expect(body.bottom - actual.last.glyph.bottom, inInclusiveRange(-.25, policy.rowPitch + policy.spacing + .5));
  for (var i = 1; i < actual.length; i++) { _expectSourceSuccessor(actual[i - 1], actual[i]); }
  return actual;
}

void _expectSourceSuccessor(_Row before, _Row after) {
  if (before.item == after.item) {
    expect(after.sourceStart, before.sourceEnd, reason: 'A wrapped source line resumes at the exact next UTF-16 source character');
  } else {
    expect(after.item, before.item + 1, reason: 'Paging must not skip a source paragraph');
    expect(after.sourceStart, 0, reason: 'A new paragraph starts at its actual first source character');
  }
}

int _sourceLength(String text) => text.replaceAll(RegExp('[\\u200B\\uFFFC]'), '').length;

List<_Row> _rows(WidgetTester tester) {
  expect(_spacingPolicy, isNotNull);
  final renders = <int, RenderParagraph>{};
  for (final element in find.byWidgetPredicate((widget) => widget is Text && widget.textAlign == TextAlign.justify &&
    widget.textSpan!.toPlainText().contains('页底测试')).evaluate()) {
    final render = element.findRenderObject()! as RenderParagraph;
    final paragraph = int.parse(RegExp(r'页底测试(\d+)段').firstMatch(render.text.toPlainText())!.group(1)!);
    renders[paragraph + 1] = render;
  }
  final list = tester.widget<ScrollablePositionedList>(find.byKey(const ValueKey('reader-body')));
  final visible = list.itemPositionsNotifier!.itemPositions.value
    .where((item) => item.itemTrailingEdge > 0 && item.itemLeadingEdge < 1 && renders.containsKey(item.index)).first;
  final anchor = renders[visible.index]!;
  final viewport = RenderAbstractViewport.of(anchor);
  final origin = anchor.localToGlobal(Offset.zero).dy - viewport.getOffsetToReveal(anchor, 0).offset;
  final rows = <_Row>[];
  for (final entry in renders.entries) {
    final render = entry.value;
    if (RenderAbstractViewport.maybeOf(render) != viewport) continue;
    RenderObject? parent = render.parent;
    while (parent != null && parent is! RenderPadding) { parent = parent.parent; }
    expect(parent, isA<RenderPadding>());
    expect((parent! as RenderPadding).padding.resolve(TextDirection.ltr).top,
      closeTo(_spacingPolicy!.spacing, 1e-3),
      reason: 'Every body paragraph follows its real visible chapter label/paragraph with the policy spacing');
    final full = render.text.toPlainText();
    final offset = Offset(render.localToGlobal(Offset.zero).dx, viewport.getOffsetToReveal(render, 0).offset + origin);
    Map<int, Rect> grouped(ui.BoxHeightStyle style) {
    final result = <int, Rect>{};
    final boxes = render.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: full.length), boxHeightStyle: style);
    for (final box in boxes) {
      final rect = box.toRect();
      if (rect.width < 0.01 || rect.height < 2) continue;
      final a = render.getPositionForOffset(Offset(-1, rect.center.dy)).offset;
      final b = render.getPositionForOffset(Offset(render.size.width + 1, rect.center.dy)).offset;
      final start = a < b ? a : b;
      result.update(start, (previous) => previous.expandToInclude(rect), ifAbsent: () => rect);
    }
    return result;
  }
    final glyph = grouped(ui.BoxHeightStyle.tight), spacing = grouped(ui.BoxHeightStyle.includeLineSpacingMiddle);
    for (final row in glyph.entries) {
      expect(spacing.containsKey(row.key), isTrue, reason: 'Glyph and leading probes must identify the same native visual row');
      final right = render.getPositionForOffset(Offset(render.size.width + 1, row.value.center.dy)).offset;
      final start = row.key < right ? row.key : right, end = row.key < right ? right : row.key;
      rows.add((key: '${entry.key}/$start', item: entry.key,
        sourceStart: _sourceLength(full.substring(0, start)), sourceEnd: _sourceLength(full.substring(0, end)),
        glyph: row.value.shift(offset), spacing: spacing[row.key]!.shift(offset)));
    }
  }
  rows.sort((a, b) => a.spacing.top.compareTo(b.spacing.top));
  return rows;
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
