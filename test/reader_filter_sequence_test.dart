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
import 'package:duoduo_langdu/services/tts_audio_handler.dart';
import 'package:duoduo_langdu/services/tts_reader.dart';

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
    ReaderPreparation.clearMemoryCache(); globalAudioHandler = previous;
    unawaited(handler.playbackState.close()); unawaited(handler.mediaItem.close());
  });

  testWidgets('page intent after filtered installation waits for the restored visible page', (tester) async {
    _setView(tester);
    final storage = _InstallGateStorage();
    await _mount(tester, storage, 'post-install', animation: 'off');
    final original = _firstLine(tester);
    final expected = await _nextAndBack(tester, original);
    storage.armed = true;
    await _enableFilter(tester);
    await _until(tester, () => storage.entered.isCompleted);
    addTearDown(storage.releaseGate);
    await _closeSettings(tester);
    // This is later than the existing preparation gate tests: the new book
    // has already replaced the list but its visible anchor has not restored.
    expect(find.byType(RawImage), findsWidgets,
      reason: 'The old visible page must still cover the unfinished installation');
    await tester.tapAt(const Offset(370, 380));
    await tester.pump(const Duration(milliseconds: 16));
    storage.releaseGate();
    for (var frame = 0; frame < 16; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (find.byType(RawImage).evaluate().isEmpty) {
        expect(_firstLine(tester).text, anyOf(original.text, expected.text),
          reason: 'Temporary paragraph positioning must stay covered until a stable page is painted');
      }
    }
    await tester.pumpAndSettle();
    final actual = _firstLine(tester);
    expect(actual.text, expected.text,
      reason: 'A page request during installation must advance from the restored visible page, not be overwritten by its old anchor');
    expect(actual.top, closeTo(expected.top, 0.5));
    expect(find.byType(RawImage), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(seconds: 45)));

  testWidgets('installed snapshot retains a rapid next previous next intent sequence', (tester) async {
    _setView(tester);
    final storage = _InstallGateStorage();
    await _mount(tester, storage, 'post-install-ordered', animation: 'off');
    final original = _firstLine(tester);
    final expected = await _nextAndBack(tester, original);
    storage.armed = true;
    await _enableFilter(tester);
    await _until(tester, () => storage.entered.isCompleted);
    addTearDown(storage.releaseGate);
    await _closeSettings(tester);
    for (final x in [370.0, 20.0, 370.0]) {
      await tester.tapAt(Offset(x, 380)); await tester.pump(const Duration(milliseconds: 16));
    }
    storage.releaseGate(); await tester.pumpAndSettle();
    final actual = _firstLine(tester);
    expect(actual.text, expected.text, reason: 'Held manual inputs must execute in order on stable pages');
    expect(actual.top, closeTo(expected.top, 0.5));
    expect(find.byType(RawImage), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(seconds: 45)));

  testWidgets('settled filter installation preserves anchor and next-page boundary control', (tester) async {
    _setView(tester);
    final storage = AppStorage();
    await _mount(tester, storage, 'settled-control', animation: 'off');
    final original = _firstLine(tester);
    final expected = await _nextAndBack(tester, original);
    await _enableFilter(tester);
    await tester.pumpAndSettle();
    await _closeSettings(tester);
    final restored = _firstLine(tester);
    expect(restored.text, original.text, reason: 'The settled control must first preserve its existing page anchor');
    expect(restored.top, closeTo(original.top, 0.5));
    await tester.tapAt(const Offset(370, 380)); await tester.pumpAndSettle();
    final actual = _firstLine(tester);
    expect(actual.text, expected.text,
      reason: 'Filtering only material after this paragraph must not change its next-page boundary, even without concurrent input');
    expect(actual.top, closeTo(expected.top, 0.5));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(seconds: 45)));

  testWidgets('filter completion during an unfinished page turn preserves its destination', (tester) async {
    _setView(tester);
    final storage = AppStorage();
    await _mount(tester, storage, 'turn-install', animation: 'slide');
    final original = _firstLine(tester);
    final expected = await _nextAndBack(tester, original);
    final entered = Completer<void>(), release = Completer<void>();
    addTearDown(() { if (!release.isCompleted) release.complete(); });
    ReaderPreparation.clearMemoryCache();
    ReaderPreparation.runnerForTesting = (request) async {
      if (request.filter == 'ads') {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      }
      return ReaderPreparation.prepareSynchronously(request);
    };
    await _enableFilter(tester);
    await _until(tester, () => entered.isCompleted);
    await _closeSettings(tester);
    await tester.tapAt(const Offset(370, 380));
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byKey(const ValueKey('page-outgoing-transform')), findsOneWidget,
      reason: 'The actual user turn must still be active when preparation returns');
    release.complete();
    // Sample individual frames as well as the settled result. Intermediate
    // replacement must retain a page cover, never expose a temporary list jump.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final incoming = tester.widget<FractionalTranslation>(find.byKey(const ValueKey('page-incoming-transform')));
      if (incoming.translation != Offset.zero) {
        expect(find.byKey(const ValueKey('page-outgoing-transform')), findsOneWidget);
      }
    }
    await tester.pumpAndSettle();
    final actual = _firstLine(tester);
    expect(actual.text, expected.text,
      reason: 'Installing a completed filter must wait for the authoritative user page destination');
    expect(actual.top, closeTo(expected.top, 0.5));
    expect(find.byType(RawImage), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(seconds: 45)));

  testWidgets('rapid filter level and toggle edits publish only the latest prepared draft', (tester) async {
    _setView(tester);
    final storage = _RecordingStorage();
    await _mount(tester, storage, 'latest-draft', animation: 'off');
    final original = _firstLine(tester);
    final entered = Completer<void>(), release = Completer<void>();
    addTearDown(() { if (!release.isCompleted) release.complete(); });
    final preparations = <String>[];
    ReaderPreparation.clearMemoryCache();
    ReaderPreparation.runnerForTesting = (request) async {
      preparations.add(request.filter);
      if (request.filter == 'ads') {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      }
      return ReaderPreparation.prepareSynchronously(request);
    };
    storage.record = true;
    await _enableFilter(tester);
    await _until(tester, () => entered.isCompleted);
    // Scroll the lazy settings list as needed, while deliberately retaining
    // the preparation gate. Settling a menu scroll does not complete the
    // pending parse or serialize these newer drafts behind its installation.
    final scroll = find.descendant(of: find.byType(BottomSheet).last, matching: find.byType(Scrollable)).last;
    final links = find.byWidgetPredicate((widget) => widget is RadioListTile<String> && widget.value == 'links');
    await tester.scrollUntilVisible(links, 160, scrollable: scroll); await tester.pumpAndSettle();
    await tester.tap(links); await tester.pumpAndSettle();
    final extra = find.byWidgetPredicate((widget) => widget is RadioListTile<String> && widget.value == 'extra');
    await tester.scrollUntilVisible(extra, 160, scrollable: scroll); await tester.pumpAndSettle();
    await tester.tap(extra); await tester.pumpAndSettle();
    final filter = find.byKey(const ValueKey('information-filter'));
    await tester.scrollUntilVisible(filter, -160, scrollable: scroll); await tester.pumpAndSettle();
    await tester.tap(filter); await tester.pumpAndSettle();
    await tester.scrollUntilVisible(filter, -160, scrollable: scroll); await tester.pumpAndSettle();
    await tester.tap(filter); await tester.pumpAndSettle();
    await _closeSettings(tester);
    // Navigation while the old parse is held still belongs to ordinary
    // reading and must rebase the eventual final draft onto the latest page.
    await tester.tapAt(const Offset(370, 380)); await tester.pumpAndSettle();
    final navigated = _firstLine(tester);
    expect(navigated.text, isNot(original.text));
    release.complete(); await tester.pumpAndSettle();
    expect(preparations, ['ads', 'extra'],
      reason: 'Intermediate drafts may be coalesced before preparation begins');
    expect(storage.writes, isNotEmpty);
    expect(storage.writes.map((settings) => settings['informationFilterLevel']), everyElement('extra'),
      reason: 'The obsolete ads result must not be installed and persisted before the latest extra draft');
    expect(storage.writes.map((settings) => settings['informationFilter']), everyElement(isTrue));
    final actual = _firstLine(tester);
    expect(actual.text, navigated.text);
    expect(actual.top, closeTo(navigated.top, 0.5));
    expect(find.byType(RawImage), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(seconds: 45)));

  for (final playing in [true, false]) {
    testWidgets('manual reading-mode page turn during gated filtering retains ${playing ? 'playing' : 'paused'} intent and applies the filter', (tester) async {
      _setView(tester);
      final storage = _RecordingStorage(), speech = _SequenceSpeech();
      await _mount(tester, storage, 'reading-turn-$playing', animation: 'off', speech: speech);
      // Open the settings before entering reading mode through the media
      // session, matching the supported user route used in existing tests.
      if (find.byKey(const ValueKey('reader-menu')).evaluate().isEmpty) {
        await tester.tapAt(const Offset(195, 300)); await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('阅读设置')); await tester.pumpAndSettle();
      await _complete(tester, handler.play()); await tester.pumpAndSettle();
      if (!playing) { await _complete(tester, handler.pause()); await tester.pumpAndSettle(); }
      final entered = Completer<void>(), release = Completer<void>();
      addTearDown(() { if (!release.isCompleted) release.complete(); });
      ReaderPreparation.clearMemoryCache();
      ReaderPreparation.runnerForTesting = (request) async {
        if (request.filter == 'ads') { if (!entered.isCompleted) entered.complete(); await release.future; }
        return ReaderPreparation.prepareSynchronously(request);
      };
      storage.record = true;
      final filter = find.byKey(const ValueKey('information-filter'));
      await tester.scrollUntilVisible(filter, 220,
        scrollable: find.descendant(of: find.byType(BottomSheet).last, matching: find.byType(Scrollable)).last);
      await tester.pumpAndSettle(); await tester.tap(filter);
      await _until(tester, () => entered.isCompleted);
      await _closeSettings(tester);
      await tester.tapAt(const Offset(370, 380));
      await tester.pump(const Duration(milliseconds: 16));
      release.complete(); await tester.pumpAndSettle();
      expect(storage.writes.where((settings) => settings['informationFilter'] == true &&
        settings['informationFilterLevel'] == 'ads'), isNotEmpty,
        reason: 'A manual page seek must not cancel and silently consume the pending filter selection');
      expect(speech.state, playing ? TtsState.playing : TtsState.paused);
      expect(handler.playbackState.value.playing, playing);
      expect(find.byType(RawImage), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    }, timeout: const Timeout(Duration(seconds: 45)));
  }

  for (final requestPlay in [false, true]) {
    testWidgets('coalescing back to the original filter preserves cross-paragraph ${requestPlay ? 'playback' : 'progress'}', (tester) async {
      _setView(tester);
      final storage = _RecordingStorage(), speech = _SequenceSpeech();
      final id = 'same-draft-$requestPlay';
      await _mount(tester, storage, id, animation: 'off', speech: speech, extraBody: true);
      final entered = Completer<void>(), release = Completer<void>();
      addTearDown(() { if (!release.isCompleted) release.complete(); });
      ReaderPreparation.clearMemoryCache();
      ReaderPreparation.runnerForTesting = (request) async {
        if (request.filter == 'ads') { if (!entered.isCompleted) entered.complete(); await release.future; }
        return ReaderPreparation.prepareSynchronously(request);
      };
      storage.record = true;
      await _enableFilter(tester);
      await _until(tester, () => entered.isCompleted);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('information-filter'))).value, isTrue);
      await tester.tap(find.byKey(const ValueKey('information-filter'))); await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('information-filter'))).value, isFalse);
      await _closeSettings(tester);
      final body = find.byKey(const ValueKey('reader-body'));
      tester.widget<ScrollablePositionedList>(body).itemScrollController!.jumpTo(index: 2);
      await tester.pumpAndSettle();
      final navigated = _firstLine(tester, marker: '第二段第0句');
      await tester.pump(const Duration(milliseconds: 600)); await tester.pumpAndSettle();
      if (requestPlay) { await _complete(tester, handler.play()); await tester.pumpAndSettle(); }
      release.complete(); await tester.pumpAndSettle();
      expect(storage.writes, isNotEmpty);
      expect(storage.writes.map((settings) => settings['informationFilter']), everyElement(isFalse),
        reason: 'Returning to the original settings must discard the obsolete prepared version');
      expect(_firstLine(tester, marker: '第二段第0句').text, navigated.text);
      if (requestPlay) {
        expect(speech.state, TtsState.playing);
        expect(speech.lastSentences[speech.currentIndex], contains('第二段'),
          reason: 'Deferred play must begin in the newly navigated paragraph');
      } else {
        await tester.pump(const Duration(milliseconds: 600)); await tester.pumpAndSettle();
        final progress = await storage.loadProgress('filter-sequence-$id');
        expect(progress, isNotNull);
        expect(progress!.paragraphIndex, 1);
        expect(progress.percent, greaterThan(0),
          reason: 'The no-reformat fast path must retain the latest progress cursor, not the cursor from before preparation');
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    }, timeout: const Timeout(Duration(seconds: 45)));
  }
}

