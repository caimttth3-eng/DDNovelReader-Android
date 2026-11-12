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

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(const MethodChannel('com.ddnovelreader/volume_keys'),
      (call) async => call.method == 'getMediaVolume' ? 0.5 : null);
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
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    const fontPath = '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc';
    if (File(fontPath).existsSync()) {
      final loader = FontLoader('Preview');
      loader.addFont(Future.value(ByteData.sublistView(File(fontPath).readAsBytesSync())));
      await loader.load();
    }
    final key = GlobalKey();
    Widget app(Widget child) => RepaintBoundary(key: key, child: MaterialApp(
      theme: ThemeData(useMaterial3: true, fontFamily: 'Preview',
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6498B5))),
      home: child,
    ));
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
    await tester.tap(find.byIcon(Icons.menu_book));
    await tester.pumpAndSettle();
    expect(find.text('目录'), findsOneWidget);
    await capture('reader-contents');
    await tester.tapAt(const Offset(370, 400));
    await tester.pumpAndSettle();
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
    await capture('shelf');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
