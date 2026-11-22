import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:duoduo_langdu/screens/sync_screen.dart';
import 'package:duoduo_langdu/services/annotation_store.dart';
import 'package:duoduo_langdu/services/app_storage.dart';
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

  testWidgets('服务器为空时点保存到云端给出提示，不发请求', (tester) async {
    final storage = AppStorage();
    await tester.pumpWidget(MaterialApp(
      home: SyncScreen(storage: storage, annotations: AnnotationStore()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('保存到云端'));
    await tester.pumpAndSettle();

    expect(find.textContaining('请先填写服务器地址'), findsOneWidget);
  });
}
