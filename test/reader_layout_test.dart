import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:duoduo_langdu/models/book.dart';
import 'package:duoduo_langdu/models/progress.dart';
import 'package:duoduo_langdu/models/speech_word.dart';
import 'package:duoduo_langdu/screens/reader_screen.dart';
import 'package:duoduo_langdu/screens/shelf_screen.dart';
import 'package:duoduo_langdu/services/app_storage.dart';
import 'package:duoduo_langdu/services/app_appearance.dart';
import 'package:duoduo_langdu/services/tts_reader.dart';
import 'package:duoduo_langdu/services/system_tts.dart';
import 'package:duoduo_langdu/services/tts_audio_handler.dart';
import 'package:duoduo_langdu/services/playback_notifications.dart';
import 'package:duoduo_langdu/services/display_cutout.dart';
import 'package:duoduo_langdu/services/network_connectivity.dart';
import 'package:duoduo_langdu/services/reading_text.dart';
import 'package:duoduo_langdu/services/reader_preparation.dart';
import 'package:duoduo_langdu/services/book_cache_task.dart';
import 'package:duoduo_langdu/services/tts_cache_store.dart';
import 'package:duoduo_langdu/services/reader_typography.dart';
import 'package:duoduo_langdu/services/text_cleaner.dart';
import 'package:duoduo_langdu/services/annotation_store.dart';
import 'package:duoduo_langdu/services/sync_engine.dart';
import 'package:duoduo_langdu/widgets/reader_brightness_control.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  final volumeCalls = <MethodCall>[];
  final platformCalls = <MethodCall>[];
  setUp(() {
    ReaderPreparation.runnerForTesting = (request) async => ReaderPreparation.prepareSynchronously(request);
    SharedPreferences.setMockInitialValues({'duoduo.settings.v1': jsonEncode({'brightness': 1.0, 'autoPageSeconds': 2,
      'wordHighlightEnabled': true, 'pageTurnMode': 'tap', 'pageTurnAnimation': 'slide', 'sentenceDragDelay': 0.0})});
    AppAppearance.updateSystemBrightness(Brightness.light);
    AppAppearance.setThemeMode('system');
    volumeCalls.clear(); platformCalls.clear();
    messenger.setMockMethodCallHandler(const MethodChannel('com.ddnovelreader/volume_keys'),
      (call) async { volumeCalls.add(call); return ['getMediaVolume', 'getSystemBrightness'].contains(call.method) ? 0.5 : null; });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async { platformCalls.add(call); return null; });
    messenger.setMockMethodCallHandler(const MethodChannel('com.ddnovelreader/debug_log'), (_) async => null);
    messenger.setMockMethodCallHandler(SystemTtsClient.channel, (call) async =>
      call.method == 'voices' ? [] : call.method == 'initialize' ? {'voiceName': '系统默认测试音色'} : null);
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

  testWidgets('reader, contents and shelf fit phone layouts', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.viewPadding = const FakeViewPadding(top: 40, bottom: 24);
    tester.view.padding = const FakeViewPadding(top: 40, bottom: 24);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetViewPadding);
    addTearDown(tester.view.resetPadding);
    const fontPath = '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc';
    await tester.runAsync(() async {
      if (File(fontPath).existsSync()) {
        for (final family in ['Preview', 'Roboto']) {
          final loader = FontLoader(family);
          loader.addFont(Future.value(ByteData.sublistView(File(fontPath).readAsBytesSync())));
          await loader.load();
        }
      }
      final icons = File('${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
      if (icons.existsSync()) {
        final loader = FontLoader('MaterialIcons');
        loader.addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
        await loader.load();
      }
      // Font-change platform messages must settle without depending on PNG IO.
      await Future<void>.delayed(Duration.zero);
    });

    final key = GlobalKey();
    Widget app(Widget child) => ValueListenableBuilder<bool>(valueListenable: AppAppearance.nightMode,
      builder: (context, night, _) => RepaintBoundary(key: key, child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppAppearance.theme(night).copyWith(textTheme: AppAppearance.theme(night).textTheme.apply(fontFamily: 'Preview')),
      home: child,
    )));
    Future<void> capture(String name) async {
      expect(tester.takeException(), isNull);
      if (!Platform.isLinux || Platform.environment['DD_READER_CAPTURE_UI_PREVIEWS'] != '1') return;
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory('build/ui-previews').create(recursive: true);
        await File('build/ui-previews/$name.png').writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }
    final book = Book(id: 'preview', title: '阅读示例', filePath: '', format: BookFormat.txt,
      addedAt: DateTime(2026), chapters: List.generate(20, (c) => Chapter(
        title: '第 ${c + 1} 章 山间来信',
        paragraphs: List.generate(15, (p) => const Paragraph(
          display: '清晨，阳光照进窗前。他展开来信，读起远方朋友的问候。',
          tts: '清晨，阳光照进窗前。他展开来信，读起远方朋友的问候。',
          sentences: [Sentence('清晨，阳光照进窗前。', '清晨阳光照进窗前'),
            Sentence('他展开来信，读起远方朋友的问候。', '他展开来信读起远方朋友的问候')],
          sentenceStartTts: [0, 9],
        )),
      )));
    await tester.pumpWidget(app(ReaderScreen(book: book, storage: AppStorage())));
    await tester.pumpAndSettle();
    expect(volumeCalls.where((c) => c.method == 'setScreenBrightness'), isEmpty,
      reason: 'Opening a book must not force maximum brightness');
    await capture('reader-controls');
    final list = find.byKey(const ValueKey('reader-body'));
    final text = find.byWidgetPredicate((w) => w is Text && w.textAlign == TextAlign.justify && (w.textSpan?.toPlainText().replaceAll('\u200B', '').contains('清晨，阳光照进窗前。') ?? false)).first;
    expect(tester.widget<Text>(text).textSpan!.toPlainText(), startsWith('\uFFFC'));
    final paragraphRender = tester.renderObject<RenderParagraph>(text);
    final displayed = tester.widget<Text>(text).textSpan!.toPlainText();
    final firstGlyph = paragraphRender.getBoxesForSelection(TextSelection(baseOffset: displayed.indexOf('清'), extentOffset: displayed.indexOf('清') + 1));
    expect(firstGlyph.first.left, greaterThanOrEqualTo(38), reason: 'First-line indentation must also be visible when justified');
    final punctuationSource = '甲乙丙丁，后面继续。';
    final punctuationLayout = ReaderTypography.layout(punctuationSource, paragraphStart: true);
    final painter = TextPainter(text: TextSpan(text: punctuationLayout,
      style: const TextStyle(fontSize: 20, fontFamily: 'Preview')), textDirection: TextDirection.ltr,
      textAlign: TextAlign.justify)..layout(maxWidth: 80);
    final lastLetter = painter.getBoxesForSelection(TextSelection(baseOffset: ReaderTypography.layoutOffset(punctuationSource, 3),
      extentOffset: ReaderTypography.layoutOffset(punctuationSource, 4)));
    final comma = painter.getBoxesForSelection(TextSelection(baseOffset: ReaderTypography.layoutOffset(punctuationSource, 4),
      extentOffset: ReaderTypography.layoutOffset(punctuationSource, 5)));
    expect(lastLetter.first.top, closeTo(0, 0.5), reason: 'Four full-width characters fit before the punctuation');
    expect(comma.first.top, greaterThan(lastLetter.first.top), reason: 'Punctuation may start the next line');
    painter.dispose();
    final before = tester.getTopLeft(text);
    final listSize = tester.getSize(list);
    await tester.tapAt(const Offset(195, 360));
    await tester.pumpAndSettle();
    tester.view.viewPadding = const FakeViewPadding();
    tester.view.padding = const FakeViewPadding();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(text), before, reason: 'Hiding chrome must not move the text');
    expect(tester.getSize(list), listSize, reason: 'Toolbars must overlay the text viewport');
    await capture('reader');
    await tester.tapAt(const Offset(195, 360));
    await tester.pumpAndSettle();
    tester.view.viewPadding = const FakeViewPadding(top: 40, bottom: 24);
    tester.view.padding = const FakeViewPadding(top: 40, bottom: 24);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(text), before);
    expect(tester.getSize(list), listSize);
    final handle = find.byKey(const ValueKey('contents-handle'));
    expect(tester.getRect(handle).right, lessThanOrEqualTo(tester.getRect(list).left + 16));
    await tester.tap(handle);
    await tester.pumpAndSettle();
    expect(find.text('目录'), findsOneWidget);
    await capture('reader-contents');
    await tester.tapAt(const Offset(370, 400));
    await tester.pumpAndSettle();
    int topIndex() {
      final widget = tester.widget<ScrollablePositionedList>(list);
      final visible = widget.itemPositionsNotifier!.itemPositions.value
        .where((p) => p.itemTrailingEdge > 0 && p.itemLeadingEdge < 1).toList()
        ..sort((a,b) => a.index.compareTo(b.index));
      return visible.first.index;
    }
    final firstPage = topIndex();
    await tester.drag(list, const Offset(-220, 0));
    await tester.pumpAndSettle();
    expect(topIndex(), firstPage, reason: 'Tap mode must ignore swipes');
    await tester.tapAt(const Offset(360, 360));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    for (var frame = 0; frame < 20; frame++) {
      final current = tester.widget<FractionalTranslation>(find.byKey(const ValueKey('page-incoming-transform')));
      if (current.translation.dx > 0) break;
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 16));
    final incoming = tester.widget<FractionalTranslation>(find.byKey(const ValueKey('page-incoming-transform')));
    final outgoing = tester.widget<FractionalTranslation>(find.byKey(const ValueKey('page-outgoing-transform')));
    expect(incoming.translation.dx, greaterThan(0));
    expect(outgoing.translation.dx, lessThan(0));
    expect(incoming.translation.dy, 0);
    expect(outgoing.translation.dy, 0);
    await capture('horizontal-page-transition');
    await tester.pumpAndSettle();
    final nextPage = topIndex();
    expect(nextPage, greaterThan(firstPage));
    await tester.tapAt(const Offset(30, 360));
    await tester.pumpAndSettle();
    expect(topIndex(), lessThan(nextPage));
    await tester.tapAt(const Offset(195, 300)); await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('next-chapter')));
    await tester.pumpAndSettle();
    expect(find.text('第 2/20 章'), findsOneWidget);
    expect(topIndex(), greaterThanOrEqualTo(16));
    await tester.tap(find.byKey(const ValueKey('next-chapter')));
    await tester.pumpAndSettle();
    expect(find.text('第 3/20 章'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('previous-chapter')));
    await tester.pumpAndSettle();
    expect(find.text('第 2/20 章'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('previous-chapter')));
    await tester.pumpAndSettle();
    expect(find.text('第 1/20 章'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('reader-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('next-chapter')));
    await tester.pumpAndSettle();
    expect(find.text('第 2/20 章'), findsOneWidget);
    expect(find.byKey(const ValueKey('quick-brightness')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('previous-chapter')));
    await tester.pumpAndSettle();
    expect(find.text('第 1/20 章'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('reader-menu')));
    await tester.pumpAndSettle();
    await capture('reader-menu');
    final brightness = find.byKey(const ValueKey('quick-brightness'));
    final fontSlider = find.byWidgetPredicate((w) => w is Slider && w.max == 64);
    expect(tester.getRect(fontSlider).width, closeTo(tester.getRect(brightness).width, 0.1));
    expect(tester.getRect(fontSlider).left, closeTo(tester.getRect(brightness).left, 0.1));
    final slider = tester.getRect(brightness);
    await tester.dragFrom(slider.center, Offset(slider.width, 0));
    await tester.pumpAndSettle();
    expect(volumeCalls.where((c) => c.method == 'setScreenBrightness').last.arguments, 1.0);
    await tester.tapAt(Offset(slider.left + 12 + (slider.width - 24) * 0.125, slider.center.dy));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reader-dim-mask')), findsOneWidget);
    expect(volumeCalls.where((c) => c.method == 'setScreenBrightness').last.arguments, 0.01);
    await capture('extra-dim-brightness');
    await tester.tap(find.byKey(const ValueKey('brightness-auto')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reader-dim-mask')), findsNothing);
    expect(volumeCalls.lastWhere((c) => ['setScreenBrightness','resetScreenBrightness'].contains(c.method)).method,
      'resetScreenBrightness');
    expect((await AppStorage().loadSettings())['automaticBrightness'], isTrue);
    await tester.tap(find.byKey(const ValueKey('font-fine-tune')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('font-increase')));
    await tester.pumpAndSettle();
    expect((await AppStorage().loadSettings())['fontSize'], 21);
    await tester.tap(find.byKey(const ValueKey('font-decrease')));
    await tester.pumpAndSettle();
    expect((await AppStorage().loadSettings())['fontSize'], 20);
    await tester.tapAt(const Offset(20, 120));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('自动翻页'));
    await tester.pumpAndSettle();
    expect(find.text('每 2 秒翻一页'), findsOneWidget);
    final autoStartPage = topIndex();
    await tester.tap(find.byKey(const ValueKey('auto-page-start')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final guide = find.byKey(const ValueKey('auto-reading-guide'));
    final guideTop = tester.getTopLeft(guide).dy;
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.getTopLeft(guide).dy, greaterThan(guideTop));
    await capture('auto-reading-guide');
    await tester.pump(const Duration(milliseconds: 1400));
    for (var frame = 0; frame < 8; frame++) { await tester.pump(const Duration(milliseconds: 60)); }
    expect(topIndex(), greaterThan(autoStartPage));
    for (var frame = 0; frame < 60 && find.byKey(const ValueKey('page-outgoing-transform')).evaluate().isNotEmpty; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.byKey(const ValueKey('page-outgoing-transform')), findsNothing);
    await tester.tapAt(const Offset(195, 360));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('auto-page-pause')));
    await tester.pumpAndSettle();
    final pausedY = tester.getTopLeft(guide).dy;
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.getTopLeft(guide).dy, pausedY);
    await capture('auto-reading-paused');
    await tester.tap(find.byKey(const ValueKey('auto-page-pause')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tapAt(const Offset(195, 360));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('auto-page-stop')));
    await tester.pumpAndSettle();
    expect(guide, findsNothing);
    await tester.tap(find.byKey(const ValueKey('reader-menu')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(195, 500));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('night-mode')));
    await tester.pumpAndSettle();
    expect(AppAppearance.nightMode.value, isTrue);
    expect((await AppStorage().loadSettings())['themeIndex'], 2);
    await tester.tap(find.byKey(const ValueKey('night-mode')));
    await tester.pumpAndSettle();
    expect(AppAppearance.nightMode.value, isFalse);
    expect((await AppStorage().loadSettings())['themeIndex'], 0);
    await tester.tap(find.byKey(const ValueKey('night-mode')));
    await tester.pumpAndSettle();
    await capture('reader-night');
    await tester.tap(find.byKey(const ValueKey('reader-menu')));
    await tester.pumpAndSettle();
    await capture('reader-menu-night');
    await tester.tap(find.byTooltip('阅读设置'));
    await tester.pumpAndSettle();
    expect(Theme.of(tester.element(find.byType(Slider).last)).brightness, Brightness.dark);
    await capture('reader-settings-night');
    final readingSettings = find.byType(BottomSheet).last;
    expect(find.descendant(of: readingSettings, matching: find.byType(ReaderBrightnessControl)), findsNothing);
    expect(find.descendant(of: readingSettings, matching: find.byWidgetPredicate((w) => w is Slider && w.max == 64)), findsNothing);
    expect(find.byWidgetPredicate((w) => w is DropdownButton<String> && w.value == 'zh-CN-XiaoxiaoNeural'), findsNothing);
    expect(find.text('缓存在线语音'), findsNothing, reason: 'Online cache belongs to the playback panel');
    expect(find.text('变速'), findsNothing, reason: 'Speech speed belongs to the playback panel');
    Future<void> revealSetting(Finder target, {double delta = 200}) async {
      final scrollable = find.descendant(of: readingSettings, matching: find.byType(Scrollable)).last;
      await tester.scrollUntilVisible(target, delta, scrollable: scrollable);
      await tester.pumpAndSettle();
    }
    final correction = find.byKey(const ValueKey('text-correction'));
    await revealSetting(correction); await tester.tap(correction);
    await tester.pumpAndSettle();
    expect((await AppStorage().loadSettings())['textCorrection'], isFalse);
    await revealSetting(correction); await tester.tap(correction);
    await tester.pumpAndSettle();
    final indent = find.byKey(const ValueKey('first-line-indent'));
    await revealSetting(indent); await tester.tap(indent); await tester.pumpAndSettle();
    expect((await AppStorage().loadSettings())['firstLineIndent'], isFalse);
    await revealSetting(indent); await tester.tap(indent); await tester.pumpAndSettle();
    final filter = find.byKey(const ValueKey('information-filter'));
    await revealSetting(filter);
    expect(tester.widget<SwitchListTile>(filter).value, isTrue);
    await tester.tap(filter); await tester.pumpAndSettle();
    await tester.tap(filter); await tester.pumpAndSettle();
    expect((await AppStorage().loadSettings())['informationFilterLevel'], 'links', reason: 'Level one is selected by default');
    for (final label in ['一级：网址和邮箱', '二级：再过滤明确广告行', '三级：再过滤求票、求收藏及作者说明行']) {
      final option = find.widgetWithText(RadioListTile<String>, label);
      await revealSetting(option); expect(option, findsOneWidget);
    }
    final firstLevel = find.widgetWithText(RadioListTile<String>, '一级：网址和邮箱');
    await revealSetting(firstLevel, delta: -200); await tester.tap(firstLevel); await tester.pumpAndSettle();
    expect((await AppStorage().loadSettings())['informationFilterLevel'], 'links');
    await revealSetting(filter, delta: -200);
    await capture('reader-text-options');
    await tester.tap(filter); await tester.pumpAndSettle();
    await tester.tapAt(const Offset(20, 120));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('横竖屏切换'));
    await tester.pumpAndSettle();
    expect(platformCalls.where((c) => c.method == 'SystemChrome.setPreferredOrientations').last.arguments,
      ['DeviceOrientation.landscapeLeft']);
    tester.view.physicalSize = const Size(844, 390);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-menu')));
    await tester.pumpAndSettle();
    await capture('reader-landscape');
    await tester.tap(find.byTooltip('横竖屏切换'));
    await tester.pumpAndSettle();
    expect(platformCalls.where((c) => c.method == 'SystemChrome.setPreferredOrientations').last.arguments,
      ['DeviceOrientation.portraitUp']);
    tester.view.physicalSize = const Size(320, 640);
    await tester.pumpAndSettle();
    await capture('reader-small-phone');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(390, 844);
    final storage = AppStorage();
    for (var i = 0; i < 3; i++) {
      await storage.addBook(BookMeta(id: 'shelf$i', title: ['山间来信', '远方的故事', '春日随笔'][i],
        filePath: 'sample$i.txt', format: 'txt', addedAt: DateTime(2026)));
      await storage.saveProgress(BookProgress(bookId: 'shelf$i', percent: i * 0.15));
    }
    await tester.pumpWidget(app(const ShelfScreen()));
    await tester.pumpAndSettle();
    expect(Theme.of(tester.element(find.byType(ShelfScreen))).brightness, Brightness.dark);
    await capture('shelf-night');
    AppAppearance.nightMode.value = false;
    await tester.pumpAndSettle();
    await capture('shelf');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  Book sample(String id) => Book(id: id, title: id, filePath: '', format: BookFormat.txt,
    addedAt: DateTime(2026), chapters: List.generate(12, (c) => Chapter(title: '第${c + 1}章',
      paragraphs: List.generate(30, (p) => Paragraph(
        display: '第${c + 1}章第${p + 1}段。' + List.filled(6, '山间的风吹过树林，远方传来朋友的问候。').join(),
        tts: '', sentences: const [], sentenceStartTts: const [])))));

  for (final palette in [
    (name: 'dark', index: 2, background: const Color(0xFF1A1A1A), paper: const Color(0xFF1A1A1A)),
    (name: 'light', index: 0, background: Colors.white, paper: const Color(0xFFB5AB92)),
  ]) {
    testWidgets('reading, voice and playback settings share surfaces, text hierarchy and section boundaries in ${palette.name}', (tester) async {
      tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
      tester.view.viewPadding = const FakeViewPadding(top: 40, bottom: 24);
      tester.view.padding = const FakeViewPadding(top: 40, bottom: 24);
      addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetViewPadding); addTearDown(tester.view.resetPadding);
      final sizes = <Size>[];
      final titleOffsets = <Offset>[];
      for (final menu in ['reading', 'voice', 'playback']) {
        AppAppearance.setThemeMode(palette.name);
        final storage = AppStorage();
        await storage.saveSettings((ReadingSettings()..themeMode = palette.name
          ..themeIndex = palette.index..dayThemeIndex = 0).toJson());
        await tester.pumpWidget(MaterialApp(theme: AppAppearance.theme(palette.name == 'dark'),
          home: ReaderScreen(book: sample('settings-${palette.name}-$menu'), storage: storage, ttsReader: _TestSpeech())));
        await tester.pumpAndSettle();
        if (menu == 'reading') {
          await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('阅读设置'));
        } else {
          await tester.tap(find.byTooltip('朗读')); await tester.pumpAndSettle();
          await tester.tapAt(const Offset(195, 360)); await tester.pumpAndSettle();
          await tester.tap(find.byKey(ValueKey(menu == 'voice' ? 'reading-voice' : 'playback-settings')));
        }
        await tester.pumpAndSettle();
        final panel = find.byKey(const ValueKey('reader-settings-panel'));
        final title = find.byKey(const ValueKey('settings-panel-title'));
        expect(panel, findsOneWidget); expect(title, findsOneWidget);
        final rect = tester.getRect(panel);
        sizes.add(rect.size); titleOffsets.add(tester.getTopLeft(title) - rect.topLeft);
        expect(rect.height, closeTo(844 * .85, 1));
        expect(tester.getTopLeft(title).dx - rect.left, closeTo(16, 1), reason: 'Every settings title aligns to the same left edge');
        final titleDivider = find.byKey(const ValueKey('settings-panel-divider'));
        expect(titleDivider, findsOneWidget);
        final list = find.descendant(of: panel, matching: find.byType(ListView)).first;
        expect(tester.widget<ListView>(list).padding, const EdgeInsets.all(16));
        final menuTheme = Theme.of(tester.element(title));
        expect(menuTheme.colorScheme.surface, palette.background);
        expect(menuTheme.canvasColor, palette.background);
        expect(menuTheme.dialogTheme.backgroundColor, palette.background);
        expect(menuTheme.dialogTheme.surfaceTintColor, Colors.transparent);
        expect(tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor, palette.paper,
          reason: 'Menu surfaces must not replace the chosen reading paper');
        TextStyle renderedStyle(Finder text) => tester.renderObject<RenderParagraph>(text).text.style!;
        final headingStyle = renderedStyle(title);
        expect(headingStyle.fontSize, 20); expect(headingStyle.fontWeight, FontWeight.w600);
        expect(menuTheme.listTileTheme.titleTextStyle!.fontSize, 16);
        expect(menuTheme.listTileTheme.subtitleTextStyle!.fontSize, 14);
        final scrollable = find.descendant(of: panel, matching: find.byType(Scrollable)).first;
        final sections = switch (menu) {
          'reading' => ['settingsAppearance', 'settingsPageTurning', 'settingsScreen', 'settingsTextProcessing'],
          'voice' => ['voiceSectionOnline', 'voiceSectionLocal'],
          _ => ['settingsSpeechFeedback', 'settingsSpeechNetwork', 'settingsSpeechControls'],
        };
        for (var index = 0; index < sections.length; index++) {
          final section = sections[index];
          final label = find.byKey(ValueKey('reader-menu-section-$section'));
          await tester.scrollUntilVisible(label, 180, scrollable: scrollable); await tester.pumpAndSettle();
          final style = renderedStyle(label);
          expect(style.fontSize, 16); expect(style.fontWeight, FontWeight.w600);
          expect(style.color, menuTheme.colorScheme.primary);
          expect(tester.getTopLeft(label).dx - rect.left, closeTo(16, 1));
          final boundary = find.byKey(ValueKey('reader-menu-divider-$section'));
          expect(boundary, index == 0 ? findsNothing : findsOneWidget,
            reason: 'Only a transition into another major group adds a section boundary');
          for (final divider in tester.widgetList<Divider>(find.descendant(of: panel, matching: find.byType(Divider)))) {
            final key = divider.key;
            expect(key, isA<ValueKey<String>>());
            final value = (key! as ValueKey<String>).value;
            expect(value == 'settings-panel-divider' || value.startsWith('reader-menu-divider-'), isTrue,
              reason: 'Ordinary setting rows must not gain their own divider');
          }
        }
        tester.state<ScrollableState>(scrollable).position.jumpTo(0); await tester.pumpAndSettle();
        final entry = find.byKey(ValueKey(switch (menu) {
          'reading' => 'reader-font-family', 'voice' => 'system-engine-', _ => 'word-highlight',
        }));
        await tester.scrollUntilVisible(entry, 180, scrollable: scrollable); await tester.pumpAndSettle();
        final entryWidget = tester.widget(entry);
        final Widget entryTitle = entryWidget is SwitchListTile ? entryWidget.title! : (entryWidget as ListTile).title!;
        final entryStyle = renderedStyle(find.byWidget(entryTitle));
        expect(entryStyle.fontSize, 16); expect(entryStyle.fontWeight, FontWeight.w400);
        if (menu != 'voice') {
          final supported = find.byKey(ValueKey(menu == 'reading' ? 'retain-page-line' : 'reading-prefetch'));
          await tester.scrollUntilVisible(supported, 180, scrollable: scrollable); await tester.pumpAndSettle();
          final supportedWidget = tester.widget(supported);
          final Widget description = supportedWidget is SwitchListTile
            ? supportedWidget.subtitle! : (supportedWidget as ListTile).subtitle!;
          expect(renderedStyle(find.byWidget(description)).fontSize, 14);
        }
        expect(tester.getTopLeft(title) - rect.topLeft, titleOffsets.last,
          reason: 'The shared title remains fixed while each menu scrolls');
        final background = tester.widgetList<Material>(find.ancestor(of: panel, matching: find.byType(Material)))
          .where((material) => material.color == palette.background);
        expect(background, isNotEmpty);
        expect(background.every((material) => material.surfaceTintColor == null || material.surfaceTintColor == Colors.transparent), isTrue);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
      }
      expect(sizes.toSet(), hasLength(1));
      expect(titleOffsets.toSet(), hasLength(1));
    });
  }

  testWidgets('disabled launch sync prevents the startup sync request', (tester) async {
    final storage = AppStorage();
    await storage.saveSettings({SyncEngine.cfgServer: 'https://example.invalid', SyncEngine.cfgAuto: false});
    final sync = _CountingSyncEngine(storage);
    await tester.pumpWidget(MaterialApp(home: ShelfScreen(syncEngine: sync)));
    await tester.pumpAndSettle();
    expect(sync.calls, 0);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  testWidgets('canonical desktop bookmark selects the matching formatted paragraph', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    final storage = AppStorage();
    await storage.saveSettings((ReadingSettings()..firstLineIndent = true..mergeNonSentenceBreaks = false).toJson());
    final book = Book(id: 'canonical-bookmark', title: '跨端书签', filePath: '', format: BookFormat.txt,
      addedAt: DateTime(2026), chapters: [Chapter(title: '第一章', paragraphs: List.generate(30,
        (p) => ReadingText.paragraph('第$p段。${List.filled(10, '远方传来朋友的问候。').join()}')))]);
    final offset = book.charOffsetOf(0, 20, 0);
    await AnnotationStore().saveRawBookmarks(book.id, [
      {'id': 'desktop-position', 'chapter_idx': 0, 'offset': offset, 'offset_end': offset + 5,
        'text': '跨端目标', 'created_at': 100.0},
    ]);
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: book, storage: storage, ttsReader: _TestSpeech())));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('contents-handle'))); await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bookmarks-tab'))); await tester.pumpAndSettle();
    await tester.tap(find.text('跨端目标')); await tester.pumpAndSettle();
    final positions = tester.widget<ScrollablePositionedList>(find.byKey(const ValueKey('reader-body')))
      .itemPositionsNotifier!.itemPositions.value;
    expect(positions.any((position) => position.index == 21 && position.itemLeadingEdge >= -0.1 &&
      position.itemLeadingEdge < 0.2), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  testWidgets('shelf cache clearing waits for every matching composite-key task', (tester) async {
    final root = (await tester.runAsync(() => Directory.systemTemp.createTemp('shelf-cache-stop-')))!;
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(pathChannel, (_) async => root.path);
    const key = '0123456789abcdef';
    final cache = TtsCacheStore('cache-book-id', TtsReader.defaultVoice, 1, contentKey: key, textFingerprint: 'test');
    final task = _TestBookCacheTask(book: sample('cache-book-id'), store: cache)..cancelGate = Completer<void>();
    const taskKey = 'cache-book-id/test/zh-CN-XiaoxiaoNeural/1.00';
    activeBookCaches[taskKey] = task;
    late File audio;
    await tester.runAsync(() async {
      audio = File('${root.path}${Platform.pathSeparator}tts_cache${Platform.pathSeparator}$key'
        '${Platform.pathSeparator}voice${Platform.pathSeparator}0${Platform.pathSeparator}entry.mp3');
      await audio.parent.create(recursive: true); await audio.writeAsBytes([1, 2, 3]);
    });
    addTearDown(() async {
      if (!task.cancelGate!.isCompleted) task.cancelGate!.complete();
      activeBookCaches.remove(taskKey); task.statusNotifier.dispose();
      messenger.setMockMethodCallHandler(pathChannel, null);
      await root.delete(recursive: true);
    });
    final storage = AppStorage();
    await storage.addBook(BookMeta(id: 'cache-book-id', title: '缓存测试', filePath: '', format: 'txt',
      addedAt: DateTime(2026), contentKey: key, totalChars: 100, chapterCount: 1));
    await tester.pumpWidget(const MaterialApp(home: ShelfScreen())); await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shelf-menu'))); await tester.pumpAndSettle();
    await tester.tap(find.text('缓存管理'));
    await tester.pump(); await tester.pump(const Duration(milliseconds: 350));
    for (var frame = 0; frame < 100 && find.text('清除缓存').evaluate().isEmpty; frame++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero)); await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.tap(find.text('清除缓存')); await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('确定')));
    await tester.pump(); await tester.pump(const Duration(milliseconds: 350));
    expect(task.cancelCalls, 1); expect(await tester.runAsync(audio.exists), isTrue);
    task.cancelGate!.complete();
    var exists = true;
    for (var frame = 0; frame < 100 && exists; frame++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero)); await tester.pump(const Duration(milliseconds: 16));
      exists = (await tester.runAsync(audio.exists))!;
    }
    expect(exists, isFalse); expect(activeBookCaches.containsKey(taskKey), isFalse);
    expect((await storage.loadBooks()).single.id, 'cache-book-id'); expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  testWidgets('each book restores its viewport and long seeks keep text visible', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    final storage = AppStorage();
    final a = sample('book-a'), b = sample('book-b');
    await storage.saveProgress(BookProgress(bookId: a.id));
    Future<void> open(Book book) async {
      await tester.pumpWidget(MaterialApp(home: ReaderScreen(key: ValueKey(book.id), book: book, storage: storage)));
      await tester.pumpAndSettle();
    }
    final list = find.byKey(const ValueKey('reader-body'));
    List<ItemPosition> visible() => (tester.widget<ScrollablePositionedList>(list).itemPositionsNotifier!.itemPositions.value
      .where((p) => p.itemTrailingEdge > 0 && p.itemLeadingEdge < 1).toList()..sort((a,b) => a.index.compareTo(b.index)));
    Future<void> assertVisible() async {
      expect(visible(), isNotEmpty);
      final paragraph = find.byWidgetPredicate((w) => w is Text && w.textAlign == TextAlign.justify);
      expect(paragraph, findsWidgets);
      expect(tester.takeException(), isNull);
    }
    await open(a);
    expect(visible().first.index, 0, reason: 'New and migrated chapter-start positions include their heading');
    final progressSlider = find.byWidgetPredicate((w) => w is Slider && w.max == 1 && w.min == 0);
    tester.widget<Slider>(progressSlider).onChanged!(0.82);
    await tester.pumpAndSettle();
    await assertVisible();
    final seekIndex = visible().first.index;
    expect(seekIndex, greaterThan(250));
    await tester.tapAt(const Offset(360, 360)); await tester.pumpAndSettle();
    await assertVisible();
    expect(visible().first.index, greaterThanOrEqualTo(seekIndex));
    await tester.pump(const Duration(milliseconds: 500));
    final savedA = (await storage.loadProgress(a.id))!;
    expect(savedA.chapterIndex, greaterThan(6));
    final aIndex = visible().first.index, aEdge = visible().first.itemLeadingEdge;
    await open(b);
    expect(visible().first.index, 0);
    tester.widget<Slider>(progressSlider).onChanged!(0.25);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    final savedB = (await storage.loadProgress(b.id))!;
    expect(savedB.chapterIndex, lessThan(savedA.chapterIndex));
    await open(a);
    await assertVisible();
    expect(visible().first.index, aIndex);
    expect(visible().first.itemLeadingEdge, closeTo(aEdge, 0.025));
    await tester.tapAt(const Offset(360, 360)); await tester.pumpAndSettle();
    await assertVisible();
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  testWidgets('swipe and scroll modes are exclusive and text options persist', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    final storage = AppStorage();
    final settings = ReadingSettings()..wordHighlightEnabled = true..pageTurnMode = 'swipe'..fontSize = 64;
    await storage.saveSettings(settings.toJson());
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: sample('modes'), storage: storage)));
    await tester.pumpAndSettle();
    final list = find.byKey(const ValueKey('reader-body'));
    int firstIndex() => (tester.widget<ScrollablePositionedList>(list).itemPositionsNotifier!.itemPositions.value
      .where((p) => p.itemTrailingEdge > 0 && p.itemLeadingEdge < 1).toList()..sort((a,b) => a.index.compareTo(b.index))).first.index;
    final initial = firstIndex();
    await tester.tapAt(const Offset(360, 360)); await tester.pumpAndSettle();
    expect(firstIndex(), initial, reason: 'Swipe mode ignores side taps');
    await tester.drag(list, const Offset(-220, 0)); await tester.pumpAndSettle();
    final after = tester.widget<ScrollablePositionedList>(list).itemPositionsNotifier!.itemPositions.value
      .firstWhere((p) => p.index == firstIndex()).itemLeadingEdge;
    expect(firstIndex() > initial || after < 0, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    settings.pageTurnMode = 'scroll'; settings.fontSize = 20; await storage.saveSettings(settings.toJson());
    final speech = _TestSpeech();
    final wordPreviewKey = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(key: wordPreviewKey,
      child: MaterialApp(debugShowCheckedModeBanner: false,
        home: ReaderScreen(book: sample('scroll'), storage: storage, ttsReader: speech))));
    await tester.pumpAndSettle();
    expect(tester.widget<ScrollablePositionedList>(list).physics, isA<ClampingScrollPhysics>());
    for (var i = 0; i < 40; i++) { await tester.drag(list, const Offset(0, -700)); await tester.pumpAndSettle(); }
    final scrollIndex = firstIndex();
    expect(scrollIndex, greaterThan(60));
    await tester.drag(list, const Offset(-220, 0)); await tester.pumpAndSettle();
    expect(firstIndex(), scrollIndex, reason: 'Scroll mode ignores horizontal swipes');
    // Enter speech mode far from the list's initial anchor. Do not depend on
    // internet audio: its loading frame must keep the same visible paragraph.
    final before = tester.widget<ScrollablePositionedList>(list).itemPositionsNotifier!.itemPositions.value
      .where((p) => p.itemTrailingEdge > 0 && p.itemLeadingEdge < 1).toList();
    await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('朗读'));
    await tester.pump(); await tester.pump(const Duration(milliseconds: 32));
    expect(tester.widget<ScrollablePositionedList>(list).itemPositionsNotifier!.itemPositions.value
      .where((p) => p.itemTrailingEdge > 0 && p.itemLeadingEdge < 1), isNotEmpty);
    expect(before, isNotEmpty); expect(tester.takeException(), isNull);
    expect(find.text('上下拖动连续切句，松手确认'), findsOneWidget);
    expect(speech.startedAt, greaterThan(0), reason: 'Speech must start at the visible sentence rather than the chapter start');
    speech.onWordChanged?.call(speech.currentTtsOffset, speech.currentTtsOffset + 2);
    await tester.pump();
    final spans = <TextSpan>[];
    void collect(InlineSpan span) { if (span is TextSpan) { spans.add(span); for (final child in span.children ?? <InlineSpan>[]) { collect(child); } } }
    for (final text in tester.widgetList<Text>(find.byType(Text))) { if (text.textSpan != null) collect(text.textSpan!); }
    expect(spans.any((s) => s.style?.backgroundColor == const Color(0xFF9BC5DD)), isTrue,
      reason: 'The current word has a stronger highlight');
    expect(spans.any((s) => s.style?.backgroundColor == const Color(0x44FFC107)), isTrue,
      reason: 'The rest of the sentence stays highlighted');
    if (Platform.isLinux && Platform.environment['DD_READER_CAPTURE_UI_PREVIEWS'] == '1') {
      await tester.pump();
      await tester.runAsync(() async {
        final boundary = wordPreviewKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory('build/ui-previews').create(recursive: true);
        await File('build/ui-previews/reader-word-highlight.png').writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.tapAt(const Offset(195, 360)); await tester.pumpAndSettle();
    final volume = find.byKey(const ValueKey('reading-volume-slider'));
    final speed = find.byKey(const ValueKey('reading-rate-slider'));
    expect(tester.getRect(volume).width, closeTo(tester.getRect(speed).width, 0.1));
    expect(tester.getRect(volume).left, closeTo(tester.getRect(speed).left, 0.1));
    expect(tester.getCenter(speed).dy, closeTo(tester.getCenter(find.byKey(const ValueKey('reading-rate-minus'))).dy, 0.1));
    expect(tester.getCenter(speed).dy, closeTo(tester.getCenter(find.byKey(const ValueKey('reading-rate-plus'))).dy, 0.1));
    expect(tester.widget<Slider>(speed).max, 2);
    expect(tester.widget<Slider>(speed).divisions, 75);
    tester.widget<Slider>(speed).onChanged!(2.4); await tester.pumpAndSettle();
    expect((await storage.loadSettings())['speechRate'], 2);
    final savedSpeech = await storage.loadBookSpeech('scroll');
    expect(savedSpeech?['voice'], TtsReader.defaultVoice);
    expect(savedSpeech?['rate'], 2);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    final nextSpeech = _TestSpeech();
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: sample('rate-restored'), storage: storage, ttsReader: nextSpeech)));
    await tester.pumpAndSettle();
    expect(nextSpeech.speechRate, 2);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  testWidgets('speech sentence and word highlights follow across paragraphs and offscreen', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    final storage = AppStorage();
    final settings = ReadingSettings()..wordHighlightEnabled = true..fontSize = 20..mergeNonSentenceBreaks = false..firstLineIndent = false;
    await storage.saveSettings(settings.toJson());
    String sentence(int paragraph, int sentence) => sentence == 0
      ? '第${paragraph.toString().padLeft(2, '0')}段清晨风吹过树林。' : '朋友在第${paragraph.toString().padLeft(2, '0')}段带来问候。';
    final book = Book(id: 'speech-paragraph-follow', title: '跨段朗读', filePath: '', format: BookFormat.txt,
      addedAt: DateTime(2026), chapters: [Chapter(title: '第一章', paragraphs: List.generate(36, (p) => Paragraph(
        display: sentence(p, 0) + sentence(p, 1), tts: '', sentences: const [], sentenceStartTts: const [])))]);
    final speech = _TestSpeech();
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: book, storage: storage, ttsReader: speech)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('朗读')); await tester.pumpAndSettle();
    expect(speech.startedAt, 0);
    final body = find.byKey(const ValueKey('reader-body'));
    final viewport = tester.getRect(body);
    final initialPositions = tester.widget<ScrollablePositionedList>(body).itemPositionsNotifier!.itemPositions.value;
    expect(initialPositions.any((p) => p.index == 21 && p.itemLeadingEdge < 1 && p.itemTrailingEdge > 0), isFalse,
      reason: 'The final test paragraph must start outside the viewport');
    List<TextSpan> coloredSpans(Text text) {
      final found = <TextSpan>[];
      void visit(InlineSpan span) {
        if (span is! TextSpan) return;
        if (span.style?.backgroundColor == const Color(0xFF9BC5DD) ||
            span.style?.backgroundColor == const Color(0x44FFC107)) found.add(span);
        for (final child in span.children ?? <InlineSpan>[]) { visit(child); }
      }
      if (text.textSpan != null) visit(text.textSpan!);
      return found;
    }
    String plain(InlineSpan span) => span.toPlainText().replaceAll('\u200B', '');
    // Exercise every sentence transition, including the first sentence of a
    // different paragraph. Cached list children must lose their old highlight.
    for (var p = 0; p <= 20; p++) {
      for (var s = 0; s < 2; s++) {
        speech.onSentenceChanged?.call(p * 2 + s);
        speech.onWordChanged?.call(0, 3);
        await tester.pumpAndSettle();
        final rich = tester.widgetList<Text>(find.byType(Text)).where((w) => w.textAlign == TextAlign.justify).toList();
        final highlighted = rich.where((w) => coloredSpans(w).isNotEmpty).toList();
        expect(highlighted, hasLength(1), reason: 'Only paragraph $p may retain speech colors');
        final current = highlighted.single;
        expect(plain(current.textSpan!), contains(sentence(p, s)));
        final spans = coloredSpans(current);
        final paragraphFinder = find.byWidgetPredicate((w) => identical(w, current));
        final render = tester.renderObject<RenderParagraph>(paragraphFinder);
        final displayed = current.textSpan!.toPlainText();
        final clipFinder = find.byKey(const ValueKey('reader-page-clip'));
        final clipSize = tester.getSize(clipFinder);
        final clip = tester.widget<ClipRect>(clipFinder).clipper?.getClip(clipSize) ?? (Offset.zero & clipSize);
        final origin = render.localToGlobal(Offset.zero) - tester.getTopLeft(clipFinder);
        final plainOffsets = [for (var i = 0; i < displayed.length; i++) if (displayed[i] != '\u200B') i];
        final sentenceStart = displayed.replaceAll('\u200B', '').indexOf(sentence(p, s));
        expect(sentenceStart, greaterThanOrEqualTo(0));
        var visibleEnd = 0;
        // A sentence can straddle a fixed page cut. Compute the expected
        // highlighted prefix from actual glyph boxes and the page clip,
        // independently of the produced color spans.
        for (var i = 0; i < sentence(p, s).length; i++) {
          final offset = plainOffsets[sentenceStart + i];
          final boxes = render.getBoxesForSelection(TextSelection(
            baseOffset: offset, extentOffset: offset + 1),
            boxHeightStyle: ui.BoxHeightStyle.tight);
          if (boxes.isEmpty || boxes.any((box) => box.top + origin.dy < clip.top - 0.5 ||
              box.bottom + origin.dy > clip.bottom + 0.5)) break;
          visibleEnd = i + 1;
        }
        expect(visibleEnd, greaterThan(0), reason: 'The active sentence must actually begin inside the page clip');
        final wordEnd = visibleEnd < 3 ? visibleEnd : 3;
        expect(spans.where((w) => w.style?.backgroundColor == const Color(0xFF9BC5DD)).map(plain).join(),
          sentence(p, s).substring(0, wordEnd), reason: 'The visible word cursor must move into paragraph $p sentence $s');
        expect(spans.where((w) => w.style?.backgroundColor == const Color(0x44FFC107)).map(plain).join(),
          sentence(p, s).substring(wordEnd, visibleEnd), reason: 'The current sentence must follow the audio up to the actual page cut');
        final position = tester.widget<ScrollablePositionedList>(body).itemPositionsNotifier!.itemPositions.value
          .singleWhere((pos) => pos.index == p + 1);
        expect(position.itemLeadingEdge, lessThan(1));
        expect(position.itemTrailingEdge, greaterThan(0));
        final glyphOffset = displayed.indexOf(sentence(p, s).substring(0, 1));
        final glyph = render.getBoxesForSelection(TextSelection(baseOffset: glyphOffset, extentOffset: glyphOffset + 1)).first;
        final cursorY = render.localToGlobal(Offset(glyph.left, glyph.top)).dy;
        expect(cursorY, greaterThanOrEqualTo(viewport.top - 1));
        expect(cursorY, lessThan(viewport.bottom), reason: 'The actual highlighted glyph must scroll onscreen');
        expect(tester.takeException(), isNull);
      }
    }
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  testWidgets('speech respects previous page limits and replays events received during a page turn', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    final storage = AppStorage();
    await storage.saveSettings((ReadingSettings()..wordHighlightEnabled = true..fontSize = 20..mergeNonSentenceBreaks = false
      ..pageTurnMode = 'tap'..firstLineIndent = false).toJson());
    String sentence(int paragraph, int sentence) => sentence == 0
      ? '第${paragraph.toString().padLeft(2, '0')}段清晨风吹过树林。' : '朋友在第${paragraph.toString().padLeft(2, '0')}段带来问候。';
    final book = Book(id: 'speech-after-paging', title: '翻页后朗读', filePath: '', format: BookFormat.txt,
      addedAt: DateTime(2026), chapters: [Chapter(title: '第一章', paragraphs: List.generate(36, (p) => Paragraph(
        display: sentence(p, 0) + sentence(p, 1), tts: '', sentences: const [], sentenceStartTts: const [])))]);
    final speech = _TestSpeech();
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: book, storage: storage, ttsReader: speech)));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(360, 360)); await tester.pumpAndSettle();
    await tester.tapAt(const Offset(360, 360)); await tester.pumpAndSettle();
    await tester.tapAt(const Offset(30, 360)); await tester.pumpAndSettle();
    await tester.tapAt(const Offset(195, 300)); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('朗读')); await tester.pumpAndSettle();
    expect(speech.startedAt, greaterThan(0), reason: 'Exercise a backward page endpoint before starting speech');
    Future<void> assertCursor(int idx) async {
      await tester.pumpAndSettle();
      final expected = sentence(idx ~/ 2, idx % 2);
      final highlighted = <(Text, TextSpan)>[];
      void visit(Text text, InlineSpan span) {
        if (span is! TextSpan) return;
        if (span.style?.backgroundColor == const Color(0xFF9BC5DD)) highlighted.add((text, span));
        for (final child in span.children ?? <InlineSpan>[]) { visit(text, child); }
      }
      for (final text in tester.widgetList<Text>(find.byType(Text))) {
        if (text.textSpan != null) visit(text, text.textSpan!);
      }
      expect(highlighted, hasLength(1));
      final (text, word) = highlighted.single;
      final blue = word.toPlainText().replaceAll('\u200B', '');
      expect(blue, expected.substring(0, 3), reason: 'Queued word offsets belong to the new sentence');
      expect(text.textSpan!.toPlainText().replaceAll('\u200B', ''), contains(expected));
      final render = tester.renderObject<RenderParagraph>(find.byWidgetPredicate((w) => identical(w, text)));
      final start = text.textSpan!.toPlainText().indexOf(blue);
      final line = render.getBoxesForSelection(TextSelection(baseOffset: start, extentOffset: start + 1),
        boxHeightStyle: ui.BoxHeightStyle.tight).first;
      final clipFinder = find.byKey(const ValueKey('reader-page-clip'));
      final clip = tester.widget<ClipRect>(clipFinder);
      final clipSize = tester.getSize(clipFinder);
      final bounds = clip.clipper?.getClip(clipSize) ?? (Offset.zero & clipSize);
      final origin = render.localToGlobal(Offset.zero) - tester.getTopLeft(clipFinder);
      final glyph = line.toRect().shift(origin);
      expect(glyph.top, greaterThanOrEqualTo(bounds.top - 0.5));
      expect(glyph.bottom, lessThanOrEqualTo(bounds.bottom + 0.5),
        reason: 'The complete highlighted line must fit inside the actual page clip');
      expect(tester.takeException(), isNull);
    }
    for (var idx = speech.startedAt; idx < speech.startedAt + 14; idx++) {
      speech.onSentenceChanged?.call(idx); speech.onWordChanged?.call(0, 3);
      await assertCursor(idx);
    }
    // An event from the outgoing audio must not override the manual seek.
    speech.recordJumps = true;
    await tester.tapAt(const Offset(360, 360)); await tester.pump(const Duration(milliseconds: 16));
    speech.onSentenceChanged?.call(60); speech.onWordChanged?.call(0, 3);
    await tester.pumpAndSettle();
    expect(speech.jumpCalls, 1);
    expect(speech.currentIndex, isNot(60));
    final position = speech.currentIndex;
    speech.onSentenceChanged?.call(position); speech.onWordChanged?.call(0, 3);
    await assertCursor(position);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  for (final target in [
    ('zh-CN-YunxiNeural', '云希（男·阳光）'),
    (TtsReader.systemVoice, '系统默认测试音色'),
  ]) {
    testWidgets('changing paused speech voice to ${target.$1} resumes UI follow state', (tester) async {
      tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
      final speech = _TestSpeech();
      final storage = AppStorage();
      await storage.saveSettings((ReadingSettings()..wordHighlightEnabled = true..fontSize = 20..voice = TtsReader.defaultVoice).toJson());
      await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: sample('voice-follow-${target.$1}'),
        storage: storage, ttsReader: speech)));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('朗读')); await tester.pumpAndSettle();
      await tester.tapAt(const Offset(195, 360)); await tester.pumpAndSettle();
      expect(speech.state, TtsState.paused);
      expect(find.byKey(const ValueKey('reading-volume-slider')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('reading-voice'))); await tester.pumpAndSettle();
      final voiceRow = target.$1 == TtsReader.systemVoice
        ? find.byKey(const ValueKey('system-engine-')) : find.widgetWithText(ListTile, target.$2);
      await _ensureVoiceRowVisible(tester, voiceRow);
      await tester.tap(voiceRow); await tester.pumpAndSettle();
      expect(speech.voice, target.$1);
      expect(speech.state, TtsState.playing);
      expect(find.byKey(const ValueKey('reading-volume-slider')), findsNothing,
        reason: 'Changing voice restarts audio and must also leave the paused UI state');
      final body = find.byKey(const ValueKey('reader-body'));
      for (var idx = 14; idx <= 27; idx++) {
        speech.onSentenceChanged?.call(idx); speech.onWordChanged?.call(0, 2);
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 100));
        final expectedParagraph = idx ~/ 7;
        final expectedSentence = idx % 7;
        final blue = <TextSpan>[];
        final yellow = <TextSpan>[];
        Text? highlighted;
        void visit(Text text, InlineSpan span) {
          if (span is! TextSpan) return;
          if (span.style?.backgroundColor == const Color(0xFF9BC5DD)) { blue.add(span); highlighted = text; }
          if (span.style?.backgroundColor == const Color(0x44FFC107)) yellow.add(span);
          for (final child in span.children ?? <InlineSpan>[]) { visit(text, child); }
        }
        for (final text in tester.widgetList<Text>(find.byType(Text))) {
          if (text.textSpan != null) visit(text, text.textSpan!);
        }
        expect(blue, hasLength(1));
        expect(highlighted!.textSpan!.toPlainText().replaceAll('\u200B', ''),
          contains('第1章第${expectedParagraph + 1}段。'));
        final blueText = blue.single.toPlainText().replaceAll('\u200B', '');
        expect(blueText, expectedSentence == 0 ? '第1' : '山间',
          reason: 'A scroll notification must not move the word cursor back to the viewport start');
        final yellowText = yellow.map((span) => span.toPlainText().replaceAll('\u200B', '')).join();
        final trailing = expectedSentence == 0 ? '章第${expectedParagraph + 1}段。' : '的风吹过树林，远方传来朋友的问候。';
        expect(trailing, startsWith(yellowText));
        final positions = tester.widget<ScrollablePositionedList>(body).itemPositionsNotifier!.itemPositions.value;
        expect(positions.any((p) => p.index == expectedParagraph + 1 && p.itemLeadingEdge < 1 && p.itemTrailingEdge > 0), isTrue);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    });
  }

  testWidgets('paused cursor survives layout drift and foreground return never restarts speech', (tester) async {
    var entryResets = 0;
    final previousLayoutHook = ReaderScreen.onLayoutWorkForTesting;
    ReaderScreen.onLayoutWorkForTesting = (event, count) {
      previousLayoutHook?.call(event, count);
      if (event == 'jointEntryReset') entryResets += count;
    };
    addTearDown(() => ReaderScreen.onLayoutWorkForTesting = previousLayoutHook);
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    final storage = AppStorage();
    await storage.saveSettings((ReadingSettings()..wordHighlightEnabled = true..fontSize = 20..mergeNonSentenceBreaks = false..firstLineIndent = false).toJson());
    String sentence(int p, int s) => (s == 0 ? '第${p}段第一句' : '第${p}段第二句') +
      List.filled(7, s == 0 ? '清晨山间的风吹过树林，' : '远方朋友带来温暖的问候，').join() + '。';
    final book = Book(id: 'speech-lock-position', title: '锁屏进度', filePath: '', format: BookFormat.txt,
      addedAt: DateTime(2026), chapters: [Chapter(title: '第一章', paragraphs: List.generate(12, (p) => Paragraph(
        display: sentence(p, 0) + sentence(p, 1), tts: '', sentences: const [], sentenceStartTts: const [])))]);
    final speech = _TestSpeech();
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: book, storage: storage, ttsReader: speech)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('朗读')); await tester.pumpAndSettle();
    void emit(int idx) { speech.emitSentence(idx); speech.onWordChanged?.call(0, 2); }
    void assertCursor(int idx) {
      final blue = <String>[], yellow = <String>[];
      String? paragraph;
      void visit(Text text, InlineSpan span) {
        if (span is! TextSpan) return;
        final content = span.toPlainText().replaceAll('\u200B', '');
        if (span.style?.backgroundColor == const Color(0xFF9BC5DD)) {
          blue.add(content); paragraph = text.textSpan!.toPlainText().replaceAll('\u200B', '');
        }
        if (span.style?.backgroundColor == const Color(0x44FFC107)) yellow.add(content);
        for (final child in span.children ?? <InlineSpan>[]) { visit(text, child); }
      }
      for (final text in tester.widgetList<Text>(find.byType(Text))) {
        if (text.textSpan != null) visit(text, text.textSpan!);
      }
      final expected = sentence(idx ~/ 2, idx % 2);
      expect(blue, [expected.substring(0, 2)]);
      expect(expected.substring(2), startsWith(yellow.join()),
        reason: 'Only the on-page part of the sentence gets a yellow background');
      expect(paragraph, contains(expected));
    }
    emit(5); await tester.pumpAndSettle(); assertCursor(5);
    await tester.tapAt(const Offset(195, 360)); await tester.pumpAndSettle();
    expect(speech.state, TtsState.paused);
    // Simulate position notifications caused by showing controls or relayout,
    // rather than an explicit sentence/page navigation action.
    final list = tester.widget<ScrollablePositionedList>(find.byKey(const ValueKey('reader-body')));
    final drift = list.scrollOffsetController!.animateScroll(offset: -40, duration: const Duration(milliseconds: 1));
    await tester.pumpAndSettle(); await drift;
    assertCursor(5);
    await tester.pump(const Duration(milliseconds: 500));
    expect((await storage.loadProgress(book.id))!.offsetInParagraph, sentence(2, 0).length,
      reason: 'Saving while paused must preserve the speech sentence, not the viewport first line');
    final starts = speech.startCalls, resumes = speech.resumeCalls;
    expect(find.text('锁屏'), findsNothing, reason: 'Playback controls use the system lock screen');
    await tester.tapAt(const Offset(195, 360)); await tester.pumpAndSettle();
    expect(speech.startCalls, starts); expect(speech.resumeCalls, resumes + 1);
    assertCursor(5);
    emit(7); await tester.pumpAndSettle();
    emit(8); await tester.pumpAndSettle();
    expect(speech.currentIndex, 8); assertCursor(8);
    expect(speech.state, TtsState.playing);
    expect(speech.startCalls, starts); expect(speech.resumeCalls, resumes + 1,
      reason: 'Sentence callbacks must follow the existing stream without restarting');
    // System background/foreground changes also never issue audio commands.
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive); await tester.pump();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused); emit(10); emit(11);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed); await tester.pumpAndSettle();
    expect(speech.currentIndex, 11); assertCursor(11);
    expect(speech.startCalls, starts); expect(speech.resumeCalls, resumes + 1);
    expect(entryResets, greaterThan(0), reason: 'Viewport drift must retire overlapping old cuts before replanning');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  testWidgets('word highlight after a silent dash maps to its own display segment', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    final storage = AppStorage();
    await storage.saveSettings((ReadingSettings()..wordHighlightEnabled = true..firstLineIndent = false).toJson());
    final book = Book(id: 'dash-word-offset', title: '破折号光标', filePath: '', format: BookFormat.txt,
      addedAt: DateTime(2026), chapters: const [Chapter(title: '第一章', paragraphs: [Paragraph(
        display: '你好——世界', tts: '', sentences: [], sentenceStartTts: [])])]);
    final speech = _TestSpeech();
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: book, storage: storage, ttsReader: speech)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('朗读')); await tester.pumpAndSettle();
    expect(speech.lastSentences, ['你好', '世界']);
    expect(speech.lastPauses, [200, 300]);
    speech.emitSentence(1); speech.onWordChanged?.call(0, 2); await tester.pumpAndSettle();
    final paragraph = tester.widget<Text>(find.byWidgetPredicate((w) => w is Text && w.textAlign == TextAlign.justify &&
      (w.textSpan?.toPlainText().replaceAll('\u200B', '') == '你好——世界')));
    final words = <String>[];
    void visit(InlineSpan span) {
      if (span is! TextSpan) return;
      if (span.style?.backgroundColor == const Color(0xFF9BC5DD)) words.add(span.toPlainText().replaceAll('\u200B', ''));
      for (final child in span.children ?? <InlineSpan>[]) { visit(child); }
    }
    visit(paragraph.textSpan!);
    expect(words, ['世界'], reason: 'Skipped speech dashes must not shift the word cursor to the dash');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  testWidgets('media stop cancels a pending screen resume without restoring playback UI', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    final handler = TtsAudioHandler(), previousHandler = globalAudioHandler;
    globalAudioHandler = handler;
    addTearDown(() { globalAudioHandler = previousHandler; });
    final speech = _TestSpeech();
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: sample('stop-during-resume'),
      storage: AppStorage(), ttsReader: speech)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('朗读')); await tester.pumpAndSettle();
    await tester.tapAt(const Offset(195, 360)); await tester.pumpAndSettle();
    expect(speech.state, TtsState.paused);
    final pending = Completer<bool>(); speech.resumeResult = pending;
    final resume = handler.play(); await tester.pump();
    expect(speech.resumeCalls, 1);
    await handler.stop(); await tester.pumpAndSettle();
    expect(handler.playbackState.value.playing, isFalse);
    pending.complete(true); await resume; await tester.pumpAndSettle();
    expect(handler.playbackState.value.playing, isFalse,
      reason: 'Late resume completion must not overwrite the explicit stop state');
    expect(find.byTooltip('朗读'), findsOneWidget);
    expect(find.byKey(const ValueKey('reading-volume-slider')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    await handler.playbackState.close(); await handler.mediaItem.close();
  });

  for (final grant in [false, true]) {
    testWidgets('foreground playback handles notification permission grant=$grant and settings refresh', (tester) async {
      tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
      var enabled = false, asked = false, requests = 0, settingsOpened = 0;
      Map<String, bool> status() => {'supported': true, 'enabled': enabled, 'canRequest': !asked, 'asked': asked};
      messenger.setMockMethodCallHandler(PlaybackNotifications.channel, (call) async {
        if (call.method == 'requestNotificationPermission') { requests++; asked = true; enabled = grant; }
        if (call.method == 'openNotificationSettings') { settingsOpened++; return true; }
        return status();
      });
      final speech = _TestSpeech();
      await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: sample('notifications-$grant'),
        storage: AppStorage(), ttsReader: speech)));
      await tester.pumpAndSettle();
      expect(requests, 0, reason: 'Opening a book must not prompt without a playback gesture');
      await tester.tap(find.byTooltip('朗读')); await tester.pumpAndSettle();
      expect(requests, 1); expect(speech.state, TtsState.playing);
      expect(speech.startCalls, 1, reason: 'Denying notification permission must not block reading');
      expect(find.text(grant ? '播放通知已开启' : '播放通知未开启，仍可继续朗读。可在系统设置中开启。'), findsOneWidget);
      expect(find.byKey(const ValueKey('playback-notifications')), findsNothing);
      if (!grant) {
        await tester.tap(find.text('打开设置')); await tester.pumpAndSettle();
        expect(settingsOpened, 1);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive); await tester.pump();
        enabled = true;
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed); await tester.pumpAndSettle();
        expect(find.text('播放通知已开启'), findsOneWidget,
          reason: 'The permission-result settings action still refreshes status after returning');
      }
      ScaffoldMessenger.of(tester.element(find.byKey(const ValueKey('reader-body')))).hideCurrentSnackBar();
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(195, 360)); await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('playback-notifications')), findsNothing);
      expect(settingsOpened, grant ? 0 : 1);
      expect(requests, 1);
      ScaffoldMessenger.of(tester.element(find.byKey(const ValueKey('reader-body')))).hideCurrentSnackBar();
      await tester.pumpAndSettle();
      await tester.tap(find.text('退出')); await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('朗读')); await tester.pumpAndSettle();
      expect(requests, 1, reason: 'Restarting playback must not repeat the permission prompt');
      await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    });
  }

  testWidgets('media playback does not request notification permission', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    var requests = 0;
    messenger.setMockMethodCallHandler(PlaybackNotifications.channel, (call) async {
      if (call.method == 'requestNotificationPermission') requests++;
      return {'supported': true, 'enabled': false, 'canRequest': true, 'asked': false};
    });
    final handler = TtsAudioHandler(), previousHandler = globalAudioHandler;
    globalAudioHandler = handler;
    addTearDown(() { globalAudioHandler = previousHandler; });
    final speech = _TestSpeech();
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: sample('media-notification-permission'),
      storage: AppStorage(), ttsReader: speech)));
    await tester.pumpAndSettle();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive); await tester.pump();
    await handler.play(); await tester.pumpAndSettle();
    expect(speech.startCalls, 1); expect(requests, 0);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed); await tester.pumpAndSettle();
    expect(requests, 0);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    await handler.playbackState.close(); await handler.mediaItem.close();
  });

  testWidgets('permission result delivered while inactive waits for resumed before starting once', (tester) async {
    final permission = Completer<Map<String, bool>>();
    var asked = false;
    messenger.setMockMethodCallHandler(PlaybackNotifications.channel, (call) async {
      if (call.method == 'requestNotificationPermission') { asked = true; return permission.future; }
      return {'supported': true, 'enabled': asked && permission.isCompleted, 'canRequest': !asked, 'asked': asked};
    });
    final speech = _TestSpeech();
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: sample('inactive-permission-result'),
      storage: AppStorage(), ttsReader: speech)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('朗读')); await tester.pump();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive); await tester.pump();
    permission.complete({'supported': true, 'enabled': true, 'canRequest': false, 'asked': true});
    await tester.pump();
    expect(speech.startCalls, 0, reason: 'Permission result alone must not play before foreground resumes');
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed); await tester.pumpAndSettle();
    expect(speech.startCalls, 1); expect(speech.state, TtsState.playing);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive); await tester.pump();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed); await tester.pumpAndSettle();
    expect(speech.startCalls, 1, reason: 'Later foreground events only refresh current playback');
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  for (final leaveReader in [false, true]) {
    testWidgets('permission completion after leaving foreground reader=$leaveReader does not start speech', (tester) async {
      final permission = Completer<Map<String, bool>>();
      messenger.setMockMethodCallHandler(PlaybackNotifications.channel, (call) async {
        if (call.method == 'requestNotificationPermission') return permission.future;
        return {'supported': true, 'enabled': false, 'canRequest': true, 'asked': false};
      });
      final speech = _TestSpeech();
      await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: sample('leave-permission-$leaveReader'),
        storage: AppStorage(), ttsReader: speech)));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('朗读')); await tester.pump();
      if (leaveReader) {
        await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
      } else {
        binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive); await tester.pump();
        binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden); await tester.pump();
        binding.handleAppLifecycleStateChanged(AppLifecycleState.paused); await tester.pump();
      }
      permission.complete({'supported': true, 'enabled': true, 'canRequest': false, 'asked': true});
      await tester.pump();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed); await tester.pumpAndSettle();
      expect(speech.startCalls, 0); expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    });
  }

  for (final width in [320.0, 390.0]) {
    for (final engine in [('iOS-婷婷', '婷婷'), ('AiService TTS', 'AiService')]) {
      testWidgets('playback action slots remain equally spaced at width $width with ${engine.$1}', (tester) async {
        tester.view.devicePixelRatio = 1; tester.view.physicalSize = Size(width, 844);
        addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
        messenger.setMockMethodCallHandler(SystemTtsClient.channel, (call) async => call.method == 'voiceCatalog'
          ? {'defaultEngine': 'engine.local', 'engines': [{'id': 'engine.local', 'name': engine.$1}]} : null);
        final storage = AppStorage();
        final selected = '${SystemTtsClient.voicePrefix}${SystemTtsClient.engineVoiceIdentifier('engine.local', '')}';
        await storage.saveSettings((ReadingSettings()..voice = selected).toJson());
        await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: sample('equal-actions-$width-${engine.$2}'),
          storage: storage, ttsReader: _TestSpeech())));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('朗读')); await tester.pumpAndSettle();
        await tester.tapAt(Offset(width / 2, 360)); await tester.pumpAndSettle();
        final row = tester.getRect(find.byKey(const ValueKey('reading-actions')));
        final actions = [for (final key in ['reading-sleep', 'reading-voice', 'playback-settings', 'reading-exit'])
          find.byKey(ValueKey(key))];
        final boxes = actions.map(tester.getRect).toList();
        final slotWidth = row.width / actions.length;
        for (var index = 0; index < boxes.length; index++) {
          expect(boxes[index].width, closeTo(slotWidth, .5));
          expect(boxes[index].center.dx, closeTo(row.left + slotWidth * (index + .5), .5));
          if (index > 0) expect(boxes[index].center.dx - boxes[index - 1].center.dx, closeTo(slotWidth, .5));
          final caption = find.descendant(of: actions[index], matching: find.byType(Text)).first;
          expect(tester.renderObject<RenderParagraph>(caption).text.style!.fontSize, 11,
            reason: 'Long engine names must not change the font size of one action');
        }
        final voice = actions[1];
        final caption = find.descendant(of: voice, matching: find.text(engine.$2));
        expect(caption, findsOneWidget);
        expect(tester.renderObject<RenderParagraph>(caption).didExceedMaxLines, isFalse,
          reason: 'A local engine short name may use two lines within its equal-width slot');
        expect(tester.getRect(caption).left, greaterThanOrEqualTo(boxes[1].left - .5));
        expect(tester.getRect(caption).right, lessThanOrEqualTo(boxes[1].right + .5));
        expect(tester.widget<Tooltip>(find.ancestor(of: voice, matching: find.byType(Tooltip)).first).message,
          '音源：${engine.$1}');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
      });
    }
  }

  testWidgets('playback preloading persists and custom timer accepts only 1 to 120 minutes', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    final storage = AppStorage(), speech = _TestSpeech();
    final preview = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(key: preview, child: MaterialApp(
      home: ReaderScreen(book: sample('speech-options'), storage: storage, ttsReader: speech))));
    await tester.pumpAndSettle();
    expect(speech.prefetchSentences, 8);
    await tester.tap(find.byTooltip('朗读')); await tester.pumpAndSettle();
    await tester.tapAt(const Offset(195, 360)); await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reading-cache')), findsNothing);
    expect(find.descendant(of: find.byKey(const ValueKey('reading-voice')), matching: find.text('音源：晓晓')), findsOneWidget);
    expect(tester.widget<Text>(find.descendant(of: find.byKey(const ValueKey('reading-voice')),
      matching: find.byType(Text))).maxLines, 1);
    await _captureReaderPreview(tester, preview, 'reader-speech-controls');
    await tester.tap(find.byKey(const ValueKey('playback-settings'))); await tester.pumpAndSettle();
    final fallback = tester.widget<SwitchListTile>(find.byKey(const ValueKey('system-fallback-enabled')));
    expect(fallback.value, isFalse);
    fallback.onChanged!(true); await tester.pumpAndSettle();
    expect((await storage.loadSettings())['systemFallbackEnabled'], isTrue);
    await tester.tap(find.byKey(const ValueKey('reading-prefetch'))); await tester.pumpAndSettle();
    final prefetch = find.byKey(const ValueKey('prefetch-number'));
    await tester.enterText(prefetch, '101'); await tester.tap(find.text('确定')); await tester.pumpAndSettle();
    expect(prefetch, findsOneWidget, reason: 'Prefetch values above 100 must be rejected');
    await tester.enterText(prefetch, '100'); await tester.tap(find.text('确定')); await tester.pumpAndSettle();
    expect(speech.prefetchSentences, 100); expect((await storage.loadSettings())['prefetchSentences'], 100);
    await tester.tap(find.byKey(const ValueKey('reading-prefetch'))); await tester.pumpAndSettle();
    await tester.enterText(prefetch, '0'); await tester.tap(find.text('确定')); await tester.pumpAndSettle();
    expect(speech.prefetchSentences, 0); expect((await storage.loadSettings())['prefetchSentences'], 0);
    await tester.tapAt(const Offset(195, 80)); await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reading-sleep'))); await tester.pumpAndSettle();
    for (final minutes in [0, 15, 30, 60, 90]) {
      expect(find.byKey(ValueKey('sleep-preset-$minutes')), findsOneWidget);
    }
    await tester.ensureVisible(find.byKey(const ValueKey('sleep-custom')));
    await tester.tap(find.byKey(const ValueKey('sleep-custom'))); await tester.pumpAndSettle();
    final custom = find.byKey(const ValueKey('sleep-custom-minutes'));
    await tester.enterText(custom, '121'); await tester.tap(find.text('确定')); await tester.pumpAndSettle();
    expect(custom, findsOneWidget, reason: 'The custom timer must enforce the 120 minute maximum');
    await tester.enterText(custom, '120'); await tester.tap(find.text('确定')); await tester.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const ValueKey('reading-sleep')), matching: find.text('120 分')), findsOneWidget);
    tester.view.physicalSize = const Size(844, 390); await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(const ValueKey('reading-panel'))).top, greaterThanOrEqualTo(0));
    await _captureReaderPreview(tester, preview, 'reader-speech-controls-landscape');
    await tester.tap(find.byKey(const ValueKey('reading-sleep'))); await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('sleep-custom')));
    await tester.tap(find.byKey(const ValueKey('sleep-custom'))); await tester.pumpAndSettle();
    await tester.enterText(custom, '1'); await tester.tap(find.text('确定')); await tester.pumpAndSettle();
    await tester.tapAt(const Offset(422, 80)); await tester.pumpAndSettle();
    expect(speech.state, TtsState.playing);
    await tester.pump(const Duration(minutes: 1)); await tester.pumpAndSettle();
    expect(speech.state, TtsState.paused, reason: 'The custom minute timer must actually pause playback');
    expect(find.descendant(of: find.byKey(const ValueKey('reading-sleep')), matching: find.text('定时')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    final restored = _TestSpeech();
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: sample('prefetch-restored'), storage: storage, ttsReader: restored)));
    await tester.pumpAndSettle(); expect(restored.prefetchSentences, 0);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  testWidgets('cache panel appears before disk scan and cancellation keeps the reader open', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    final storage = AppStorage(), speech = _TestSpeech();
    await storage.saveSettings((ReadingSettings()..voice = TtsReader.defaultVoice..speechRate = 1.8).toJson());
    final book = sample('cache-slow-scan');
    final formatted = ReadingText.format(book, merge: true, indent: true);
    final fingerprint = 'words2-${ReadingText.fingerprint(formatted)}';
    final store = _GatedScanStore(book.id, fingerprint);
    final task = BookCacheTask(book: formatted, bookId: book.id, store: store);
    final key = '${book.id}/$fingerprint/${TtsReader.defaultVoice}/1.80';
    activeBookCaches[key] = task;
    addTearDown(() {
      if (!store.gate.isCompleted) store.gate.complete(<String>{});
      activeBookCaches.remove(key);
    });
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: book, storage: storage, ttsReader: speech)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('朗读')); await tester.pumpAndSettle();
    await tester.tapAt(const Offset(195, 360)); await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reading-voice'))); await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cache-voice-zh-CN-XiaoxiaoNeural')));
    await tester.pump(); await tester.pump(const Duration(milliseconds: 350));
    expect(find.byKey(const ValueKey('cache-binding')), findsOneWidget);
    expect(task.status.state, 'building'); expect(store.gate.isCompleted, isFalse);
    expect(tester.widget<TextButton>(find.byKey(const ValueKey('cache-rescan'))).onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('cache-cancel'))); await tester.pump();
    expect(task.status.state, 'cancelled');
    store.gate.complete(<String>{}); await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cache-binding')), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-body')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  testWidgets('cache controls identify and clear only the selected online voice and speed', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    final root = (await tester.runAsync(() => Directory.systemTemp.createTemp('reader-selected-cache-')))!;
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(pathChannel, (_) async => root.path);
    addTearDown(() async { messenger.setMockMethodCallHandler(pathChannel, null); await root.delete(recursive: true); });
    final storage = AppStorage(), speech = _TestSpeech();
    final settings = ReadingSettings()..voice = TtsReader.defaultVoice..speechRate = 1.8;
    await storage.saveSettings(settings.toJson());
    final book = sample('cache-selected-voice');
    final formatted = ReadingText.format(book, merge: true, indent: true);
    final fingerprint = 'words2-${ReadingText.fingerprint(formatted)}';
    String key(String voice) => '${book.id}/$fingerprint/$voice/1.80';
    final first = _TestBookCacheTask(book: formatted,
      store: TtsCacheStore(book.id, TtsReader.defaultVoice, 1.8, textFingerprint: fingerprint));
    final second = _TestBookCacheTask(book: formatted,
      store: TtsCacheStore(book.id, 'zh-CN-YunxiNeural', 1.8, textFingerprint: fingerprint));
    activeBookCaches[key(TtsReader.defaultVoice)] = first; activeBookCaches[key('zh-CN-YunxiNeural')] = second;
    addTearDown(() {
      activeBookCaches.remove(key(TtsReader.defaultVoice)); activeBookCaches.remove(key('zh-CN-YunxiNeural'));
      first.statusNotifier.dispose(); second.statusNotifier.dispose();
    });
    final preview = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(key: preview, child: MaterialApp(
      home: ReaderScreen(book: book, storage: storage, ttsReader: speech))));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('朗读')); await tester.pumpAndSettle();
    await tester.tapAt(const Offset(195, 360)); await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reading-voice'))); await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cache-voice-zh-CN-XiaoxiaoNeural'))); await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const ValueKey('cache-binding'))).data, '音源: 晓晓（女·温暖） · 语速 1.80x');
    await _captureReaderPreview(tester, preview, 'reader-selected-voice-cache');
    await tester.tapAt(const Offset(195, 100)); await tester.pumpAndSettle();
    await _captureReaderPreview(tester, preview, 'reader-voice-menu-cache-actions');
    await tester.tap(find.byKey(const ValueKey('cache-voice-zh-CN-YunxiNeural'))); await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const ValueKey('cache-binding'))).data, '音源: 云希（男·阳光） · 语速 1.80x');
    expect(speech.voice, TtsReader.defaultVoice, reason: 'Opening another voice cache must not change the playing voice');
    await tester.tapAt(const Offset(195, 100)); await tester.pumpAndSettle();
    await tester.tap(find.text('云希（男·阳光）')); await tester.pumpAndSettle();
    await tester.tapAt(const Offset(195, 360)); await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reading-voice'))); await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cache-voice-zh-CN-YunxiNeural'))); await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const ValueKey('cache-binding'))).data, '音源: 云希（男·阳光） · 语速 1.80x');
    await tester.tap(find.text('清除缓存')); await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(AlertDialog), matching: find.textContaining('云希（男·阳光）')), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('确定'))); await tester.pumpAndSettle();
    expect(second.cancelCalls, 1); expect(first.cancelCalls, 0);
    expect(activeBookCaches.containsKey(key('zh-CN-YunxiNeural')), isFalse);
    expect(activeBookCaches[key(TtsReader.defaultVoice)], same(first));
    await tester.tap(find.text('开始缓存')); await tester.pumpAndSettle();
    expect(second.startCalls, 1);
    expect(activeBookCaches[key('zh-CN-YunxiNeural')], same(second),
      reason: 'Restarting from an already open cleared-cache sheet must register its controller again.');
    ScaffoldMessenger.of(tester.element(find.byKey(const ValueKey('reader-body')))).hideCurrentSnackBar();
    await tester.pumpAndSettle(); await tester.tapAt(const Offset(195, 100)); await tester.pumpAndSettle();
    final systemEngineRow = find.byKey(const ValueKey('system-engine-'));
    await _ensureVoiceRowVisible(tester, systemEngineRow);
    await tester.tap(systemEngineRow); await tester.pumpAndSettle();
    await tester.tapAt(const Offset(195, 360)); await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reading-cache')), findsNothing);
    final voiceShortcut = find.byKey(const ValueKey('reading-voice'));
    expect(find.descendant(of: voiceShortcut, matching: find.text('系统默认测试音色')), findsOneWidget);
    expect(find.descendant(of: voiceShortcut, matching: find.text('音源：系统默认测试音色')), findsNothing);
    expect(tester.widget<Tooltip>(find.ancestor(of: voiceShortcut, matching: find.byType(Tooltip)).first).message,
      '音源：系统默认测试音色');
    await tester.tap(find.byKey(const ValueKey('reading-voice'))); await tester.pumpAndSettle();
    final systemOption = find.byKey(const ValueKey('system-engine-'));
    await _ensureVoiceRowVisible(tester, systemOption);
    expect(find.descendant(of: systemOption,
      matching: find.byKey(const ValueKey('pause-voice-__system_tts__'))), findsOneWidget);
    expect(find.descendant(of: systemOption, matching: find.byIcon(Icons.download_outlined)), findsNothing);
    expect(find.descendant(of: systemOption, matching: find.byIcon(Icons.hourglass_empty)), findsOneWidget);
    expect(tester.widget<ListTile>(systemOption).subtitle, isNull);
    await tester.tapAt(const Offset(195, 100)); await tester.pumpAndSettle();
    await _captureReaderPreview(tester, preview, 'reader-system-cache-disabled');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  testWidgets('temporary system fallback persists without changing the online cache voice', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    final storage = AppStorage();
    await storage.saveSettings((ReadingSettings()..voice = TtsReader.defaultVoice..systemFallbackEnabled = true..systemFallbackActive = true).toJson());
    final speech = _TestSpeech();
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: sample('fallback-restored'), storage: storage, ttsReader: speech)));
    await tester.pumpAndSettle(); expect(speech.usingSystemFallback, isTrue); expect(speech.voice, TtsReader.defaultVoice);
    await tester.tap(find.byTooltip('朗读')); await tester.pumpAndSettle();
    await tester.tapAt(const Offset(195, 360)); await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tts-offline-fallback')), findsOneWidget);
    expect(find.text('音源：晓晓'), findsOneWidget);
    expect(find.byKey(const ValueKey('reading-cache')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('reading-voice'))); await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cache-voice-zh-CN-XiaoxiaoNeural')), findsOneWidget);
    await tester.tap(find.widgetWithText(ListTile, '晓晓（女·温暖）')); await tester.pumpAndSettle();
    expect(speech.usingSystemFallback, isFalse); expect(speech.voice, TtsReader.defaultVoice);
    expect((await storage.loadSettings())['systemFallbackActive'], isFalse);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  for (final scenario in [
    ('plain', const Size(390, 844), null, false),
    ('center-cutout', const Size(390, 844), const Rect.fromLTWH(175, 0, 40, 40), false),
    ('left-cutout', const Size(390, 844), const Rect.fromLTWH(18, 4, 28, 32), true),
    ('right-cutout', const Size(390, 844), const Rect.fromLTWH(344, 4, 28, 32), true),
    ('landscape', const Size(844, 390), null, false),
  ]) {
    testWidgets('compact chapter header fits ${scenario.$1} without moving text under overlays', (tester) async {
      final size = scenario.$2, cutout = scenario.$3;
      tester.view.devicePixelRatio = 1; tester.view.physicalSize = size;
      tester.view.viewPadding = FakeViewPadding(top: cutout != null ? 40 : size.width > size.height ? 0 : 24);
      addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetViewPadding);
      var statusVisible = false;
      messenger.setMockMethodCallHandler(DisplayCutoutService.channel, (_) async => {
        'width': size.width, 'height': size.height,
        'safeInsets': {'top': cutout != null ? 40 : 0, 'left': 0, 'right': 0, 'bottom': 0},
        'cutouts': [if (cutout != null) {
          'left': scenario.$4 ? 175.0 : cutout.left, 'top': scenario.$4 ? 0.0 : cutout.top,
          'right': scenario.$4 ? 215.0 : cutout.right, 'bottom': 40.0,
        }], 'topLeftRadius': 16, 'topRightRadius': 16,
        'statusBarVisible': statusVisible, 'statusBarTop': statusVisible ? 40 : 0,
      });
      final storage = AppStorage(); await storage.saveSettings((ReadingSettings()..fontSize = 64).toJson());
      final book = scenario.$1 == 'center-cutout' ? Book(id: 'header-center-cutout', title: '长句进度',
        filePath: '', format: BookFormat.txt, addedAt: DateTime(2026), chapters: [Chapter(title: '第一章',
          paragraphs: List.generate(30, (p) => Paragraph(display: '第${p + 1}段' + List.filled(30, '清晨风吹树林').join() + '。',
            tts: '', sentences: const [], sentenceStartTts: const [])))]) : sample('header-${scenario.$1}');
      if (scenario.$1 == 'center-cutout') {
        await storage.saveProgress(BookProgress(bookId: book.id, paragraphIndex: 12, offsetInParagraph: 100,
          chapterAnchor: ReadingText.anchor(book, 0, 12, 100), layoutSignature: 'typography3/legacy',
          viewportItem: 1, viewportAlignment: 0, atChapterTitle: false));
      }
      final preview = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(key: preview, child: MaterialApp(builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(displayFeatures: [
          if (scenario.$4 && cutout != null) ui.DisplayFeature(bounds: cutout,
            type: ui.DisplayFeatureType.cutout, state: ui.DisplayFeatureState.unknown),
        ]), child: child!), home: ReaderScreen(book: book, storage: storage))));
      await tester.pumpAndSettle();
      final header = find.byKey(const ValueKey('reader-chapter-header'));
      final body = find.byKey(const ValueKey('reader-body'));
      if (scenario.$1 == 'center-cutout') {
        final positions = tester.widget<ScrollablePositionedList>(body).itemPositionsNotifier!.itemPositions.value;
        expect(positions.any((p) => p.index == 13 && p.itemLeadingEdge < 1 && p.itemTrailingEdge > 0), isTrue,
          reason: 'Legacy viewport geometry must restore by source anchor under the compact header');
        final formatted = ReadingText.format(book, merge: true, indent: true);
        final location = ReadingText.locate(formatted, 0, ReadingText.anchor(book, 0, 12, 100));
        final source = formatted.chapters[0].paragraphs[12].display;
        final paragraph = find.byWidgetPredicate((w) => w is Text && w.textAlign == TextAlign.justify &&
          (w.textSpan?.toPlainText().contains('第13段') ?? false));
        final render = tester.renderObject<RenderParagraph>(paragraph);
        final offset = ReaderTypography.layoutOffset(source, location.$2);
        final glyph = render.getBoxesForSelection(TextSelection(baseOffset: offset, extentOffset: offset + 1)).first;
        final origin = render.localToGlobal(Offset.zero);
        expect(origin.dy, lessThan(tester.getRect(body).top), reason: 'A long-sentence restore must not return to paragraph start');
        expect(origin.dy + glyph.top, greaterThanOrEqualTo(tester.getRect(body).top - 1));
        expect(origin.dy + glyph.bottom, lessThanOrEqualTo(tester.getRect(body).bottom + 1),
          reason: 'The saved middle-of-sentence character must be visible');
        final bodyRect = tester.getRect(body), rows = <Rect>[];
        for (final paragraph in tester.renderObjectList<RenderParagraph>(find.descendant(of: body, matching: find.byType(RichText)))) {
          if (!paragraph.hasSize) continue;
          final boxes = paragraph.getBoxesForSelection(TextSelection(baseOffset: 0,
            extentOffset: paragraph.text.toPlainText().length), boxHeightStyle: ui.BoxHeightStyle.tight);
          final topLeft = paragraph.localToGlobal(Offset.zero);
          for (final box in boxes) {
            final rect = box.toRect().shift(topLeft);
            if (rect.height > 2 && rect.width > 0.1 && rect.bottom > bodyRect.top + 0.5 && rect.top < bodyRect.bottom) rows.add(rect);
          }
        }
        rows.sort((a, b) => a.top.compareTo(b.top));
        expect(rows, isNotEmpty);
        expect(rows.first.top, closeTo(bodyRect.top, 0.5),
          reason: 'Normal reading restores at a complete line boundary, without a half row above the target');
      }
      final expectedTop = 24 + (cutout != null ? 40.0 : size.width > size.height ? 24.0 : 48.0);
      expect(tester.getRect(header).height, 24, reason: 'Chapter chrome must stay compact at body font size 64');
      expect(tester.getRect(body).top, expectedTop);
      final headerText = tester.widget<Text>(find.descendant(of: header, matching: find.byType(Text)));
      expect(headerText.style!.fontSize, 12); expect(headerText.textScaler, TextScaler.noScaling);
      if (cutout != null) expect(tester.getRect(header).overlaps(cutout), isFalse);
      if (scenario.$1 == 'left-cutout') expect(tester.getCenter(header).dx, greaterThan(size.width / 2));
      if (scenario.$1 == 'right-cutout' || scenario.$1 == 'center-cutout') {
        expect(tester.getCenter(header).dx, lessThan(size.width / 2));
      }
      final before = tester.getRect(body), titleBefore = tester.getRect(header);
      await tester.tapAt(Offset(size.width / 2, size.height * 0.45)); await tester.pumpAndSettle();
      expect(tester.getRect(body), before); expect(tester.getRect(header), titleBefore);
      await _captureReaderPreview(tester, preview, 'reader-header-${scenario.$1}');
      statusVisible = true;
      tester.view.viewPadding = const FakeViewPadding(); await tester.pumpAndSettle();
      expect(tester.getRect(body), before, reason: 'Transient system bars must not push the text');
      expect(tester.getRect(header), titleBefore);
      expect(tester.getRect(header).bottom, lessThanOrEqualTo(tester.getRect(body).top),
        reason: 'A revealed system bar must not move the header over the first text line');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    });
  }

  testWidgets('sleep timer pauses an in-flight loading resume and ignores its late completion', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    final speech = _TestSpeech();
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: sample('timer-loading'), storage: AppStorage(), ttsReader: speech)));
    await tester.pumpAndSettle(); await tester.tap(find.byTooltip('朗读')); await tester.pumpAndSettle();
    await tester.tapAt(const Offset(195, 360)); await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reading-sleep'))); await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('sleep-custom')));
    await tester.tap(find.byKey(const ValueKey('sleep-custom'))); await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('sleep-custom-minutes')), '1');
    await tester.tap(find.text('确定')); await tester.pumpAndSettle();
    final pending = Completer<bool>(); speech.resumeResult = pending;
    await tester.tapAt(const Offset(195, 360)); await tester.pump(const Duration(milliseconds: 16));
    expect(find.text('正在加载语音…'), findsOneWidget);
    await tester.pump(const Duration(minutes: 1)); await tester.pumpAndSettle();
    expect(speech.state, TtsState.paused); expect(find.byKey(const ValueKey('reading-panel')), findsOneWidget);
    pending.complete(true); await tester.pumpAndSettle();
    expect(speech.state, TtsState.paused);
    expect(find.byKey(const ValueKey('reading-panel')), findsOneWidget,
      reason: 'A late loading result must not revive playback after the timer pauses it');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  testWidgets('theme mode follows system live and explicit choices preserve current reader preferences', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    final storage = AppStorage();
    final initial = AppAppearance.initialize(ReadingSettings()..fontSize = 37..speechRate = 2.4
      ..themeIndex = 1..dayThemeIndex = 1..themeMode = 'system', Brightness.light);
    await storage.saveSettings(initial.toJson());
    final book = sample('theme-modes');
    await tester.pumpWidget(ValueListenableBuilder<bool>(valueListenable: AppAppearance.nightMode,
      builder: (_, night, child) => MaterialApp(theme: AppAppearance.theme(night),
        home: ReaderScreen(book: book, storage: storage))));
    await tester.pumpAndSettle();
    Color? background() => tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor;
    expect(background(), const Color(0xFFC7EDCC));
    AppAppearance.updateSystemBrightness(Brightness.dark); await tester.pumpAndSettle();
    expect(background(), const Color(0xFF1A1A1A), reason: 'The reader body must follow the global theme immediately');
    await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('阅读设置')); await tester.pumpAndSettle();
    final mode = find.byKey(const ValueKey('theme-mode'));
    expect(tester.widget<DropdownButton<String>>(mode).value, 'system');
    await tester.tap(mode); await tester.pumpAndSettle();
    await tester.tap(find.text('浅色').last); await tester.pumpAndSettle();
    expect(background(), const Color(0xFFC7EDCC));
    expect((await storage.loadSettings())['themeMode'], 'light');
    expect((await storage.loadSettings())['fontSize'], 37); expect((await storage.loadSettings())['speechRate'], 2);
    AppAppearance.updateSystemBrightness(Brightness.dark); await tester.pumpAndSettle();
    expect(background(), const Color(0xFFC7EDCC), reason: 'Explicit light mode must ignore system darkness');
    await tester.tapAt(const Offset(195, 100)); await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('night-mode'))); await tester.pumpAndSettle();
    expect((await storage.loadSettings())['themeMode'], 'dark'); expect(background(), const Color(0xFF1A1A1A));
    await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('阅读设置')); await tester.pumpAndSettle();
    expect(tester.widget<DropdownButton<String>>(mode).value, 'dark');
    await tester.tap(mode); await tester.pumpAndSettle();
    await tester.tap(find.text('跟随系统').last); await tester.pumpAndSettle();
    expect((await storage.loadSettings())['themeMode'], 'system');
    AppAppearance.updateSystemBrightness(Brightness.light); await tester.pumpAndSettle();
    expect(background(), const Color(0xFFC7EDCC));
    await tester.tapAt(const Offset(195, 100)); await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('阅读设置')); await tester.pumpAndSettle();
    // This settings sheet captured the light palette before the OS changes.
    AppAppearance.updateSystemBrightness(Brightness.dark); await tester.pumpAndSettle();
    expect(background(), const Color(0xFF1A1A1A));
    final lineHeight = find.byKey(const ValueKey('reader-line-height'));
    tester.widget<Slider>(lineHeight).onChanged!(1.9); await tester.pumpAndSettle();
    expect(background(), const Color(0xFF1A1A1A), reason: 'Editing an old settings copy must resolve the current system theme');
    expect((await storage.loadSettings())['fontSize'], 37); expect((await storage.loadSettings())['lineHeight'], 1.9);
    expect((await storage.loadSettings())['speechRate'], 2);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  testWidgets('TOC indices locate headings inside one source paragraph and toggles keep viewport and audio', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    final storage = AppStorage();
    await storage.saveSettings((ReadingSettings()..firstLineIndent = false).toJson());
    final book = Book(id: 'toc-index-toggle', title: '目录示例', filePath: '', format: BookFormat.txt, addedAt: DateTime(2026),
      chapters: [Chapter(title: '正文', paragraphs: [Paragraph(display: '开篇文字没有结束符\n第一章 山中\n' +
        List.filled(20, '山间吹来清新的风。').join() + '\n第二章 海边\n' + List.filled(20, '海边传来悠远的歌声。').join(),
        tts: '', sentences: const [], sentenceStartTts: const [])])]);
    final speech = _TestSpeech(), handler = TtsAudioHandler(), previousHandler = globalAudioHandler;
    globalAudioHandler = handler; addTearDown(() { globalAudioHandler = previousHandler; });
    final preview = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(key: preview, child: MaterialApp(home: ReaderScreen(book: book,
      storage: storage, ttsReader: speech))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('contents-handle'))); await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, '第一章 山中'), findsOneWidget);
    expect(find.widgetWithText(ListTile, '第二章 海边'), findsOneWidget);
    await _captureReaderPreview(tester, preview, 'reader-extracted-toc');
    await tester.tap(find.widgetWithText(ListTile, '第一章 山中')); await tester.pumpAndSettle();
    final header = find.byKey(const ValueKey('reader-chapter-header'));
    expect(find.descendant(of: header, matching: find.text('第一章 山中')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('next-chapter'))); await tester.pumpAndSettle();
    expect(find.descendant(of: header, matching: find.text('第二章 海边')), findsOneWidget,
      reason: 'A single chapter triangle click navigates the next logical heading, even in the same source paragraph');
    await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('阅读设置')); await tester.pumpAndSettle();
    await handler.play(); await tester.pumpAndSettle();
    expect(speech.lastSentences[speech.startedAt], '第二章 海边',
      reason: 'Text correction must not merge a TOC heading with preceding unfinished prose');
    final list = find.byKey(const ValueKey('reader-body'));
    List<(int, double)> visible() => tester.widget<ScrollablePositionedList>(list).itemPositionsNotifier!.itemPositions.value
      .where((p) => p.itemTrailingEdge > 0 && p.itemLeadingEdge < 1).map((p) => (p.index, p.itemLeadingEdge)).toList();
    final before = visible(), started = speech.startCalls, resumed = speech.resumeCalls;
    final toggle = find.byKey(const ValueKey('auto-extract-toc'));
    final settingsScroll = find.descendant(of: find.byType(BottomSheet).last, matching: find.byType(Scrollable)).last;
    await tester.scrollUntilVisible(toggle, 180, scrollable: settingsScroll); await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    await tester.tap(toggle); await tester.pumpAndSettle();
    expect(visible(), before, reason: 'Rebuilding only the TOC must preserve the first visible text line');
    expect(speech.startCalls, started); expect(speech.resumeCalls, resumed); expect(speech.state, TtsState.playing);
    expect((await storage.loadSettings())['autoExtractToc'], isFalse);
    await tester.tapAt(const Offset(195, 100)); await tester.pumpAndSettle();
    await handler.stop(); await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('contents-handle'))); await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('toc-entry-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('toc-entry-1')), findsNothing, reason: 'A short book uses one approximate 5000-character section when extraction is off');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    await handler.playbackState.close(); await handler.mediaItem.close();
  });

  for (final link in [
    (name: 'url', prefix: 'https://', text: 'https://example.invalid/advertisement'),
    (name: 'email', prefix: 'reader__', text: 'reader__example@example.invalid'),
    (name: 'dotted-url', prefix: 'abc.', text: 'abc.example'),
    (name: 'mixed-dotted-url', prefix: 'abc.', text: '中文abc.example中文'),
  ]) {
    for (final voice in [TtsReader.systemVoice, TtsReader.defaultVoice]) {
      testWidgets('starting speech on an unfiltered link page preserves its first line ${link.name} $voice', (tester) async {
        tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
        addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
        final spoken = <String>[], nativeRequests = <Map>[];
        Future<void> nativeEvent(String name, Map data) async {
          final done = Completer<void>();
          messenger.handlePlatformMessage(SystemTtsClient.channel.name,
            const StandardMethodCodec().encodeMethodCall(MethodCall(name, data)), (_) => done.complete());
          await done.future;
        }
        messenger.setMockMethodCallHandler(SystemTtsClient.channel, (call) async {
          if (call.method == 'initialize') return {'voiceName': '测试音色'};
          if (call.method == 'speak') {
            final data = call.arguments as Map; nativeRequests.add(data); spoken.add(data['text'] as String);
            unawaited(Future<void>.microtask(() => nativeEvent('start', {'id': data['id']})));
          }
          return null;
        });
        final player = _PageStartAudioPlayer();
        final speech = TtsReader(player: player, activateAudioSession: (_) async => true,
          synthesize: (text, {required voice, required rate, required onWords, required cancelToken}) async {
            spoken.add(text);
            onWords([SpeechWord(startMicros: 0, durationMicros: 1000000, textStart: 0, textEnd: 1, text: text[0])]);
            return Uint8List.fromList([1]);
          });
        final storage = AppStorage();
        await storage.saveSettings((ReadingSettings()..voice = voice..pageTurnMode = 'tap'..pageTurnAnimation = 'off'
          ..fontSize = 20..lineHeight = 1.5..firstLineIndent = false..mergeNonSentenceBreaks = false
          ..prefetchSentences = 0..wordHighlightEnabled = true..informationFilter = true..informationFilterLevel = 'links').toJson());
        final advert = List.generate(68, (index) => '${'字' * (index % 17)}请访问本站 ${link.text} 广告标记${index.toString().padLeft(2, '0')} ').join();
        final book = Book(id: 'link-start-${link.name}-$voice', title: '网址页首', filePath: '', format: BookFormat.txt,
          addedAt: DateTime(2026), chapters: [Chapter(title: '正文', paragraphs: [
            Paragraph(display: List.filled(50, '前文正文。').join(), tts: '', sentences: const [], sentenceStartTts: const []),
            Paragraph(display: advert, tts: '', sentences: const [], sentenceStartTts: const []),
            Paragraph(display: List.filled(100, '后续正文。').join(), tts: '', sentences: const [], sentenceStartTts: const []),
          ])]);
        await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: book, storage: storage, ttsReader: speech)));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('阅读设置')); await tester.pumpAndSettle();
        final filter = find.byKey(const ValueKey('information-filter'));
        final settingsScroll = find.descendant(of: find.byType(BottomSheet).last, matching: find.byType(Scrollable)).last;
        await tester.scrollUntilVisible(filter, 180, scrollable: settingsScroll); await tester.pumpAndSettle();
        await tester.tap(filter); await tester.pumpAndSettle();
        expect((await storage.loadSettings())['informationFilter'], isFalse);
        Navigator.of(tester.element(find.byType(BottomSheet).last)).pop(); await tester.pumpAndSettle();
        final body = find.byKey(const ValueKey('reader-body'));
        final indexed = tester.widget<ScrollablePositionedList>(body);
        indexed.itemScrollController!.jumpTo(index: 2); await tester.pumpAndSettle();
        final paragraph = find.byWidgetPredicate((widget) => widget is Text &&
          (widget.textSpan?.toPlainText().replaceAll('\u200B', '').contains(link.text) ?? false)).first;
        RenderParagraph render() => tester.renderObject<RenderParagraph>(paragraph);
        Rect glyph(int sourceOffset) => render().getBoxesForSelection(TextSelection(
          baseOffset: ReaderTypography.layoutOffset(advert, sourceOffset),
          extentOffset: ReaderTypography.layoutOffset(advert, sourceOffset + 1)),
          boxHeightStyle: ui.BoxHeightStyle.tight).first.toRect();
        int? floor;
        final ordinaryDomain = link.name.contains('dotted');
        for (final match in RegExp(RegExp.escape(link.prefix)).allMatches(advert)) {
          if (ordinaryDomain) {
            // Use the actual row containing a domain, without requiring the
            // domain's suffix to wrap. A previous line box may extend .1 px
            // into the viewport while the intended row is fully visible.
            final row = glyph(match.start);
            if (row.top < 30) continue;
            var first = match.start;
            while (first > 0) {
              if (advert[first - 1].trim().isEmpty) { first--; continue; }
              if ((glyph(first - 1).top - row.top).abs() >= .5) break;
              first--;
            }
            while (first < advert.length && advert[first].trim().isEmpty) { first++; }
            if ((glyph(first).top - row.top).abs() >= .5 || !RegExp(r'[A-Za-z\u4E00-\u9FFF]').hasMatch(advert[first])) continue;
            floor = first; break;
          } else {
            final next = match.end;
            if (glyph(next).top > glyph(next - 1).top + .5) { floor = next; break; }
          }
        }
        expect(floor, isNotNull, reason: 'The fixture needs a complete text row containing the chosen domain boundary');
        final clip = find.byKey(const ValueKey('reader-page-clip'));
        double topOfFloor() => render().localToGlobal(Offset(0, glyph(floor!).top)).dy - tester.getTopLeft(clip).dy;
        final rowInset = ordinaryDomain ? .1 : 0.0;
        unawaited(indexed.scrollOffsetController!.animateScroll(offset: topOfFloor() - rowInset, duration: const Duration(milliseconds: 1)));
        await tester.pumpAndSettle();
        expect(topOfFloor(), closeTo(rowInset, .02));
        if (find.byTooltip('朗读').hitTestable().evaluate().isEmpty) {
          await tester.tapAt(const Offset(195, 300)); await tester.pumpAndSettle();
        }
        final before = topOfFloor();
        await tester.tap(find.byTooltip('朗读')); await tester.pumpAndSettle();
        expect(topOfFloor(), closeTo(before, .5),
          reason: 'Page preparation and the sentence callback must preserve the displayed first line at the URL boundary');
        expect(spoken, isNotEmpty);
        if (ordinaryDomain) {
          final formatted = ReadingText.paragraph(advert);
          final sentence = formatted.sentences[ReadingText.sentenceAt(formatted, floor!)];
          final expected = const TextCleaner().clean(sentence.display.substring(floor! - sentence.displayStart)).tts;
          expect(spoken.first, expected, reason: 'Speech must start at this complete visible row, not the preceding line');
        } else {
          expect(spoken.first, startsWith('example'));
        }
        if (voice == TtsReader.systemVoice) {
          await nativeEvent('range', {'id': nativeRequests.last['id'], 'start': 0, 'end': 1});
        } else {
          player.positions.add(Duration.zero);
        }
        await tester.pumpAndSettle();
        expect(topOfFloor(), closeTo(before, .5), reason: 'The first real word event must preserve the same visible page');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
      });
    }
  }

  for (final voice in [TtsReader.systemVoice, TtsReader.defaultVoice]) {
  testWidgets('$voice speech starts at the visible line and manual pages keep its character offset', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    final storage = AppStorage(); await storage.saveSettings((ReadingSettings()..pageTurnMode = 'tap'..voice = voice).toJson());
    final book = Book(id: 'system-page-offset', title: '系统翻页', filePath: '', format: BookFormat.txt, addedAt: DateTime(2026),
      chapters: [Chapter(title: '第一章 山间', paragraphs: [Paragraph(display: List.filled(200, '清晨山间风吹树林远方传来朋友问候').join() + '。',
        tts: '', sentences: const [], sentenceStartTts: const [])])]);
    final speech = _TestSpeech()..recordJumps = true;
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: book, storage: storage, ttsReader: speech)));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(360, 360)); await tester.pumpAndSettle();
    await tester.tapAt(const Offset(195, 300)); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('朗读')); await tester.pumpAndSettle();
    final started = speech.currentTtsOffset;
    expect(started, greaterThan(0), reason: 'Starting speech after a page turn must not read from the sentence beginning');
    await tester.tapAt(const Offset(360, 360)); await tester.pumpAndSettle();
    expect(speech.jumpCalls, 1); expect(speech.currentTtsOffset, greaterThan(started));
    final list = find.byKey(const ValueKey('reader-body'));
    double edge() => tester.widget<ScrollablePositionedList>(list).itemPositionsNotifier!.itemPositions.value
      .singleWhere((p) => p.index == 1).itemLeadingEdge;
    final before = edge();
    speech.onSentenceChanged?.call(0); speech.onWordChanged?.call(speech.currentTtsOffset, speech.currentTtsOffset + 2);
    await tester.pumpAndSettle();
    expect(edge(), closeTo(before, 0.001), reason: 'The initial sentence callback and real word range must not scroll back to the previous page');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });
  }

  for (final scenario in [
    ('near-right-wide', 170, false, 'reader-header-split-number-name'),
    ('equal', 175, false, 'reader-header-equal-left-number-right-name'),
    ('near-left-wide', 180, false, 'reader-header-near-equal-left-number-right-name'),
    ('corner', 8, true, 'reader-header-corner-full-title'),
  ]) {
    testWidgets('header uses left number and right name for comparable slots ${scenario.$1}', (tester) async {
      final corner = scenario.$3;
      tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
      tester.view.viewPadding = const FakeViewPadding(top: 40);
      addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetViewPadding);
      messenger.setMockMethodCallHandler(DisplayCutoutService.channel, (_) async => {
        'width': 390, 'height': 844, 'safeInsets': {'top': 40},
        'cutouts': [{'left': scenario.$2, 'right': corner ? 40 : scenario.$2 + 40, 'top': 0, 'bottom': 40}],
      });
      final book = Book(id: 'dual-header-${scenario.$1}', title: '双侧标题', filePath: '', format: BookFormat.txt,
        addedAt: DateTime(2026), chapters: [Chapter(title: '第十二章 山间来信', paragraphs: [ReadingText.paragraph('清晨风吹过树林。')])]);
      final preview = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(key: preview, child: MaterialApp(home: ReaderScreen(book: book, storage: AppStorage()))));
      await tester.pumpAndSettle(); await tester.tapAt(const Offset(195, 360)); await tester.pumpAndSettle();
      final name = find.byKey(const ValueKey('reader-chapter-header')), number = find.byKey(const ValueKey('reader-chapter-number'));
      expect(tester.getRect(find.byKey(const ValueKey('reader-body'))).top, 64);
      if (corner) {
        expect(number, findsNothing); expect(find.descendant(of: name, matching: find.text('第十二章 山间来信')), findsOneWidget);
      } else {
        expect(find.descendant(of: name, matching: find.text('山间来信')), findsOneWidget);
        expect(tester.widget<Text>(number).data, '第十二章');
        expect(tester.getCenter(name).dx, greaterThan(tester.getCenter(number).dx));
        expect(tester.getCenter(number).dx, lessThan(195));
        expect(tester.getCenter(name).dx, greaterThan(195));
      }
      await _captureReaderPreview(tester, preview, scenario.$4);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    });
  }

  testWidgets('word highlighting defaults off while real word position and sidebar selection remain available', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    final storage = AppStorage(); await storage.saveSettings((ReadingSettings()..firstLineIndent = false).toJson());
    final speech = _TestSpeech();
    final book = Book(id: 'word-option', title: '高亮设置', filePath: '', format: BookFormat.txt, addedAt: DateTime(2026),
      chapters: [Chapter(title: '第一章', paragraphs: [ReadingText.paragraph('清晨阳光洒在树上。')])]);
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: book, storage: storage, ttsReader: speech)));
    await tester.pumpAndSettle(); await tester.tap(find.byTooltip('朗读')); await tester.pumpAndSettle();
    List<String> blue() {
      final result = <String>[];
      void visit(InlineSpan span) {
        if (span is! TextSpan) return;
        if (span.style?.backgroundColor == const Color(0xFF9BC5DD)) result.add(span.toPlainText().replaceAll('\u200B', ''));
        for (final child in span.children ?? <InlineSpan>[]) { visit(child); }
      }
      for (final text in tester.widgetList<Text>(find.byType(Text))) { if (text.textSpan != null) visit(text.textSpan!); }
      return result;
    }
    speech.onWordChanged?.call(0, 2); await tester.pumpAndSettle(); expect(blue(), isEmpty);
    await tester.tapAt(const Offset(195, 360)); await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('word-highlight'));
    await tester.tap(find.byKey(const ValueKey('playback-settings'))); await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    tester.widget<SwitchListTile>(toggle).onChanged!(true); await tester.pumpAndSettle(); expect(blue(), ['清晨']);
    tester.widget<SwitchListTile>(toggle).onChanged!(false); await tester.pumpAndSettle();
    speech.onWordChanged?.call(3, 5); await tester.pumpAndSettle(); expect(blue(), isEmpty);
    tester.widget<SwitchListTile>(toggle).onChanged!(true); await tester.pumpAndSettle(); expect(blue(), ['光洒']);
    expect((await storage.loadSettings())['wordHighlightEnabled'], isTrue);
    await tester.tapAt(const Offset(195, 80)); await tester.pumpAndSettle();
    await tester.tap(find.text('退出')); await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const ValueKey('contents-touch'))), const Size(48, 64));
    expect(tester.getRect(find.byKey(const ValueKey('contents-handle'))).right, 16);
    await tester.tap(find.byKey(const ValueKey('contents-handle'))); await tester.pumpAndSettle();
    final active = tester.widget<TextButton>(find.byKey(const ValueKey('contents-tab')));
    final inactive = tester.widget<TextButton>(find.byKey(const ValueKey('bookmarks-tab')));
    expect(active.style!.backgroundColor?.resolve({}), isNull);
    expect(inactive.style!.backgroundColor?.resolve({}), isNull);
    expect(active.style!.foregroundColor!.resolve({}), isNot(inactive.style!.foregroundColor!.resolve({})));
    expect(tester.widget<ListTile>(find.byKey(const ValueKey('toc-entry-0'))).selected, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  for (final paused in [false, true]) {
    testWidgets('direct sentence drag previews reversibly and commits audio once originalPaused=$paused', (tester) async {
      tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
      final speech = _TestSpeech()..recordJumps = true;
      final book = Book(id: 'drag-$paused', title: '拖动选句', filePath: '', format: BookFormat.txt, addedAt: DateTime(2026),
        chapters: [Chapter(title: '第一章', paragraphs: List.generate(6, (p) => ReadingText.paragraph('第$p句清晨风吹过树林。')))]);
      await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: book, storage: AppStorage(), ttsReader: speech)));
      await tester.pumpAndSettle(); await tester.tap(find.byTooltip('朗读')); await tester.pumpAndSettle();
      if (paused) { await tester.tapAt(const Offset(195, 280)); await tester.pumpAndSettle(); }
      String highlighted() {
        String result = '';
        bool yellow(InlineSpan span) => span is TextSpan && (span.style?.backgroundColor == const Color(0x44FFC107) ||
          (span.children ?? <InlineSpan>[]).any(yellow));
        for (final text in tester.widgetList<Text>(find.byType(Text))) {
          if (text.textSpan != null && yellow(text.textSpan!)) result = text.textSpan!.toPlainText().replaceAll('\u200B', '');
        }
        return result;
      }
      final gesture = await tester.startGesture(const Offset(195, 220));
      await gesture.moveBy(const Offset(0, 160)); await tester.pumpAndSettle();
      expect(highlighted(), contains('第3句')); expect(speech.startCalls, 1); expect(speech.state, TtsState.paused);
      await gesture.moveBy(const Offset(0, -112)); await tester.pumpAndSettle();
      expect(highlighted(), contains('第1句')); expect(speech.startCalls, 1); expect(speech.jumpCalls, 0);
      await gesture.up(); await tester.pumpAndSettle();
      expect(highlighted(), contains('第1句'));
      expect(speech.state, paused ? TtsState.paused : TtsState.playing);
      expect(speech.startCalls, paused ? 1 : 2); expect(speech.jumpCalls, paused ? 1 : 0);
      final starts = speech.startCalls, jumps = speech.jumpCalls;
      final boundary = await tester.startGesture(const Offset(195, 220));
      await boundary.moveBy(const Offset(0, 960)); await tester.pumpAndSettle(); expect(highlighted(), contains('第5句'));
      await boundary.moveBy(const Offset(0, -48)); await tester.pumpAndSettle(); expect(highlighted(), contains('第4句'));
      await boundary.cancel(); await tester.pumpAndSettle();
      expect(highlighted(), contains('第1句')); expect(speech.state, TtsState.paused);
      expect(speech.startCalls, starts); expect(speech.jumpCalls, jumps);
      speech.speechOffset = 7;
      final short = await tester.startGesture(const Offset(195, 220));
      await short.moveBy(const Offset(0, 24)); await tester.pumpAndSettle(); await short.up(); await tester.pumpAndSettle();
      expect(speech.jumpCalls, jumps, reason: 'A zero-step paused drag must preserve the existing resume position');
      expect(speech.speechOffset, 7);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    });
  }

  testWidgets('stop after releasing a drag cancels its pending pause completion', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    final speech = _TestSpeech(), handler = TtsAudioHandler(), previous = globalAudioHandler;
    globalAudioHandler = handler; addTearDown(() { globalAudioHandler = previous; });
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: sample('drag-stop'), storage: AppStorage(), ttsReader: speech)));
    await tester.pumpAndSettle(); await tester.tap(find.byTooltip('朗读')); await tester.pumpAndSettle();
    final paused = Completer<void>(); speech.pauseResult = paused;
    final drag = await tester.startGesture(const Offset(195, 220));
    await drag.moveBy(const Offset(0, 160)); await tester.pumpAndSettle(); await drag.up(); await tester.pump();
    await handler.stop(); await tester.pumpAndSettle(); paused.complete(); await tester.pumpAndSettle();
    expect(speech.startCalls, 1); expect(speech.resumeCalls, 0); expect(speech.state, TtsState.stopped);
    expect(find.byTooltip('朗读'), findsOneWidget); expect(handler.playbackState.value.playing, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    await handler.playbackState.close(); await handler.mediaItem.close();
  });

  testWidgets('reader waits only for native geometry and pins same viewport header metrics', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    tester.view.viewPadding = const FakeViewPadding(top: 44);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetViewPadding);
    final geometry = Completer<Map<String, dynamic>>();
    var reads = 0;
    Map<String, dynamic> snapshot(int top) => {'width': 390, 'height': 844, 'safeInsets': {'top': top},
      'cutouts': [{'left': 175, 'right': 215, 'top': 0, 'bottom': top}]};
    messenger.setMockMethodCallHandler(DisplayCutoutService.channel, (_) async {
      reads++; return reads == 1 ? geometry.future : snapshot(44);
    });
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: sample('initial-viewport'), storage: AppStorage(), ttsReader: _TestSpeech())));
    await tester.pump(const Duration(milliseconds: 16));
    expect(platformCalls.any((call) => call.method == 'SystemChrome.setEnabledSystemUIMode' &&
      call.arguments == 'SystemUiMode.immersiveSticky'), isTrue);
    expect(find.byKey(const ValueKey('reader-body')), findsNothing);
    expect(reads, 1);
    tester.view.viewPadding = const FakeViewPadding(); await tester.pump();
    geometry.complete(snapshot(40)); await tester.pumpAndSettle();
    final body = find.byKey(const ValueKey('reader-body')), header = find.byKey(const ValueKey('reader-chapter-header'));
    expect(tester.getRect(body).top, 64, reason: 'The first text frame must use the prepared cutout, not the earlier 44px status inset');
    final beforeBody = tester.getRect(body), beforeHeader = tester.getRect(header);
    tester.view.viewPadding = const FakeViewPadding(top: 44); await tester.pumpAndSettle();
    expect(reads, greaterThan(1));
    expect(tester.getRect(body), beforeBody); expect(tester.getRect(header), beforeHeader);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  testWidgets('native geometry can display reader during route transition while immersive response is pending', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    tester.view.viewPadding = const FakeViewPadding(top: 44);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetViewPadding);
    final immersive = Completer<void>();
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      platformCalls.add(call);
      if (call.method == 'SystemChrome.setEnabledSystemUIMode' && call.arguments == 'SystemUiMode.immersiveSticky') {
        await immersive.future;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(DisplayCutoutService.channel, (_) async => {
      'width': 390, 'height': 844, 'safeInsets': {'top': 40},
      'cutouts': [{'left': 175, 'right': 215, 'top': 0, 'bottom': 40}],
    });
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(navigatorKey: navigator, home: Builder(builder: (context) => Scaffold(body: TextButton(
      onPressed: () => Navigator.push(context, MaterialPageRoute<void>(allowSnapshotting: false,
        builder: (_) => ReaderScreen(book: sample('parallel-viewport'), storage: AppStorage(), ttsReader: _TestSpeech()))),
      child: const Text('打开'))))));
    await tester.tap(find.text('打开')); await tester.pump(); await tester.pump(const Duration(milliseconds: 16));
    final body = find.byKey(const ValueKey('reader-body'));
    expect(body, findsOneWidget, reason: 'Content must not wait for the immersive platform call or full route animation');
    final reader = tester.element(find.byType(ReaderScreen));
    expect(ModalRoute.of(reader)!.animation!.status, AnimationStatus.forward);
    // Compare reader-local coordinates while the route transition transforms
    // its subtree, rather than measuring the animated screen position.
    final beforeSize = tester.getSize(body);
    double localTop() {
      final scaffold = tester.renderObject<RenderBox>(find.descendant(of: find.byType(ReaderScreen), matching: find.byType(Scaffold)).first);
      return tester.renderObject<RenderBox>(body).localToGlobal(Offset.zero, ancestor: scaffold).dy;
    }
    expect(localTop(), 64);
    immersive.complete(); tester.view.viewPadding = const FakeViewPadding(); await tester.pumpAndSettle();
    expect(tester.getSize(body), beforeSize); expect(localTop(), 64);
    expect(tester.takeException(), isNull);
    navigator.currentState!.pop(); await tester.pumpAndSettle();
  });

  testWidgets('reader restores bars at route pop start while dialog dismissal keeps immersive', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(navigatorKey: navigator, home: Builder(builder: (context) => Scaffold(
      body: TextButton(key: const ValueKey('open-reader'), onPressed: () => Navigator.push(context,
        MaterialPageRoute<void>(builder: (_) => ReaderScreen(book: sample('route-bars'), storage: AppStorage(), ttsReader: _TestSpeech()))),
        child: const Text('打开阅读'))))));
    int modes(String mode) => platformCalls.where((call) => call.method == 'SystemChrome.setEnabledSystemUIMode' &&
      call.arguments == mode).length;
    await tester.tap(find.byKey(const ValueKey('open-reader'))); await tester.pumpAndSettle();
    final before = tester.getRect(find.byKey(const ValueKey('reader-body')));
    await tester.tap(find.byKey(const ValueKey('contents-handle'))); await tester.pumpAndSettle();
    navigator.currentState!.pop(); await tester.pumpAndSettle();
    expect(modes('SystemUiMode.edgeToEdge'), 0, reason: 'A modal belonging to the reader is not a reader exit');
    navigator.currentState!.pop(); await tester.pump();
    expect(modes('SystemUiMode.edgeToEdge'), 1);
    expect(find.byType(ReaderScreen), findsOneWidget, reason: 'System bars must restore before the outgoing route is disposed');
    expect(tester.getRect(find.byKey(const ValueKey('reader-body'))), before);
    await tester.pumpAndSettle(); expect(find.byType(ReaderScreen), findsNothing);
    expect(modes('SystemUiMode.edgeToEdge'), 1, reason: 'Dispose is only an idempotent fallback');
    await tester.tap(find.byKey(const ValueKey('open-reader'))); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('返回')); await tester.pump();
    expect(modes('SystemUiMode.edgeToEdge'), 2);
    await tester.pumpAndSettle(); expect(find.byType(ReaderScreen), findsNothing);
    expect(modes('SystemUiMode.edgeToEdge'), 2); expect(tester.takeException(), isNull);
  });

  testWidgets('leaving reader while initial geometry is pending cannot reenter immersive on completion', (tester) async {
    final geometry = Completer<Map<String, dynamic>?>();
    messenger.setMockMethodCallHandler(DisplayCutoutService.channel, (_) => geometry.future);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(navigatorKey: navigator, home: Builder(builder: (context) => Scaffold(body: TextButton(
      onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => ReaderScreen(
        book: sample('leave-initial-geometry'), storage: AppStorage(), ttsReader: _TestSpeech()))), child: const Text('打开'))))));
    await tester.tap(find.text('打开')); await tester.pump(); await tester.pump(const Duration(milliseconds: 16));
    navigator.currentState!.pop(); await tester.pump();
    final afterPop = platformCalls.length;
    geometry.complete(null); await tester.pumpAndSettle();
    expect(platformCalls.skip(afterPop).where((call) => call.method == 'SystemChrome.setEnabledSystemUIMode' &&
      call.arguments == 'SystemUiMode.immersiveSticky'), isEmpty);
    expect(find.byType(ReaderScreen), findsNothing); expect(tester.takeException(), isNull);
  });

  testWidgets('pending initial preparation leaves loading responsive and late completion cannot reopen disposed reader', (tester) async {
    final pending = Completer<PreparedReadingBook>();
    ReaderPreparationRequest? request;
    ReaderPreparation.runnerForTesting = (value) { request = value; return pending.future; };
    final speech = _TestSpeech();
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: sample('pending-preparation'), storage: AppStorage(), ttsReader: speech)));
    await tester.pump(const Duration(milliseconds: 16));
    expect(request, isNotNull); expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-body')), findsNothing); expect(speech.startCalls, 0);
    await tester.pumpWidget(const SizedBox()); await tester.pump();
    pending.complete(ReaderPreparation.prepareSynchronously(request!)); await tester.pumpAndSettle();
    expect(find.byType(ReaderScreen), findsNothing); expect(speech.startCalls, 0); expect(tester.takeException(), isNull);
  });

  testWidgets('playback preferences persist and system voice owns additive pauses', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    final storage = AppStorage(); await storage.saveSettings((ReadingSettings()..readingScreenSeconds = 60..keepScreenMinutes = 15..voice = TtsReader.systemVoice).toJson());
    final speech = _TestSpeech();
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: sample('playback-preferences'), storage: storage, ttsReader: speech)));
    await tester.pumpAndSettle();
    expect(volumeCalls.lastWhere((call) => call.method == 'setKeepScreenOn').arguments, isTrue);
    await tester.tap(find.byTooltip('朗读')); await tester.pumpAndSettle();
    await tester.tapAt(const Offset(195, 300)); await tester.pumpAndSettle();
    expect(volumeCalls.lastWhere((call) => call.method == 'setKeepScreenOn').arguments, isFalse);
    await tester.tap(find.byKey(const ValueKey('reading-rate-plus'))); await tester.pumpAndSettle();
    expect(find.text('语速 1.02x'), findsOneWidget);
    expect(tester.widget<Slider>(find.byKey(const ValueKey('reading-rate-slider'))).divisions, 125);
    tester.widget<Slider>(find.byKey(const ValueKey('reading-rate-slider'))).onChanged!(1.3); await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reading-rate-minus'))); await tester.pumpAndSettle();
    expect(speech.speechRate, 1.28); expect((await storage.loadSettings())['speechRate'], 1.28);
    tester.widget<Slider>(find.byKey(const ValueKey('reading-rate-slider'))).onChanged!(1.4); await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reading-rate-plus'))); await tester.pumpAndSettle();
    expect(speech.speechRate, 1.42); expect((await storage.loadSettings())['speechRate'], 1.42);
    expect(find.text('语速 1.42x'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('reading-rate-minus'))); await tester.pumpAndSettle();
    expect(speech.speechRate, 1.4); expect(find.text('语速 1.40x'), findsOneWidget);
    expect(find.byKey(const ValueKey('reading-prefetch')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('playback-settings'))); await tester.pumpAndSettle();
    tester.widget<Slider>(find.byKey(const ValueKey('sentence-drag-delay'))).onChanged!(0.4); await tester.pumpAndSettle();
    expect((await storage.loadSettings())['sentenceDragDelay'], 0.4);
    expect(find.byKey(const ValueKey('pause-expand')), findsNothing);
    await tester.tapAt(const Offset(195, 60)); await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reading-voice'))); await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pause-voice-zh-CN-XiaoxiaoNeural')), findsNothing);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('pause-voice-__system_tts__')), 250,
      scrollable: find.byType(Scrollable).last);
    await tester.tap(find.byKey(const ValueKey('pause-voice-__system_tts__'))); await tester.pumpAndSettle();
    final expandPauses = find.byKey(const ValueKey('pause-expand'));
    expect(expandPauses, findsOneWidget);
    expect(find.text('系统的追加停顿'), findsNothing);
    final pause = find.byKey(const ValueKey('pause-comma'));
    await tester.ensureVisible(pause); await tester.pumpAndSettle();
    await tester.tap(pause); await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('pause-number-comma')), '.35');
    await tester.tap(find.text('确定').last); await tester.pumpAndSettle();
    final apply = find.byKey(const ValueKey('pause-apply'));
    await tester.ensureVisible(apply); await tester.tap(apply); await tester.pumpAndSettle();
    expect(speech.startCalls, 1, reason: 'Changing pauses while paused must not start speech');
    expect(((await storage.loadSettings())['speechPauses'] as Map)['comma'], 0);
    expect((await storage.loadSettings())['perVoiceSpeechPauses'][TtsReader.systemVoice]['comma'], 350);
    expect((await storage.loadSettings())['keepScreenMinutes'], 15);
    expect((await storage.loadSettings())['readingScreenSeconds'], 60);
    await tester.tapAt(const Offset(195, 60)); await tester.pumpAndSettle();
    await tester.tapAt(const Offset(195, 300)); await tester.pumpAndSettle();
    expect(speech.startCalls, 2); expect(speech.lastPauses, contains(350));
    expect(volumeCalls.lastWhere((call) => call.method == 'setKeepScreenOn').arguments, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  testWidgets('wake keeps the active page and complete speech line without restarting audio', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    tester.view.viewPadding = const FakeViewPadding(top: 40);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetViewPadding);
    final speech = _TestSpeech();
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: sample('wake-line'), storage: AppStorage(), ttsReader: speech)));
    await tester.pumpAndSettle(); await tester.tap(find.byTooltip('朗读')); await tester.pumpAndSettle();
    speech.emitSentence(17); speech.onWordChanged?.call(4, 6); await tester.pumpAndSettle();
    final starts = speech.startCalls;
    final body = find.byKey(const ValueKey('reader-body'));
    List<(int, double)> viewport() => tester.widget<ScrollablePositionedList>(body).itemPositionsNotifier!.itemPositions.value
      .where((p) => p.itemLeadingEdge < 1 && p.itemTrailingEdge > 0)
      .map((p) => (p.index, p.itemLeadingEdge)).toList()..sort((a, b) => a.$1.compareTo(b.$1));
    final beforeWake = viewport();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive); await tester.pump();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused); await tester.pump();
    tester.view.viewPadding = const FakeViewPadding(top: 44);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed); await tester.pumpAndSettle();
    expect(viewport(), beforeWake, reason: 'Foreground alignment must not scroll the current cursor to the first line.');
    void expectCompleteTopLine() {
      final bodyRect = tester.getRect(body), rows = <Rect>[];
      for (final render in tester.renderObjectList<RenderParagraph>(find.descendant(of: body, matching: find.byType(RichText)))) {
        final origin = render.localToGlobal(Offset.zero);
        for (final box in render.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: render.text.toPlainText().length),
          boxHeightStyle: ui.BoxHeightStyle.tight)) {
          final rect = box.toRect().shift(origin);
          if (rect.height > 2 && rect.width > 0.1 && rect.bottom > bodyRect.top + 0.5 && rect.top < bodyRect.bottom) rows.add(rect);
        }
      }
      rows.sort((a, b) => a.top.compareTo(b.top));
      expect(rows.first.top, greaterThanOrEqualTo(bodyRect.top - 0.5));
    }
    expectCompleteTopLine();
    tester.view.physicalSize = const Size(390, 840); await tester.pumpAndSettle();
    expectCompleteTopLine();
    expect(find.byKey(const ValueKey('reader-menu')), findsNothing, reason: 'Wake must not leave an overlay over the first text row');
    expect(speech.startCalls, starts); expect(speech.resumeCalls, 0); expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  testWidgets('reader defaults to scroll and can select immediate tap pages and system rotation', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    final storage = AppStorage(); await storage.saveSettings(ReadingSettings().toJson());
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: sample('page-rotation-options'), storage: storage, ttsReader: _TestSpeech())));
    await tester.pumpAndSettle();
    MethodCall rotation() => platformCalls.lastWhere((call) => call.method == 'SystemChrome.setPreferredOrientations');
    expect(rotation().arguments, ['DeviceOrientation.portraitUp']);
    await tester.tapAt(const Offset(360, 360)); await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('page-outgoing-transform')), findsNothing);
    expect(tester.widget<FractionalTranslation>(find.byKey(const ValueKey('page-incoming-transform'))).translation, Offset.zero);
    await tester.tapAt(const Offset(195, 300)); await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('阅读设置')); await tester.pumpAndSettle();
    final mode = tester.widget<DropdownButton<String>>(find.byKey(const ValueKey('page-turn-mode')));
    expect(mode.value, 'scroll');
    mode.onChanged!('tap'); await tester.pumpAndSettle();
    expect((await storage.loadSettings())['pageTurnMode'], 'tap');
    expect(tester.widget<DropdownButton<String>>(find.byKey(const ValueKey('page-turn-animation'))).value, 'off');
    tester.widget<DropdownButton<String>>(find.byKey(const ValueKey('page-turn-animation'))).onChanged!('slide'); await tester.pumpAndSettle();
    expect((await storage.loadSettings())['pageTurnAnimation'], 'slide');
    final settingsScroll = find.descendant(of: find.byType(BottomSheet).last, matching: find.byType(Scrollable)).last;
    await tester.scrollUntilVisible(find.byKey(const ValueKey('follow-system-rotation')), 160, scrollable: settingsScroll);
    await tester.pumpAndSettle();
    tester.widget<SwitchListTile>(find.byKey(const ValueKey('follow-system-rotation'))).onChanged!(true); await tester.pumpAndSettle();
    expect(rotation().arguments, DeviceOrientation.values.map((value) => value.toString()).toList());
    await tester.scrollUntilVisible(find.byKey(const ValueKey('reading-screen-seconds')), 120, scrollable: settingsScroll);
    await tester.pumpAndSettle();
    expect(tester.widget<DropdownButton<int>>(find.byKey(const ValueKey('reading-screen-seconds'))).items!.map((item) => item.value), [0, 60, 120, 300, 600, 1800]);
    tester.widget<DropdownButton<int>>(find.byKey(const ValueKey('reading-screen-seconds'))).onChanged!(120); await tester.pumpAndSettle();
    expect((await storage.loadSettings())['readingScreenSeconds'], 120);
    await tester.tapAt(const Offset(195, 100)); await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('横竖屏切换')); await tester.pumpAndSettle();
    expect(rotation().arguments, ['DeviceOrientation.landscapeLeft']);
    expect((await storage.loadSettings())['followSystemRotation'], isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    expect(rotation().arguments, ['DeviceOrientation.portraitUp']);
  });

  testWidgets('visible playback volume follows hardware changes without stale read rollback', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    var systemVolume = 0.5, reads = 0;
    Completer<double>? delayed;
    messenger.setMockMethodCallHandler(const MethodChannel('com.ddnovelreader/volume_keys'), (call) async {
      if (call.method == 'getMediaVolume') {
        reads++;
        final pending = delayed; delayed = null;
        return pending == null ? systemVolume : await pending.future;
      }
      if (call.method == 'setMediaVolume') systemVolume = (call.arguments as num).toDouble();
      if (call.method == 'getSystemBrightness') return 0.5;
      return null;
    });
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: sample('volume-sync'), storage: AppStorage(), ttsReader: _TestSpeech())));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('朗读')); await tester.pumpAndSettle();
    await tester.tapAt(const Offset(195, 360)); await tester.pumpAndSettle();
    final volume = find.byKey(const ValueKey('reading-volume-slider'));
    expect(tester.widget<Slider>(volume).value, 0.5);
    systemVolume = 0.8;
    await tester.pump(const Duration(milliseconds: 300)); await tester.pump();
    expect(tester.widget<Slider>(volume).value, 0.8);
    final stale = Completer<double>(); delayed = stale;
    await tester.pump(const Duration(milliseconds: 250));
    tester.widget<Slider>(volume).onChangeStart!(0.8);
    tester.widget<Slider>(volume).onChanged!(0.6);
    tester.widget<Slider>(volume).onChangeEnd!(0.6);
    stale.complete(0.2); await tester.pump();
    expect(tester.widget<Slider>(volume).value, 0.6);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive); await tester.pump();
    final pausedReads = reads;
    await tester.pump(const Duration(seconds: 1)); expect(reads, pausedReads);
    systemVolume = 0.9;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 300)); await tester.pump();
    expect(tester.widget<Slider>(volume).value, 0.9);
    await tester.tapAt(const Offset(195, 360)); await tester.pumpAndSettle();
    expect(volume, findsNothing);
    final hiddenReads = reads;
    await tester.pump(const Duration(seconds: 1)); expect(reads, hiddenReads);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1)); expect(reads, hiddenReads);
  });

  testWidgets('single-line landscape pages still advance when overlap is enabled', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(844, 320);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    final storage = AppStorage();
    await storage.saveSettings((ReadingSettings()..pageTurnMode = 'tap'..fontSize = 64..retainPageLine = true).toJson());
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: sample('one-line'), storage: storage)));
    await tester.pumpAndSettle();
    final list = find.byKey(const ValueKey('reader-body'));
    (int,double) anchor() {
      final positions = tester.widget<ScrollablePositionedList>(list).itemPositionsNotifier!.itemPositions.value
        .where((p) => p.itemLeadingEdge < 1 && p.itemTrailingEdge > 0).toList()..sort((a,b) => a.index.compareTo(b.index));
      return (positions.first.index, positions.first.itemLeadingEdge);
    }
    final first = anchor();
    await tester.tapAt(const Offset(800, 210)); await tester.pumpAndSettle();
    final second = anchor(); expect(second, isNot(first));
    await tester.tapAt(const Offset(800, 210)); await tester.pumpAndSettle();
    expect(anchor(), isNot(second));
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  testWidgets('partially restored one-row viewport can still turn in either direction', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(844, 320);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final storage = AppStorage();
    await storage.saveSettings((ReadingSettings()..pageTurnMode = 'tap'..fontSize = 64).toJson());
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: sample('partial-page'), storage: storage)));
    await tester.pumpAndSettle();
    final body = find.byKey(const ValueKey('reader-body'));
    final controller = tester.widget<ScrollablePositionedList>(body);
    final item = find.descendant(of: body, matching: find.byType(RichText));
    List<({int start, int end, Rect rect})> rows() {
      final paragraph = tester.renderObjectList<RenderParagraph>(item).firstWhere(
        (render) => render.text.toPlainText().replaceAll('\u200B', '').replaceAll('\uFFFC', '').startsWith('第1章第4段。'));
      final origin = paragraph.localToGlobal(Offset.zero) - tester.getTopLeft(body);
      final lines = <int, Rect>{};
      for (final box in paragraph.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: paragraph.text.toPlainText().length),
        boxHeightStyle: ui.BoxHeightStyle.tight)) {
        final rect = box.toRect();
        if (rect.width <= 2 || rect.height < 2) continue;
        final start = paragraph.getPositionForOffset(Offset(-1, rect.center.dy)).offset;
        lines.update(start, (line) => line.expandToInclude(rect), ifAbsent: () => rect);
      }
      return [for (final entry in lines.entries) (start: entry.key,
        end: paragraph.getPositionForOffset(Offset(paragraph.size.width + 1, entry.value.center.dy)).offset,
        rect: entry.value.shift(origin))]..sort((a, b) => a.rect.top.compareTo(b.rect.top));
    }
    controller.itemScrollController!.jumpTo(index: 4);
    await tester.pumpAndSettle();
    final glyphHeight = rows()[2].rect.height;
    final fixedHeight = 320 - tester.getSize(body).height;
    tester.view.physicalSize = Size(844, (fixedHeight + glyphHeight * 1.15).roundToDouble());
    await tester.pumpAndSettle();
    final bodyHeight = tester.getSize(body).height;
    expect(rows().where((row) => row.rect.top >= -.25 && row.rect.bottom <= bodyHeight + .25),
      hasLength(1), reason: 'The actual calibrated viewport fits one complete native row');
    for (final direction in [-1, 1]) {
      controller.itemScrollController!.jumpTo(index: 4);
      await tester.pumpAndSettle();
      final original = rows();
      final offset = original[2].rect.top + glyphHeight * .65;
      var nearest = 0;
      for (var row = 1; row < original.length; row++) {
        if ((original[row].rect.top - offset).abs() < (original[nearest].rect.top - offset).abs()) nearest = row;
      }
      final scroll = controller.scrollOffsetController!.animateScroll(offset: offset, duration: const Duration(milliseconds: 1));
      await tester.pump(); await tester.pump(const Duration(milliseconds: 16)); await scroll;
      await tester.pumpAndSettle();
      final before = rows();
      final viewportSize = tester.getSize(body);
      final clipBefore = tester.widget<ClipRect>(find.byKey(const ValueKey('reader-page-clip'))).clipper!.getClip(viewportSize);
      final completeBefore = before.where((row) => row.rect.top >= -.25 && row.rect.bottom <= viewportSize.height + .25).toList();
      expect(completeBefore, hasLength(1), reason: 'An injected partial restore normalizes to one complete actual row');
      expect(completeBefore.single.start, original[nearest].start,
        reason: 'Normalization retains the true native row nearest the injected viewport top');
      expect(before[nearest].rect.top, closeTo(0, .25));
      expect(clipBefore.bottom, closeTo(before[nearest].rect.bottom, .25),
        reason: 'The normalized clip ends exactly at the current complete glyph row');
      final y = tester.getCenter(body).dy;
      await tester.tapAt(Offset(direction < 0 ? 100 : 790, y));
      final outgoing = find.byKey(const ValueKey('page-outgoing-transform'));
      await tester.pump();
      expect(outgoing, findsOneWidget, reason: 'Do not expose the old clip over new text, even without animation');
      for (var frame = 0; frame < 20 && outgoing.evaluate().isNotEmpty; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(outgoing, findsNothing);
      final after = rows();
      expect(after[nearest + direction].rect.top, closeTo(0, .25),
        reason: 'One tap must land on the immediately adjacent row, even after an in-between restore');
      final viewport = tester.getRect(body);
      final clip = tester.widget<ClipRect>(find.byKey(const ValueKey('reader-page-clip'))).clipper!.getClip(viewport.size);
      final visible = after.where((row) => row.rect.top < clip.bottom - .5 && row.rect.bottom > .5).toList();
      expect(visible, hasLength(1));
      expect(visible.single.start, before[nearest + direction].start,
        reason: 'The new source row is the exact immediate neighbour, without skipping or repeating the old row');
      expect(visible.single.start, isNot(completeBefore.single.start));
      expect(visible.single.end, before[nearest + direction].end);
      expect(clip.bottom, closeTo(visible.single.rect.bottom, .25));
      expect(visible.single.rect.bottom, lessThanOrEqualTo(clip.bottom + .5));
    }
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  for (final fontSize in [24.0, 64.0]) {
    for (final dpr in [1.0, 2.75]) {
    testWidgets('TOC chapter jumps followed by previous-page taps keep complete rows at font $fontSize DPR $dpr', (tester) async {
      tester.view.devicePixelRatio = dpr;
      tester.view.physicalSize = dpr == 1 ? const Size(390, 844) : const Size(1080, 2400);
      tester.view.viewPadding = const FakeViewPadding(top: 40);
      addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetViewPadding);
      const fontPath = '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc';
      if (File(fontPath).existsSync()) {
        await tester.runAsync(() async {
          final loader = FontLoader('PagingCjk');
          loader.addFont(Future.value(ByteData.sublistView(File(fontPath).readAsBytesSync())));
          await loader.load();
          await Future<void>.delayed(Duration.zero);
        });
      }
      final storage = AppStorage();
      await storage.saveSettings((ReadingSettings()..pageTurnMode = 'tap'..fontSize = fontSize..lineHeight = 1.63..pageTurnAnimation = 'off'
        ..fontFamily = File(fontPath).existsSync() ? 'PagingCjk' : '').toJson());
      final book = Book(id: 'toc-previous-$fontSize', title: '章节翻页边界', filePath: '', format: BookFormat.txt,
        addedAt: DateTime(2026), chapters: List.generate(8, (c) => Chapter(title: '第${c + 1}章 山间来信',
          paragraphs: List.generate(7, (p) => Paragraph(
            display: '第${c + 1}章第${p + 1}段。' + List.filled(p.isEven ? 27 : 4, '晨风吹过山林，远方传来朋友的问候。').join(),
            tts: '', sentences: const [], sentenceStartTts: const [])))));
      final preview = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(key: preview, child: MaterialApp(home: ReaderScreen(book: book, storage: storage))));
      await tester.pumpAndSettle();
      final body = find.byKey(const ValueKey('reader-body'));
      final renderItems = <RenderParagraph, int>{};
      final rowKeys = <String, String>{};
      final jointCuts = <String, List<String>>{};
      final precedingPlanHook = ReaderScreen.onJointPagePlanForTesting;
      ReaderScreen.onJointPagePlanForTesting = (chapter, plan, keys) {
        precedingPlanHook?.call(chapter, plan, keys);
        for (final page in plan.pages) { jointCuts[keys[page.first]] = keys.sublist(page.first, page.end); }
      };
      addTearDown(() => ReaderScreen.onJointPagePlanForTesting = precedingPlanHook);
      (int, double) viewportAnchor() {
        final visible = tester.widget<ScrollablePositionedList>(body).itemPositionsNotifier!.itemPositions.value
          .where((position) => position.itemTrailingEdge > 0 && position.itemLeadingEdge < 1).toList()
            ..sort((a, b) => a.index.compareTo(b.index));
        return (visible.first.index, visible.first.itemLeadingEdge);
      }
      List<(RenderParagraph, Offset)> positionedParagraphs() {
        final paragraphs = <int, RenderParagraph>{};
        for (final element in find.descendant(of: body, matching: find.byType(RichText)).evaluate()) {
          int? index;
          element.visitAncestorElements((ancestor) {
            final key = ancestor.widget.key;
            if (key is ValueKey<int>) { index = key.value; return false; }
            return true;
          });
          final render = element.findRenderObject();
          final itemIndex = index;
          if (itemIndex != null && render is RenderParagraph && render.attached) {
            paragraphs[itemIndex] = render; renderItems[render] = itemIndex;
          }
        }
        final visible = tester.widget<ScrollablePositionedList>(body).itemPositionsNotifier!.itemPositions.value
          .where((position) => position.itemTrailingEdge > 0 && position.itemLeadingEdge < 1 && paragraphs.containsKey(position.index));
        final anchor = paragraphs[visible.first.index]!;
        final viewport = RenderAbstractViewport.of(anchor);
        final origin = anchor.localToGlobal(Offset.zero).dy - viewport.getOffsetToReveal(anchor, 0).offset;
        return [for (final render in paragraphs.values)
          if (RenderAbstractViewport.maybeOf(render) == viewport)
            (render, Offset(render.localToGlobal(Offset.zero).dx, viewport.getOffsetToReveal(render, 0).offset + origin))];
      }
      List<(String, Rect)> laidOutRows() {
        final bounds = tester.getRect(body), result = <(String, Rect)>[];
        for (final (render, origin) in positionedParagraphs()) {
          if (origin.dy - bounds.top > bounds.height * 2 || origin.dy + render.size.height < bounds.top - bounds.height) continue;
          final text = render.text.toPlainText(), lines = <int, Rect>{};
          for (final box in render.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: text.length),
            boxHeightStyle: ui.BoxHeightStyle.tight)) {
            final rect = box.toRect();
            if (rect.width < 0.01 || rect.height < 2) continue;
            final start = render.getPositionForOffset(Offset(-10000, rect.center.dy)).offset;
            lines[start] = lines[start]?.expandToInclude(rect) ?? rect;
          }
          for (final line in lines.entries) {
            final id = '$text/${line.key}';
            rowKeys[id] = '${renderItems[render]}/${line.key}';
            result.add((id, line.value.shift(origin)));
          }
        }
        result.sort((a, b) => a.$2.top.compareTo(b.$2.top));
        return result;
      }
      void expectWholeVisibleRows({bool checkToolbar = false}) {
        final bounds = tester.getRect(body);
        final localClip = tester.widget<ClipRect>(find.byKey(const ValueKey('reader-page-clip'))).clipper!.getClip(bounds.size);
        final clip = localClip.shift(bounds.topLeft);
        final visible = <Rect>[];
        for (final (render, origin) in positionedParagraphs()) {
          for (final box in render.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: render.text.toPlainText().length),
            boxHeightStyle: ui.BoxHeightStyle.tight)) {
            final row = box.toRect().shift(origin);
            if (row.width < 0.01 || row.height < 2 || row.bottom <= clip.top + 0.5 || row.top >= clip.bottom - 0.5) continue;
            visible.add(row);
            expect(row.top, greaterThanOrEqualTo(clip.top - 0.5), reason: 'A TOC jump followed by previous page must not expose a clipped first row');
            expect(row.bottom, lessThanOrEqualTo(clip.bottom + 0.5), reason: 'The previous page must end on a whole row');
          }
          for (final box in render.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: render.text.toPlainText().length))) {
            final glyph = box.toRect().shift(origin);
            if (glyph.width < 0.01 || glyph.bottom <= clip.top + 0.01 || glyph.top >= clip.bottom - 0.01) continue;
            expect(glyph.bottom, lessThanOrEqualTo(clip.bottom + 0.01),
              reason: 'The clip must not reveal a sliver of the next glyph at fractional offsets');
          }
        }
        expect(visible, isNotEmpty);
        if (checkToolbar) {
          final menu = find.byKey(const ValueKey('reader-menu'));
          if (menu.evaluate().isNotEmpty) {
            final toolbarBottom = tester.getRect(menu).bottom + 4;
            for (final row in visible) {
              expect(row.top, greaterThanOrEqualTo(toolbarBottom - 0.5), reason: 'A previous-page first row must not be hidden behind the retained top toolbar');
            }
          }
        }
      }
      for (final chapter in [5, 2, 4]) {
        if (find.byKey(const ValueKey('contents-handle')).evaluate().isEmpty) {
          await tester.tapAt(const Offset(195, 300)); await tester.pumpAndSettle();
        }
        await tester.tap(find.byKey(const ValueKey('contents-handle'))); await tester.pumpAndSettle();
        final entry = find.byKey(ValueKey('toc-entry-$chapter'));
        await tester.ensureVisible(entry); await tester.pumpAndSettle();
        jointCuts.clear();
        await tester.tap(entry); await tester.pumpAndSettle();
        expectWholeVisibleRows();
        for (var page = 0; page < 3; page++) {
          final before = viewportAnchor();
          final bounds = tester.getRect(body);
          final rows = laidOutRows(), complete = rows.where((row) => row.$2.top >= bounds.top - 0.5).toList();
          final previous = rows.where((row) => row.$2.bottom <= complete.first.$2.top + 0.5).toList();
          // More preceding items can be laid out in the next frame. Only predict
          // a first row if the current cache already covers an entire page.
          final target = previous.isEmpty || previous.last.$2.bottom - previous.first.$2.top < bounds.height - 0.5
            ? null : previous.firstWhere((row) => previous.last.$2.bottom - row.$2.top <= bounds.height + 0.5).$1;
          final precedingBoundary = previous.isEmpty ? null : previous.last.$1;
          await tester.tapAt(const Offset(60, 360));
          await tester.pump();
          final outgoing = find.byKey(const ValueKey('page-outgoing-transform'));
          expect(outgoing, findsOneWidget, reason: 'The previous-page search must not expose its intermediate viewport');
          expect(tester.widget<FractionalTranslation>(outgoing).translation, Offset.zero,
            reason: 'Turning animation is disabled; keep the old page stationary until the new one is ready');
          await tester.pumpAndSettle();
          expect(outgoing, findsNothing);
          expect(viewportAnchor(), isNot(before), reason: 'Each left-side tap must really move to the previous page');
          final landed = laidOutRows().firstWhere((row) => row.$2.bottom > tester.getRect(body).top + 0.5);
          final actualCut = jointCuts[rowKeys[landed.$1]];
          if (actualCut != null) {
            final actualBounds = tester.getRect(body);
            final actualClip = tester.widget<ClipRect>(find.byKey(const ValueKey('reader-page-clip'))).clipper!.getClip(actualBounds.size);
            final actualKeys = laidOutRows().where((row) => row.$2.top >= actualBounds.top - .5 &&
              row.$2.bottom <= actualBounds.top + actualClip.bottom + .5).map((row) => rowKeys[row.$1]).toList();
            expect(actualKeys, actualCut, reason: 'The actual TOC-back page must implement its complete joint slice');
          } else if (target != null) {
            expect(landed.$1, target, reason: 'The actual first row must remain the selected previous-page row after the indexed list settles');
          } else if (previous.isEmpty) {
            // This fixture has one title and seven paragraphs per chapter.
            // Later taps may start in paragraph 6, not at the chapter title.
            final precedingItem = before.$1 - 1;
            expect(precedingItem, greaterThanOrEqualTo(0));
            final precedingChapter = precedingItem ~/ 8;
            final precedingParagraph = precedingItem % 8;
            final precedingText = precedingParagraph == 0 ? book.chapters[precedingChapter].title
              : book.chapters[precedingChapter].paragraphs[precedingParagraph - 1].display;
            expect(landed.$1.replaceAll('\u200B', '').replaceAll('\uFFFC', ''), contains(precedingText),
              reason: 'An uncached item boundary must prepare the actual immediate preceding paragraph or title before paging');
            expect(find.descendant(of: find.byKey(const ValueKey('reader-chapter-header')),
              matching: find.text(book.chapters[precedingChapter].title)), findsOneWidget,
              reason: 'The post-layout source anchor must update the chapter header for the actual preceding item');
          }
          expect(landed.$2.top, closeTo(tester.getRect(body).top, 0.25),
            reason: 'The selected row must land at zero actual pixel offset, not a partial row');
          if (precedingBoundary != null) {
            final landedBounds = tester.getRect(body);
            final landedClip = tester.widget<ClipRect>(find.byKey(const ValueKey('reader-page-clip'))).clipper!.getClip(landedBounds.size);
            final fullRows = laidOutRows().where((row) => row.$2.top >= landedBounds.top - 0.5 &&
              row.$2.bottom <= landedBounds.top + landedClip.bottom + 0.5).toList();
            expect(fullRows.last.$1, precedingBoundary,
              reason: 'The preceding page must end at the old page immediate predecessor without skipping or repeating a row');
          }
          if (chapter == 5 && page == 0) {
            await _captureReaderPreview(tester, preview, 'reader-toc-previous-${fontSize.toInt()}-$dpr');
            expect(find.byKey(const ValueKey('reader-menu')), findsNothing,
              reason: 'Returning to reading by paging must dismiss the toolbar overlay over the first row');
          }
          expectWholeVisibleRows(checkToolbar: true);
        }
      }
      await _captureReaderPreview(tester, preview, 'reader-toc-previous-${fontSize.toInt()}');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    });
    }
  }

  testWidgets('paging shows complete rows and optional overlap repeats exactly one boundary row', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: sample('whole-lines'), storage: AppStorage())));
    await tester.pumpAndSettle();
    final list = find.byKey(const ValueKey('reader-body'));
    List<(String,double,double)> lines({bool hidden = false}) {
      final bounds = tester.getRect(list);
      final clip = tester.widget<ClipRect>(find.byKey(const ValueKey('reader-page-clip'))).clipper!.getClip(bounds.size);
      final result = <(String,double,double)>[];
      for (final element in find.descendant(of: list, matching: find.byType(RichText)).evaluate()) {
        final render = element.findRenderObject();
        if (render is! RenderParagraph || !render.hasSize) continue;
        final origin = render.localToGlobal(Offset.zero);
        final text = render.text.toPlainText();
        final boxes = render.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: text.length),
          boxHeightStyle: ui.BoxHeightStyle.tight);
        final seen = <int>{};
        for (final box in boxes) {
          if (box.right - box.left < 0.01 || box.bottom - box.top < 2) continue;
          final start = render.getPositionForOffset(Offset(-10000,(box.top+box.bottom)/2)).offset;
          if (!seen.add(start)) continue;
          final end = render.getPositionForOffset(Offset(10000,(box.top+box.bottom)/2)).offset;
          final top = origin.dy + box.top, bottom = origin.dy + box.bottom;
          if (top < bounds.top - 0.5 || (!hidden && bottom > bounds.top + clip.bottom + 0.5)) continue;
          result.add((text.substring(start,end).replaceAll('\u200B','').replaceAll('\uFFFC','').trim(),top,bottom));
        }
      }
      result.sort((a,b)=>a.$2.compareTo(b.$2)); return result;
    }
    final before = lines(); expect(before, isNotEmpty);
    final all = lines(hidden: true);
    final next = all.firstWhere((r)=>r.$2 >= before.last.$3 - 0.5).$1;
    final viewport = tester.getRect(list);
    final clip = tester.widget<ClipRect>(find.byKey(const ValueKey('reader-page-clip'))).clipper!.getClip(viewport.size);
    expect(before.last.$3, closeTo(viewport.top+clip.bottom, 0.5));
    await tester.tapAt(const Offset(360,360)); await tester.pumpAndSettle();
    expect(lines().first.$1, next, reason: 'Default paging starts with the next complete line');
    await tester.tapAt(const Offset(195, 300)); await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('阅读设置')); await tester.pumpAndSettle();
    final overlap = find.byKey(const ValueKey('retain-page-line'));
    expect(tester.widget<SwitchListTile>(overlap).value, isFalse);
    tester.widget<SwitchListTile>(overlap).onChanged!(true); await tester.pumpAndSettle();
    await tester.tapAt(const Offset(20,120)); await tester.pumpAndSettle();
    final retained = lines().last.$1;
    await tester.tapAt(const Offset(360,360)); await tester.pumpAndSettle();
    expect(lines().first.$1, retained);
    await tester.tapAt(const Offset(195, 300)); await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('阅读设置')); await tester.pumpAndSettle();
    tester.widget<DropdownButton<String>>(find.byKey(const ValueKey('page-turn-mode'))).onChanged!('scroll');
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(overlap).onChanged, isNull);
    expect(tester.widget<ClipRect>(find.byKey(const ValueKey('reader-page-clip'))).clipper!.getClip(tester.getSize(list)).height, tester.getSize(list).height);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  testWidgets('slow initial speech does not produce an unrelated five-second network error', (tester) async {
    final speech = _TestSpeech()..delay = const Duration(seconds: 7);
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: sample('slow-speech'), storage: AppStorage(), ttsReader: speech)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('朗读')); await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    expect(find.byType(SnackBar), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    await tester.pump(const Duration(seconds: 2)); await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  testWidgets('filter toggles preserve the first visible line and quick bookmark adds at it', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    final storage = AppStorage();
    final settings = ReadingSettings()..pageTurnMode = 'scroll'..informationFilter = false..informationFilterLevel = 'ads';
    await storage.saveSettings(settings.toJson());
    final book = Book(id: 'filter-position', title: 'filter', filePath: '', format: BookFormat.txt,
      addedAt: DateTime(2026), chapters: [Chapter(title: '第一章', paragraphs: List.generate(30, (p) => Paragraph(
        display: '第${p + 1}段 https://example.com/long/path 链接之后的正文。' +
          List.generate(20, (s) => '这是第${s + 1}句，山间的风吹过树林，远方传来朋友的问候。').join(),
        tts: '', sentences: const [], sentenceStartTts: const [])))]);
    Future<void> open() async {
      await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: book, storage: storage)));
      await tester.pumpAndSettle();
    }
    final list = find.byKey(const ValueKey('reader-body'));
    (String, double) firstLine() {
      final viewport = tester.getRect(list);
      final texts = find.byWidgetPredicate((w) => w is Text && w.textAlign == TextAlign.justify);
      final candidates = texts.evaluate().map((e) => e.findRenderObject()).whereType<RenderParagraph>()
        .where((r) => r.localToGlobal(Offset.zero).dy < viewport.bottom && r.localToGlobal(Offset(0,r.size.height)).dy > viewport.top)
        .toList()..sort((a,b) => a.localToGlobal(Offset.zero).dy.compareTo(b.localToGlobal(Offset.zero).dy));
      final render = candidates.first;
      final origin = render.localToGlobal(Offset.zero);
      final y = (viewport.top - origin.dy).clamp(0.0, render.size.height);
      final range = TextRange(start: render.getPositionForOffset(Offset(-10000, y)).offset,
        end: render.getPositionForOffset(Offset(10000, y)).offset);
      final full = render.text.toPlainText();
      var start = range.start;
      while (start < range.end && (full[start] == '\u200B' || full[start] == '\n')) { start++; }
      final boxes = render.getBoxesForSelection(TextSelection(baseOffset: start, extentOffset: start + 1));
      return (full.substring(range.start, range.end).replaceAll('\u200B','').replaceAll('\n',''), origin.dy + boxes.first.top);
    }
    await open();
    tester.widget<ScrollablePositionedList>(list).itemScrollController!.jumpTo(index: 12);
    await tester.pumpAndSettle();
    unawaited(tester.widget<ScrollablePositionedList>(list).scrollOffsetController!.animateScroll(
      offset: 280, duration: const Duration(milliseconds: 1)));
    await tester.pumpAndSettle();
    final before = firstLine();
    await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('阅读设置')); await tester.pumpAndSettle();
    final filter = find.byKey(const ValueKey('information-filter'));
    final settingsScroll = find.descendant(of: find.byType(BottomSheet).last, matching: find.byType(Scrollable)).last;
    await tester.scrollUntilVisible(filter, 200, scrollable: settingsScroll); await tester.pumpAndSettle();
    await tester.tap(filter); await tester.pumpAndSettle();
    expect(firstLine().$1, before.$1); expect(firstLine().$2, closeTo(before.$2, 1));
    await tester.scrollUntilVisible(filter, 200, scrollable: settingsScroll); await tester.pumpAndSettle();
    await tester.tap(filter); await tester.pumpAndSettle();
    expect(firstLine().$1, before.$1); expect(firstLine().$2, closeTo(before.$2, 1));
    await tester.tapAt(const Offset(20, 120)); await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('添加书签')); await tester.pumpAndSettle();
    final bookmarks = await AnnotationStore().loadBookmarks(book.id);
    expect(bookmarks.length, 1); expect(bookmarks.single.chapterAnchor, isNotNull);
    final sourcePosition = ReadingText.locate(book, bookmarks.single.chapterIndex, bookmarks.single.chapterAnchor!);
    expect(bookmarks.single.charOffset, book.charOffsetOf(bookmarks.single.chapterIndex, sourcePosition.$1, sourcePosition.$2));
    expect(bookmarks.single.charOffset, greaterThan(0));
    expect(bookmarks.single.charOffsetEnd, greaterThan(bookmarks.single.charOffset));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    await open();
    expect(firstLine().$1, before.$1); expect(firstLine().$2, closeTo(before.$2, 1));
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });
}

