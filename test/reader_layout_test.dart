import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:duoduo_langdu/models/book.dart';
import 'package:duoduo_langdu/models/progress.dart';
import 'package:duoduo_langdu/screens/reader_screen.dart';
import 'package:duoduo_langdu/screens/shelf_screen.dart';
import 'package:duoduo_langdu/services/app_storage.dart';
import 'package:duoduo_langdu/services/app_appearance.dart';
import 'package:duoduo_langdu/services/tts_reader.dart';
import 'package:duoduo_langdu/services/tts_audio_handler.dart';
import 'package:duoduo_langdu/services/playback_notifications.dart';
import 'package:duoduo_langdu/services/display_cutout.dart';
import 'package:duoduo_langdu/services/network_connectivity.dart';
import 'package:duoduo_langdu/services/reading_text.dart';
import 'package:duoduo_langdu/services/book_cache_task.dart';
import 'package:duoduo_langdu/services/tts_cache_store.dart';
import 'package:duoduo_langdu/services/reader_typography.dart';
import 'package:duoduo_langdu/services/annotation_store.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  final volumeCalls = <MethodCall>[];
  final platformCalls = <MethodCall>[];
  setUp(() {
    SharedPreferences.setMockInitialValues({'duoduo.settings.v1': jsonEncode({'brightness': 1.0, 'autoPageSeconds': 2, 'wordHighlightEnabled': true})});
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
    final key = GlobalKey();
    Widget app(Widget child) => ValueListenableBuilder<bool>(valueListenable: AppAppearance.nightMode,
      builder: (context, night, _) => RepaintBoundary(key: key, child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppAppearance.theme(night).copyWith(textTheme: AppAppearance.theme(night).textTheme.apply(fontFamily: 'Preview')),
      home: child,
    )));
    Future<void> capture(String name) async {
      expect(tester.takeException(), isNull);
      if (!Platform.isLinux) return;
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
    final settingBrightness = find.byWidgetPredicate((w) => w is Slider && w.max == 1).last;
    final settingFont = find.byWidgetPredicate((w) => w is Slider && w.max == 64).last;
    expect(tester.getRect(settingFont).width, closeTo(tester.getRect(settingBrightness).width, 0.1));
    expect(tester.getRect(settingFont).left, closeTo(tester.getRect(settingBrightness).left, 0.1));
    expect(find.byWidgetPredicate((w) => w is DropdownButton<String> && w.value == 'zh-CN-XiaoxiaoNeural'), findsNothing);
    expect(find.text('缓存在线语音'), findsNothing, reason: 'Online cache belongs to the playback panel');
    expect(find.text('变速'), findsNothing, reason: 'Speech speed belongs to the playback panel');
    final correction = find.byKey(const ValueKey('text-correction'));
    tester.widget<SwitchListTile>(correction).onChanged!(false);
    await tester.pumpAndSettle();
    expect((await AppStorage().loadSettings())['textCorrection'], isFalse);
    tester.widget<SwitchListTile>(correction).onChanged!(true);
    await tester.pumpAndSettle();
    final indent = find.byKey(const ValueKey('first-line-indent'));
    tester.widget<SwitchListTile>(indent).onChanged!(false); await tester.pumpAndSettle();
    expect((await AppStorage().loadSettings())['firstLineIndent'], isFalse);
    tester.widget<SwitchListTile>(indent).onChanged!(true); await tester.pumpAndSettle();
    final filter = find.byKey(const ValueKey('information-filter'));
    expect(tester.widget<SwitchListTile>(filter).value, isFalse);
    tester.widget<SwitchListTile>(filter).onChanged!(true); await tester.pumpAndSettle();
    expect((await AppStorage().loadSettings())['informationFilterLevel'], 'none', reason: 'The user chooses a level');
    final radios = find.byType(RadioListTile<String>);
    expect(radios, findsNWidgets(3));
    tester.widget<RadioListTile<String>>(radios.first).onChanged!('links'); await tester.pumpAndSettle();
    expect((await AppStorage().loadSettings())['informationFilterLevel'], 'links');
    await tester.ensureVisible(filter); await tester.pumpAndSettle();
    await capture('reader-text-options');
    tester.widget<SwitchListTile>(filter).onChanged!(false); await tester.pumpAndSettle();
    await tester.tapAt(const Offset(20, 120));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('横竖屏切换'));
    await tester.pumpAndSettle();
    expect(platformCalls.where((c) => c.method == 'SystemChrome.setPreferredOrientations').last.arguments,
      ['DeviceOrientation.landscapeLeft', 'DeviceOrientation.landscapeRight']);
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
    speech.onWordChanged?.call(0, 2);
    await tester.pump();
    final spans = <TextSpan>[];
    void collect(InlineSpan span) { if (span is TextSpan) { spans.add(span); for (final child in span.children ?? <InlineSpan>[]) { collect(child); } } }
    for (final text in tester.widgetList<Text>(find.byType(Text))) { if (text.textSpan != null) collect(text.textSpan!); }
    expect(spans.any((s) => s.style?.backgroundColor == const Color(0xFF9BC5DD)), isTrue,
      reason: 'The current word has a stronger highlight');
    expect(spans.any((s) => s.style?.backgroundColor == const Color(0x44FFC107)), isTrue,
      reason: 'The rest of the sentence stays highlighted');
    if (Platform.isLinux) {
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
    tester.widget<Slider>(speed).onChanged!(2.4); await tester.pumpAndSettle();
    expect((await storage.loadSettings())['speechRate'], 2.4);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    final nextSpeech = _TestSpeech();
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: sample('rate-restored'), storage: storage, ttsReader: nextSpeech)));
    await tester.pumpAndSettle();
    expect(nextSpeech.speechRate, 2.4);
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
        expect(spans.where((w) => w.style?.backgroundColor == const Color(0xFF9BC5DD)).map(plain).join(),
          sentence(p, s).substring(0, 3), reason: 'The word cursor must move into paragraph $p sentence $s');
        expect(spans.where((w) => w.style?.backgroundColor == const Color(0x44FFC107)).map(plain).join(),
          sentence(p, s).substring(3), reason: 'The current sentence must follow the audio');
        final position = tester.widget<ScrollablePositionedList>(body).itemPositionsNotifier!.itemPositions.value
          .singleWhere((pos) => pos.index == p + 1);
        expect(position.itemLeadingEdge, lessThan(1));
        expect(position.itemTrailingEdge, greaterThan(0));
        final paragraphFinder = find.byWidgetPredicate((w) => identical(w, current));
        final render = tester.renderObject<RenderParagraph>(paragraphFinder);
        final displayed = current.textSpan!.toPlainText();
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

  testWidgets('speech clears previous page limits and replays events received during a page turn', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    final storage = AppStorage();
    await storage.saveSettings((ReadingSettings()..wordHighlightEnabled = true..fontSize = 20..mergeNonSentenceBreaks = false
      ..firstLineIndent = false).toJson());
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
        boxHeightStyle: ui.BoxHeightStyle.includeLineSpacingMiddle).first;
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
    // Deliver a complete sentence/word event while the 80 ms horizontal page
    // animation is active. It must be replayed after the page settles.
    await tester.tapAt(const Offset(360, 360)); await tester.pump(const Duration(milliseconds: 16));
    speech.onSentenceChanged?.call(60); speech.onWordChanged?.call(0, 3);
    await assertCursor(60);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  for (final target in [
    ('zh-CN-YunxiNeural', '云希（男·阳光）'),
    (TtsReader.systemVoice, '使用系统文本转语音能力'),
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
      await tester.tap(find.text(target.$2)); await tester.pumpAndSettle();
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
        expect(yellowText, expectedSentence == 0 ? '章第${expectedParagraph + 1}段。' : '的风吹过树林，远方传来朋友的问候。');
        final positions = tester.widget<ScrollablePositionedList>(body).itemPositionsNotifier!.itemPositions.value;
        expect(positions.any((p) => p.index == expectedParagraph + 1 && p.itemLeadingEdge < 1 && p.itemTrailingEdge > 0), isTrue);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    });
  }

  testWidgets('paused cursor survives layout drift and foreground return never restarts speech', (tester) async {
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
      expect(yellow.join(), expected.substring(2));
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
    expect(speech.lastPauses, [300, 0]);
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
      ScaffoldMessenger.of(tester.element(find.byKey(const ValueKey('reader-body')))).hideCurrentSnackBar();
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(195, 360)); await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('playback-notifications'))); await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      expect(find.descendant(of: dialog, matching: find.text(grant ? '播放通知已开启' :
        '播放通知未开启，仍可继续朗读。可在系统设置中开启。')), findsOneWidget);
      await tester.tap(find.descendant(of: dialog, matching: find.text('打开设置'))); await tester.pumpAndSettle();
      expect(settingsOpened, 1);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive); await tester.pump();
      enabled = true;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed); await tester.pumpAndSettle();
      final statusIcon = tester.widget<Icon>(find.descendant(
        of: find.byKey(const ValueKey('playback-notifications')), matching: find.byType(Icon)));
      expect(statusIcon.icon, Icons.notifications_active_outlined,
        reason: 'Returning from system settings refreshes the current status');
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
    await tester.tap(find.byKey(const ValueKey('reading-prefetch'))); await tester.pumpAndSettle();
    final prefetch = find.byKey(const ValueKey('prefetch-number'));
    await tester.enterText(prefetch, '101'); await tester.tap(find.text('确定')); await tester.pumpAndSettle();
    expect(prefetch, findsOneWidget, reason: 'Prefetch values above 100 must be rejected');
    await tester.enterText(prefetch, '100'); await tester.tap(find.text('确定')); await tester.pumpAndSettle();
    expect(speech.prefetchSentences, 100); expect((await storage.loadSettings())['prefetchSentences'], 100);
    await tester.tap(find.byKey(const ValueKey('reading-prefetch'))); await tester.pumpAndSettle();
    await tester.enterText(prefetch, '0'); await tester.tap(find.text('确定')); await tester.pumpAndSettle();
    expect(speech.prefetchSentences, 0); expect((await storage.loadSettings())['prefetchSentences'], 0);
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

  testWidgets('cache controls identify and clear only the selected online voice and speed', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    final storage = AppStorage(), speech = _TestSpeech();
    final settings = ReadingSettings()..voice = TtsReader.defaultVoice..speechRate = 1.8;
    await storage.saveSettings(settings.toJson());
    final book = sample('cache-selected-voice');
    final formatted = ReadingText.format(book, merge: true, indent: true);
    final fingerprint = 'words1-${ReadingText.fingerprint(formatted)}';
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
    expect(tester.widget<Text>(find.byKey(const ValueKey('cache-binding'))).data, '音源: 晓晓（女·温暖） · 语速 1.8x');
    await _captureReaderPreview(tester, preview, 'reader-selected-voice-cache');
    await tester.tapAt(const Offset(195, 100)); await tester.pumpAndSettle();
    await _captureReaderPreview(tester, preview, 'reader-voice-menu-cache-actions');
    await tester.tap(find.byKey(const ValueKey('cache-voice-zh-CN-YunxiNeural'))); await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const ValueKey('cache-binding'))).data, '音源: 云希（男·阳光） · 语速 1.8x');
    expect(speech.voice, TtsReader.defaultVoice, reason: 'Opening another voice cache must not change the playing voice');
    await tester.tapAt(const Offset(195, 100)); await tester.pumpAndSettle();
    await tester.tap(find.text('云希（男·阳光）')); await tester.pumpAndSettle();
    await tester.tapAt(const Offset(195, 360)); await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reading-voice'))); await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cache-voice-zh-CN-YunxiNeural'))); await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const ValueKey('cache-binding'))).data, '音源: 云希（男·阳光） · 语速 1.8x');
    await tester.tap(find.text('清除缓存')); await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(AlertDialog), matching: find.textContaining('云希（男·阳光）')), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('确定'))); await tester.pumpAndSettle();
    expect(second.cancelCalls, 1); expect(first.cancelCalls, 0);
    expect(activeBookCaches.containsKey(key('zh-CN-YunxiNeural')), isFalse);
    expect(activeBookCaches[key(TtsReader.defaultVoice)], same(first));
    ScaffoldMessenger.of(tester.element(find.byKey(const ValueKey('reader-body')))).hideCurrentSnackBar();
    await tester.pumpAndSettle(); await tester.tapAt(const Offset(195, 100)); await tester.pumpAndSettle();
    await tester.tap(find.text('使用系统文本转语音能力')); await tester.pumpAndSettle();
    await tester.tapAt(const Offset(195, 360)); await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reading-cache')), findsNothing);
    expect(find.text('音源：系统'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('reading-voice'))); await tester.pumpAndSettle();
    final systemOption = find.widgetWithText(ListTile, '使用系统文本转语音能力');
    expect(tester.widget<ListTile>(systemOption).trailing, isNull);
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
    await storage.saveSettings((ReadingSettings()..voice = TtsReader.defaultVoice..systemFallbackActive = true).toJson());
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
            extentOffset: paragraph.text.toPlainText().length), boxHeightStyle: ui.BoxHeightStyle.includeLineSpacingMiddle);
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
    expect((await storage.loadSettings())['fontSize'], 37); expect((await storage.loadSettings())['speechRate'], 2.4);
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
    final font = find.byWidgetPredicate((w) => w is Slider && w.max == 64).last;
    tester.widget<Slider>(font).onChanged!(45); await tester.pumpAndSettle();
    expect(background(), const Color(0xFF1A1A1A), reason: 'Editing an old settings copy must resolve the current system theme');
    expect((await storage.loadSettings())['fontSize'], 45); expect((await storage.loadSettings())['speechRate'], 2.4);
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
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    tester.widget<SwitchListTile>(toggle).onChanged!(false); await tester.pumpAndSettle();
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

  testWidgets('system speech starts at the visible line and page turns keep its sentence character offset', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    final storage = AppStorage(); await storage.saveSettings((ReadingSettings()..voice = TtsReader.systemVoice).toJson());
    final book = Book(id: 'system-page-offset', title: '系统翻页', filePath: '', format: BookFormat.txt, addedAt: DateTime(2026),
      chapters: [Chapter(title: '第一章 山间', paragraphs: [Paragraph(display: List.filled(200, '清晨山间风吹树林远方传来朋友问候').join() + '。',
        tts: '', sentences: const [], sentenceStartTts: const [])])]);
    final speech = _TestSpeech();
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: book, storage: storage, ttsReader: speech)));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(360, 360)); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('朗读')); await tester.pumpAndSettle();
    final started = speech.currentTtsOffset;
    expect(started, greaterThan(0), reason: 'Starting system speech after a page turn must not read from the sentence beginning');
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
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    tester.widget<SwitchListTile>(toggle).onChanged!(true); await tester.pumpAndSettle(); expect(blue(), ['清晨']);
    tester.widget<SwitchListTile>(toggle).onChanged!(false); await tester.pumpAndSettle();
    speech.onWordChanged?.call(3, 5); await tester.pumpAndSettle(); expect(blue(), isEmpty);
    tester.widget<SwitchListTile>(toggle).onChanged!(true); await tester.pumpAndSettle(); expect(blue(), ['光洒']);
    expect((await storage.loadSettings())['wordHighlightEnabled'], isTrue);
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
    await storage.saveSettings((ReadingSettings()..fontSize = 64..retainPageLine = true).toJson());
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
          boxHeightStyle: ui.BoxHeightStyle.includeLineSpacingMiddle);
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
    await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('阅读设置')); await tester.pumpAndSettle();
    final overlap = find.byKey(const ValueKey('retain-page-line'));
    expect(tester.widget<SwitchListTile>(overlap).value, isFalse);
    tester.widget<SwitchListTile>(overlap).onChanged!(true); await tester.pumpAndSettle();
    await tester.tapAt(const Offset(20,120)); await tester.pumpAndSettle();
    final retained = lines().last.$1;
    await tester.tapAt(const Offset(360,360)); await tester.pumpAndSettle();
    expect(lines().first.$1, retained);
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
    final settings = ReadingSettings()..pageTurnMode = 'scroll'..informationFilterLevel = 'ads';
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
    tester.widget<SwitchListTile>(filter).onChanged!(true); await tester.pumpAndSettle();
    expect(firstLine().$1, before.$1); expect(firstLine().$2, closeTo(before.$2, 1));
    tester.widget<SwitchListTile>(filter).onChanged!(false); await tester.pumpAndSettle();
    expect(firstLine().$1, before.$1); expect(firstLine().$2, closeTo(before.$2, 1));
    await tester.tapAt(const Offset(20, 120)); await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('添加书签')); await tester.pumpAndSettle();
    final bookmarks = await AnnotationStore().loadBookmarks(book.id);
    expect(bookmarks.length, 1); expect(bookmarks.single.chapterAnchor, isNotNull);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    await open();
    expect(firstLine().$1, before.$1); expect(firstLine().$2, closeTo(before.$2, 1));
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });
}

