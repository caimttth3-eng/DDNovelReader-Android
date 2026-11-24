import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/services/reader_line_layout.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final font = File('${Platform.environment['SystemRoot']}\\Fonts\\msyh.ttc');

  setUpAll(() async {
    if (!font.existsSync()) return;
    // Existing Windows font data is registered only in this test process.
    await (FontLoader('ReaderLineLayoutCjk')
      ..addFont(font.readAsBytes().then((bytes) => ByteData.sublistView(bytes)))).load();
  });

  testWidgets('complete original spans match rendered CJK, bidi, mixed fonts, indentation and title rows', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 2400);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    const base = TextStyle(fontFamily: 'ReaderLineLayoutCjk', fontSize: 24,
      height: 1.6, letterSpacing: 0, fontWeight: FontWeight.normal);
    final inputs = [
      ReaderParagraphShapeInput(itemIndex: 7, isTitle: true, textDirection: TextDirection.ltr,
        locale: const ui.Locale('zh', 'CN'), textAlign: TextAlign.center,
        paddingBefore: 16, paddingAfter: 16,
        textSpan: const TextSpan(text: '第一章 山间来客', style: TextStyle(
          fontFamily: 'ReaderLineLayoutCjk', fontSize: 30, height: 1.6,
          letterSpacing: 0, fontWeight: FontWeight.bold))),
      ReaderParagraphShapeInput(itemIndex: 8, textDirection: TextDirection.ltr,
        locale: const ui.Locale('zh', 'CN'), indentWidth: 48,
        textSpan: const TextSpan(style: base, children: [
          WidgetSpan(alignment: ui.PlaceholderAlignment.middle, child: SizedBox(width: 48, height: 1)),
          TextSpan(text: '山间小路通向村庄，A long English word preserves its original wrapping. '),
          TextSpan(text: '较大字形', style: TextStyle(fontSize: 32)),
          TextSpan(text: ' بعدها يعود المسافر إلى الطريق。\n另一行继续向前，不重新截取子串排版。'),
        ])),
      ReaderParagraphShapeInput(itemIndex: 9, textDirection: TextDirection.rtl,
        locale: const ui.Locale('ar'), textScaler: TextScaler.linear(1.25),
        maxWidth: 260, paddingBefore: 6,
        textSpan: const TextSpan(style: base,
          text: 'مرحبا بالعالم English 山川湖海。 الأصل الكامل يبقى كما هو。')),
    ];
    const columnKey = ValueKey('shape-column');
    await tester.pumpWidget(MaterialApp(home: Align(alignment: Alignment.topLeft,
      child: SizedBox(width: 320, child: Column(key: columnKey,
        mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
        children: [for (final input in inputs) Padding(
          padding: EdgeInsets.only(top: input.paddingBefore, bottom: input.paddingAfter),
          child: SizedBox(width: input.maxWidth ?? 320, child: Text.rich(input.textSpan,
            key: ValueKey('render-${input.itemIndex}'), textAlign: input.textAlign,
            textDirection: input.textDirection, textScaler: input.textScaler, locale: input.locale,
            strutStyle: input.strutStyle, textHeightBehavior: input.textHeightBehavior,
            textWidthBasis: input.textWidthBasis))),
        ])))));
    await tester.pumpAndSettle();
    final table = await ReaderLineLayout.measure(inputs, maxWidth: 320,
      yieldBudget: const Duration(days: 1));
    expect(table, isNotNull);
    final origin = tester.getTopLeft(find.byKey(columnKey)).dy;
    final expected = <({String key, double top, double bottom, bool title})>[];
    for (final input in inputs) {
      final render = tester.renderObject<RenderParagraph>(find.byKey(ValueKey('render-${input.itemIndex}')));
      final top = render.localToGlobal(Offset.zero).dy - origin;
      final rows = <int, Rect>{};
      // Independent rendered geometry oracle: never shape page substrings.
      for (final box in render.getBoxesForSelection(TextSelection(baseOffset: 0,
        extentOffset: render.text.toPlainText().length), boxHeightStyle: ui.BoxHeightStyle.tight)) {
        final rect = box.toRect();
        if (rect.width < .01 || rect.height < 2) continue;
        final left = render.getPositionForOffset(Offset(-1, rect.center.dy)).offset;
        final right = render.getPositionForOffset(Offset(render.size.width + 1, rect.center.dy)).offset;
        final offset = left < right ? left : right;
        rows.update(offset, (previous) => previous.expandToInclude(rect), ifAbsent: () => rect);
      }
      final entries = rows.entries.toList()..sort((a, b) => a.value.top.compareTo(b.value.top));
      for (final row in entries) {
        expected.add((key: '${input.itemIndex}/${row.key}', top: top + row.value.top,
          bottom: top + row.value.bottom, title: input.isTitle));
      }
    }
    expect(table!.lines.length, greaterThan(5));
    expect(table.lines.map((line) => line.key), orderedEquals(expected.map((row) => row.key)));
    for (var i = 0; i < expected.length; i++) {
      expect(table.lines[i].top, closeTo(expected[i].top, .01));
      expect(table.lines[i].bottom, closeTo(expected[i].bottom, .01));
      expect(table.lines[i].isTitle, expected[i].title);
      expect(table.lines[i].bottom, greaterThan(table.lines[i].top + 1),
        reason: 'Indentation placeholders must not become body rows');
    }
    expect(table.totalHeight, closeTo(tester.getSize(find.byKey(columnKey)).height, .01));
    expect(() => table.lines.add(table.lines.first), throwsUnsupportedError);
    expect(tester.takeException(), isNull);
  }, skip: !font.existsSync());

  test('padding and empty items contribute to height without inventing glyph rows', () async {
    const empty = TextSpan(text: '', style: TextStyle(fontSize: 20, height: 1.4));
    final painter = TextPainter(text: empty, textDirection: TextDirection.ltr)
      ..layout(minWidth: 200, maxWidth: 200);
    final expected = painter.height + 11;
    painter.dispose();
    final result = await ReaderLineLayout.measure([
      ReaderParagraphShapeInput(itemIndex: 2, textSpan: empty, textDirection: TextDirection.ltr,
        paddingBefore: 4, paddingAfter: 7),
    ], maxWidth: 200);
    expect(result!.lines, isEmpty);
    expect(result.totalHeight, closeTo(expected, .01));
  });

  test('early cancellation does no shaping or yielding and publishes no table', () async {
    var yields = 0;
    final result = await ReaderLineLayout.measure([_input(1)], maxWidth: 200,
      isCurrent: () => false, onYield: () async { yields++; });
    expect(result, isNull);
    expect(yields, 0);
  });

  test('cancellation after a cooperative yield discards the partially measured chapter', () async {
    var current = true;
    var yields = 0;
    final result = await ReaderLineLayout.measure([_input(1), _input(2)], maxWidth: 200,
      yieldBudget: Duration.zero, isCurrent: () => current,
      onYield: () async { yields++; current = false; });
    expect(result, isNull);
    expect(yields, 1);
    // A later independent measurement remains valid after cancellation/disposal.
    final retry = await ReaderLineLayout.measure([_input(3)], maxWidth: 200);
    expect(retry!.lines, isNotEmpty);
    expect(retry.lines.every((line) => line.itemIndex == 3), isTrue);
  });

  test('default cooperative yielding completes without a scheduled Flutter frame', () async {
    final result = await ReaderLineLayout.measure([_input(1), _input(2)], maxWidth: 200,
      yieldBudget: Duration.zero);
    expect(result!.lines.map((line) => line.itemIndex).toSet(), {1, 2});
  });

  test('invalid widths and duplicate item identities are rejected', () async {
    expect(ReaderLineLayout.measure([_input(1)], maxWidth: 0), throwsArgumentError);
    expect(ReaderLineLayout.measure([_input(1)], maxWidth: double.infinity), throwsArgumentError);
    expect(ReaderLineLayout.measure([_input(1), _input(1)], maxWidth: 200), throwsArgumentError);
  });
}

ReaderParagraphShapeInput _input(int index) => ReaderParagraphShapeInput(itemIndex: index,
  textDirection: TextDirection.ltr, textSpan: const TextSpan(text: 'alpha beta gamma delta',
    style: TextStyle(fontSize: 20, height: 1.6, letterSpacing: 0)));
