import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:duoduo_langdu/i18n.dart';
import 'package:duoduo_langdu/models/book.dart';
import 'package:duoduo_langdu/models/progress.dart';
import 'package:duoduo_langdu/screens/reader_screen.dart';
import 'package:duoduo_langdu/screens/sync_screen.dart';
import 'package:duoduo_langdu/services/annotation_store.dart';
import 'package:duoduo_langdu/services/app_appearance.dart';
import 'package:duoduo_langdu/services/app_storage.dart';
import 'package:duoduo_langdu/services/display_cutout.dart';
import 'package:duoduo_langdu/services/network_connectivity.dart';
import 'package:duoduo_langdu/services/playback_notifications.dart';
import 'package:duoduo_langdu/services/reader_preparation.dart';
import 'package:duoduo_langdu/services/reading_text.dart';
import 'package:duoduo_langdu/services/sync_engine.dart';
import 'package:duoduo_langdu/services/system_tts.dart';
import 'package:duoduo_langdu/services/tts_audio_handler.dart';
import 'package:duoduo_langdu/services/tts_reader.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppI18n.current = AppLang.zhHans;
    AppAppearance.setThemeMode('light');
  });

  for (final mode in ['both', 'push', 'pull']) {
    testWidgets('$mode is previewed and confirmed before execution', (tester) async {
      final engine = await _mountDialog(tester);
      await _choose(tester, mode);
      expect(engine.calls, ['$mode:true']);
      expect(find.byKey(const ValueKey('sync-preview')), findsOneWidget);
      expect(find.textContaining('预计'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('sync-preview-confirm'))); await tester.pumpAndSettle();
      expect(engine.calls, ['$mode:true', '$mode:false']);
      expect(engine.targets, hasLength(2));
      for (final target in engine.targets) {
        expect(target?[SyncEngine.cfgServer], 'https://sync.example.invalid/',
          reason: 'Preview and execution must both fence the exact confirmed target inside the engine');
      }
      expect(engine.completed, 1);
      expect(tester.widgetList<TextField>(find.byType(TextField)).every((field) => field.enabled == true), isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    });
  }

  for (final kind in ['source', 'deletion']) {
    testWidgets('$kind-only work is previewed and cancelling never executes it', (tester) async {
      final engine = await _mountDialog(tester);
      engine.preview = (mode) => _report(mode, true)
        ..sourceUploaded = kind == 'source' ? 1 : 0
        ..deletionUpdates = kind == 'deletion' ? 1 : 0;
      await _choose(tester, kind == 'deletion' ? 'pull' : 'push');
      expect(find.textContaining(kind == 'source' ? '预计补传书源 1 个' : '预计记录删除信息 1 项'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sync-preview-cancel'))); await tester.pumpAndSettle();
      expect(engine.calls, hasLength(1));
      expect(engine.completed, 0);
      expect(find.text('已取消'), findsOneWidget);
      await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    });
  }

  testWidgets('changing the target during confirmation cancels the old preview', (tester) async {
    final engine = await _mountDialog(tester);
    await _choose(tester, 'push');
    await engine.storage.saveSettings({SyncEngine.cfgServer: 'https://changed.example.invalid/'});
    await tester.tap(find.byKey(const ValueKey('sync-preview-confirm'))); await tester.pumpAndSettle();
    expect(engine.calls, ['push:true']);
    expect(find.text('同步配置已改变，请重新检查后再同步'), findsOneWidget);
    expect(engine.completed, 0);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  testWidgets('busy begins before settings persistence and releases after a thrown execution', (tester) async {
    final engine = await _mountDialog(tester);
    final persist = Completer<void>();
    addTearDown(() { if (!persist.isCompleted) persist.complete(); });
    engine.persistGate = persist;
    await tester.tap(find.byKey(const ValueKey('sync-push')));
    await tester.tap(find.byKey(const ValueKey('sync-push')));
    await tester.pump();
    expect(engine.persists, 1, reason: 'The second tap cannot enter before the first settings write finishes');
    expect(engine.calls, isEmpty);
    expect(tester.widgetList<TextField>(find.byType(TextField)).every((field) => field.enabled == false), isTrue);
    expect(tester.widgetList<SwitchListTile>(find.byType(SwitchListTile)).every((tile) => tile.onChanged == null), isTrue);
    persist.complete(); await tester.pumpAndSettle();
    engine.throwOnExecute = true;
    await tester.tap(find.byKey(const ValueKey('sync-preview-confirm'))); await tester.pumpAndSettle();
    expect(find.textContaining('synthetic execution failure'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(find.byKey(const ValueKey('sync-push'))).onPressed, isNotNull);
    expect(tester.widgetList<TextField>(find.byType(TextField)).every((field) => field.enabled == true), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  testWidgets('disposing while persistence waits never opens a preview or sets disposed state', (tester) async {
    final engine = await _mountDialog(tester);
    final persist = Completer<void>(); engine.persistGate = persist;
    addTearDown(() { if (!persist.isCompleted) persist.complete(); });
    await tester.tap(find.byKey(const ValueKey('sync-pull'))); await tester.pump();
    await tester.pumpWidget(const SizedBox());
    persist.complete(); await tester.pumpAndSettle();
    expect(engine.calls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unchanged remote-only records remain explained without pretending they can be imported', (tester) async {
    final engine = await _mountDialog(tester);
    engine.preview = (mode) => _report(mode, true)..remoteOnly.add('synthetic remote record');
    await _choose(tester, 'pull');
    expect(find.byKey(const ValueKey('sync-preview')), findsNothing);
    expect(find.textContaining('远端另有 1 本未导入'), findsOneWidget);
    expect(engine.calls, ['pull:true']);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  testWidgets('preview follows the neutral dark theme and keeps estimated counts', (tester) async {
    final engine = await _mountDialog(tester, dark: true);
    await _choose(tester, 'both');
    final preview = find.byKey(const ValueKey('sync-preview'));
    final dialogTheme = Theme.of(tester.element(preview)).dialogTheme;
    expect(dialogTheme.backgroundColor, const Color(0xFF1A1A1A));
    expect(dialogTheme.titleTextStyle?.fontSize, 20);
    expect(dialogTheme.contentTextStyle?.fontSize, 16);
    expect(engine.calls, ['both:true']);
    await tester.tap(find.byKey(const ValueKey('sync-preview-cancel'))); await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  testWidgets('all directions remain reachable in a short landscape dialog', (tester) async {
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(760, 320);
    addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
    final engine = await _mountDialog(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('sync-pull'))); await tester.pumpAndSettle();
    await _choose(tester, 'pull');
    expect(engine.calls, ['pull:true']);
    await tester.tap(find.byKey(const ValueKey('sync-preview-cancel'))); await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  group('reader integration', () {
    final messenger = binding.defaultBinaryMessenger;
    TtsAudioHandler? previous;
    late TtsAudioHandler handler;
    setUp(() async {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      ReaderPreparation.clearMemoryCache();
      ReaderPreparation.runnerForTesting = (request) async => ReaderPreparation.prepareSynchronously(request);
      previous = globalAudioHandler; handler = TtsAudioHandler(); globalAudioHandler = handler;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
      messenger.setMockMethodCallHandler(const MethodChannel('com.ddnovelreader/volume_keys'),
        (call) async => call.method == 'getMediaVolume' ? .5 : null);
      messenger.setMockMethodCallHandler(const MethodChannel('com.ddnovelreader/debug_log'), (_) async => null);
      messenger.setMockMethodCallHandler(DisplayCutoutService.channel, (_) async => null);
      messenger.setMockMethodCallHandler(NetworkConnectivity.channel, (_) async => null);
      messenger.setMockMethodCallHandler(SystemTtsClient.channel, (_) async => null);
      messenger.setMockMethodCallHandler(PlaybackNotifications.channel, (_) async =>
        {'supported': false, 'enabled': false, 'canRequest': false, 'asked': false});
      await Future<void>.delayed(Duration.zero);
    });
    tearDown(() {
      ReaderPreparation.runnerForTesting = null; ReaderPreparation.clearMemoryCache();
      globalAudioHandler = previous;
      unawaited(handler.playbackState.close()); unawaited(handler.mediaItem.close());
    });

    testWidgets('three modes occupy one equally spaced reader slot and cancellation keeps the current viewport', (tester) async {
      tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
      final storage = AppStorage(); await _configure(storage);
      final engine = _UiEngine(storage);
      final book = _book('popup');
      await tester.pumpWidget(MaterialApp(theme: AppAppearance.theme(false), home: ReaderScreen(
        book: book, storage: storage, syncEngine: engine, ttsReader: TtsReader(player: _SilentPlayer()))));
      await tester.pumpAndSettle();
      await _openQuick(tester);
      final sync = find.byKey(const ValueKey('reader-sync'));
      final siblings = [sync, find.byTooltip('添加书签'), find.byTooltip('横竖屏切换'), find.byTooltip('阅读设置')];
      final centers = siblings.map((finder) => tester.getCenter(finder).dx).toList();
      expect(centers[1] - centers[0], closeTo(centers[2] - centers[1], .5));
      expect(centers[2] - centers[1], closeTo(centers[3] - centers[2], .5));
      final before = tester.getRect(find.byKey(const ValueKey('reader-body')));
      final beforeItems = _viewport(tester);
      await tester.tap(sync); await tester.pumpAndSettle();
      for (final mode in ['both', 'push', 'pull']) {
        expect(find.byKey(ValueKey('reader-sync-mode-$mode')), findsOneWidget);
      }
      await tester.tap(find.byKey(const ValueKey('reader-sync-mode-pull'))); await tester.pumpAndSettle();
      expect(engine.calls, ['pull:true']);
      await tester.tap(find.byKey(const ValueKey('sync-preview-cancel'))); await tester.pumpAndSettle();
      expect(engine.calls, ['pull:true']);
      expect(tester.getRect(find.byKey(const ValueKey('reader-body'))), before);
      expect(_viewport(tester), beforeItems, reason: 'Cancelling leaves the same source items and scroll offsets in place');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    });

    testWidgets('reader waits for an already running progress save before previewing', (tester) async {
      tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio); addTearDown(tester.view.resetPhysicalSize);
      final storage = _GatedProgressStorage(); await _configure(storage);
      addTearDown(() { if (!storage.gate.isCompleted) storage.gate.complete(); });
      final engine = _UiEngine(storage);
      final book = _book('pending-save');
      await tester.pumpWidget(MaterialApp(home: ReaderScreen(book: book, storage: storage,
        syncEngine: engine, ttsReader: TtsReader(player: _SilentPlayer()))));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 450));
      expect(storage.entered, greaterThan(0));
      await _openQuick(tester);
      await tester.tap(find.byKey(const ValueKey('reader-sync'))); await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reader-sync-mode-push'))); await tester.pumpAndSettle();
      expect(engine.calls, isEmpty, reason: 'The snapshot cannot race an already started debounced write');
      storage.gate.complete(); await tester.pumpAndSettle();
      expect(engine.calls, ['push:true']);
      expect(engine.progressAtPreview, isNotNull);
      await tester.tap(find.byKey(const ValueKey('sync-preview-cancel'))); await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
    });
  });
}

Future<void> _configure(AppStorage storage) => storage.saveSettings({
  SyncEngine.cfgServer: 'https://sync.example.invalid/',
  SyncEngine.cfgDir: SyncEngine.remoteDirDefault,
  SyncEngine.cfgVerifyTls: true,
});

Future<_UiEngine> _mountDialog(WidgetTester tester, {bool dark = false}) async {
  final storage = AppStorage(); await _configure(storage);
  final engine = _UiEngine(storage);
  await tester.pumpWidget(MaterialApp(theme: AppAppearance.theme(dark), home: SyncScreen(
    storage: storage, annotations: AnnotationStore(), syncEngine: engine,
    onSynced: () => engine.completed++)));
  await tester.pumpAndSettle();
  return engine;
}

Future<void> _choose(WidgetTester tester, String mode) async {
  await tester.tap(mode == 'both' ? find.text('立即同步') : find.byKey(ValueKey('sync-$mode')));
  await tester.pumpAndSettle();
}

Future<void> _openQuick(WidgetTester tester) async {
  if (find.byKey(const ValueKey('reader-menu')).evaluate().isEmpty) {
    await tester.tapAt(const Offset(195, 300)); await tester.pumpAndSettle();
  }
  await tester.tap(find.byKey(const ValueKey('reader-menu'))); await tester.pumpAndSettle();
}

List<(String, double, double)> _viewport(WidgetTester tester) {
  final body = find.byKey(const ValueKey('reader-body'));
  final viewport = tester.getRect(body);
  final rows = <String, Rect>{};
  for (final paragraph in tester.renderObjectList<RenderParagraph>(
    find.descendant(of: body, matching: find.byType(RichText)))) {
    final text = paragraph.text.toPlainText();
    if (text.isEmpty || !paragraph.hasSize) continue;
    final origin = paragraph.localToGlobal(Offset.zero);
    final prefix = text.length > 32 ? text.substring(0, 32) : text;
    for (final box in paragraph.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: text.length))) {
      final local = box.toRect(), rect = local.shift(origin);
      if (rect.width <= 2 || rect.height <= 2 || rect.bottom <= viewport.top || rect.top >= viewport.bottom) continue;
      final offset = paragraph.getPositionForOffset(Offset(-1, local.center.dy)).offset;
      final key = '$prefix/$offset';
      rows.update(key, (previous) => previous.expandToInclude(rect), ifAbsent: () => rect);
    }
  }
  final result = [for (final row in rows.entries)
    (row.key, row.value.top - viewport.top, row.value.bottom - viewport.top)]
    ..sort((a, b) => a.$2 != b.$2 ? a.$2.compareTo(b.$2) : a.$1.compareTo(b.$1));
  expect(result, isNotEmpty, reason: 'Capture real visible source rows, not merely the viewport container');
  return result;
}

SyncReport _report(String mode, bool dryRun) => SyncReport()..ok = true..mode = mode..dryRun = dryRun;

Book _book(String id) => Book(id: id, title: '同步界面回归', filePath: '', format: BookFormat.txt,
  addedAt: DateTime(2026), chapters: [Chapter(title: '第一章', paragraphs: [
    for (var i = 0; i < 12; i++) ReadingText.paragraph('这是第$i段。' + List.filled(30, '此处是供同步与阅读定位回归使用的合成正文。').join()),
  ])]);

class _UiEngine extends SyncEngine {
  final calls = <String>[];
  final targets = <Map<String, dynamic>?>[];
  SyncReport Function(String)? preview;
  Completer<void>? persistGate;
  int persists = 0, completed = 0;
  bool throwOnExecute = false;
  BookProgress? progressAtPreview;
  _UiEngine(AppStorage storage) : super(storage: storage, annotations: AnnotationStore());
  @override Future<void> saveSettings(Map<String, dynamic> settings) async {
    persists++;
    final gate = persistGate;
    if (gate != null) await gate.future;
    await super.saveSettings(settings);
  }
  @override Future<SyncReport> sync({String mode = 'both', bool dryRun = false,
    Map<String, dynamic>? expectedSettings}) async {
    calls.add('$mode:$dryRun');
    targets.add(expectedSettings == null ? null : Map<String, dynamic>.from(expectedSettings));
    if (dryRun) {
      progressAtPreview = await storage.loadProgress('pending-save');
      if (preview != null) return preview!(mode);
      return _report(mode, true)..pushed = (mode == 'pull' ? 0 : 1)..pulled = (mode == 'push' ? 0 : 1);
    }
    if (throwOnExecute) throw StateError('synthetic execution failure');
    return _report(mode, false)..pushed = (mode == 'pull' ? 0 : 1)..pulled = (mode == 'push' ? 0 : 1);
  }
}

class _GatedProgressStorage extends AppStorage {
  final gate = Completer<void>();
  int entered = 0;
  @override Future<bool> trySaveProgress(BookProgress progress, {bool remote = false}) async {
    entered++;
    await gate.future;
    return super.trySaveProgress(progress, remote: remote);
  }
}

class _SilentPlayer implements AudioPlayer {
  @override PositionUpdater? positionUpdater;
  @override Stream<void> get onPlayerComplete => const Stream.empty();
  @override Stream<Duration> get onPositionChanged => const Stream.empty();
  @override Future<Duration?> getCurrentPosition() async => Duration.zero;
  @override Future<void> stop() async {}
  @override Future<void> pause() async {}
  @override Future<void> dispose() async { positionUpdater?.dispose(); }
  @override dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected player operation: ${invocation.memberName}');
}
