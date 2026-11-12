import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/widgets/reader_gestures.dart';

void main() {
  testWidgets('normal reading leaves swipes to its scrollable child', (tester) async {
    var navigations = 0;
    final controller = ScrollController();
    await tester.pumpWidget(MaterialApp(home: ReaderGestures(
      enabled: false,
      onPreviousSentence: () => navigations++, onNextSentence: () => navigations++,
      onPreviousPage: () => navigations++, onNextPage: () => navigations++,
      child: ListView.builder(controller: controller, itemCount: 100,
        itemBuilder: (_, i) => SizedBox(height: 80, child: Text('$i'))),
    )));
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(navigations, 0);
    expect(controller.offset, greaterThan(0));
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('long presses and child buttons remain accessible', (tester) async {
    var presses = 0;
    var taps = 0;
    var parentTaps = 0;
    await tester.pumpWidget(MaterialApp(home: ReaderGestures(
      onPreviousSentence: () {}, onNextSentence: () {},
      onPreviousPage: () {}, onNextPage: () {},
      onTapUp: (_) => parentTaps++,
      child: Center(child: GestureDetector(onLongPress: () => presses++,
        child: TextButton(onPressed: () => taps++, child: const Text('sentence')))),
    )));
    await tester.longPress(find.text('sentence'));
    expect(presses, 1);
    expect(parentTaps, 0);
    await tester.tap(find.text('sentence'));
    expect(taps, 1);
    expect(parentTaps, 0);
  });

  testWidgets('swipes dispatch exactly one action on the dominant axis',
      (tester) async {
    final actions = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: ReaderGestures(
        onPreviousSentence: () => actions.add('previous sentence'),
        onNextSentence: () => actions.add('next sentence'),
        onPreviousPage: () => actions.add('previous page'),
        onNextPage: () => actions.add('next page'),
        onTapUp: (_) => actions.add('tap'),
        child: const SizedBox.expand(),
      ),
    ));
    final area = find.byType(ReaderGestures);
    for (final delta in [
      const Offset(0, -160),
      const Offset(0, 160),
      const Offset(-160, 0),
      const Offset(160, 0),
      const Offset(-180, 70),
    ]) {
      await tester.drag(area, delta);
      await tester.pump();
    }
    expect(actions, [
      'previous sentence', 'next sentence', 'next page', 'previous page',
      'next page',
    ]);

    actions.clear();
    await tester.drag(area, const Offset(0, 30));
    expect(actions, isEmpty);
    final gesture = await tester.startGesture(tester.getCenter(area));
    await gesture.moveBy(const Offset(0, 160));
    await gesture.cancel();
    expect(actions, isEmpty);
    await tester.tap(area);
    expect(actions, ['tap']);
  });
}
