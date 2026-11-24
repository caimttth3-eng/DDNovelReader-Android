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
import 'package:duoduo_langdu/services/reading_text.dart';
import 'package:duoduo_langdu/services/system_tts.dart';
import 'package:duoduo_langdu/services/text_cleaner.dart';
import 'package:duoduo_langdu/services/tts_audio_handler.dart';
import 'package:duoduo_langdu/services/tts_reader.dart';

final _uniqueBodyGlyph = RegExp('[\u3400-\u4DBF]');

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  TtsAudioHandler? previous;
  late TtsAudioHandler handler;
  setUp(() async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    SharedPreferences.setMockInitialValues({});
    ReaderPreparation.clearMemoryCache();
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
    ReaderPreparation.clearMemoryCache();
    globalAudioHandler = previous;
    unawaited(handler.playbackState.close()); unawaited(handler.mediaItem.close());
  });

  testWidgets('real speech preparation keeps unique target glyphs visible across cached paragraph seeks', (tester) async {
    _setView(tester);
    final source = _fixture('prepare-cached');
    final storage = AppStorage(), speech = _PreparingSpeech();
    await _mount(tester, source, storage, speech);
    await _complete(tester, handler.play()); await tester.pumpAndSettle();
    final projected = await _projected(source, storage);
    final indices = [for (var i = 0; i < speech.sentences.length; i++)
      if (_uniqueBodyGlyph.hasMatch(speech.sentences[i])) i].take(28).toList();
    expect(indices.length, 28);
    // Unlike earlier fakes, seek awaits the exact onPreparePlayback hook used
    // by TtsReader before publishing a sentence. Reverse traversal visits text
    // cached before the indexed viewport's centre as well as text after it.
    for (final index in [...indices, ...indices.reversed]) {
      await _complete(tester, speech.seek(index)); await tester.pumpAndSettle();
      final target = _uniqueBodyGlyph.firstMatch(speech.sentences[index])!.group(0)!;
      _expectGlyphVisible(tester, projected, target, reason: 'Prepared sentence $index must be physically inside the page');
    }
    expect(speech.preparations, greaterThan(50));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(seconds: 90)));

  for (final paused in [false, true]) {
    testWidgets('filtered mixed paragraphs start and resume at each manual page first glyph paused=$paused', (tester) async {
      _setView(tester);
      final source = _fixture('manual-$paused');
      final storage = AppStorage(), speech = _PreparingSpeech();
      await _mount(tester, source, storage, speech);
      // Each projection contains actual inline URLs and separate ad/author
      // paragraphs, so changing the level changes items on these pages.
      for (final level in ['links', 'ads', 'extra', 'links', 'extra', 'ads']) {
        await _setFilter(tester, level);
        final projected = await _projected(source, storage);
        await _complete(tester, handler.play()); await tester.pumpAndSettle();
        _expectSpeechAtPageStart(tester, projected, speech, phase: '$level start');
        if (paused) { await _complete(tester, handler.pause()); await tester.pumpAndSettle(); }
        for (final direction in [1, 1, -1, 1, -1, -1]) {
          await tester.tapAt(Offset(direction > 0 ? 370 : 20, 380));
          await tester.pumpAndSettle();
          if (paused) { await _complete(tester, handler.play()); await tester.pumpAndSettle(); }
          _expectSpeechAtPageStart(tester, projected, speech, phase: '$level direction=$direction');
          if (paused) { await _complete(tester, handler.pause()); await tester.pumpAndSettle(); }
        }
        await _complete(tester, handler.stop()); await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    }, timeout: const Timeout(Duration(seconds: 120)));
  }

  testWidgets('immediate resume after a paused page turn waits for the asynchronous speech seek', (tester) async {
    _setView(tester);
    final source = _fixture('deferred-seek');
    final storage = AppStorage(), speech = _DeferredSeekSpeech();
    await _mount(tester, source, storage, speech);
    await _complete(tester, handler.play()); await tester.pumpAndSettle();
    await _complete(tester, handler.pause()); await tester.pumpAndSettle();
    final projected = await _projected(source, storage);
    final gate = speech.holdNextSeek();
    addTearDown(() { if (!gate.isCompleted) gate.complete(); });
    await tester.tapAt(const Offset(370, 380)); await tester.pumpAndSettle();
    expect(speech.seekEntered.isCompleted, isTrue,
      reason: 'This fixture must hold the real asynchronous part of a manual page seek');
    final target = _pageStartCursor(tester, projected);
    final before = speech.playedCursors.length;
    final resume = handler.play();
    for (var frame = 0; frame < 12; frame++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 16));
    }
    final prematurePlayback = speech.playedCursors.skip(before).toList();
    gate.complete();
    await _complete(tester, resume); await tester.pumpAndSettle();
    expect(prematurePlayback, isEmpty,
      reason: 'A resume must not play or repaginate to the old sentence while the requested page seek is stopping its old player');
    expect((speech.index, speech.offset), target,
      reason: 'A quick resume must retain the page seek even if stopping old speech completes later');
    expect(_pageStartCursor(tester, projected), target,
      reason: 'Resuming must not silently pull the screen back to the old speech page');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('explicit pause cancels a resume waiting for a page seek without discarding its target', (tester) async {
    _setView(tester);
    final source = _fixture('deferred-seek-cancel');
    final storage = AppStorage(), speech = _DeferredSeekSpeech();
    await _mount(tester, source, storage, speech);
    await _complete(tester, handler.play()); await tester.pumpAndSettle();
    await _complete(tester, handler.pause()); await tester.pumpAndSettle();
    final projected = await _projected(source, storage);
    final gate = speech.holdNextSeek();
    addTearDown(() { if (!gate.isCompleted) gate.complete(); });
    await tester.tapAt(const Offset(370, 380)); await tester.pumpAndSettle();
    expect(speech.seekEntered.isCompleted, isTrue);
    final target = _pageStartCursor(tester, projected);
    final before = speech.playedCursors.length;
    final resume = handler.play();
    await tester.pump(const Duration(milliseconds: 16));
    await _complete(tester, handler.pause()); await tester.pumpAndSettle();
    gate.complete();
    await _complete(tester, resume); await tester.pumpAndSettle();
    expect(speech.playedCursors.skip(before), isEmpty,
      reason: 'Explicit pause must revoke the waiting play intent before either the old or target sentence can start');
    expect(speech.state, TtsState.paused);
    expect(handler.playbackState.value.playing, isFalse);
    expect((speech.index, speech.offset), target,
      reason: 'Cancelling playback must retain the separately requested page seek');
    expect(_pageStartCursor(tester, projected), target);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(seconds: 60)));
}

