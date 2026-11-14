import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/i18n.dart';
import 'package:duoduo_langdu/services/speech_breaks.dart';
import 'package:duoduo_langdu/widgets/speech_pause_editor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => AppI18n.current = AppLang.zhHans);

  testWidgets('single apply action stays in the expandable header and fixed columns survive narrow-screen decimal edits', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 844);
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final initial = const SpeechPauseSettings().withPause(SpeechPauseKind.comma, 400);
    final applied = <SpeechPauseSettings>[];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(
      child: Padding(padding: const EdgeInsets.all(16), child: SpeechPauseEditor(
        initialPauses: initial, onApply: applied.add))))));
    await tester.pumpAndSettle();
    final current = find.byKey(const ValueKey('pause-apply'));
    expect(current, findsNothing);
    expect(find.byKey(const ValueKey('pause-slider-comma')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('pause-expand-label'))); await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(current).onPressed, isNull);
    expect(find.byKey(const ValueKey('pause-apply-global')), findsNothing);
    expect(find.byKey(const ValueKey('pause-reset-global')), findsNothing);
    expect(find.byType(FilledButton), findsOneWidget);
    final title = tester.getRect(find.byKey(const ValueKey('pause-expand-label')));
    final button = tester.getRect(current);
    expect(button.left, greaterThan(title.right));
    expect(button.center.dy, closeTo(title.center.dy, 1));
    expect(button.height, greaterThanOrEqualTo(48));
    expect(find.descendant(of: current, matching: find.text(T('applyPauseSettings'))), findsOneWidget);
    final comma = find.byKey(const ValueKey('pause-slider-comma'));
    final semicolon = find.byKey(const ValueKey('pause-slider-semicolon'));
    final before = tester.getRect(comma), next = tester.getRect(semicolon);
    expect(before.left, next.left); expect(before.right, next.right);
    expect(tester.getRect(find.byKey(const ValueKey('pause-comma'))).right, lessThanOrEqualTo(before.left));

    await tester.tap(find.byKey(const ValueKey('pause-comma'))); await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('pause-number-comma'));
    expect(tester.widget<TextFormField>(input).controller!.text, '0.40');
    await tester.enterText(input, '3.50');
    await tester.tap(find.text(T('ok'))); await tester.pumpAndSettle();
    expect(input, findsOneWidget, reason: 'The existing 0.00–3.00 second range remains enforced');
    await tester.enterText(input, '.25');
    await tester.tap(find.text(T('ok'))); await tester.pumpAndSettle();
    expect(tester.widget<Slider>(comma).value, 250);
    expect(tester.getRect(comma).left, before.left); expect(tester.getRect(comma).right, before.right);
    expect(tester.getRect(semicolon).left, before.left); expect(tester.getRect(semicolon).right, before.right);
    expect(tester.widget<FilledButton>(current).onPressed, isNotNull);
    expect(applied, isEmpty, reason: 'Editing a draft cannot persist it');

    await tester.tap(find.byKey(const ValueKey('pause-expand-label'))); await tester.pumpAndSettle();
    expect(current, findsNothing); expect(comma, findsNothing); expect(applied, isEmpty);
    await tester.tap(find.byKey(const ValueKey('pause-expand-label'))); await tester.pumpAndSettle();
    expect(tester.widget<Slider>(comma).value, 250, reason: 'Collapsing preserves the local draft');
    await tester.tap(current); await tester.pumpAndSettle();
    expect(applied, hasLength(1));
    expect(applied.single.millisecondsFor(SpeechPauseKind.comma), 250);
    expect(initial.millisecondsFor(SpeechPauseKind.comma), 400);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing the containing sheet discards unapplied pause drafts', (tester) async {
    final applied = <SpeechPauseSettings>[];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) => TextButton(
      key: const ValueKey('open-pause-sheet'), child: const Text('open'), onPressed: () => showModalBottomSheet<void>(
        context: context, isScrollControlled: true, builder: (_) => SafeArea(child: SingleChildScrollView(
          child: SpeechPauseEditor(initialPauses: const SpeechPauseSettings(),
            initiallyExpanded: true, onApply: applied.add)))))))));
    Future<void> open() async {
      await tester.tap(find.byKey(const ValueKey('open-pause-sheet'))); await tester.pumpAndSettle();
    }
    await open();
    await tester.tap(find.byKey(const ValueKey('pause-comma'))); await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('pause-number-comma')), '0.55');
    await tester.tap(find.text(T('ok'))); await tester.pumpAndSettle();
    expect(tester.widget<Slider>(find.byKey(const ValueKey('pause-slider-comma'))).value, 550);
    Navigator.of(tester.element(find.byType(SpeechPauseEditor))).pop(); await tester.pumpAndSettle();
    expect(applied, isEmpty);
    await open();
    expect(tester.widget<Slider>(find.byKey(const ValueKey('pause-slider-comma'))).value, 0);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('pause-apply'))).onPressed, isNull);
    expect(find.byKey(const ValueKey('pause-reset-global')), findsNothing);
    expect(applied, isEmpty); expect(tester.takeException(), isNull);
  });
}
