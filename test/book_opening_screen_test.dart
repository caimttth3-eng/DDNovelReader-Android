import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:duoduo_langdu/models/book.dart';
import 'package:duoduo_langdu/models/progress.dart';
import 'package:duoduo_langdu/screens/book_opening_screen.dart';
import 'package:duoduo_langdu/screens/reader_screen.dart';
import 'package:duoduo_langdu/services/app_storage.dart';
import 'package:duoduo_langdu/services/reading_text.dart';
import 'package:duoduo_langdu/services/reader_preparation.dart';
import 'package:duoduo_langdu/services/app_appearance.dart';

class _NavigationLog extends NavigatorObserver {
  final pushed = <Route<dynamic>>[];
  final popped = <Route<dynamic>>[];
  var replacements = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) { pushed.add(route); }
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) { popped.add(route); }
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) { replacements++; }
}

Book readableBook() => Book(id: 'opening-screen-test', title: '测试书籍', filePath: '', format: BookFormat.txt,
  addedAt: DateTime(2026), chapters: [Chapter(title: '第一章', paragraphs: [ReadingText.paragraph('正文内容。')])]);

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  setUp(() {
    AppAppearance.updateSystemBrightness(Brightness.light); AppAppearance.setThemeMode('system');
    SharedPreferences.setMockInitialValues({});
    ReaderPreparation.runnerForTesting = (request) async => ReaderPreparation.prepareSynchronously(request);
    for (final name in ['com.ddnovelreader/volume_keys', 'com.ddnovelreader/debug_log',
      'com.ddnovelreader/notifications', 'com.ddnovelreader/display_cutout', 'com.ddnovelreader/network',
      'xyz.luan/audioplayers.global', 'xyz.luan/audioplayers.global/events']) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    messenger.setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers'), (call) async {
      if (call.method == 'create') {
        messenger.setMockMethodCallHandler(MethodChannel('xyz.luan/audioplayers/events/${(call.arguments as Map)['playerId']}'), (_) async => null);
      }
      return null;
    });
  });
  tearDown(() { ReaderPreparation.runnerForTesting = null; });

  Future<void> open(WidgetTester tester, _NavigationLog log, Future<(Book, BookProgress?)> Function() load) async {
    await tester.pumpWidget(MaterialApp(navigatorObservers: [log], home: Builder(builder: (context) => Scaffold(
      body: TextButton(onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => BookOpeningScreen(title: '测试书籍', loadBook: load, storage: AppStorage()))),
        child: const Text('open book'))))));
    await tester.tap(find.text('open book'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  testWidgets('opening a pending book immediately provides its title, progress and back button', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
    final log = _NavigationLog(), pending = Completer<(Book, BookProgress?)>();
    var loads = 0;
    await open(tester, log, () { loads++; return pending.future; });
    expect(find.text('测试书籍'), findsNothing);
    expect(find.byType(AppBar), findsNothing);
    expect(find.bySemanticsLabel('测试书籍'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);
    expect(loads, 1);
    expect(log.pushed, hasLength(2));
    await tester.tap(find.byType(BackButton));
    await tester.pump(); await tester.pump(const Duration(milliseconds: 350));
    pending.complete((readableBook(), null)); await tester.pump();
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('a late successful load cannot reopen the reader after returning', (tester) async {
    final log = _NavigationLog(), pending = Completer<(Book, BookProgress?)>();
    await open(tester, log, () => pending.future);
    final route = log.pushed.last as TransitionRoute<dynamic>;
    var removed = false;
    route.completed.then((_) { removed = true; });
    await tester.tap(find.byType(BackButton));
    await tester.pump();
    // Wait for the actual reverse transition/overlay removal, rather than a
    // fixed duration that may be shorter than the platform page transition.
    // pumpAndSettle cannot be used while the loading spinner is still active.
    for (var frame = 0; frame < 20 && !removed; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump();
    expect(removed, isTrue);
    expect(find.byType(BookOpeningScreen), findsNothing);
    expect(find.text('open book'), findsOneWidget);
    pending.complete((readableBook(), null));
    await tester.pump(); await tester.pump();
    expect(find.byType(ReaderScreen), findsNothing);
    expect(find.byType(BookOpeningScreen), findsNothing);
    expect(log.pushed, hasLength(2));
    expect(log.popped, hasLength(1));
    expect(log.replacements, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a load exception remains on the same route and offers a working back button', (tester) async {
    final log = _NavigationLog(), pending = Completer<(Book, BookProgress?)>();
    await open(tester, log, () => pending.future);
    pending.completeError(StateError('file decoding failed'));
    await tester.pump(); await tester.pump();
    expect(find.textContaining('file decoding failed'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('测试书籍'), findsOneWidget);
    expect(log.pushed, hasLength(2)); expect(log.replacements, 0);
    await tester.tap(find.byType(BackButton));
    await tester.pump(); await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('open book'), findsOneWidget);
  });

  testWidgets('a result arriving during the reverse transition cannot start the reader', (tester) async {
    final log = _NavigationLog(), pending = Completer<(Book, BookProgress?)>();
    final systemUiCalls = <MethodCall>[];
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async { systemUiCalls.add(call); return null; });
    await open(tester, log, () => pending.future);
    await tester.tap(find.byType(BackButton));
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byType(BookOpeningScreen), findsOneWidget, reason: 'The popped route is still animating out');
    pending.complete((readableBook(), null));
    await tester.pump(); await tester.pump(const Duration(milliseconds: 16));
    expect(find.byType(ReaderScreen), findsNothing);
    expect(systemUiCalls.where((call) => call.method == 'SystemChrome.setEnabledSystemUIMode'), isEmpty);
    expect(log.pushed, hasLength(2)); expect(log.popped, hasLength(1));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('open book'), findsOneWidget);
  });

  testWidgets('a parser failure displays its error without creating another route', (tester) async {
    final log = _NavigationLog(), pending = Completer<(Book, BookProgress?)>();
    await open(tester, log, () => pending.future);
    pending.complete((Book.failed(id: 'failed', title: '测试书籍', filePath: '', format: BookFormat.txt,
      addedAt: DateTime(2026), error: 'unsupported file'), null));
    await tester.pump(); await tester.pump();
    expect(find.textContaining('unsupported file'), findsOneWidget);
    expect(find.byType(ReaderScreen), findsNothing);
    expect(log.pushed, hasLength(2)); expect(log.replacements, 0);
    await tester.tap(find.byType(BackButton));
    await tester.pump(); await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('open book'), findsOneWidget);
  });

  testWidgets('successful loading builds the reader inside the original opening route', (tester) async {
    final log = _NavigationLog(), pending = Completer<(Book, BookProgress?)>();
    await open(tester, log, () => pending.future);
    final openingRoute = log.pushed.last;
    pending.complete((readableBook(), null));
    await tester.pump(); await tester.pump();
    expect(find.byType(BookOpeningScreen), findsOneWidget);
    expect(find.byType(ReaderScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-body')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing, reason: 'Prepared handoff must show text on the first reader frame');
    expect(log.pushed, hasLength(2));
    expect(identical(log.pushed.last, openingRoute), isTrue);
    expect(log.replacements, 0);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('parser and preparation share one loading view before a spinner-free reader handoff', (tester) async {
    final log = _NavigationLog(), parsed = Completer<(Book, BookProgress?)>(), prepared = Completer<PreparedReadingBook>();
    ReaderPreparationRequest? request;
    var runs = 0;
    ReaderPreparation.runnerForTesting = (value) { runs++; request = value; return prepared.future; };
    await open(tester, log, () => parsed.future);
    expect(find.byType(AppBar), findsNothing); expect(find.byType(CircularProgressIndicator), findsOneWidget);
    parsed.complete((readableBook(), null)); await tester.pump(); await tester.pump();
    expect(runs, 1); expect(find.byType(ReaderScreen), findsNothing);
    expect(find.byType(AppBar), findsNothing); expect(find.byType(CircularProgressIndicator), findsOneWidget);
    prepared.complete(ReaderPreparation.prepareSynchronously(request!)); await tester.pump(); await tester.pump();
    expect(runs, 1, reason: 'Reader must reuse prepared data rather than run its own second preparation');
    expect(find.byKey(const ValueKey('reader-body')), findsOneWidget); expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(log.pushed, hasLength(2)); expect(log.replacements, 0); expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pump();
  });

  testWidgets('format changes during preparation are refreshed and latest appearance is used on handoff', (tester) async {
    final log = _NavigationLog(), requests = <ReaderPreparationRequest>[], completions = <Completer<PreparedReadingBook>>[];
    ReaderPreparation.runnerForTesting = (request) { requests.add(request); final pending = Completer<PreparedReadingBook>();
      completions.add(pending); return pending.future; };
    await open(tester, log, () async => (readableBook(), null));
    expect(requests, hasLength(1)); expect(requests.first.merge, isTrue);
    final storage = AppStorage();
    await storage.saveSettings((ReadingSettings()..mergeNonSentenceBreaks = false..fontSize = 45..speechRate = 2.3).toJson());
    completions[0].complete(ReaderPreparation.prepareSynchronously(requests[0])); await tester.pump(); await tester.pump();
    expect(requests, hasLength(2)); expect(requests.last.merge, isFalse);
    expect(find.byType(CircularProgressIndicator), findsOneWidget); expect(find.byType(ReaderScreen), findsNothing);
    AppAppearance.updateSystemBrightness(Brightness.dark);
    completions[1].complete(ReaderPreparation.prepareSynchronously(requests[1])); await tester.pump(); await tester.pump();
    final reader = tester.widget<ReaderScreen>(find.byType(ReaderScreen));
    expect(reader.initialData!.settings.fontSize, 45); expect(reader.initialData!.settings.speechRate, 2.3);
    expect(tester.widget<Scaffold>(find.descendant(of: find.byType(ReaderScreen), matching: find.byType(Scaffold))).backgroundColor,
      const Color(0xFF1A1A1A));
    expect(find.byType(CircularProgressIndicator), findsNothing); expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pump();
  });

  testWidgets('leaving during preparation ignores late success without a second route or reader', (tester) async {
    final log = _NavigationLog(), prepared = Completer<PreparedReadingBook>();
    ReaderPreparationRequest? request;
    ReaderPreparation.runnerForTesting = (value) { request = value; return prepared.future; };
    await open(tester, log, () async => (readableBook(), null));
    expect(request, isNotNull);
    await tester.tap(find.byType(BackButton)); await tester.pump(); await tester.pump(const Duration(milliseconds: 350));
    prepared.complete(ReaderPreparation.prepareSynchronously(request!)); await tester.pump(); await tester.pump();
    expect(find.byType(ReaderScreen), findsNothing); expect(log.pushed, hasLength(2)); expect(log.replacements, 0);
    expect(tester.takeException(), isNull);
  });
}
