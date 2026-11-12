import 'dart:io';
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
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  final volumeCalls = <MethodCall>[];
  final platformCalls = <MethodCall>[];
  setUp(() {
    SharedPreferences.setMockInitialValues({'duoduo.settings.v1': jsonEncode({'brightness': 1.0, 'autoPageSeconds': 2})});
    AppAppearance.nightMode.value = false;
    volumeCalls.clear(); platformCalls.clear();
    messenger.setMockMethodCallHandler(const MethodChannel('com.ddnovelreader/volume_keys'),
      (call) async { volumeCalls.add(call); return ['getMediaVolume', 'getSystemBrightness'].contains(call.method) ? 0.5 : null; });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async { platformCalls.add(call); return null; });
    messenger.setMockMethodCallHandler(const MethodChannel('com.ddnovelreader/debug_log'), (_) async => null);
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
    final text = find.byWidgetPredicate((w) => w is Text && w.textAlign == TextAlign.justify && (w.textSpan?.toPlainText().contains('清晨，阳光照进窗前。') ?? false)).first;
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
    await tester.tapAt(const Offset(20, 400));
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
    expect(find.byWidgetPredicate((w) => w is DropdownButton<String> && w.value == 'zh-CN-XiaoxiaoNeural'), findsOneWidget);
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
    expect(visible().first.index, 0, reason: 'New books open on their chapter heading');
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
    final settings = ReadingSettings()..pageTurnMode = 'swipe'..fontSize = 64;
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
    settings.pageTurnMode = 'scroll'; await storage.saveSettings(settings.toJson());
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: sample('scroll'), storage: storage)));
    await tester.pumpAndSettle();
    expect(tester.widget<ScrollablePositionedList>(list).physics, isA<ClampingScrollPhysics>());
    for (var i = 0; i < 12; i++) { await tester.drag(list, const Offset(0, -1000)); await tester.pumpAndSettle(); }
    final scrollIndex = firstIndex();
    expect(scrollIndex, greaterThan(5));
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
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

}
