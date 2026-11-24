import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/services/reader_line_layout.dart';
import 'package:duoduo_langdu/services/reader_page_planner.dart';
import 'package:duoduo_langdu/services/reader_typography.dart';

// Research only: this checks measured whole paragraphs, without enabling a
// new production policy or claiming a guarantee for arbitrary book structure.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final font = File('${Platform.environment['SystemRoot']}\\Fonts\\msyh.ttc');
  setUpAll(() async {
    if (!font.existsSync()) return;
    await (FontLoader('SpacingRatioResearchCjk')
      ..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
  });

  test('native visible quarter-font spacing supports full 8 and 7 row pages in both directions', () async {
    const size = 64.0, pitch = 96.0, spacing = 16.0, height = 760.0;
    final lengths = <int>[for (var period = 0; period < 8; period++) ...[8, 1, 1, 1, 1, 1, 1, 1]];
    final layout = await _shape(lengths, size: size, lineHeight: pitch / size, spacing: spacing);
    final pages = _pack(layout, height);
    expect(pages.map((page) => page.rows), orderedEquals([for (var i = 0; i < 8; i++) ...[8, 7]]));
    _check(layout, pages, height: height, fontSize: size);
    final reverse = _mirrored(layout);
    final reversePages = _pack(reverse, height);
    _check(reverse, reversePages, height: height, fontSize: size);
    final count = layout.lines.length;
    expect(reversePages.reversed.map((page) => (count - page.end, count - page.first)),
      orderedEquals(pages.map((page) => (page.first, page.end))));
    print('RATIO_NATIVE variableRows F=$size P=$pitch S=$spacing H=$height '
      'pages=${pages.length} rows=${pages.map((page) => page.rows).toSet()} '
      'R=${pages.map((page) => page.remaining).reduce(math.min)}..${pages.map((page) => page.remaining).reduce(math.max)}');
  }, skip: !font.existsSync());

  test('native three or four line paragraphs retain visible spacing at every source-row entry', () async {
    const size = 38.0, pitch = 56.0, spacing = 9.5, height = 764.0;
    final lengths = List.generate(80, (index) => ((index * 13 + index ~/ 3) % 5 < 2) ? 3 : 4);
    final layout = await _shape(lengths, size: size, lineHeight: pitch / size, spacing: spacing);
    for (final table in [layout, _mirrored(layout)]) {
      for (var first = 0; first + 13 <= table.lines.length; first++) {
        final suffix = ReaderMeasuredLayout(lines: table.lines.sublist(first), totalHeight: table.totalHeight);
        final page = _pack(suffix, height).first;
        expect(page.rows, 13);
        _check(suffix, [page], height: height, fontSize: size);
      }
    }
    final pages = _pack(layout, height);
    _check(layout, pages.take(pages.length - 1).toList(), height: height, fontSize: size);
    final ordinary = pages.where((page) => page.rows == 13).toList();
    print('RATIO_NATIVE structuralFamily F=$size P=$pitch S=$spacing H=$height '
      'testedEntries=${2 * (layout.lines.length - 12)} '
      'R=${ordinary.map((page) => page.remaining).reduce(math.min)}..${ordinary.map((page) => page.remaining).reduce(math.max)}');
  }, skip: !font.existsSync());
}

Future<ReaderMeasuredLayout> _shape(List<int> rowCounts, {required double size,
  required double lineHeight, required double spacing}) async {
  const width = 358.0;
  final perLine = (width / size).floor();
  final strut = StrutStyle(fontSize: size, fontFamily: 'SpacingRatioResearchCjk',
    height: lineHeight, fontWeight: FontWeight.normal, forceStrutHeight: true);
  final layout = (await ReaderLineLayout.measure([
    for (var index = 0; index < rowCounts.length; index++) ReaderParagraphShapeInput(
      itemIndex: index, textDirection: TextDirection.ltr, strutStyle: strut,
      paddingBefore: index == 0 ? 0 : spacing,
      textSpan: TextSpan(text: ReaderTypography.layout(List.filled(rowCounts[index] * perLine, '田').join()),
        style: TextStyle(fontFamily: 'SpacingRatioResearchCjk', fontSize: size,
          height: lineHeight, fontWeight: FontWeight.normal))),
  ], maxWidth: width, yieldBudget: const Duration(days: 1)))!;
  for (var index = 0; index < rowCounts.length; index++) {
    expect(layout.lines.where((row) => row.itemIndex == index), hasLength(rowCounts[index]));
  }
  return layout;
}

List<ReaderPlannedPage> _pack(ReaderMeasuredLayout layout, double height) => ReaderPagePlanner(
  layout.lines.map((row) => row.top).toList(), layout.lines.map((row) => row.bottom).toList(),
  height: height).greedy()!;

ReaderMeasuredLayout _mirrored(ReaderMeasuredLayout layout) => ReaderMeasuredLayout(
  totalHeight: layout.totalHeight, lines: [for (final row in layout.lines.reversed) ReaderMeasuredLine(
    itemIndex: row.itemIndex, layoutOffset: row.layoutOffset, isTitle: false,
    top: layout.totalHeight - row.bottom, bottom: layout.totalHeight - row.top)]);

void _check(ReaderMeasuredLayout layout, List<ReaderPlannedPage> pages,
  {required double height, required double fontSize}) {
  final remainders = <double>[];
  for (final page in pages) {
    expect(page.used, closeTo(layout.lines[page.end - 1].bottom - layout.lines[page.first].top, .001));
    expect(page.used, lessThanOrEqualTo(height + .001));
    expect(page.remaining, lessThan(fontSize));
    if (page.end < layout.lines.length) {
      expect(layout.lines[page.end].bottom - layout.lines[page.first].top, greaterThan(height));
    }
    remainders.add(page.remaining);
  }
  expect(remainders.reduce(math.max) - remainders.reduce(math.min), lessThanOrEqualTo(fontSize / 2 + .001));
}
