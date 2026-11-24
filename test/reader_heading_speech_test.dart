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
import 'package:duoduo_langdu/services/reader_spacing_policy.dart';
import 'package:duoduo_langdu/services/reading_text.dart';
import 'package:duoduo_langdu/services/system_tts.dart';
import 'package:duoduo_langdu/services/text_cleaner.dart';
import 'package:duoduo_langdu/services/tts_audio_handler.dart';
import 'package:duoduo_langdu/services/tts_reader.dart';

typedef _Row = ({int chapter, int paragraph, int offset, String key, Rect rect});
ReaderSpacingPlan? _spacingPolicy;

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  TtsAudioHandler? previous;
  late TtsAudioHandler handler;
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
    ReaderPreparation.clearMemoryCache(); globalAudioHandler = previous;
    unawaited(handler.playbackState.close()); unawaited(handler.mediaItem.close());
  });

  testWidgets('legacy title progress at an untitled technical chunk restores the next source row and speech cursor', (tester) async {
    _setView(tester);
    final book = _book('legacy-untitled', emptySecondTitle: true);
    final speech = _Speech();
    await _mount(tester, book, speech, progress: BookProgress(bookId: book.id,
      chapterIndex: 1, paragraphIndex: 0, atChapterTitle: true, updatedAt: 1));
    expect(book.chapters[1].title, isEmpty,
      reason: 'Technical chunk metadata has no generated section heading at its source');
    final before = _rows(tester, book);
    expect((before.first.chapter, before.first.paragraph, before.first.offset), (1, 0, 0),
      reason: 'An empty metadata placeholder must not become a blank restored page or a previous-chapter anchor');
    await _complete(tester, handler.play()); await tester.pumpAndSettle();
    _expectSpeechAtPageStart(tester, book, speech);
    expect((speech.chapter, speech.index, speech.offset), (1, 0, 0));
    expect(_rows(tester, book).map((row) => row.key).toList(), before.map((row) => row.key).toList(),
      reason: 'Starting speech at legacy title progress must retain the already visible source rows');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  testWidgets('an original heading shares a page with the previous chapter tail and automatic speech continues without moving it', (tester) async {
    _setView(tester);
    final book = _book('same-page-heading');
    final speech = _Speech();
    await _mount(tester, book, speech);
    final initial = _rows(tester, book);
    expect(initial.any((row) => row.chapter == 0), isTrue);
    expect(initial.any((row) => row.chapter == 1 && row.paragraph == 0), isTrue,
      reason: 'The fixture must physically include the next original heading on the same page');
    expect(initial.any((row) => row.chapter == 1 && row.paragraph == 1), isTrue,
      reason: 'The same page must also contain real text after the next heading');
    final heading = find.descendant(of: find.byKey(const ValueKey('reader-body')),
      matching: find.byWidgetPredicate((widget) => widget is Text &&
        (widget.data ?? widget.textSpan?.toPlainText()) == '第2节 春风'));
    expect(heading, findsOneWidget, reason: 'An original heading must not also be duplicated as a metadata title');
    expect(tester.widget<Text>(heading).textAlign, TextAlign.center);
    final headingRender = tester.renderObject<RenderParagraph>(heading);
    final effectiveHeight = headingRender.strutStyle!.height!;
    expect(effectiveHeight, 1.6, reason: 'Heading line height preserves the exact requested setting');
    expect(_expectHeadingStyle(headingRender.text, const TextStyle(), effectiveHeight), greaterThan(0));

    await _complete(tester, handler.play()); await tester.pumpAndSettle();
    expect(speech.chapter, 0);
    final before = _rows(tester, book);
    speech.completeChapter();
    await _until(tester, () => speech.played.any((cursor) => cursor.$1 == 1));
    await tester.pumpAndSettle();
    expect((speech.chapter, speech.index, speech.offset), (1, 0, 0),
      reason: 'Automatic chapter completion must begin at the original heading source sentence exactly once');
    expect(speech.sentences.where((sentence) => sentence == book.chapters[1].paragraphs[0].tts).length, 1);
    final after = _rows(tester, book);
    expect(after.map((row) => row.key).toList(), before.map((row) => row.key).toList(),
      reason: 'A chapter boundary already on screen must not force a blank or separate page');
    for (var i = 0; i < after.length; i++) {
      expect(after[i].rect.top, closeTo(before[i].rect.top, 0.25));
    }
    // Advancing to the body sentence must likewise use source paragraph 1,
    // without re-reading the heading or manufacturing a metadata sentence.
    final bodyIndex = book.chapters[1].paragraphs[0].sentences.length;
    await _complete(tester, speech.seek(bodyIndex)); await tester.pumpAndSettle();
    expect(speech.index, bodyIndex);
    expect(_rows(tester, book).map((row) => row.key).toList(), before.map((row) => row.key).toList());
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  for (final paused in <bool>[false, true]) {
    testWidgets('manual cross-chapter pages retain exact heading/body speech coordinates paused=$paused', (tester) async {
      _setView(tester);
      final book = _book('manual-heading-$paused');
      final speech = _Speech();
      await _mount(tester, book, speech);
      await _complete(tester, handler.play()); await tester.pumpAndSettle();
      if (paused) { await _complete(tester, handler.pause()); await tester.pumpAndSettle(); }
      final visited = <List<String>>[_rows(tester, book).map((row) => row.key).toList()];
      for (var page = 0; page < 3; page++) {
        await _turn(tester, 1);
        if (paused) { await _complete(tester, handler.play()); await tester.pumpAndSettle(); }
        _expectSpeechAtPageStart(tester, book, speech);
        final actual = _rows(tester, book);
        expect(actual.first.chapter, 1, reason: 'The actual incoming page must cross into the next chapter body');
        expect(actual.first.paragraph, 1);
        expect(actual.first.offset, greaterThan(0), reason: 'Exercise a genuine middle-of-sentence page cursor');
        visited.add(actual.map((row) => row.key).toList());
        if (paused) { await _complete(tester, handler.pause()); await tester.pumpAndSettle(); }
      }
      for (var page = visited.length - 2; page >= 0; page--) {
        await _turn(tester, -1);
        if (paused) { await _complete(tester, handler.play()); await tester.pumpAndSettle(); }
        _expectSpeechAtPageStart(tester, book, speech);
        expect(_rows(tester, book).map((row) => row.key).toList(), visited[page],
          reason: 'Cross-chapter backward paging must restore the exact visited source slice');
        if (paused) { await _complete(tester, handler.pause()); await tester.pumpAndSettle(); }
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    }, timeout: const Timeout(Duration(seconds: 90)));
  }
}

void _setView(WidgetTester tester) {
  tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
}

Book _book(String id, {bool emptySecondTitle = false}) => Book(id: 'heading-speech-$id', title: '章节原文坐标',
  filePath: '', format: BookFormat.txt, addedAt: DateTime(2026), chapters: [
    Chapter(title: '', paragraphs: [ReadingText.paragraph(String.fromCharCodes(List.generate(70, (i) => 0x3400 + i)))]),
    Chapter(title: emptySecondTitle ? '' : '第2节 春风', paragraphs: [
      if (!emptySecondTitle) ReadingText.paragraph('第2节 春风'),
      ReadingText.paragraph(String.fromCharCodes(List.generate(1100, (i) => 0x3500 + i))),
    ]),
  ]);

Future<void> _mount(WidgetTester tester, Book book, _Speech speech, {BookProgress? progress}) async {
  final storage = AppStorage();
  await storage.saveSettings((ReadingSettings()..fontSize = 26..lineHeight = 1.6..paragraphSpacingLevel = 2
    ..firstLineIndent = false..informationFilter = false..mergeNonSentenceBreaks = false
    ..pageTurnMode = 'tap'..pageTurnAnimation = 'off').toJson());
  await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: book, storage: storage,
    initialProgress: progress, ttsReader: speech)));
  await tester.pumpAndSettle();
  expect(_spacingPolicy, isNotNull, reason: 'Speech tests must inspect a layout with a real native spacing certificate');
}

List<_Row> _rows(WidgetTester tester, Book book, {bool includeUnpainted = false}) {
  final source = <int, (int, int)>{};
  var item = 0;
  for (var c = 0; c < book.chapters.length; c++) {
    item++; // Empty metadata slots retain their item identity for old progress.
    for (var p = 0; p < book.chapters[c].paragraphs.length; p++) { source[item++] = (c, p); }
  }
  final body = find.byKey(const ValueKey('reader-body'));
  final active = tester.widget<ScrollablePositionedList>(body).itemPositionsNotifier!.itemPositions.value.toList();
  final renders = <int, RenderParagraph>{};
  for (final element in find.descendant(of: body, matching: find.byType(RichText)).evaluate()) {
    int? index;
    element.visitAncestorElements((ancestor) {
      final key = ancestor.widget.key;
      if (key is ValueKey<int>) { index = key.value; return false; }
      return true;
    });
    final render = element.findRenderObject();
    if (source.containsKey(index) && active.any((position) => position.index == index) &&
      render is RenderParagraph && render.attached && render.hasSize) { renders[index!] = render; }
  }
  final visible = active.where((position) => position.itemTrailingEdge > 0 && position.itemLeadingEdge < 1 && renders.containsKey(position.index)).toList()
    ..sort((a, b) => a.index.compareTo(b.index));
  expect(visible, isNotEmpty);
  final anchor = renders[visible.first.index]!;
  final viewport = RenderAbstractViewport.of(anchor);
  final clipFinder = find.byKey(const ValueKey('reader-page-clip'));
  final widget = tester.widget<ClipRect>(clipFinder), size = tester.getSize(clipFinder);
  final clip = includeUnpainted ? tester.getRect(body) :
    (widget.clipper?.getClip(size) ?? (Offset.zero & size)).shift(tester.getTopLeft(clipFinder));
  final rows = <_Row>[];
  for (final entry in renders.entries) {
    final render = entry.value;
    if (RenderAbstractViewport.maybeOf(render) != viewport) continue;
    final text = render.text.toPlainText();
    final grouped = <int, Rect>{};
    for (final box in render.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: text.length),
      boxHeightStyle: ui.BoxHeightStyle.tight)) {
      final rect = box.toRect();
      if (rect.width < 0.01 || rect.height < 2) continue;
      final a = render.getPositionForOffset(Offset(-1, rect.center.dy)).offset;
      final b = render.getPositionForOffset(Offset(render.size.width + 1, rect.center.dy)).offset;
      final offset = a < b ? a : b;
      grouped.update(offset, (previous) => previous.expandToInclude(rect), ifAbsent: () => rect);
    }
    final top = render.localToGlobal(Offset.zero).dy;
    for (final row in grouped.entries) {
      final rect = row.value.shift(Offset(render.localToGlobal(Offset.zero).dx, top));
      if (includeUnpainted && (rect.top < clip.top - .25 || rect.bottom > clip.bottom + .25)) continue;
      if (rect.bottom <= clip.top + 0.25 || rect.top >= clip.bottom - 0.25) continue;
      expect(rect.top, greaterThanOrEqualTo(clip.top - 0.25));
      expect(rect.bottom, lessThanOrEqualTo(clip.bottom + 0.25));
      final location = source[entry.key]!;
      final offset = text.substring(0, row.key).replaceAll(RegExp('[\u200B\uFFFC\n]'), '').length;
      rows.add((chapter: location.$1, paragraph: location.$2, offset: offset,
        key: '${entry.key}/${row.key}', rect: rect));
    }
  }
  rows.sort((a, b) => a.rect.top.compareTo(b.rect.top));
  expect(rows, isNotEmpty);
  return rows;
}