void _setView(WidgetTester tester) {
  tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
}

Book _fixture(String id) => Book(id: 'speech-stress-$id', title: '跨段语音坐标', filePath: '', format: BookFormat.txt,
  addedAt: DateTime(2026), chapters: [Chapter(title: '第一章', paragraphs: [
    for (var paragraph = 0; paragraph < 32; paragraph++) ...[
      ReadingText.paragraph((() {
        final body = String.fromCharCodes(List.generate(70, (i) => 0x3400 + paragraph * 70 + i));
        return '${body.substring(0, 20)}，${body.substring(20, 35)}。${body.substring(35)}。';
      })()),
      if (paragraph % 2 == 0) ReadingText.paragraph('网址 https://example.invalid/$paragraph 邮箱 row$paragraph@example.invalid。'),
      if (paragraph % 3 == 0) ReadingText.paragraph('请下载APP阅读更多小说，编号$paragraph。'),
      if (paragraph % 4 == 0) ReadingText.paragraph('作者有话说：请投票支持，编号$paragraph。'),
    ],
  ])]);

Future<void> _mount(WidgetTester tester, Book source, AppStorage storage, _PreparingSpeech speech) async {
  await storage.saveSettings((ReadingSettings()..informationFilter = false..informationFilterLevel = 'links'
    ..pageTurnMode = 'tap'..pageTurnAnimation = 'off'..fontSize = 32..lineHeight = 1.8
    ..firstLineIndent = false..mergeNonSentenceBreaks = false).toJson());
  await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: source, storage: storage, ttsReader: speech)));
  await tester.pumpAndSettle();
  final body = find.byKey(const ValueKey('reader-body'));
  tester.widget<ScrollablePositionedList>(body).itemScrollController!.jumpTo(index: 1);
  await tester.pumpAndSettle();
}

Future<Book> _projected(Book source, AppStorage storage) async {
  final settings = ReadingSettings.fromJson(await storage.loadSettings());
  return ReadingText.format(source, merge: settings.mergeNonSentenceBreaks, indent: settings.firstLineIndent,
    filter: settings.informationFilter ? settings.informationFilterLevel : 'none', pauseSettings: settings.effectiveSpeechPauses);
}