Future<void> _ensureVoiceRowVisible(WidgetTester tester, Finder row) async {
  final sheet = find.byType(BottomSheet).last;
  final scroll = find.descendant(of: sheet, matching: find.byType(Scrollable)).last;
  await tester.scrollUntilVisible(row, 250, scrollable: scroll);
  await tester.ensureVisible(row); await tester.pumpAndSettle();
  final bounds = tester.getRect(scroll).intersect(tester.getRect(sheet));
  final actual = tester.getRect(row);
  expect(actual.top, greaterThanOrEqualTo(bounds.top - 0.5), reason: 'The complete voice row must be inside the sheet scrolling area before interaction');
  expect(actual.bottom, lessThanOrEqualTo(bounds.bottom + 0.5), reason: 'Finding a cached voice label below the sheet is not enough to select it');
}

Future<void> _captureReaderPreview(WidgetTester tester, GlobalKey key, String name) async {
  expect(tester.takeException(), isNull);
  if (!Platform.isLinux || Platform.environment['DD_READER_CAPTURE_UI_PREVIEWS'] != '1') return;
  await tester.runAsync(() async {
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory('build/ui-previews').create(recursive: true);
    await File('build/ui-previews/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

class _TestBookCacheTask extends BookCacheTask {
  int cancelCalls = 0;
  int startCalls = 0;
  Completer<void>? cancelGate;
  _TestBookCacheTask({required Book book, required TtsCacheStore store}) : super(book: book, store: store, bookId: book.id);
  @override
  Future<void> restoreFromDisk() async {}
  @override
  Future<void> start({bool resume = false, int? fromChapter, int? fromOffset}) async { startCalls++; }
  @override
  Future<void> cancel() async { cancelCalls++; await cancelGate?.future; }
}

class _GatedScanStore extends TtsCacheStore {
  final gate = Completer<Set<String>>();
  _GatedScanStore(String id, String fingerprint) : super(id, TtsReader.defaultVoice, 1.8, textFingerprint: fingerprint);
  @override Future<CacheProgress?> loadProgress() async => null;
  @override Future<Set<String>> listMp3Names() => gate.future;
  @override Future<int> sizeBytes() async => 0;
  @override Future<void> saveProgress({required int total, required int done,
    required Set<int> completed, required String state, int? fromChapter, int? fromOffset}) async {}
}

class _CountingSyncEngine extends SyncEngine {
  int calls = 0;
  _CountingSyncEngine(AppStorage storage) : super(storage: storage, annotations: AnnotationStore());
  @override Future<SyncReport> sync({String mode = 'both', bool dryRun = false,
    Map<String, dynamic>? expectedSettings}) async { calls++; return SyncReport()..ok = true; }
}

class _PageStartAudioPlayer implements AudioPlayer {
  final positions = StreamController<Duration>.broadcast();
  @override PositionUpdater? positionUpdater;
  @override Stream<void> get onPlayerComplete => const Stream<void>.empty();
  @override Stream<Duration> get onPositionChanged => positions.stream;
  @override Future<Duration?> getCurrentPosition() async => Duration.zero;
  @override Future<void> play(Source source, {double? volume, double? balance, AudioContext? ctx,
    Duration? position, PlayerMode? mode}) async {}
  @override Future<void> stop() async {}
  @override Future<void> pause() async {}
  @override Future<void> dispose() async { positionUpdater?.dispose(); await positions.close(); }
  @override dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected audio call: ${invocation.memberName}');
}

class _TestSpeech extends TtsReader {
  Duration delay = Duration.zero;
  TtsState _status = TtsState.idle;
  int startedAt = -1;
  int startCalls = 0, resumeCalls = 0, _sentenceIndex = -1;
  int speechOffset = 0, jumpCalls = 0;
  bool recordJumps = false;
  List<String> lastSentences = const [];
  List<int>? lastPauses;
  Completer<bool>? resumeResult;
  Completer<void>? pauseResult;
  void emitSentence(int idx) { if (idx != _sentenceIndex) speechOffset = 0; _sentenceIndex = idx; onSentenceChanged?.call(idx); }
  @override
  int get currentTtsOffset => speechOffset;
  @override
  int get currentIndex => _sentenceIndex;
  @override
  TtsState get state => _status;
  @override
  Future<void> start(List<String> sentences, {List<int>? offsets, List<int>? pauseAfterMilliseconds,
    int chapterIndex = 0, int from = 0, int initialTtsOffset = 0}) async {
    lastSentences = List.of(sentences); lastPauses = pauseAfterMilliseconds == null ? null : List.of(pauseAfterMilliseconds);
    speechOffset = initialTtsOffset;
    startCalls++; startedAt = from; _status = TtsState.playing; _sentenceIndex = from; onSentenceChanged?.call(from);
    if (delay > Duration.zero) await Future<void>.delayed(delay);
  }
  @override
  Future<void> pause({bool interrupted = false}) async { _status = TtsState.paused; if (pauseResult != null) await pauseResult!.future; }
  @override
  Future<void> jumpTo(int sentenceIndex, {int ttsOffset = 0}) async {
    if (!usesSystemVoice && !recordJumps) return super.jumpTo(sentenceIndex, ttsOffset: ttsOffset);
    jumpCalls++; speechOffset = ttsOffset; _sentenceIndex = sentenceIndex; onSentenceChanged?.call(sentenceIndex);
  }
  @override
  Future<bool> resume() async {
    resumeCalls++; _status = TtsState.playing; onSentenceChanged?.call(_sentenceIndex);
    return resumeResult == null ? true : await resumeResult!.future;
  }
  @override
  Future<void> stop() async { _status = TtsState.stopped; }
}
