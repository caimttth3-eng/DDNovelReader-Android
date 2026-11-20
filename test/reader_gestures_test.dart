import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/widgets/reader_gestures.dart';

void main() {
  Widget continuous(List<String> actions, List<int> steps, {bool sentenceMode = true, bool enabled = true,
    Duration delay = Duration.zero}) => MaterialApp(
    home: ReaderGestures(enabled: enabled, sentenceSwipesEnabled: sentenceMode,
      sentenceDragDelay: delay,
      onPreviousSentence: () => actions.add('old previous'), onNextSentence: () => actions.add('old next'),
      onPreviousPage: () => actions.add('previous page'), onNextPage: () => actions.add('next page'),
      onSentenceDragStart: () => actions.add('start'), onSentenceDragChange: steps.add,
      onSentenceDragEnd: (cancelled) => actions.add(cancelled ? 'cancel' : 'end'),
      child: const SizedBox.expand()));

  testWidgets('default delay is 200ms and a held vertical position activates at expiry without another move', (tester) async {
    final actions = <String>[], steps = <int>[];
    expect(ReaderGestures(child: const SizedBox(), onPreviousSentence: () {}, onNextSentence: () {},
      onPreviousPage: () {}, onNextPage: () {}).sentenceDragDelay, const Duration(milliseconds: 200));
    await tester.pumpWidget(continuous(actions, steps, delay: const Duration(milliseconds: 200)));
    final gesture = await tester.startGesture(const Offset(200, 200));
    await gesture.moveBy(const Offset(0, 100));
    await tester.pump(const Duration(milliseconds: 199));
    expect(actions, isEmpty); expect(steps, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(actions, ['start']); expect(steps, [2]);
    await gesture.up(); expect(actions, ['start', 'end']);
  });

  testWidgets('release, cancellation and horizontal motion before expiry never dispatch a sentence', (tester) async {
    final actions = <String>[], steps = <int>[];
    await tester.pumpWidget(continuous(actions, steps, delay: const Duration(milliseconds: 200)));
    var gesture = await tester.startGesture(const Offset(200, 200));
    await gesture.moveBy(const Offset(0, 100)); await gesture.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(actions, isEmpty); expect(steps, isEmpty);
    gesture = await tester.startGesture(const Offset(200, 200));
    await gesture.moveBy(const Offset(0, 100)); await gesture.cancel();
    await tester.pump(const Duration(milliseconds: 300)); expect(actions, isEmpty);
    gesture = await tester.startGesture(const Offset(200, 200));
    await gesture.moveBy(const Offset(-100, 0)); await tester.pump(const Duration(milliseconds: 300));
    await gesture.up(); expect(actions, ['next page']); expect(steps, isEmpty);
  });

  testWidgets('a tiny held wobble does not activate and background invalidates a pending deadline', (tester) async {
    final actions = <String>[], steps = <int>[];
    await tester.pumpWidget(continuous(actions, steps, delay: const Duration(milliseconds: 200)));
    var gesture = await tester.startGesture(const Offset(200, 200));
    await gesture.moveBy(const Offset(0, 3)); await tester.pump(const Duration(milliseconds: 300));
    expect(actions, isEmpty); await gesture.up();
    gesture = await tester.startGesture(const Offset(200, 200));
    await gesture.moveBy(const Offset(0, 100));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(milliseconds: 300));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await gesture.up(); expect(actions, isEmpty); expect(steps, isEmpty);
  });

  testWidgets('changing the delay cancels the old pointer deadline and uses the new value next time', (tester) async {
    final actions = <String>[], steps = <int>[];
    await tester.pumpWidget(continuous(actions, steps, delay: const Duration(milliseconds: 200)));
    var gesture = await tester.startGesture(const Offset(200, 200));
    await gesture.moveBy(const Offset(0, 100)); await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(continuous(actions, steps, delay: const Duration(milliseconds: 500)));
    await tester.pump(const Duration(milliseconds: 500)); await gesture.up();
    expect(actions, isEmpty); expect(steps, isEmpty);
    gesture = await tester.startGesture(const Offset(200, 200));
    await gesture.moveBy(const Offset(0, 100)); await tester.pump(const Duration(milliseconds: 499));
    expect(actions, isEmpty);
    await tester.pump(const Duration(milliseconds: 1)); expect(actions, ['start']);
    await gesture.up(); expect(actions, ['start', 'end']);
  });

  testWidgets('direct vertical dragging previews multiple sentences and reverses from the original touch', (tester) async {
    final actions = <String>[], steps = <int>[];
    await tester.pumpWidget(continuous(actions, steps));
    final gesture = await tester.startGesture(const Offset(200, 200));
    await gesture.moveBy(const Offset(0, 25));
    await tester.pump();
    expect(actions, ['start'], reason: 'No long-press delay is required');
    await gesture.moveBy(const Offset(0, 85));
    await gesture.moveBy(const Offset(0, -20));
    await gesture.moveBy(const Offset(0, -150));
    expect(steps, [2, 1, -1]);
    await gesture.up();
    expect(actions, ['start', 'end'], reason: 'Release must not trigger a second legacy swipe');
  });

  testWidgets('vertical cancellation and lifecycle changes end a preview exactly once', (tester) async {
    final actions = <String>[], steps = <int>[];
    await tester.pumpWidget(continuous(actions, steps));
    var gesture = await tester.startGesture(const Offset(200, 200));
    await gesture.moveBy(const Offset(0, 80));
    await gesture.cancel();
    expect(actions, ['start', 'cancel']);
    actions.clear();
    gesture = await tester.startGesture(const Offset(200, 200));
    await gesture.moveBy(const Offset(0, 80));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await gesture.up();
    expect(actions, ['start', 'cancel']);
  });

  testWidgets('the first accepted axis stays locked for the whole drag', (tester) async {
    final actions = <String>[], steps = <int>[];
    await tester.pumpWidget(continuous(actions, steps));
    var gesture = await tester.startGesture(const Offset(200, 200));
    await gesture.moveBy(const Offset(70, 0));
    await gesture.moveBy(const Offset(0, 180));
    await gesture.up();
    expect(actions, ['previous page']);
    expect(steps, isEmpty);
    actions.clear();
    gesture = await tester.startGesture(const Offset(200, 200));
    await gesture.moveBy(const Offset(0, -70));
    await gesture.moveBy(const Offset(180, 0));
    await gesture.up();
    expect(actions, ['start', 'end']);
    expect(steps, [-1]);
  });

  testWidgets('disabling continuous gestures cancels a preview and ordinary reading never starts one', (tester) async {
    final actions = <String>[], steps = <int>[];
    await tester.pumpWidget(continuous(actions, steps));
    final gesture = await tester.startGesture(const Offset(200, 200));
    await gesture.moveBy(const Offset(0, 80));
    await tester.pumpWidget(continuous(actions, steps, sentenceMode: false));
    await tester.pump();
    await gesture.up();
    expect(actions, ['start', 'cancel']);
    actions.clear(); steps.clear();
    await tester.drag(find.byType(ReaderGestures), const Offset(0, -100));
    expect(actions, isEmpty);
    expect(steps, isEmpty);
  });

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

  testWidgets('normal reading supports horizontal pages and vertical scrolling', (tester) async {
    final actions = <String>[];
    final controller = ScrollController();
    await tester.pumpWidget(MaterialApp(home: ReaderGestures(
      sentenceSwipesEnabled: false,
      onPreviousSentence: () => actions.add('sentence'), onNextSentence: () => actions.add('sentence'),
      onPreviousPage: () => actions.add('previous'), onNextPage: () => actions.add('next'),
      child: ListView.builder(controller: controller, itemCount: 100,
        itemBuilder: (_, i) => SizedBox(height: 80, child: Text('$i'))),
    )));
    await tester.drag(find.byType(ListView), const Offset(-200, 0));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(200, 0));
    await tester.pumpAndSettle();
    expect(actions, ['next', 'previous']);
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(actions, ['next', 'previous']);
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
        sentenceDragDelay: Duration.zero,
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