Future<void> _setFilter(WidgetTester tester, String level) async {
  if (find.byKey(const ValueKey('reader-menu')).evaluate().isEmpty) {
    await tester.tapAt(const Offset(195, 300)); await tester.pumpAndSettle();
  }
  await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('阅读设置')); await tester.pumpAndSettle();
  final scroll = find.descendant(of: find.byType(BottomSheet).last, matching: find.byType(Scrollable)).last;
  final filter = find.byKey(const ValueKey('information-filter'));
  await tester.scrollUntilVisible(filter, 220, scrollable: scroll); await tester.pumpAndSettle();
  if (!tester.widget<SwitchListTile>(filter).value) { await tester.tap(filter); await tester.pumpAndSettle(); }
  final radio = find.byWidgetPredicate((widget) => widget is RadioListTile<String> && widget.value == level);
  await tester.scrollUntilVisible(radio, 160, scrollable: scroll); await tester.pumpAndSettle();
  await tester.tap(radio); await tester.pumpAndSettle();
  // Exercise an off/on cycle after the level change, while preserving the
  // latest settings draft in the actual menu rather than calling reader state.
  await tester.scrollUntilVisible(filter, -160, scrollable: scroll); await tester.pumpAndSettle();
  await tester.tap(filter); await tester.pumpAndSettle();
  await tester.tap(filter); await tester.pumpAndSettle();
  await tester.tapAt(const Offset(195, 60)); await tester.pumpAndSettle();
  if (find.byTooltip('阅读设置').evaluate().isNotEmpty) {
    await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
  }
}

String _plain(String text) => text.replaceAll(RegExp(r'[\u200B\uFFFC\s]'), '');

Map<int, RenderParagraph> _renders(WidgetTester tester, Book projected) {
  final paragraphs = projected.chapters.single.paragraphs;
  final body = find.byKey(const ValueKey('reader-body'));
  final positions = tester.widget<ScrollablePositionedList>(body).itemPositionsNotifier!.itemPositions.value;
  final activeItems = positions.map((position) => position.index).toSet();
  expect(activeItems, isNotEmpty, reason: 'The oracle needs the indexed list actual item positions');
  final renders = <int, RenderParagraph>{};
  for (final element in find.descendant(of: body,
    matching: find.byWidgetPredicate((widget) => widget is Text && widget.textAlign == TextAlign.justify)).evaluate()) {
    int? itemIndex;
    element.visitAncestorElements((ancestor) {
      final key = ancestor.widget.key;
      if (key is ValueKey<int>) { itemIndex = key.value; return false; }
      return true;
    });
    // Virtualized lists may retain inactive text renderers with clamped paint
    // transforms inside the same viewport. They are not painted source items;
    // viewport identity and a plausible reveal offset alone cannot admit them.
    if (itemIndex == null || !activeItems.contains(itemIndex)) continue;
    final render = element.findRenderObject();
    if (render is! RenderParagraph || !render.attached) continue;
    final actualText = _plain(render.text.toPlainText());
    if (actualText.isEmpty) continue;
    final paragraph = itemIndex! - 1;
    expect(paragraph, inInclusiveRange(0, paragraphs.length - 1));
    expect(actualText, _plain(paragraphs[paragraph].display),
      reason: 'The active item identity must match its own projected paragraph even when other paragraphs have identical filtered text');
    renders[itemIndex!] = render;
  }
  return renders;
}

({RenderAbstractViewport viewport, double origin}) _coordinates(WidgetTester tester, Map<int, RenderParagraph> renders) {
  final list = tester.widget<ScrollablePositionedList>(find.byKey(const ValueKey('reader-body')));
  final positions = list.itemPositionsNotifier!.itemPositions.value
    .where((item) => item.itemTrailingEdge > 0 && item.itemLeadingEdge < 1 && renders.containsKey(item.index)).toList()
      ..sort((a, b) => a.index.compareTo(b.index));
  expect(positions, isNotEmpty);
  final anchor = renders[positions.first.index]!;
  final viewport = RenderAbstractViewport.of(anchor);
  return (viewport: viewport, origin: anchor.localToGlobal(Offset.zero).dy - viewport.getOffsetToReveal(anchor, 0).offset);
}

