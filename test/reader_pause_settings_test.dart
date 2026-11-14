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
    Future<void> scrollTo(Finder target) async {
      // The narrow, enlarged-text sheet lazily builds its offscreen rows.
      // Scroll its own viewport so absent controls are actually mounted.
      final scrollable = find.descendant(of: find.byType(BottomSheet), matching: find.byType(Scrollable)).last;
      await tester.scrollUntilVisible(target, 180, scrollable: scrollable);
      await tester.pumpAndSettle();
    }
    Future<void> openMenu() async {
      await tester.tap(find.byKey(const ValueKey('playback-settings'))); await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pause-slider-comma')), findsNothing);
      final expand = find.byKey(const ValueKey('pause-expand'));
      await scrollTo(expand); await tester.tap(expand); await tester.pumpAndSettle();
      await scrollTo(find.byKey(const ValueKey('pause-slider-comma')));
    }
    await openMenu();
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
    final sheetScroll = find.descendant(of: find.byType(BottomSheet), matching: find.byType(Scrollable)).last;
    await tester.scrollUntilVisible(expand, -180, scrollable: sheetScroll); await tester.pumpAndSettle();
    await tester.tap(expand); await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pause-slider-comma')), findsNothing);
    await tester.tap(expand); await tester.pumpAndSettle(); await scrollTo(comma);
    expect(tester.widget<Slider>(comma).value, drafted);
    expect(requests, isEmpty);
    expect((await storage.loadSettings())['speechPauses']['comma'], 0);
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
    await tester.tapAt(const Offset(195, 60)); await tester.pumpAndSettle();
    expect(requests, isEmpty);
    await openMenu();
    await tester.tap(find.byKey(const ValueKey('pause-comma'))); await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('pause-number-comma')), '250');
    await tester.tap(find.text('确定').last); await tester.pumpAndSettle();
    final apply = find.byKey(const ValueKey('pause-apply'));
    await scrollTo(apply); await tester.tap(apply); await tester.pumpAndSettle();
    expect(requests, hasLength(1)); expect(spoken, hasLength(1));
    expect((await storage.loadSettings())['speechPauses']['comma'], 0, reason: 'The old settings remain valid until preparation succeeds');
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byKey(const ValueKey('reader-body')), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'The pending worker must not prevent reader painting');
    prepared.complete(ReaderPreparation.prepareSynchronously(requests.single)); await tester.pumpAndSettle();
    expect((await storage.loadSettings())['speechPauses']['comma'], 250);
    expect(spoken, hasLength(1), reason: 'Applying a paused setting must remain paused');
    await tester.tapAt(const Offset(195, 300)); await tester.pumpAndSettle();
    expect(spoken, hasLength(2));
    expect(spoken.last['text'], '庚辛壬癸。', reason: 'Re-segmentation must map the saved word into the new sentence before system resume');
    expect(requests, hasLength(1)); expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

}