void _expectSpeechAtPageStart(WidgetTester tester, Book book, _Speech speech) {
  final rows = _rows(tester, book), first = rows.first;
  expect(_spacingPolicy, isNotNull);
  expect(_spacingPolicy!.fixedRows, isFalse);
  expect(rows.map((row) => row.key), orderedEquals(_rows(tester, book, includeUnpainted: true).map((row) => row.key)),
    reason: 'Speech follows every complete physically fitting source row, without a K cap');
  final body = tester.getRect(find.byKey(const ValueKey('reader-body')));
  expect(body.bottom - rows.last.rect.bottom,
    inInclusiveRange(-.25, _spacingPolicy!.rowPitch + _spacingPolicy!.spacing + .5));
  final paragraphs = book.chapters[first.chapter].paragraphs;
  final paragraph = paragraphs[first.paragraph];
  final sentenceIndex = paragraph.sentences.indexWhere((sentence) => sentence.displayEnd > first.offset);
  expect(sentenceIndex, greaterThanOrEqualTo(0));
  final sentence = paragraph.sentences[sentenceIndex];
  final index = paragraphs.take(first.paragraph).fold<int>(0, (total, p) => total + p.sentences.length) + sentenceIndex;
  final relative = first.offset > sentence.displayStart ? first.offset - sentence.displayStart : 0;
  final offset = const TextCleaner().clean(sentence.display).ttsOffsetOfDisplay(relative);
  expect((speech.chapter, speech.index, speech.offset), (first.chapter, index, offset),
    reason: 'Heading styling, untitled chunks and chapter boundaries must preserve the actual first complete source glyph and exact TTS offset');
}

