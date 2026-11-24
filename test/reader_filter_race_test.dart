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

  for (final command in ['pause', 'stop', 'play']) {
    final name = command == 'play'
      ? 'user play during gated filter preparation resumes only the newly prepared queue'
      : 'user $command during gated filter preparation prevents stale speech restart';
    testWidgets(name, (tester) async {
      tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
      final entered = Completer<void>(), release = Completer<void>(), returned = Completer<void>();
      addTearDown(() { if (!release.isCompleted) release.complete(); });
      ReaderPreparation.runnerForTesting = (request) async {
        if (request.filter == 'ads') {
          if (!entered.isCompleted) entered.complete();
          await release.future;
          final prepared = ReaderPreparation.prepareSynchronously(request);
          if (!returned.isCompleted) returned.complete();
          return prepared;
        }
        return ReaderPreparation.prepareSynchronously(request);
      };
      final source = Book(id: 'filter-prepare-$command', title: '准备取消', filePath: '', format: BookFormat.txt,
        addedAt: DateTime(2026), chapters: [Chapter(title: '第一章', paragraphs: [
          ReadingText.paragraph('正文从这里开始。\n请下载APP阅读更多小说。\n后面的正文仍然存在。'),
        ])]);
      final storage = AppStorage(), speech = _RaceSpeech();
      await storage.saveSettings((ReadingSettings()..informationFilter = false..informationFilterLevel = 'ads'
        ..firstLineIndent = false..mergeNonSentenceBreaks = false).toJson());
      await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: source, storage: storage, ttsReader: speech)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('阅读设置')); await tester.pumpAndSettle();
      await _complete(tester, handler.play()); await tester.pumpAndSettle();
      expect(speech.starts, 1); expect(speech.state, TtsState.playing);
      final filter = find.byKey(const ValueKey('information-filter'));
      await tester.scrollUntilVisible(filter, 220,
        scrollable: find.descendant(of: find.byType(BottomSheet).last, matching: find.byType(Scrollable)).last);
      await tester.pumpAndSettle(); await tester.tap(filter);
      await _until(tester, () => entered.isCompleted);
      // The app has paused internally for reformatting. A new explicit user
      // pause still has to revoke the previously captured auto-resume intent.
      expect(speech.state, TtsState.paused);
      final startsAtIntent = speech.starts;
      final resumesAtIntent = speech.resumes;
      final playing = <bool>[];
      final subscription = handler.playbackState.listen((value) { playing.add(value.playing); });
      addTearDown(() { unawaited(subscription.cancel()); });
      await _complete(tester, switch (command) {
        'pause' => handler.pause(), 'stop' => handler.stop(), _ => handler.play(),
      });
      await tester.pumpAndSettle();
      expect(speech.starts, startsAtIntent, reason: 'A media command must not start the old queue while preparation is held');
      expect(speech.resumes, resumesAtIntent, reason: 'A play intent must not resume the old queue before new filtering is ready');
      expect(playing, everyElement(isFalse), reason: 'No playing notification may escape while the preparation gate is held');
      release.complete();
      await _until(tester, () => returned.isCompleted); await tester.pumpAndSettle();
      expect(playing, isNotEmpty);
      if (command == 'play') {
        expect(speech.starts, startsAtIntent + 1, reason: 'The latest play intent starts exactly one newly prepared queue');
        expect(speech.resumes, resumesAtIntent);
        expect(speech.lastSentences.join(), isNot(contains('下载APP')),
          reason: 'Playback must use the new filter rather than briefly resuming the old sentences');
        expect(speech.state, TtsState.playing); expect(handler.playbackState.value.playing, isTrue);
      } else {
        expect(speech.starts, startsAtIntent,
          reason: 'Late filter preparation must not start a new utterance after an explicit user $command');
        expect(speech.state, command == 'pause' ? TtsState.paused : TtsState.stopped);
        expect(playing, everyElement(isFalse), reason: 'No transient playing notification may escape after the user command');
        expect(handler.playbackState.value.playing, isFalse);
      }
      if (command == 'stop') {
        expect(find.byKey(const ValueKey('reading-panel')), findsNothing);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    }, timeout: const Timeout(Duration(seconds: 45)));
  }

  testWidgets('navigation during gated filter preparation preserves the latest page anchor', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    final entered = Completer<void>(), release = Completer<void>(), returned = Completer<void>();
    addTearDown(() { if (!release.isCompleted) release.complete(); });
    ReaderPreparation.runnerForTesting = (request) async {
      if (request.filter == 'ads') {
        entered.complete(); await release.future;
        final prepared = ReaderPreparation.prepareSynchronously(request);
        returned.complete(); return prepared;
      }
      return ReaderPreparation.prepareSynchronously(request);
    };
    final source = Book(id: 'filter-prepare-navigation', title: '过滤时继续翻页', filePath: '', format: BookFormat.txt,
      addedAt: DateTime(2026), chapters: [Chapter(title: '第一章', paragraphs: [
        ReadingText.paragraph(List.generate(100, (i) => '第${i}句，清晨的风吹过树林，远方的小路延伸到村庄。').join()),
        ReadingText.paragraph('请下载APP阅读更多小说。'),
      ])]);
    final storage = AppStorage();
    await storage.saveSettings((ReadingSettings()..informationFilter = false..informationFilterLevel = 'ads'
      ..pageTurnMode = 'tap'..pageTurnAnimation = 'off'..fontSize = 24..lineHeight = 1.8
      ..firstLineIndent = false..mergeNonSentenceBreaks = false).toJson());
    final speech = _RaceSpeech();
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: source, storage: storage, ttsReader: speech)));
    await tester.pumpAndSettle();
    tester.widget<ScrollablePositionedList>(find.byKey(const ValueKey('reader-body')))
      .itemScrollController!.jumpTo(index: 1);
    await tester.pumpAndSettle();
    final before = _firstBodyLine(tester);
    await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('阅读设置')); await tester.pumpAndSettle();
    final filter = find.byKey(const ValueKey('information-filter'));
    await tester.scrollUntilVisible(filter, 220,
      scrollable: find.descendant(of: find.byType(BottomSheet).last, matching: find.byType(Scrollable)).last);
    await tester.pumpAndSettle(); await tester.tap(filter);
    await _until(tester, () => entered.isCompleted);
    await tester.tapAt(const Offset(195, 60)); await tester.pumpAndSettle();
    if (find.byTooltip('阅读设置').evaluate().isNotEmpty) {
      await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
    }
    await tester.tapAt(const Offset(370, 380)); await tester.pumpAndSettle();
    final navigated = _firstBodyLine(tester);
    expect(navigated.text, isNot(before.text), reason: 'The actual user page turn must complete before preparation is released');
    release.complete(); await _until(tester, () => returned.isCompleted); await tester.pumpAndSettle();
    final restored = _firstBodyLine(tester);
    expect(restored.text, navigated.text, reason: 'Late preparation must rebase onto the latest surviving source anchor');
    expect(restored.top, closeTo(navigated.top, 0.5), reason: 'Installing the filtered text must not move the latest page');
    expect(speech.starts, 0); expect(handler.playbackState.value.playing, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(seconds: 45)));

  testWidgets('play from ordinary reading during gated filtering starts only the newly prepared queue', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    final entered = Completer<void>(), release = Completer<void>(), returned = Completer<void>();
    addTearDown(() { if (!release.isCompleted) release.complete(); });
    ReaderPreparation.runnerForTesting = (request) async {
      if (request.filter == 'ads') {
        entered.complete(); await release.future;
        final prepared = ReaderPreparation.prepareSynchronously(request);
        returned.complete(); return prepared;
      }
      return ReaderPreparation.prepareSynchronously(request);
    };
    final source = Book(id: 'filter-prepare-ordinary-play', title: '过滤后开始朗读', filePath: '', format: BookFormat.txt,
      addedAt: DateTime(2026), chapters: [Chapter(title: '第一章', paragraphs: [
        ReadingText.paragraph('正文从这里开始。\n请下载APP阅读更多小说。\n后面的正文仍然存在。'),
      ])]);
    final storage = AppStorage(), speech = _RaceSpeech();
    await storage.saveSettings((ReadingSettings()..informationFilter = false..informationFilterLevel = 'ads'
      ..firstLineIndent = false..mergeNonSentenceBreaks = false).toJson());
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: source, storage: storage, ttsReader: speech)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('阅读设置')); await tester.pumpAndSettle();
    final filter = find.byKey(const ValueKey('information-filter'));
    await tester.scrollUntilVisible(filter, 220,
      scrollable: find.descendant(of: find.byType(BottomSheet).last, matching: find.byType(Scrollable)).last);
    await tester.pumpAndSettle(); await tester.tap(filter);
    await _until(tester, () => entered.isCompleted);
    expect(speech.starts, 0); expect(speech.state, TtsState.idle);
    final playing = <bool>[];
    final subscription = handler.playbackState.listen((value) { playing.add(value.playing); });
    addTearDown(() { unawaited(subscription.cancel()); });
    await _complete(tester, handler.play()); await tester.pumpAndSettle();
    expect(speech.starts, 0, reason: 'Starting speech from ordinary reading must wait for the selected filter');
    expect(speech.resumes, 0);
    expect(playing, isNotEmpty); expect(playing, everyElement(isFalse));
    release.complete(); await _until(tester, () => returned.isCompleted); await tester.pumpAndSettle();
    expect(speech.starts, 1, reason: 'The retained play intent must enter reading mode once preparation finishes');
    expect(speech.resumes, 0);
    expect(speech.lastSentences.join(), isNot(contains('下载APP')),
      reason: 'The first utterance must already use the newly filtered text');
    expect(speech.lastSentences.join(), contains('正文从这里开始'));
    expect(speech.state, TtsState.playing); expect(handler.playbackState.value.playing, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(seconds: 45)));

  testWidgets('free scrolling during gated filter preparation preserves the latest visible line', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    final entered = Completer<void>(), release = Completer<void>(), returned = Completer<void>();
    addTearDown(() { if (!release.isCompleted) release.complete(); });
    ReaderPreparation.runnerForTesting = (request) async {
      if (request.filter == 'ads') {
        entered.complete(); await release.future;
        final prepared = ReaderPreparation.prepareSynchronously(request);
        returned.complete(); return prepared;
      }
      return ReaderPreparation.prepareSynchronously(request);
    };
    final source = Book(id: 'filter-prepare-free-scroll', title: '过滤时自由滚动', filePath: '', format: BookFormat.txt,
      addedAt: DateTime(2026), chapters: [Chapter(title: '第一章', paragraphs: [
        ReadingText.paragraph(List.generate(100, (i) => '第${i}句，清晨的风吹过树林，远方的小路延伸到村庄。').join()),
        ReadingText.paragraph('请下载APP阅读更多小说。'),
      ])]);
    final storage = AppStorage();
    await storage.saveSettings((ReadingSettings()..informationFilter = false..informationFilterLevel = 'ads'
      ..pageTurnMode = 'scroll'..pageTurnAnimation = 'off'..fontSize = 24..lineHeight = 1.8
      ..firstLineIndent = false..mergeNonSentenceBreaks = false).toJson());
    final speech = _RaceSpeech();
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: source, storage: storage, ttsReader: speech)));
    await tester.pumpAndSettle();
    final body = find.byKey(const ValueKey('reader-body'));
    tester.widget<ScrollablePositionedList>(body).itemScrollController!.jumpTo(index: 1);
    await tester.pumpAndSettle();
    final before = _firstBodyLine(tester);
    await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('阅读设置')); await tester.pumpAndSettle();
    final filter = find.byKey(const ValueKey('information-filter'));
    await tester.scrollUntilVisible(filter, 220,
      scrollable: find.descendant(of: find.byType(BottomSheet).last, matching: find.byType(Scrollable)).last);
    await tester.pumpAndSettle(); await tester.tap(filter);
    await _until(tester, () => entered.isCompleted);
    await tester.tapAt(const Offset(195, 60)); await tester.pumpAndSettle();
    if (find.byTooltip('阅读设置').evaluate().isNotEmpty) {
      await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
    }
    // This is a real free-scroll gesture. It must remain authoritative even
    // though it does not pass through the app's page-navigation generation.
    await tester.drag(body, const Offset(0, -470)); await tester.pumpAndSettle();
    final scrolled = _firstBodyLine(tester);
    expect(scrolled.text, isNot(before.text), reason: 'The user must actually scroll before preparation is released');
    release.complete(); await _until(tester, () => returned.isCompleted); await tester.pumpAndSettle();
    final restored = _firstBodyLine(tester);
    expect(restored.text, scrolled.text, reason: 'Late preparation must use the latest free-scroll source anchor');
    expect(restored.top, closeTo(scrolled.top, 0.5), reason: 'Reformatting must preserve the latest scroll pixel position');
    expect(speech.starts, 0); expect(handler.playbackState.value.playing, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(seconds: 45)));
}

