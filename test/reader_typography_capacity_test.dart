import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  final font = File('${Platform.environment['SystemRoot']}\\Fonts\\msyh.ttc');
  ReaderSpacingPlan? policy;
  late TtsAudioHandler handler;
  TtsAudioHandler? previous;
  setUpAll(() async {
    if (!font.existsSync()) return;
    // Existing Windows font, registered in this process only; never copied.
    await (FontLoader('CapacityInkCjk')
      ..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
  });
  setUp(() async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    SharedPreferences.setMockInitialValues({});
    ReaderPreparation.clearMemoryCache();
    ReaderPreparation.runnerForTesting = (request) async => ReaderPreparation.prepareSynchronously(request);
    ReaderScreen.onSpacingPolicyForTesting = (value) { policy = value; };
    policy = null;
    AppAppearance.setThemeMode('light');
    previous = globalAudioHandler;
    handler = TtsAudioHandler(); globalAudioHandler = handler;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('com.ddnovelreader/volume_keys'),
      (call) async => call.method == 'getMediaVolume' ? .5 : null);
    for (final channel in [const MethodChannel('com.ddnovelreader/debug_log'), DisplayCutoutService.channel,
      NetworkConnectivity.channel, SystemTtsClient.channel]) {
      messenger.setMockMethodCallHandler(channel, (_) async => null);
    }
    messenger.setMockMethodCallHandler(PlaybackNotifications.channel, (_) async =>
      {'supported': false, 'enabled': false, 'canRequest': false, 'asked': false});
    await Future<void>.delayed(Duration.zero);
  });
  tearDown(() {
    ReaderScreen.onSpacingPolicyForTesting = null;
    ReaderPreparation.runnerForTesting = null;
    ReaderPreparation.clearMemoryCache(); globalAudioHandler = previous;
    unawaited(handler.playbackState.close()); unawaited(handler.mediaItem.close());
  });

  for (final size in [20.0, 39.0, 64.0]) {
    testWidgets('font $size: native capacity and actual CJK ink have no spare complete row', (tester) async {
      tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
      final storage = AppStorage();
      await storage.saveSettings((ReadingSettings()..fontSize = size..lineHeight = 1.6
        ..paragraphSpacingLevel = 3..fontFamily = 'CapacityInkCjk'..firstLineIndent = false
        ..informationFilter = false..mergeNonSentenceBreaks = false..retainPageLine = false
        ..pageTurnMode = 'tap'..pageTurnAnimation = 'off').toJson());
      final book = Book(id: 'capacity-ink-$size', title: '字形容量', filePath: '', format: BookFormat.txt,
        addedAt: DateTime(2026), chapters: [Chapter(title: '', paragraphs: [
          ReadingText.paragraph(List.filled(2400, '田').join()),
        ])]);
      await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: book, storage: storage,
        ttsReader: TtsReader(player: _SilentPlayer()))));
      await tester.pumpAndSettle();
      final bodyFinder = find.byKey(const ValueKey('reader-body'));
      final list = tester.widget<ScrollablePositionedList>(bodyFinder);
      list.itemScrollController!.jumpTo(index: 1); await tester.pumpAndSettle();
      var render = _bodyRender();
      var rows = _rows(render);
      final delta = render.localToGlobal(Offset(0, rows.first.rect.top)).dy - tester.getTopLeft(bodyFinder).dy;
      unawaited(list.scrollOffsetController!.animateScroll(offset: delta, duration: const Duration(milliseconds: 1)));
      await tester.pumpAndSettle();
      expect(policy, isNotNull);
      render = _bodyRender(); rows = _rows(render);
      final body = tester.getRect(bodyFinder), origin = render.localToGlobal(Offset.zero);
      // The fixed footer belongs outside the actual body, rather than inside
      // an artificially shortened clipping budget. Insets are zero here.
      expect(body.bottom, closeTo(844 - 32, .01));
      final clipFinder = find.byKey(const ValueKey('reader-page-clip'));
      expect(tester.getRect(clipFinder), body);
      final clip = tester.widget<ClipRect>(clipFinder).clipper!.getClip(tester.getSize(clipFinder));
      final pageBottom = tester.getTopLeft(clipFinder).dy + clip.bottom;
      final fitting = rows.where((row) => origin.dy + row.rect.top >= body.top - .25 &&
        origin.dy + row.rect.bottom <= body.bottom + 1e-6).toList();
      final painted = fitting.where((row) => origin.dy + row.rect.bottom <= pageBottom + .25).toList();
      expect(policy!.fixedRows, isFalse);
      expect(policy!.rows, 0);
      expect(policy!.spacing, closeTo(size * .75, 1e-6));
      expect(render.strutStyle!.fontSize, size);
      expect(render.strutStyle!.height, 1.6);
      expect(painted, isNotEmpty);
      expect(painted.map((row) => row.offset), orderedEquals(fitting.map((row) => row.offset)),
        reason: 'No fitted complete source row may be hidden to obtain an artificial whitespace target');
      final last = painted.last, lastIndex = rows.indexOf(last);
      expect(lastIndex + 1, lessThan(rows.length));
      expect(origin.dy + rows[lastIndex + 1].rect.bottom, greaterThan(body.bottom),
        reason: 'The synthetic paragraph continues; the next full row must physically fail to fit');
      expect(pageBottom, closeTo(origin.dy + last.rect.bottom, .25));
      final nativeR = body.bottom - origin.dy - last.rect.bottom;
      final nextAdvance = rows[lastIndex + 1].rect.bottom - last.rect.bottom;
      expect(nativeR, greaterThanOrEqualTo(-.25));
      expect(nativeR, lessThan(nextAdvance + .25),
        reason: 'Natural whitespace is smaller than the actual native next-row advance');
      // An independent ink oracle shapes the ORIGINAL complete span using
      // precisely the render constraints. It never reshapes a page substring.
      final inkBottom = await tester.runAsync(() => _inkBottom(render, last.rect,
        nextTop: rows[lastIndex + 1].rect.top));
      expect(inkBottom, isNotNull);
      final inkLowerGap = last.rect.bottom - inkBottom!;
      final inkR = body.bottom - origin.dy - inkBottom;
      debugPrint('CAPACITY_INK font=$size actualL=${render.strutStyle?.height} '
        'H=${body.height} rows=${painted.length} nativeR=$nativeR '
        'inkLowerGap=$inkLowerGap inkR=$inkR');
      expect(inkLowerGap, greaterThanOrEqualTo(-2),
        reason: 'The independent raster must resolve the actual terminal CJK ink, rather than treat tight run metrics as pixels');
      expect(inkLowerGap, lessThan(last.rect.height));
      expect(inkR, greaterThanOrEqualTo(-.25));
      expect(inkR, lessThan(nextAdvance + math.max(0.0, inkLowerGap) + .25),
        reason: 'Ink whitespace includes its independently rasterized lower bearing in addition to the native next-row capacity bound');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    }, skip: !font.existsSync());
  }
}

