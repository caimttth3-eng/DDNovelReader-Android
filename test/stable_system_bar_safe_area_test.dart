import 'dart:async';

import 'package:duoduo_langdu/services/display_cutout.dart';
import 'package:duoduo_langdu/widgets/stable_system_bar_safe_area.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const content = Key('content');
  const normal = EdgeInsets.only(top: 24, bottom: 30);
  const smaller = EdgeInsets.only(top: 20, bottom: 12);
  const portrait = Size(400, 800);
  Map<String, Object?> geometry(Size size, EdgeInsets insets, {bool visible = false}) => {
    'width': size.width, 'height': size.height,
    'systemBarInsets': {'left': insets.left, 'top': insets.top,
      'right': insets.right, 'bottom': insets.bottom},
    'statusBarVisible': visible,
  };

  Future<void> show(WidgetTester tester, {required bool hold, EdgeInsets insets = normal,
      Size size = portrait, double dpr = 1}) async {
    await tester.pumpWidget(Directionality(textDirection: TextDirection.ltr,
      child: MediaQuery(data: MediaQueryData(size: size, devicePixelRatio: dpr,
        padding: insets, viewPadding: insets), child: StableSystemBarSafeArea(
          holdInsets: hold, child: const Align(alignment: Alignment.topLeft,
            child: SizedBox(key: content, width: 10, height: 10))))));
    await tester.pump();
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(DisplayCutoutService.channel, null);
  });

  testWidgets('holds hidden and returning shelf, then accepts restored smaller navigation insets', (tester) async {
    Map<String, Object?> response = geometry(portrait, normal);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(DisplayCutoutService.channel, (_) async => response);
    await show(tester, hold: false);
    await show(tester, hold: true, insets: EdgeInsets.zero);
    expect(tester.getTopLeft(find.byKey(content)).dy, 24);
    await show(tester, hold: false, insets: EdgeInsets.zero);
    expect(tester.getTopLeft(find.byKey(content)).dy, 24);
    response = geometry(portrait, smaller, visible: true);
    await show(tester, hold: false, insets: smaller);
    expect(tester.getTopLeft(find.byKey(content)).dy, 20);
    await show(tester, hold: false, insets: const EdgeInsets.only(top: 16));
    expect(tester.getTopLeft(find.byKey(content)).dy, 16);
  });

  testWidgets('new size and DPR use native normal insets and ignore stale replies', (tester) async {
    final requests = <Completer<Map<String, Object?>> >[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(DisplayCutoutService.channel, (_) {
        final request = Completer<Map<String, Object?>>();
        requests.add(request);
        return request.future;
      });
    await show(tester, hold: false);
    await show(tester, hold: true, insets: EdgeInsets.zero);
    const landscape = Size(800, 400);
    await show(tester, hold: true, insets: EdgeInsets.zero, size: landscape, dpr: 2);
    // The same logical size at another DPR must not accept the old reply.
    await show(tester, hold: true, insets: EdgeInsets.zero, size: landscape, dpr: 3);
    requests[1].complete(geometry(landscape, const EdgeInsets.only(top: 99)));
    await tester.pump();
    expect(tester.getTopLeft(find.byKey(content)).dy, 0);
    requests[2].complete(geometry(landscape, smaller));
    await tester.pump();
    expect(tester.getTopLeft(find.byKey(content)).dy, 20);
    // The first portrait request can finish after the widget is gone.
    await tester.pumpWidget(const SizedBox());
    requests[0].complete(geometry(portrait, normal));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('older host without native normal insets releases at its original snapshot', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(DisplayCutoutService.channel, (_) async => null);
    await show(tester, hold: false);
    await show(tester, hold: true, insets: EdgeInsets.zero);
    await show(tester, hold: false, insets: EdgeInsets.zero);
    expect(tester.getTopLeft(find.byKey(content)).dy, 24);
    await show(tester, hold: false);
    await show(tester, hold: false, insets: smaller);
    expect(tester.getTopLeft(find.byKey(content)).dy, 20);
  });
}