void _setView(WidgetTester tester) {
  tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
}

Future<void> _mount(WidgetTester tester, AppStorage storage, String id, {required String animation, _SequenceSpeech? speech, bool extraBody = false}) async {
  await storage.saveSettings((ReadingSettings()..informationFilter = false..informationFilterLevel = 'ads'
    ..pageTurnMode = 'tap'..pageTurnAnimation = animation..fontSize = 32..lineHeight = 1.8
    ..firstLineIndent = false..mergeNonSentenceBreaks = false).toJson());
  final book = Book(id: 'filter-sequence-$id', title: '过滤翻页交接', filePath: '', format: BookFormat.txt,
    addedAt: DateTime(2026), chapters: [Chapter(title: '第一章', paragraphs: [
      ReadingText.paragraph(List.generate(120, (i) => '第${i}句，山间的风吹过树林，远方的小路延伸到村庄。').join()),
      if (extraBody) ReadingText.paragraph(List.generate(120, (i) => '第二段第${i}句，清晨的阳光照亮了远方，读者已经翻到了这里。').join()),
      ReadingText.paragraph('请下载APP阅读更多小说。'),
    ])]);
  await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: book, storage: storage, ttsReader: speech ?? _SequenceSpeech())));
  await tester.pumpAndSettle();
  final body = find.byKey(const ValueKey('reader-body'));
  tester.widget<ScrollablePositionedList>(body).itemScrollController!.jumpTo(index: 1);
  await tester.pumpAndSettle();
  unawaited(tester.widget<ScrollablePositionedList>(body).scrollOffsetController!.animateScroll(
    offset: 700, duration: const Duration(milliseconds: 1)));
  await tester.pumpAndSettle();
  final delta = _firstLine(tester).top - tester.getTopLeft(body).dy;
  unawaited(tester.widget<ScrollablePositionedList>(body).scrollOffsetController!.animateScroll(
    offset: delta, duration: const Duration(milliseconds: 1)));
  await tester.pumpAndSettle();
}