RenderParagraph _bodyRender() => find.byWidgetPredicate((widget) => widget is Text &&
  widget.textAlign == TextAlign.justify && widget.textSpan?.toPlainText().startsWith('田田') == true)
  .evaluate().single.findRenderObject()! as RenderParagraph;

typedef _Line = ({int offset, Rect rect});
List<_Line> _rows(RenderParagraph render) {
  final grouped = <int, Rect>{};
  for (final box in render.getBoxesForSelection(TextSelection(baseOffset: 0,
    extentOffset: render.text.toPlainText().length), boxHeightStyle: ui.BoxHeightStyle.tight)) {
    final rect = box.toRect();
    if (rect.height < 2 || rect.width < .01) continue;
    final a = render.getPositionForOffset(Offset(-1, rect.center.dy)).offset;
    final b = render.getPositionForOffset(Offset(render.size.width + 1, rect.center.dy)).offset;
    grouped.update(math.min(a, b), (previous) => previous.expandToInclude(rect), ifAbsent: () => rect);
  }
  return [for (final line in grouped.entries) (offset: line.key, rect: line.value)]
    ..sort((a, b) => a.rect.top.compareTo(b.rect.top));
}

Future<double> _inkBottom(RenderParagraph render, Rect last, {required double nextTop}) async {
  final painter = TextPainter(text: render.text, textDirection: render.textDirection,
    textAlign: render.textAlign, textScaler: render.textScaler, locale: render.locale,
    strutStyle: render.strutStyle, textHeightBehavior: render.textHeightBehavior,
    textWidthBasis: render.textWidthBasis);
  ui.Picture? picture;
  ui.Image? image;
  const scale = 4;
  try {
    painter.layout(minWidth: render.size.width, maxWidth: render.size.width);
    expect(painter.height, closeTo(render.size.height, .01));
    // Only the terminal row is rasterized into a small transparent in-memory
    // region. No screenshot, font, picture, or image is persisted or displayed.
    final top = last.top.floorToDouble() - 2;
    final bottom = math.min(last.bottom + 2, nextTop - .25);
    expect(bottom, greaterThan(last.bottom));
    final width = (render.size.width * scale).ceil(), height = ((bottom - top) * scale).ceil();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(scale.toDouble())..translate(0, -top);
    painter.paint(canvas, Offset.zero);
    picture = recorder.endRecording();
    image = await picture.toImage(width, height);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(bytes, isNotNull);
    for (var y = height - 1; y >= 0; y--) {
      for (var x = 0; x < width; x++) {
        if (bytes!.getUint8((y * width + x) * 4 + 3) > 0) return top + (y + 1) / scale;
      }
    }
    throw StateError('The terminal CJK row produced no visible ink');
  } finally {
    image?.dispose(); picture?.dispose(); painter.dispose();
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
