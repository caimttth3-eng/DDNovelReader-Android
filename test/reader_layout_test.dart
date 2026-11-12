import 'dart:io';
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
    SharedPreferences.setMockInitialValues({});
    AppAppearance.nightMode.value = false;
    volumeCalls.clear(); platformCalls.clear();
    messenger.setMockMethodCallHandler(const MethodChannel('com.ddnovelreader/volume_keys'),
      (call) async { volumeCalls.add(call); return call.method == 'getMediaVolume' ? 0.5 : null; });
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
    await capture('reader-controls');
    final list = find.byType(ScrollablePositionedList);
    final text = find.text('清晨，阳光照进窗前。').first;
    final before = tester.getTopLeft(text);
    final listSize = tester.getSize(list);
    await tester.tapAt(const Offset(300, 360));
    await tester.pumpAndSettle();
    tester.view.viewPadding = const FakeViewPadding();
    tester.view.padding = const FakeViewPadding();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(text), before, reason: 'Hiding chrome must not move the text');
    expect(tester.getSize(list), listSize, reason: 'Toolbars must overlay the text viewport');
    await capture('reader');
    await tester.tapAt(const Offset(300, 360));
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
    final nextPage = topIndex();
    expect(nextPage, greaterThan(firstPage));
    await tester.drag(list, const Offset(220, 0));
    await tester.pumpAndSettle();
    expect(topIndex(), lessThan(nextPage));
    await tester.tap(find.byKey(const ValueKey('next-chapter')));
    await tester.pumpAndSettle();
    expect(find.text('第 2 章 山间来信'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('previous-chapter')));
    await tester.pumpAndSettle();
    expect(find.text('第 1 章 山间来信'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('reader-menu')));
    await tester.pumpAndSettle();
    await capture('reader-menu');
    final brightness = find.byKey(const ValueKey('quick-brightness'));
    final slider = tester.getRect(brightness);
    await tester.tapAt(Offset(slider.right - 12, slider.center.dy));
    await tester.pumpAndSettle();
    expect(volumeCalls.where((c) => c.method == 'setScreenBrightness').last.arguments, 1.0);
    await tester.tapAt(const Offset(20, 400));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('night-mode')));
    await tester.pumpAndSettle();
    expect(AppAppearance.nightMode.value, isTrue);
    expect((await AppStorage().loadSettings())['themeIndex'], 2);
    await capture('reader-night');
    await tester.tap(find.byKey(const ValueKey('reader-menu')));
    await tester.pumpAndSettle();
    await capture('reader-menu-night');
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
}