({String text, double top}) _firstBodyLine(WidgetTester tester) {
  final viewport = tester.getRect(find.byKey(const ValueKey('reader-body')));
  final rows = <({String text, double top})>[];
  for (final element in find.byWidgetPredicate((widget) => widget is Text && widget.textAlign == TextAlign.justify).evaluate()) {
    final render = element.findRenderObject();
    if (render is! RenderParagraph || !render.attached) continue;
    final text = render.text.toPlainText();
    // Restrict measurements to the one long, surviving paragraph so cached
    // neighbouring slivers cannot supply an artificial visible paint position.
    if (!text.replaceAll('\u200B', '').startsWith('第0句')) continue;
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
  expect(ready(), isTrue, reason: 'The explicit preparation/media gate must be reached');
}

Future<void> _complete(WidgetTester tester, Future<void> operation) async {
  var complete = false; Object? failure;
  operation.then((_) { complete = true; }, onError: (Object error) { failure = error; complete = true; });
  await _until(tester, () => complete);
  if (failure != null) throw failure!;
}

class _RaceSpeech extends TtsReader {
  _RaceSpeech() : super(player: _RacePlayer());
  TtsState status = TtsState.idle;
  int starts = 0, resumes = 0, index = -1, offset = 0;
  List<String> lastSentences = const [];
  @override TtsState get state => status;
  @override int get currentIndex => index;
  @override int get currentTtsOffset => offset;
  void _state(TtsState value) { status = value; onStateChanged?.call(); }
  @override Future<void> start(List<String> sentences, {List<int>? offsets, List<int>? pauseAfterMilliseconds,
    int chapterIndex = 0, int from = 0, int initialTtsOffset = 0}) async {
    starts++; lastSentences = List.of(sentences); index = from; offset = initialTtsOffset;
    _state(TtsState.playing); onSentenceChanged?.call(from);
  }
  @override Future<void> pause({bool interrupted = false}) async { _state(TtsState.paused); }
  @override Future<bool> resume() async { resumes++; _state(TtsState.playing); return true; }
  @override Future<void> stop() async { _state(TtsState.stopped); }
}

class _RacePlayer implements AudioPlayer {
  @override PositionUpdater? positionUpdater;
  @override Stream<void> get onPlayerComplete => const Stream.empty();
  @override Stream<Duration> get onPositionChanged => const Stream.empty();
  @override Future<Duration?> getCurrentPosition() async => Duration.zero;
  @override Future<void> stop() async {}
  @override Future<void> pause() async {}
  @override Future<void> dispose() async { positionUpdater?.dispose(); }
  @override dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected player operation: ${invocation.memberName}');
}
