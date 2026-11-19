import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:duoduo_langdu/main.dart';
import 'package:duoduo_langdu/models/book.dart';
import 'package:duoduo_langdu/models/progress.dart';
import 'package:duoduo_langdu/screens/reader_screen.dart';
import 'package:duoduo_langdu/screens/shelf_screen.dart';
import 'package:duoduo_langdu/services/app_appearance.dart';
import 'package:duoduo_langdu/services/app_storage.dart';
import 'package:duoduo_langdu/services/reader_preparation.dart';
import 'package:duoduo_langdu/widgets/book_card.dart';

double contrast(Color first, Color second) {
  final a = first.computeLuminance(), b = second.computeLuminance();
  return ((a > b ? a : b) + 0.05) / ((a < b ? a : b) + 0.05);
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  final platformCalls = <MethodCall>[];
  late Directory cacheDirectory;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppAppearance.initialize(ReadingSettings(), Brightness.light);
    ReaderPreparation.runnerForTesting = (request) async => ReaderPreparation.prepareSynchronously(request);
    platformCalls.clear();
    cacheDirectory = await Directory.systemTemp.createTemp('shelf-theme-test-');
    messenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => cacheDirectory.path);
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async { platformCalls.add(call); return null; });
    for (final name in ['com.ddnovelreader/volume_keys', 'com.ddnovelreader/debug_log',
      'com.ddnovelreader/notifications', 'com.ddnovelreader/display_cutout', 'com.ddnovelreader/network',
      'xyz.luan/audioplayers.global', 'xyz.luan/audioplayers.global/events']) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    messenger.setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers'), (call) async {
      if (call.method == 'create') {
        messenger.setMockMethodCallHandler(MethodChannel('xyz.luan/audioplayers/events/${(call.arguments as Map)['playerId']}'), (_) async => null);
      }
      return null;
    });
  });
  tearDown(() async {
    ReaderPreparation.runnerForTesting = null;
    AppAppearance.initialize(ReadingSettings(), Brightness.light);
    messenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), null);
    await cacheDirectory.delete(recursive: true);
  });

  Future<AppStorage> seed() async {
    final storage = AppStorage();
    await storage.saveSettings({'fontSize': 37.0, 'speechRate': 1.42, 'sync_auto': false});
    await storage.addBook(BookMeta(id: 'shelf-theme-book', title: '书架主题测试', filePath: '', format: 'txt',
      addedAt: DateTime(2026), contentKey: '0123456789abcdef', totalChars: 100, chapterCount: 1));
    await storage.saveProgress(BookProgress(bookId: 'shelf-theme-book', percent: .123));
    return storage;
  }

  SystemUiOverlayStyle bars(WidgetTester tester) => tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
    find.byKey(const ValueKey('shelf-system-bars'))).value;

  testWidgets('top-right toggles persist theme and original list layout without losing reader settings', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    final storage = await seed();
    await tester.pumpWidget(const DuoduoLangduApp()); await tester.pumpAndSettle();
    expect(find.byType(BookCard), findsOneWidget);
    expect(bars(tester).statusBarIconBrightness, Brightness.dark);
    await tester.tap(find.byKey(const ValueKey('shelf-layout-toggle'))); await tester.pumpAndSettle();
    expect(find.byType(BookCard), findsNothing);
    final tile = tester.widget<ListTile>(find.ancestor(of: find.text('书架主题测试'), matching: find.byType(ListTile)));
    expect(tile.minVerticalPadding, 16);
    expect((tile.title as Text).maxLines, 2);
    expect((tile.subtitle as Text).data, 'TXT');
    expect((tile.trailing as Text).data, '12.3%');
    expect(tile.onTap, isNotNull); expect(tile.onLongPress, isNotNull);
    expect(find.text('添加书籍'), findsOneWidget);
    await tester.longPress(find.text('书架主题测试')); await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('取消')); await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shelf-theme-toggle'))); await tester.pumpAndSettle();
    expect(Theme.of(tester.element(find.byType(ShelfScreen))).brightness, Brightness.dark);
    expect(bars(tester).statusBarIconBrightness, Brightness.light);
    final saved = await storage.loadSettings();
    expect(saved['themeMode'], 'dark'); expect(saved['shelfLayout'], 'list');
    expect(saved['fontSize'], 37); expect(saved['speechRate'], 1.42); expect(saved['sync_auto'], isFalse);
    final paragraph = tester.renderObject<RenderParagraph>(find.text('书架主题测试'));
    final background = tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor ??
      Theme.of(tester.element(find.byType(ShelfScreen))).scaffoldBackgroundColor;
    expect(contrast(paragraph.text.style!.color!, background), greaterThanOrEqualTo(4.5));
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    AppAppearance.initialize(ReadingSettings.fromJson(await storage.loadSettings()), Brightness.light);
    await tester.pumpWidget(const DuoduoLangduApp()); await tester.pumpAndSettle();
    expect(find.byKey(const PageStorageKey('shelf-list')), findsOneWidget);
    expect(bars(tester).statusBarIconBrightness, Brightness.light);
    await tester.tap(find.byKey(const ValueKey('shelf-theme-toggle'))); await tester.pumpAndSettle();
    expect(bars(tester).statusBarIconBrightness, Brightness.dark);
    await tester.tap(find.byKey(const ValueKey('shelf-layout-toggle'))); await tester.pumpAndSettle();
    expect(find.byType(BookCard), findsOneWidget);
    expect((await storage.loadSettings())['shelfLayout'], 'grid');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  for (final dark in [false, true]) {
    testWidgets('reader return and child dialogs keep legible shelf bars with dark=$dark', (tester) async {
      final storage = await seed();
      AppAppearance.setThemeMode(dark ? 'dark' : 'light');
      await tester.pumpWidget(const DuoduoLangduApp()); await tester.pumpAndSettle();
      final navigator = Navigator.of(tester.element(find.byType(ShelfScreen)));
      final book = Book(id: 'reader-return', title: '阅读返回', filePath: '', format: BookFormat.txt, addedAt: DateTime(2026),
        chapters: [Chapter(title: '第一章', paragraphs: [const Paragraph(display: '正文。', tts: '正文。',
          sentences: [Sentence('正文。', '正文。')], sentenceStartTts: [0])])]);
      navigator.push(MaterialPageRoute<void>(builder: (_) => ReaderScreen(book: book, storage: storage)));
      await tester.pumpAndSettle();
      navigator.pop(); await tester.pumpAndSettle();
      expect(bars(tester).statusBarIconBrightness, dark ? Brightness.light : Brightness.dark);
      final applied = platformCalls.lastWhere((call) => call.method == 'SystemChrome.setSystemUIOverlayStyle').arguments as Map;
      expect(applied['statusBarIconBrightness'], (dark ? Brightness.light : Brightness.dark).toString());
      await tester.tap(find.byKey(const ValueKey('shelf-menu'))); await tester.pumpAndSettle();
      await tester.tap(find.text('关于')); await tester.pumpAndSettle();
      final contact = find.byWidgetPredicate((widget) => widget is Text && widget.textSpan?.toPlainText().contains('230468896') == true);
      final text = tester.widget<Text>(contact).textSpan! as TextSpan;
      final scheme = Theme.of(tester.element(contact)).colorScheme;
      expect((text.children!.first as TextSpan).style!.color, scheme.onSurface);
      expect((text.children!.last as TextSpan).style!.color, scheme.primary);
      navigator.pop(); await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('shelf-menu'))); await tester.pumpAndSettle();
      final empty = find.text('暂无缓存');
      await tester.runAsync(() async {
        await tester.tap(find.text('缓存管理'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        for (var i = 0; i < 100 && empty.evaluate().isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump();
        }
      });
      expect(empty, findsOneWidget);
      expect(tester.widget<Text>(empty).style!.color, Theme.of(tester.element(empty)).colorScheme.onSurfaceVariant);
      navigator.pop(); await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    });
  }
}