Future<({String text, double top})> _nextAndBack(WidgetTester tester, ({String text, double top}) original) async {
  await tester.tapAt(const Offset(370, 380)); await tester.pumpAndSettle();
  final next = _firstLine(tester);
  expect(next.text, isNot(original.text));
  await tester.tapAt(const Offset(20, 380)); await tester.pumpAndSettle();
  expect(_firstLine(tester).text, original.text);
  return next;
}

Future<void> _enableFilter(WidgetTester tester) async {
  if (find.byKey(const ValueKey('reader-menu')).evaluate().isEmpty) {
    await tester.tapAt(const Offset(195, 300)); await tester.pumpAndSettle();
  }
  await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('阅读设置')); await tester.pumpAndSettle();
  final filter = find.byKey(const ValueKey('information-filter'));
  await tester.scrollUntilVisible(filter, 220,
    scrollable: find.descendant(of: find.byType(BottomSheet).last, matching: find.byType(Scrollable)).last);
  await tester.pumpAndSettle(); await tester.tap(filter);
}

Future<void> _closeSettings(WidgetTester tester) async {
  await tester.tapAt(const Offset(195, 60)); await tester.pumpAndSettle();
  if (find.byTooltip('阅读设置').evaluate().isNotEmpty) {
    await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
  }
}

