import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:duoduo_langdu/screens/sync_screen.dart';
import 'package:duoduo_langdu/services/annotation_store.dart';
import 'package:duoduo_langdu/services/app_storage.dart';
import 'package:duoduo_langdu/services/app_appearance.dart';
import 'package:duoduo_langdu/services/sync_engine.dart';

/// 同步对话框可打开、字段可填、保存能落盘。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('对话框渲染四个输入框 + 两个开关 + 三个按钮', (tester) async {
    final storage = AppStorage();
    await tester.pumpWidget(MaterialApp(
      home: SyncScreen(storage: storage, annotations: AnnotationStore()),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNWidgets(4));
    expect(find.byType(Switch), findsNWidgets(2));
    expect(find.byType(FilledButton), findsOneWidget);
    // 默认提示与未同步状态
    expect(find.textContaining('尚未同步'), findsOneWidget);
    // 远端目录默认值
    final dirField = tester.widgetList<TextField>(find.byType(TextField)).last;
    expect(dirField.controller?.text, SyncEngine.remoteDirDefault);
  });

  testWidgets('填写后点保存写入 settings', (tester) async {
    final storage = AppStorage();
    await tester.pumpWidget(MaterialApp(
      home: SyncScreen(storage: storage, annotations: AnnotationStore()),
    ));
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'https://dav.example.com/dav/');
    await tester.enterText(fields.at(1), 'demo');
    await tester.enterText(fields.at(2), 'secret');
    await tester.enterText(fields.at(3), 'DD/Books');
    await tester.pumpAndSettle();

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final s = await storage.loadSettings();
    expect(s[SyncEngine.cfgServer], 'https://dav.example.com/dav/');
    expect(s[SyncEngine.cfgUser], 'demo');
    expect(s[SyncEngine.cfgPass], 'secret');
    expect(s[SyncEngine.cfgDir], 'DD/Books');
    expect(s[SyncEngine.cfgAuto], true);
    expect(s[SyncEngine.cfgVerifyTls], true);
  });

  testWidgets('服务器为空时点立即同步给出提示，不发请求', (tester) async {
    final storage = AppStorage();
    await tester.pumpWidget(MaterialApp(
      home: SyncScreen(storage: storage, annotations: AnnotationStore()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('立即同步'));
    await tester.pumpAndSettle();

    expect(find.textContaining('请先填写服务器地址'), findsOneWidget);
  });

  testWidgets('sync fields and labels follow live light/dark themes without losing drafts', (tester) async {
    AppAppearance.initialize(ReadingSettings(), Brightness.light);
    addTearDown(() => AppAppearance.initialize(ReadingSettings(), Brightness.light));
    final storage = AppStorage();
    await tester.pumpWidget(ValueListenableBuilder<bool>(valueListenable: AppAppearance.nightMode,
      builder: (_, dark, __) => MaterialApp(theme: AppAppearance.theme(dark), home: Scaffold(
        body: SyncScreen(storage: storage, annotations: AnnotationStore())))));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'https://dav.example.test/');
    for (final dark in [true, false]) {
      AppAppearance.setThemeMode(dark ? 'dark' : 'light'); await tester.pumpAndSettle();
      final fields = tester.widgetList<TextField>(find.byType(TextField));
      final scheme = Theme.of(tester.element(find.byType(SyncScreen))).colorScheme;
      expect(tester.widget<Dialog>(find.byType(Dialog)).backgroundColor, scheme.surface);
      expect(tester.widget<Text>(find.text('服务器地址')).style!.color, scheme.onSurfaceVariant);
      for (final field in fields) {
        expect(field.style!.color, scheme.onSurface);
        expect(field.decoration!.fillColor, scheme.surfaceContainerHighest);
        final text = scheme.onSurface.computeLuminance(), fill = scheme.surfaceContainerHighest.computeLuminance();
        expect(((text > fill ? text : fill) + .05) / ((text < fill ? text : fill) + .05), greaterThanOrEqualTo(4.5));
      }
      expect(fields.first.controller!.text, 'https://dav.example.test/');
    }
    await tester.tap(find.text('保存')); await tester.pumpAndSettle();
    expect((await storage.loadSettings())[SyncEngine.cfgServer], 'https://dav.example.test/');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });
}