Rect _clip(WidgetTester tester) {
  final finder = find.byKey(const ValueKey('reader-page-clip'));
  final widget = tester.widget<ClipRect>(finder), size = tester.getSize(finder);
  return (widget.clipper?.getClip(size) ?? (Offset.zero & size)).shift(tester.getTopLeft(finder));
}

void _expectGlyphVisible(WidgetTester tester, Book projected, String character, {required String reason}) {
  final renders = _renders(tester, projected), coordinates = _coordinates(tester, _renders(tester, projected));
  final matching = renders.values.where((render) => render.text.toPlainText().contains(character)).toList();
  expect(matching, hasLength(1), reason: reason);
  final render = matching.single, offset = render.text.toPlainText().indexOf(character);
  final boxes = render.getBoxesForSelection(TextSelection(baseOffset: offset, extentOffset: offset + 1),
    boxHeightStyle: ui.BoxHeightStyle.tight);
  expect(boxes, isNotEmpty, reason: reason);
  final rect = boxes.first.toRect().shift(Offset(render.localToGlobal(Offset.zero).dx,
    coordinates.viewport.getOffsetToReveal(render, 0).offset + coordinates.origin));
  final clip = _clip(tester);
  expect(rect.top, greaterThanOrEqualTo(clip.top - 0.25), reason: reason);
  expect(rect.bottom, lessThanOrEqualTo(clip.bottom + 0.25), reason: reason);
}

(int, int) _pageStartCursor(WidgetTester tester, Book projected, {_PreparingSpeech? diagnostics, String phase = ''}) {
  final renders = _renders(tester, projected), coordinates = _coordinates(tester, _renders(tester, projected));
  final clip = _clip(tester);
  final rows = <({int paragraph, int displayOffset, double top})>[];
  for (final entry in renders.entries) {
    final render = entry.value;
    if (RenderAbstractViewport.maybeOf(render) != coordinates.viewport) continue;
    final text = render.text.toPlainText();
    final origin = Offset(render.localToGlobal(Offset.zero).dx,
      coordinates.viewport.getOffsetToReveal(render, 0).offset + coordinates.origin);
    for (final box in render.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: text.length),
      boxHeightStyle: ui.BoxHeightStyle.tight)) {
      final rect = box.toRect().shift(origin);
      if (rect.width < 0.01 || rect.height < 2) continue;
      if (rect.top >= clip.top - 0.25 && rect.bottom <= clip.bottom + 0.25) {
        final a = render.getPositionForOffset(Offset(-1, box.toRect().center.dy)).offset;
        final b = render.getPositionForOffset(Offset(render.size.width + 1, box.toRect().center.dy)).offset;
        final start = a < b ? a : b;
        final displayOffset = text.substring(0, start).replaceAll(RegExp('[\u200B\uFFFC\n]'), '').length;
        rows.add((paragraph: entry.key - 1, displayOffset: displayOffset, top: rect.top));
      }
    }
  }
  rows.sort((a, b) => a.top.compareTo(b.top));
  expect(rows, isNotEmpty);
  final row = rows.first, paragraphs = projected.chapters.single.paragraphs;
  final paragraph = paragraphs[row.paragraph];
  final sentence = paragraph.sentences.indexWhere((s) => s.displayEnd > row.displayOffset);
  expect(sentence, greaterThanOrEqualTo(0));
  final expectedIndex = paragraphs.take(row.paragraph).fold(0, (sum, p) => sum + p.sentences.length) + sentence;
  final target = paragraph.sentences[sentence];
  final relative = row.displayOffset > target.displayStart ? row.displayOffset - target.displayStart : 0;
  final clean = const TextCleaner().clean(target.display);
  final mapped = clean.ttsOffsetOfDisplay(relative);
  final expectedOffset = mapped < target.tts.length ? mapped : 0;
  if (diagnostics != null && (diagnostics.index != expectedIndex || diagnostics.offset != expectedOffset)) {
    final speech = diagnostics;
    final list = tester.widget<ScrollablePositionedList>(find.byKey(const ValueKey('reader-body')));
    debugPrint('SPEECH_STRESS phase=$phase expected=$expectedIndex/$expectedOffset actual=${speech.index}/${speech.offset} '
      'sentences=${speech.sentences.length}/${paragraphs.fold<int>(0, (sum, p) => sum + p.sentences.length)} '
      'clip=$clip rows=${rows.take(8)} positions=${list.itemPositionsNotifier!.itemPositions.value.map((p) => '${p.index}:${p.itemLeadingEdge.toStringAsFixed(3)}/${p.itemTrailingEdge.toStringAsFixed(3)}')}');
    for (final entry in renders.entries) {
      final render = entry.value;
      debugPrint('SPEECH_STRESS item=${entry.key} raw=${render.localToGlobal(Offset.zero).dy} '
        'reveal=${coordinates.viewport.getOffsetToReveal(render, 0).offset + coordinates.origin} '
        'size=${render.size} prefix=${render.text.toPlainText().substring(0, 5)}');
    }
  }
  return (expectedIndex, expectedOffset);
}

