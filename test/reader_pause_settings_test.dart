import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:duoduo_langdu/models/book.dart';
import 'package:duoduo_langdu/screens/reader_screen.dart';
import 'package:duoduo_langdu/services/app_storage.dart';
import 'package:duoduo_langdu/services/app_appearance.dart';
import 'package:duoduo_langdu/services/tts_reader.dart';
import 'package:duoduo_langdu/services/playback_notifications.dart';
import 'package:duoduo_langdu/services/display_cutout.dart';
import 'package:duoduo_langdu/services/network_connectivity.dart';
import 'package:duoduo_langdu/services/reading_text.dart';
import 'package:duoduo_langdu/services/reader_preparation.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  final volumeCalls = <MethodCall>[];
  final platformCalls = <MethodCall>[];
  setUp(() {
    ReaderPreparation.runnerForTesting = (request) async => ReaderPreparation.prepareSynchronously(request);
    SharedPreferences.setMockInitialValues({'duoduo.settings.v1': jsonEncode({'brightness': 1.0, 'autoPageSeconds': 2,
      'wordHighlightEnabled': true, 'pageTurnAnimation': 'slide', 'sentenceDragDelay': 0.0})});
    AppAppearance.updateSystemBrightness(Brightness.light);
    AppAppearance.setThemeMode('system');
    volumeCalls.clear(); platformCalls.clear();
    messenger.setMockMethodCallHandler(const MethodChannel('com.ddnovelreader/volume_keys'),
      (call) async { volumeCalls.add(call); return ['getMediaVolume', 'getSystemBrightness'].contains(call.method) ? 0.5 : null; });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async { platformCalls.add(call); return null; });
    messenger.setMockMethodCallHandler(const MethodChannel('com.ddnovelreader/debug_log'), (_) async => null);
    messenger.setMockMethodCallHandler(PlaybackNotifications.channel, (_) async =>
      {'supported': false, 'enabled': false, 'canRequest': false, 'asked': false});
    messenger.setMockMethodCallHandler(DisplayCutoutService.channel, (_) async => null);
    messenger.setMockMethodCallHandler(NetworkConnectivity.channel, (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers.global'), (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers.global/events'), (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers'), (call) async {
      if (call.method == 'create') {
        final id = (call.arguments as Map)['playerId'];
        messenger.setMockMethodCallHandler(MethodChannel('xyz.luan/audioplayers/events/$id'), (_) async => null);
      }
      return null;
    });
  });
  tearDown(() { ReaderPreparation.runnerForTesting = null; });

  testWidgets('pause draft is cheap and real system speech resumes at the saved word after async apply', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(320, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    const fontPath = '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc';
    if (File(fontPath).existsSync()) {
      final loader = FontLoader('Roboto');
      loader.addFont(Future.value(ByteData.sublistView(File(fontPath).readAsBytesSync())));
      await loader.load();
    }
    final storage = AppStorage();
    await storage.saveSettings((ReadingSettings()..voice = TtsReader.systemVoice).toJson());
    const channel = MethodChannel('com.ddnovelreader/system_tts');
    final spoken = <Map>[];
    Future<void> emit(String name, Map data) async {
      final done = Completer<void>();
      messenger.handlePlatformMessage(channel.name, const StandardMethodCodec().encodeMethodCall(MethodCall(name, data)), (_) => done.complete());
      await done.future;
    }
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'initialize') return 'test-system-engine';
      if (call.method == 'speak') {
        final data = call.arguments as Map; spoken.add(data);
        unawaited(Future<void>.microtask(() => emit('start', {'id': data['id']})));
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final book = Book(id: 'pause-system-cursor', title: '停顿', filePath: '', format: BookFormat.txt,
      addedAt: DateTime(2026), chapters: [Chapter(title: '正文', paragraphs: [ReadingText.paragraph('甲乙丙丁，戊己庚辛壬癸。')])]);
    final preview = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(key: preview, child: MaterialApp(home: ReaderScreen(book: book, storage: storage))));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('朗读')); await tester.pumpAndSettle();
    expect(spoken, hasLength(1));
    await emit('range', {'id': spoken.last['id'], 'start': 7, 'end': 9}); await tester.pumpAndSettle();
    await tester.tapAt(const Offset(195, 300)); await tester.pumpAndSettle();
    final requests = <ReaderPreparationRequest>[];
    final prepared = Completer<PreparedReadingBook>();
    ReaderPreparation.runnerForTesting = (request) { requests.add(request); return prepared.future; };
    Future<void> scrollTo(Finder target, {double delta = 180}) async {
      // The narrow, enlarged-text sheet lazily builds its offscreen rows.
      // Scroll its own viewport so absent controls are actually mounted.
      final scrollable = find.descendant(of: find.byType(BottomSheet).last, matching: find.byType(Scrollable)).last;
      await tester.scrollUntilVisible(target, delta, scrollable: scrollable);
      await tester.pumpAndSettle();
    }
    Future<void> dismissSheet() async {
      Navigator.of(tester.element(find.byType(BottomSheet).last)).pop();
      await tester.pumpAndSettle();
    }
    Future<void> dismissPauseAndVoice() async {
      await dismissSheet();
      expect(find.byKey(const ValueKey('pause-voice-__system_tts__')), findsOneWidget);
      await dismissSheet();
      expect(find.byKey(const ValueKey('reading-voice')), findsOneWidget);
    }
    Future<void> openMenu() async {
      await tester.tap(find.byKey(const ValueKey('reading-voice'))); await tester.pumpAndSettle();
      final systemPause = find.byKey(const ValueKey('pause-voice-__system_tts__'));
      await scrollTo(systemPause); await tester.tap(systemPause); await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pause-slider-comma')), findsOneWidget);
      expect(find.byKey(const ValueKey('pause-apply')), findsOneWidget);
      expect(find.text('系统的追加停顿'), findsNothing);
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('pause-apply'))).onPressed, isNull);
      await scrollTo(find.byKey(const ValueKey('pause-slider-comma')));
    }
    // General playback settings retain media-text options but no longer expose
    // the system-only pause editor. Close them before entering the voice sheet.
    await tester.tap(find.byKey(const ValueKey('playback-settings'))); await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pause-expand')), findsNothing);
    expect(find.byKey(const ValueKey('pause-apply')), findsNothing);
    final mediaText = find.byKey(const ValueKey('show-system-media-text'));
    await scrollTo(mediaText, delta: -180);
    expect(tester.widget<SwitchListTile>(mediaText).value, isFalse);
    await tester.tap(mediaText); await tester.pumpAndSettle();
    expect((await storage.loadSettings())['showSystemMediaText'], isTrue);
    await tester.tap(mediaText); await tester.pumpAndSettle();
    expect((await storage.loadSettings())['showSystemMediaText'], isFalse);
    expect(requests, isEmpty);
    await dismissSheet();
    await openMenu();
    await scrollTo(find.byKey(const ValueKey('pause-slider-comma')));
    expect(find.descendant(of: find.byKey(const ValueKey('pause-comma')), matching: find.text('0.00秒')), findsOneWidget);
    final comma = find.byKey(const ValueKey('pause-slider-comma'));
    final semicolon = find.byKey(const ValueKey('pause-slider-semicolon'));
    final before = tester.getRect(comma), next = tester.getRect(semicolon);
    expect(before.left, next.left); expect(before.right, next.right);
    expect(tester.getRect(find.byKey(const ValueKey('pause-comma'))).right, lessThanOrEqualTo(before.left),
      reason: 'The numeric value is a fixed middle column before the short slider');
    await tester.drag(comma, const Offset(20, 0)); await tester.pumpAndSettle();
    expect(tester.widget<Slider>(comma).value, greaterThan(0));
    expect(tester.getRect(comma).left, before.left); expect(tester.getRect(comma).right, before.right);
    expect(tester.getRect(semicolon).left, before.left); expect(tester.getRect(semicolon).right, before.right);
    final drafted = tester.widget<Slider>(comma).value;
    // Collapsing the section keeps its draft but cannot apply it.
    final expand = find.byKey(const ValueKey('pause-expand'));
    final sheetScroll = find.descendant(of: find.byType(BottomSheet).last, matching: find.byType(Scrollable)).last;
    await tester.scrollUntilVisible(expand, -180, scrollable: sheetScroll); await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pause-expand-label'))); await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pause-slider-comma')), findsNothing);
    expect(find.byKey(const ValueKey('pause-apply')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('pause-expand-label'))); await tester.pumpAndSettle(); await scrollTo(comma);
    expect(tester.widget<Slider>(comma).value, drafted);
    expect(requests, isEmpty);
    expect((await storage.loadSettings())['speechPauses']['comma'], 0);
    await scrollTo(expand, delta: -180);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('pause-apply'))).onPressed, isNotNull);
    expect(tester.getRect(find.byKey(const ValueKey('pause-apply'))).center.dy,
      closeTo(tester.getRect(expand).center.dy, 1), reason: 'Apply remains on the expanded section header row');
    if (Platform.isLinux) {
      await tester.runAsync(() async {
        final boundary = preview.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        try {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory('build/ui-previews').create(recursive: true);
          await File('build/ui-previews/reader-pause-settings.png').writeAsBytes(bytes!.buffer.asUint8List());
        } finally { image.dispose(); }
      });
    }
    await dismissPauseAndVoice();
    expect(requests, isEmpty, reason: 'Dismissing the system pause editor discards its unapplied draft');
    expect((await storage.loadSettings())['speechPauses']['comma'], 0);
    expect(spoken, hasLength(1));
    await openMenu();
    await tester.tap(find.byKey(const ValueKey('pause-comma'))); await tester.pumpAndSettle();
    expect(tester.widget<TextFormField>(find.byKey(const ValueKey('pause-number-comma'))).controller!.text, '0.00');
    await tester.enterText(find.byKey(const ValueKey('pause-number-comma')), '3.50');
    await tester.tap(find.text('确定').last); await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pause-number-comma')), findsOneWidget, reason: 'Seconds above 3.00 cannot be submitted');
    await tester.enterText(find.byKey(const ValueKey('pause-number-comma')), '.25');
    await tester.tap(find.text('确定').last); await tester.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const ValueKey('pause-comma')), matching: find.text('0.25秒')), findsOneWidget);
    final apply = find.byKey(const ValueKey('pause-apply'));
    await scrollTo(apply, delta: -180); await tester.tap(apply); await tester.pumpAndSettle();
    expect(requests, hasLength(1)); expect(spoken, hasLength(1));
    expect((await storage.loadSettings())['speechPauses']['comma'], 0, reason: 'The saved setting stays valid until preparation succeeds');
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byKey(const ValueKey('reader-body')), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'The pending worker must not prevent reader painting');
    prepared.complete(ReaderPreparation.prepareSynchronously(requests.single)); await tester.pumpAndSettle();
    expect((await storage.loadSettings())['speechPauses']['comma'], 0);
    expect((await storage.loadSettings())['perVoiceSpeechPauses'][TtsReader.systemVoice]['comma'], 250);
    expect(spoken, hasLength(1), reason: 'Applying a paused setting must remain paused');
    // Apply closed only the nested pause sheet. The underlying voice picker
    // remains, and must also close before reopening it or resuming the reader.
    expect(find.byKey(const ValueKey('pause-expand')), findsNothing);
    await dismissSheet();
    await openMenu();
    await dismissPauseAndVoice();
    expect(requests, hasLength(1), reason: 'Closing without changes must not prepare the book again');
    await tester.tapAt(const Offset(195, 300)); await tester.pumpAndSettle();
    expect(spoken, hasLength(2));
    expect(spoken.last['text'], '庚辛壬癸。', reason: 'Re-segmentation must map the saved word into the new sentence before system resume');
    expect(requests, hasLength(1)); expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(seconds: 45)));

}
