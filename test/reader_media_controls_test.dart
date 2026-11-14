import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:duoduo_langdu/models/book.dart';
import 'package:duoduo_langdu/screens/reader_screen.dart';
import 'package:duoduo_langdu/services/app_storage.dart';
import 'package:duoduo_langdu/services/app_appearance.dart';
import 'package:duoduo_langdu/services/tts_reader.dart';
import 'package:duoduo_langdu/services/tts_audio_handler.dart';
import 'package:duoduo_langdu/services/playback_notifications.dart';
import 'package:duoduo_langdu/services/display_cutout.dart';
import 'package:duoduo_langdu/services/network_connectivity.dart';
import 'package:duoduo_langdu/services/reading_text.dart';
import 'package:duoduo_langdu/services/reader_preparation.dart';
import 'package:duoduo_langdu/services/system_tts.dart';

Future<void> completeAction(WidgetTester tester, Future<void> action) async {
  var done = false;
  Object? failure;
  action.then((_) { done = true; }, onError: (Object error) { failure = error; done = true; });
  for (var frame = 0; frame < 120 && !done; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(done, isTrue, reason: 'The media callback must complete while widget frames and platform microtasks are pumped');
  if (failure != null) throw failure!;
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  late TtsAudioHandler handler;
  TtsAudioHandler? previous;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ReaderPreparation.runnerForTesting = (request) async => ReaderPreparation.prepareSynchronously(request);
    AppAppearance.setThemeMode('light');
    previous = globalAudioHandler; handler = TtsAudioHandler(); globalAudioHandler = handler;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('com.ddnovelreader/volume_keys'),
      (call) async => call.method == 'getMediaVolume' ? 0.5 : null);
    messenger.setMockMethodCallHandler(const MethodChannel('com.ddnovelreader/debug_log'), (_) async => null);
    messenger.setMockMethodCallHandler(DisplayCutoutService.channel, (_) async => null);
    messenger.setMockMethodCallHandler(NetworkConnectivity.channel, (_) async => null);
    messenger.setMockMethodCallHandler(PlaybackNotifications.channel, (_) async =>
      {'supported': false, 'enabled': false, 'canRequest': false, 'asked': false});
    messenger.setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers.global'), (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers.global/events'), (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers'), (call) async {
      if (call.method == 'create') {
        messenger.setMockMethodCallHandler(MethodChannel('xyz.luan/audioplayers/events/${(call.arguments as Map)['playerId']}'), (_) async => null);
      }
      return null;
    });
  });
  tearDown(() {
    globalAudioHandler = previous; ReaderPreparation.runnerForTesting = null;
    // Rx closes can wait for delivery in a widget test's already-finished fake
    // zone. Closing prevents further adds; explicit listeners cancel separately.
    unawaited(handler.playbackState.close()); unawaited(handler.mediaItem.close());
  });
  Book book(String id) => Book(id: id, title: '媒体暂停继续', filePath: '', format: BookFormat.txt,
    addedAt: DateTime(2026), chapters: [Chapter(title: '第一章',
      paragraphs: [ReadingText.paragraph('清晨山间的风吹过树林。朋友带来一封远方的来信。')])]);

  for (final voice in [TtsReader.defaultVoice, TtsReader.systemVoice]) {
    testWidgets('notification and screen pause/resume share one playback state for $voice', (tester) async {
      tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
      final storage = AppStorage(); await storage.saveSettings((ReadingSettings()..voice = voice).toJson());
      final speech = _MediaSpeech();
      await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: book(voice), storage: storage, ttsReader: speech)));
      await tester.pumpAndSettle(); await tester.tap(find.byTooltip('朗读')); await tester.pumpAndSettle();
      expect(handler.playbackState.value.playing, isTrue);
      await completeAction(tester, handler.pause()); await tester.pumpAndSettle();
      expect(speech.state, TtsState.paused); expect(handler.playbackState.value.playing, isFalse);
      expect(find.byKey(const ValueKey('reading-volume-slider')), findsOneWidget);
      await completeAction(tester, handler.play()); await tester.pumpAndSettle();
      expect(speech.resumes, 1); expect(handler.playbackState.value.playing, isTrue);
      expect(find.byKey(const ValueKey('reading-volume-slider')), findsNothing);
      await tester.tapAt(const Offset(195, 300)); await tester.pumpAndSettle();
      expect(handler.playbackState.value.playing, isFalse);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused); await tester.pump();
      await completeAction(tester, handler.play()); await tester.pumpAndSettle();
      expect(speech.resumes, 2); expect(handler.playbackState.value.playing, isTrue);
      await completeAction(tester, handler.pause()); await tester.pumpAndSettle();
      expect(speech.state, TtsState.paused); expect(handler.playbackState.value.playing, isFalse);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed); await tester.pumpAndSettle();
      await tester.tapAt(const Offset(195, 300)); await tester.pumpAndSettle();
      expect(speech.resumes, 3); expect(handler.playbackState.value.playing, isTrue);
      speech.changeState(TtsState.paused); await tester.pumpAndSettle();
      expect(handler.playbackState.value.playing, isFalse, reason: 'Actual service state must update the notification without a screen pause request');
      await completeAction(tester, handler.play()); await tester.pumpAndSettle();
      expect(speech.resumes, 4); expect(speech.starts, 1);
      expect(handler.playbackState.value.playing, isTrue); expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    }, timeout: const Timeout(Duration(seconds: 45)));
  }

  testWidgets('notification pause cancels a pending media play and can play again', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    final speech = _MediaSpeech()..pendingStart = Completer<void>();
    addTearDown(() { if (!speech.pendingStart!.isCompleted) speech.pendingStart!.complete(); });
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: book('pending-media'), storage: AppStorage(), ttsReader: speech)));
    await tester.pumpAndSettle();
    final starting = handler.play();
    for (var frame = 0; frame < 120 && speech.starts == 0; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(speech.starts, 1);
    final pausing = handler.pause(); await tester.pumpAndSettle();
    expect(speech.state, TtsState.paused); expect(handler.playbackState.value.playing, isFalse);
    await completeAction(tester, pausing); await completeAction(tester, starting);
    await completeAction(tester, handler.play()); await tester.pumpAndSettle();
    expect(speech.resumes, 1); expect(handler.playbackState.value.playing, isTrue);
    expect(find.byKey(const ValueKey('reading-volume-slider')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(seconds: 45)));

  testWidgets('a delayed volume read cannot block notification pause or the following play', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    var holdVolume = false;
    final pendingVolume = Completer<double>();
    addTearDown(() { if (!pendingVolume.isCompleted) pendingVolume.complete(0.5); });
    messenger.setMockMethodCallHandler(const MethodChannel('com.ddnovelreader/volume_keys'), (call) async {
      if (call.method == 'getMediaVolume') return holdVolume ? pendingVolume.future : 0.5;
      return null;
    });
    final speech = _MediaSpeech();
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: book('volume-does-not-block-media'), storage: AppStorage(), ttsReader: speech)));
    await tester.pumpAndSettle(); await tester.tap(find.byTooltip('朗读')); await tester.pumpAndSettle();
    speech.emitSentence(1); await tester.pumpAndSettle();
    holdVolume = true;
    var paused = false;
    final pauseRequest = handler.pause().then((_) { paused = true; });
    await tester.pumpAndSettle();
    expect(paused, isTrue, reason: 'Pause must finish while the independent volume request remains pending');
    expect(handler.playbackState.value.playing, isFalse);
    expect(find.byKey(const ValueKey('reading-volume-slider')), findsOneWidget);
    await completeAction(tester, pauseRequest); await completeAction(tester, handler.play()); await tester.pumpAndSettle();
    expect(speech.resumes, 1); expect(handler.playbackState.value.playing, isTrue);
    expect(find.byKey(const ValueKey('reading-volume-slider')), findsNothing);
    holdVolume = false; pendingVolume.complete(0.1); await tester.pumpAndSettle();
    expect(speech.currentIndex, 1); expect(speech.starts, 1); expect(speech.resumes, 1);
    expect(handler.playbackState.value.playing, isTrue); expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(seconds: 45)));

  testWidgets('system media text follows displayed sentences and toggles immediately without word-level updates', (tester) async {
    debugPrint('MEDIA_TEXT start');
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    final storage = AppStorage(); await storage.saveSettings((ReadingSettings()..firstLineIndent = false).toJson());
    final speech = _MediaSpeech(), items = <String?>[];
    final subscription = handler.mediaItem.listen((item) { items.add(item?.displaySubtitle); });
    addTearDown(() { unawaited(subscription.cancel()); });
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: book('media-text'), storage: storage, ttsReader: speech)));
    await tester.pumpAndSettle(); await tester.tap(find.byTooltip('朗读')); await tester.pumpAndSettle();
    expect(handler.mediaItem.value!.artist, '第一章'); expect(handler.mediaItem.value!.displaySubtitle, isNull);
    await completeAction(tester, handler.pause()); await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('playback-settings'))); await tester.pumpAndSettle();
    debugPrint('MEDIA_TEXT open');
    final toggle = find.byKey(const ValueKey('show-system-media-text'));
    await tester.ensureVisible(toggle); await tester.pumpAndSettle(); await tester.tap(toggle); await tester.pumpAndSettle();
    debugPrint('MEDIA_TEXT toggle-on');
    expect(handler.mediaItem.value!.displaySubtitle, '清晨山间的风吹过树林。');
    expect(handler.mediaItem.value!.artist, '清晨山间的风吹过树林。');
    await tester.tapAt(const Offset(195, 60)); await tester.pumpAndSettle();
    await completeAction(tester, handler.play()); await tester.pumpAndSettle();
    speech.emitSentence(1); await tester.pumpAndSettle();
    expect(handler.mediaItem.value!.displaySubtitle, '朋友带来一封远方的来信。');
    final count = items.length;
    speech.onWordChanged?.call(0, 2); speech.onWordChanged?.call(2, 4); await tester.pumpAndSettle();
    expect(items.length, count, reason: 'Real word ticks must not re-emit unchanged sentence metadata');
    await completeAction(tester, handler.pause()); await tester.pumpAndSettle();
    debugPrint('MEDIA_TEXT second-pause');
    await tester.tap(find.byKey(const ValueKey('playback-settings'))); await tester.pumpAndSettle();
    await tester.ensureVisible(toggle); await tester.pumpAndSettle(); await tester.tap(toggle); await tester.pumpAndSettle();
    debugPrint('MEDIA_TEXT toggle-off');
    expect(handler.mediaItem.value!.artist, '第一章'); expect(handler.mediaItem.value!.displaySubtitle, isNull);
    expect(handler.mediaItem.value!.extras!.containsKey('spokenText'), isFalse);
    await tester.tap(toggle); await tester.pumpAndSettle();
    expect(handler.mediaItem.value!.displaySubtitle, '朋友带来一封远方的来信。');
    await tester.tapAt(const Offset(195, 60)); await tester.pumpAndSettle(); await completeAction(tester, handler.stop()); await tester.pumpAndSettle();
    debugPrint('MEDIA_TEXT stop');
    expect(handler.mediaItem.value!.title, '媒体暂停继续'); expect(handler.mediaItem.value!.artist, '第一章');
    expect(handler.mediaItem.value!.displaySubtitle, isNull); expect(handler.mediaItem.value!.extras!.containsKey('spokenText'), isFalse);
    unawaited(subscription.cancel()); debugPrint('MEDIA_TEXT cancel'); expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    debugPrint('MEDIA_TEXT end');
  }, timeout: const Timeout(Duration(seconds: 45)));

  testWidgets('real system speech keeps its word through a delayed central pause, speed change and central resume', (tester) async {
    debugPrint('MEDIA_REAL start');
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    final spoken = <Map>[], stopEntered = Completer<void>();
    Completer<void>? stopGate;
    addTearDown(() { if (stopGate != null && !stopGate!.isCompleted) stopGate!.complete(); });
    Future<void> emit(String name, Map data) async {
      final handled = Completer<void>();
      messenger.handlePlatformMessage(SystemTtsClient.channel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall(name, data)), (_) => handled.complete());
      await handled.future;
    }
    messenger.setMockMethodCallHandler(SystemTtsClient.channel, (call) async {
      if (call.method == 'initialize') return 'phone-default-engine';
      if (call.method == 'stop' && stopGate != null) {
        if (!stopEntered.isCompleted) stopEntered.complete();
        await stopGate!.future;
      }
      if (call.method == 'speak') {
        final request = call.arguments as Map; spoken.add(request);
        unawaited(Future<void>.microtask(() => emit('start', {'id': request['id']})));
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemTtsClient.channel, null));
    final storage = AppStorage();
    await storage.saveSettings((ReadingSettings()..voice = TtsReader.systemVoice..firstLineIndent = false
      ..wordHighlightEnabled = true).toJson());
    const text = '甲乙丙丁戊己，庚辛壬癸。';
    final source = Book(id: 'real-system-center-rate', title: '中央点按与调速', filePath: '', format: BookFormat.txt,
      addedAt: DateTime(2026), chapters: [Chapter(title: '第一章', paragraphs: [ReadingText.paragraph(text)])]);
    final speech = TtsReader();
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: source, storage: storage, ttsReader: speech)));
    await tester.pumpAndSettle(); await tester.tap(find.byTooltip('朗读')); await tester.pumpAndSettle();
    expect(spoken, hasLength(1));
    final originalId = spoken.single['id'];
    await emit('range', {'id': originalId, 'start': 2, 'end': 4}); await tester.pumpAndSettle();
    debugPrint('MEDIA_REAL word');
    String highlightedWord() {
      final words = <String>[];
      void visit(InlineSpan span) {
        if (span is! TextSpan) return;
        if (span.style?.backgroundColor == const Color(0xFF9BC5DD)) {
          words.add(span.toPlainText().replaceAll('\u200B', '').replaceAll('\uFFFC', ''));
        }
        for (final child in span.children ?? <InlineSpan>[]) { visit(child); }
      }
      for (final widget in tester.widgetList<Text>(find.byType(Text))) {
        if (widget.textSpan != null) visit(widget.textSpan!);
      }
      return words.join();
    }
    expect(highlightedWord(), '丙丁'); expect(speech.currentTtsOffset, 2);
    stopGate = Completer<void>();
    await tester.tapAt(const Offset(195, 300)); await tester.pump();
    expect(stopEntered.isCompleted, isTrue); expect(speech.state, TtsState.paused);
    await emit('range', {'id': originalId, 'start': 0, 'end': 2}); await tester.pump();
    expect(highlightedWord(), '丙丁'); expect(speech.currentTtsOffset, 2);
    stopGate!.complete(); stopGate = null; await tester.pumpAndSettle();
    debugPrint('MEDIA_REAL pause');
    expect(find.byKey(const ValueKey('reading-rate-plus')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('reading-rate-plus'))); await tester.pumpAndSettle();
    expect(speech.speechRate, 1.1); expect(spoken, hasLength(1)); expect(highlightedWord(), '丙丁');
    await tester.tapAt(const Offset(195, 300)); await tester.pumpAndSettle();
    debugPrint('MEDIA_REAL resume');
    expect(spoken, hasLength(2)); expect(spoken.last['rate'], 1.1);
    expect(spoken.last['text'], '丙丁戊己，庚辛壬癸。', reason: 'The real engine request must start at the saved word, not an earlier viewport line');
    expect(speech.currentTtsOffset, 2); expect(highlightedWord(), '丙丁');
    await emit('range', {'id': originalId, 'start': 0, 'end': 2});
    await emit('range', {'id': spoken.last['id'], 'start': 0, 'end': 2}); await tester.pumpAndSettle();
    expect(speech.currentTtsOffset, 2); expect(highlightedWord(), '丙丁');
    expect(handler.playbackState.value.playing, isTrue); expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(seconds: 45)));
}

class _MediaSpeech extends TtsReader {
  TtsState status = TtsState.idle;
  int starts = 0, resumes = 0;
  int sentenceIndex = -1;
  Completer<void>? pendingStart;
  void changeState(TtsState state) { status = state; onStateChanged?.call(); }
  void emitSentence(int index) { sentenceIndex = index; onSentenceChanged?.call(index); }
  @override int get currentIndex => sentenceIndex;
  @override TtsState get state => status;
  @override Future<void> start(List<String> sentences, {List<int>? offsets, List<int>? pauseAfterMilliseconds,
    int chapterIndex = 0, int from = 0, int initialTtsOffset = 0}) async {
    starts++; changeState(TtsState.playing); emitSentence(from);
    await pendingStart?.future;
  }
  @override Future<void> pause() async {
    changeState(TtsState.paused);
    if (pendingStart != null && !pendingStart!.isCompleted) pendingStart!.complete();
  }
  @override Future<bool> resume() async { resumes++; changeState(TtsState.playing); return true; }
  @override Future<void> stop() async { changeState(TtsState.stopped); }
}