void _expectSpeechAtPageStart(WidgetTester tester, Book projected, _PreparingSpeech speech, {String phase = ''}) {
  final target = _pageStartCursor(tester, projected, diagnostics: speech, phase: phase);
  expect(speech.index, target.$1,
    reason: 'An explicit manual page seek must select the actual first visible paragraph and sentence after filtered item changes');
  expect(speech.offset, target.$2,
    reason: 'An explicit manual page seek must start at the exact first visible source character, not the sentence beginning');
}

Future<void> _complete(WidgetTester tester, Future<void> action) async {
  var done = false; Object? failure;
  action.then((_) { done = true; }, onError: (Object error) { failure = error; done = true; });
  for (var frame = 0; frame < 240 && !done; frame++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(done, isTrue, reason: 'The real speech preparation hook must finish without getting stuck in pagination');
  if (failure != null) throw failure!;
}

class _PreparingSpeech extends TtsReader {
  _PreparingSpeech() : super(player: _SilentPlayer());
  TtsState status = TtsState.idle;
  int index = -1, offset = 0, preparations = 0, serial = 0;
  List<String> sentences = const [];
  final playedCursors = <(int, int)>[];
  @override TtsState get state => status;
  @override int get currentIndex => index;
  @override int get currentTtsOffset => offset;
  void _state(TtsState value) { status = value; onStateChanged?.call(); }
  Future<void> _prepare() async {
    final owner = ++serial;
    preparations++;
    await onPreparePlayback?.call(index, offset, () => owner == serial && status == TtsState.playing);
    if (owner == serial && status == TtsState.playing) {
      playedCursors.add((index, offset));
      onWordChanged?.call(-1, -1); onSentenceChanged?.call(index);
    }
  }
  @override Future<void> start(List<String> values, {List<int>? offsets, List<int>? pauseAfterMilliseconds,
    int chapterIndex = 0, int from = 0, int initialTtsOffset = 0}) async {
    sentences = List.of(values); index = from; offset = initialTtsOffset;
    _state(TtsState.playing); await _prepare();
  }
  Future<void> seek(int value) async {
    index = value; offset = 0; await _prepare();
  }
  @override Future<void> jumpTo(int value, {int ttsOffset = 0}) async {
    index = value; offset = ttsOffset; onSentenceChanged?.call(index);
    if (status == TtsState.playing) await _prepare();
  }
  @override Future<void> pause({bool interrupted = false}) async { serial++; _state(TtsState.paused); }
  @override Future<bool> resume() async { _state(TtsState.playing); await _prepare(); return true; }
  @override Future<void> stop() async { serial++; _state(TtsState.stopped); }
}

class _DeferredSeekSpeech extends _PreparingSpeech {
  Completer<void>? _seekGate;
  final seekEntered = Completer<void>();
  Completer<void> holdNextSeek() => _seekGate = Completer<void>();
  @override Future<void> pause({bool interrupted = false}) async {
    // A real TtsReader pause already in paused state only revokes resume/focus
    // intent; it does not invalidate the independent pending seek generation.
    if (status == TtsState.playing) serial++;
    _state(TtsState.paused);
  }
  @override Future<void> jumpTo(int value, {int ttsOffset = 0}) async {
    // TtsReader.jumpTo invalidates old speech, then awaits _stopInternal before
    // publishing its new index. A concurrent resume starts a new generation.
    final owner = ++serial, gate = _seekGate;
    _seekGate = null;
    if (gate != null) {
      if (!seekEntered.isCompleted) seekEntered.complete();
      await gate.future;
    }
    if (owner != serial) return;
    index = value; offset = ttsOffset; onSentenceChanged?.call(index);
    if (status == TtsState.playing) await _prepare();
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