Future<void> _captureReaderPreview(WidgetTester tester, GlobalKey key, String name) async {
  expect(tester.takeException(), isNull);
  if (!Platform.isLinux) return;
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
  _TestBookCacheTask({required Book book, required TtsCacheStore store}) : super(book: book, store: store, bookId: book.id);
  @override
  Future<void> restoreFromDisk() async {}
  @override
  void cancel() { cancelCalls++; }
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
  int get currentTtsOffset => usesSystemVoice ? speechOffset : 0;
  @override
  int get currentIndex => _sentenceIndex;
  @override
  TtsState get state => _status;
  @override
  Future<void> start(List<String> sentences, {List<int>? offsets, List<int>? pauseAfterMilliseconds,
    int chapterIndex = 0, int from = 0, int initialTtsOffset = 0}) async {
    lastSentences = List.of(sentences); lastPauses = pauseAfterMilliseconds == null ? null : List.of(pauseAfterMilliseconds);
    speechOffset = usesSystemVoice ? initialTtsOffset : 0;
    startCalls++; startedAt = from; _status = TtsState.playing; _sentenceIndex = from; onSentenceChanged?.call(from);
    if (delay > Duration.zero) await Future<void>.delayed(delay);
  }
  @override
  Future<void> pause() async { _status = TtsState.paused; if (pauseResult != null) await pauseResult!.future; }
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