({String text, double top}) _firstLine(WidgetTester tester, {String marker = '第0句'}) {
  final viewport = tester.getRect(find.byKey(const ValueKey('reader-body')));
  final rows = <({String text, double top})>[];
  for (final element in find.byWidgetPredicate((widget) => widget is Text && widget.textAlign == TextAlign.justify).evaluate()) {
    final render = element.findRenderObject();
    if (render is! RenderParagraph || !render.attached) continue;
    final text = render.text.toPlainText();
    if (!text.replaceAll('\u200B', '').startsWith(marker)) continue;
    final origin = render.localToGlobal(Offset.zero);
    for (final box in render.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: text.length),
      boxHeightStyle: ui.BoxHeightStyle.tight)) {
      final rect = box.toRect().shift(origin);
      if (rect.width < 0.01 || rect.height < 2 || rect.top < viewport.top - 0.25 || rect.bottom > viewport.bottom + 0.25) continue;
      final a = render.getPositionForOffset(Offset(-1, box.toRect().center.dy)).offset;
      final b = render.getPositionForOffset(Offset(render.size.width + 1, box.toRect().center.dy)).offset;
      final line = text.substring(a < b ? a : b, a < b ? b : a).replaceAll(RegExp('[\u200B\n]'), '');
      if (line.trim().isNotEmpty) rows.add((text: line, top: rect.top));
    }
  }
  rows.sort((a, b) => a.top.compareTo(b.top));
  expect(rows, isNotEmpty); return rows.first;
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var frame = 0; frame < 180 && !ready(); frame++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(ready(), isTrue, reason: 'The explicit configuration gate must be reached');
}