int _expectHeadingStyle(InlineSpan span, TextStyle inherited, double lineHeight) {
  if (span is! TextSpan) return 0;
  final style = inherited.merge(span.style);
  var checked = 0;
  if (span.text?.trim().isNotEmpty ?? false) {
    expect(style.fontSize, 26); expect(style.height, lineHeight); expect(style.fontWeight, FontWeight.bold); checked++;
  }
  for (final child in span.children ?? const <InlineSpan>[]) { checked += _expectHeadingStyle(child, style, lineHeight); }
  return checked;
}

Future<void> _turn(WidgetTester tester, int direction) async {
  final body = tester.getRect(find.byKey(const ValueKey('reader-body')));
  await tester.tapAt(Offset(direction > 0 ? body.right - 20 : body.left + 20, body.center.dy));
  await tester.pumpAndSettle();
}

Future<void> _complete(WidgetTester tester, Future<void> action) async {
  var done = false; Object? failure;
  action.then((_) { done = true; }, onError: (Object error) { failure = error; done = true; });
  await _until(tester, () => done);
  if (failure != null) throw failure!;
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var frame = 0; frame < 600 && !ready(); frame++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(ready(), isTrue, reason: 'Actual speech preparation and chapter transition must finish');
}

class _Speech extends TtsReader {
  _Speech() : super(player: _SilentPlayer());
  TtsState status = TtsState.idle;
  int chapter = -1, index = -1, offset = 0, serial = 0;
  List<String> sentences = const [];
  final played = <(int, int, int)>[];
  @override TtsState get state => status;
  @override int get currentIndex => index;
  @override int get currentTtsOffset => offset;
  void _state(TtsState value) { status = value; onStateChanged?.call(); }
  Future<void> _prepare() async {
    final owner = ++serial;
    await onPreparePlayback?.call(index, offset, () => owner == serial && status == TtsState.playing);
    if (owner == serial && status == TtsState.playing) {
      played.add((chapter, index, offset)); onWordChanged?.call(-1, -1); onSentenceChanged?.call(index);
    }
  }
  @override Future<void> start(List<String> values, {List<int>? offsets, List<int>? pauseAfterMilliseconds,
    int chapterIndex = 0, int from = 0, int initialTtsOffset = 0}) async {
    sentences = List.of(values); chapter = chapterIndex; index = from; offset = initialTtsOffset;
    _state(TtsState.playing); await _prepare();
  }
  Future<void> seek(int value) async { index = value; offset = 0; await _prepare(); }
  void completeChapter() { serial++; _state(TtsState.stopped); onCompleted?.call(); }
  @override Future<void> jumpTo(int value, {int ttsOffset = 0}) async {
    index = value; offset = ttsOffset; onSentenceChanged?.call(index);
    if (status == TtsState.playing) await _prepare();
  }
  @override Future<void> pause({bool interrupted = false}) async { serial++; _state(TtsState.paused); }
  @override Future<bool> resume() async { _state(TtsState.playing); await _prepare(); return true; }
  @override Future<void> stop() async { serial++; _state(TtsState.stopped); }
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
