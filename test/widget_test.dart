import 'package:flutter_test/flutter_test.dart';

import 'package:duoduo_langdu/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const DuoduoLangduApp());
    await tester.pump(const Duration(milliseconds: 100));
    // 书架页顶部标题存在
    expect(find.text('多多朗读'), findsOneWidget);
  });
}