Future<void> _complete(WidgetTester tester, Future<void> operation) async {
  var complete = false; Object? failure;
  operation.then((_) { complete = true; }, onError: (Object error) { failure = error; complete = true; });
  await _until(tester, () => complete);
  if (failure != null) throw failure!;
}

class _InstallGateStorage extends AppStorage {
  bool armed = false;
  final entered = Completer<void>(), release = Completer<void>();
  void releaseGate() { if (!release.isCompleted) release.complete(); }
  @override Future<void> saveSettings(Map<String, dynamic> settings) async {
    if (armed && settings['informationFilter'] == true && !entered.isCompleted) {
      entered.complete(); await release.future;
    }
    await super.saveSettings(settings);
  }
}

class _RecordingStorage extends AppStorage {
  bool record = false;
  final writes = <Map<String, dynamic>>[];
  @override Future<void> saveSettings(Map<String, dynamic> settings) async {
    if (record) writes.add(Map<String, dynamic>.of(settings));
    await super.saveSettings(settings);
  }
}

class _SequenceSpeech extends TtsReader {
  _SequenceSpeech() : super(player: _SequencePlayer());
  TtsState status = TtsState.idle;
  int index = -1, offset = 0;
  List<String> lastSentences = const [];
  @override TtsState get state => status;
  @override int get currentIndex => index;
  @override int get currentTtsOffset => offset;
  void _state(TtsState value) { status = value; onStateChanged?.call(); }
  @override Future<void> start(List<String> sentences, {List<int>? offsets, List<int>? pauseAfterMilliseconds,
    int chapterIndex = 0, int from = 0, int initialTtsOffset = 0}) async {
    lastSentences = List.of(sentences); index = from; offset = initialTtsOffset;
    _state(TtsState.playing); onSentenceChanged?.call(from);
  }
  @override Future<void> pause({bool interrupted = false}) async { _state(TtsState.paused); }
  @override Future<bool> resume() async { _state(TtsState.playing); return true; }
  @override Future<void> stop() async { _state(TtsState.stopped); }
  @override Future<void> jumpTo(int sentenceIndex, {int ttsOffset = 0}) async {
    index = sentenceIndex; offset = ttsOffset; onSentenceChanged?.call(sentenceIndex);
  }
}
class _SequencePlayer implements AudioPlayer {
  @override PositionUpdater? positionUpdater;
  @override Stream<void> get onPlayerComplete => const Stream.empty();
  @override Stream<Duration> get onPositionChanged => const Stream.empty();
  @override Future<Duration?> getCurrentPosition() async => Duration.zero;
  @override Future<void> stop() async {}
  @override Future<void> pause() async {}
  @override Future<void> dispose() async { positionUpdater?.dispose(); }
  @override dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected player operation: ${invocation.memberName}');
}
