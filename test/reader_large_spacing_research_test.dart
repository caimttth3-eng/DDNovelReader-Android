import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/services/reader_page_planner.dart';

// Numerical research only: these rows model already shaped text. The solver
// must never change L/S to improve the reported capacity or margin spread.
const _font = 39.0;
const _band = _font / 2;
const _lineHeights = [1.2, 1.4, 1.6, 1.8, 2.0, 2.2, 2.4];
const _spacings = [0.25, 0.5, 0.75, 1.0, 1.5];
const _heights = [640.0, 760.0, 880.0];
typedef _Geometry = ({List<double> tops, List<double> bottoms});

_Geometry _geometry(List<int> paragraphLengths, double lineHeight, double spacing) {
  final tops = <double>[], bottoms = <double>[];
  var y = 0.0;
  for (var paragraph = 0; paragraph < paragraphLengths.length; paragraph++) {
    if (paragraph > 0) y += _font * spacing;
    for (var row = 0; row < paragraphLengths[paragraph]; row++) {
      tops.add(y); bottoms.add(y + _font); y += _font * lineHeight;
    }
  }
  return (tops: tops, bottoms: bottoms);
}

List<int> _repeatToRows(List<int> pattern, int rows) {
  final result = <int>[];
  var used = 0, index = 0;
  while (used < rows) {
    final count = math.min(pattern[index++ % pattern.length], rows - used);
    result.add(count); used += count;
  }
  return result;
}

List<(int, int)> _cuts(Iterable<ReaderPlannedPage> pages) =>
  [for (final page in pages) (page.first, page.end)];

void _verify(_Geometry geometry, ReaderPagePlan plan, double height) {
  var next = 0;
  for (final page in plan.pages) {
    expect(page.first, next); expect(page.end, greaterThan(page.first));
    expect(page.used, closeTo(geometry.bottoms[page.end - 1] - geometry.tops[page.first], 1e-7));
    expect(page.used, lessThanOrEqualTo(height + 1e-7));
    next = page.end;
  }
  expect(next, geometry.tops.length);
  expect(plan.spread, lessThanOrEqualTo(_band + 1e-6));
}

void main() {
  test('large fixed spacing matrix reports capacity rather than treating feasibility as usability', () {
    final patterns = <String, List<int>>{
      'long': [240],
      'one-line': List.filled(240, 1),
      'mixed': _repeatToRows([1, 2, 7, 1, 4, 11], 240),
      'density-zones': [80, ...List.filled(80, 1), 80],
    };
    for (final lineHeight in _lineHeights) {
      for (final spacing in _spacings) {
        var worstInflation = 0.0, minimumFill = 1.0, minimumAverageFill = 1.0;
        var minimumRows = 1 << 30, minimumAverageRows = double.infinity;
        var maximumSpread = 0.0, sparseCases = 0;
        String? worstCase;
        for (final height in _heights) {
          for (final pattern in patterns.entries) {
            final geometry = _geometry(pattern.value, lineHeight, spacing);
            final planner = ReaderPagePlanner(geometry.tops, geometry.bottoms,
              height: height, exemptLastPage: true);
            final greedy = planner.greedy()!;
            final plan = planner.solve(_band)!;
            _verify(geometry, plan, height);
            expect(plan.pages.length, greaterThanOrEqualTo(greedy.length));
            final measured = plan.measured;
            expect(measured, isNotEmpty);
            final fill = measured.map((page) => page.used / height).reduce(math.min);
            final averageFill = measured.fold<double>(0, (sum, page) => sum + page.used / height) / measured.length;
            final rows = measured.map((page) => page.rows).reduce(math.min);
            final averageRows = measured.fold<int>(0, (sum, page) => sum + page.rows) / measured.length;
            final inflation = plan.pages.length / greedy.length;
            if (inflation > worstInflation) {
              worstInflation = inflation; worstCase = '${pattern.key}/H$height';
            }
            minimumFill = math.min(minimumFill, fill);
            minimumAverageFill = math.min(minimumAverageFill, averageFill);
            minimumRows = math.min(minimumRows, rows);
            minimumAverageRows = math.min(minimumAverageRows, averageRows);
            maximumSpread = math.max(maximumSpread, plan.spread);
            // A proposed policy diagnostic, not a hidden solver constraint.
            // Research must reveal bad plans instead of making them pass as
            // usable merely because all one-row pages have equal margins.
            if (inflation > 1.1 || averageFill < 0.8 || rows < 2) sparseCases++;
          }
        }
        // Root consumes this compact log; no screenshots or benchmark files.
        // ignore: avoid_print
        print('LARGE_SPACING ${jsonEncode({'F': _font, 'L/F': lineHeight, 'S/F': spacing,
          'cases': _heights.length * patterns.length, 'maxJointOverGreedy': worstInflation,
          'worstCase': worstCase, 'minFill': minimumFill, 'minAverageFill': minimumAverageFill,
          'minRows': minimumRows, 'minAverageRows': minimumAverageRows,
          'maxSpread': maximumSpread, 'capacityPolicyFailures': sparseCases})}');
      }
    }
  });

  test('strict half-font band sacrifices capacity for incompatible paragraph densities', () {
    // The two zones cannot share a page. Their optimal greedy capacities are
    // 16 long-paragraph rows (R=19) and 7 one-line paragraphs (R=89.2).
    // No shared 19.5px band permits those capacities; even 14 long rows have
    // R=112.6, still 23.4px from 7 short paragraphs. Compatible capacities
    // fall to 12 and 6 rows. Exact divisibility removes terminal-tail effects.
    final geometry = _geometry([192, ...List.filled(192, 1)], 1.2, 1.5);
    final planner = ReaderPagePlanner(geometry.tops, geometry.bottoms,
      height: 760, forcedBreaks: [192], exemptLastPage: false,
      exemptSegmentEdges: false);
    final greedy = planner.greedy()!, plan = planner.solve(_band)!;
    _verify(geometry, plan, 760);
    expect(greedy.length, 40);
    expect(plan.pages.length, 48);
    expect(plan.pages.length / greedy.length, 1.2);
    expect(plan.pages.where((page) => page.end <= 192).map((page) => page.rows).toSet(), {12});
    expect(plan.pages.where((page) => page.first >= 192).map((page) => page.rows).toSet(), {6});
    expect(plan.measured.map((page) => page.used / 760).reduce(math.min), lessThan(0.73));
    expect(plan.spread, closeTo(11.7, 1e-6));
  });

  test('same geometry is deterministic but current-entry fixed cuts change the canonical partition', () {
    const geometry = (tops: [0.0, 10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0],
      bottoms: [8.0, 18.0, 28.0, 38.0, 48.0, 58.0, 68.0, 78.0]);
    ReaderPagePlan fresh() => ReaderPagePlanner(geometry.tops, geometry.bottoms, height: 35).solve(5)!;
    final before = fresh();
    final fixedEntry = ReaderPagePlanner(geometry.tops, geometry.bottoms, height: 35,
      forcedBreaks: [2], exemptSegmentEdges: false,
      fixedPages: [(first: 0, end: 2, bandExempt: true)]).solve(5)!;
    expect(_cuts(before.pages), [(0, 3), (3, 6), (6, 8)]);
    expect(_cuts(fixedEntry.pages), [(0, 2), (2, 5), (5, 8)]);
    expect(_cuts(fresh().pages), _cuts(before.pages),
      reason: 'Returning to a geometry must restore its canonical request, not inject the other layout entry cut');
  });

  test('cropping an identical row table changes page phase when the window becomes the planning origin', () {
    final geometry = _geometry([48], 1.6, 0.25);
    ReaderPagePlan window(int start) {
      final origin = geometry.tops[start];
      return ReaderPagePlanner(
        [for (final top in geometry.tops.skip(start)) top - origin],
        [for (final bottom in geometry.bottoms.skip(start)) bottom - origin],
        height: 350).solve(_band)!;
    }
    final whole = window(0), cropped = window(1);
    final fullEnds = whole.pages.map((page) => page.end).toSet();
    final cropEnds = cropped.pages.map((page) => page.end + 1).toSet();
    expect(fullEnds.intersection(cropEnds).length, lessThan(math.min(fullEnds.length, cropEnds.length)),
      reason: 'An arbitrary measurement window is not a stable pagination identity even with unchanged F/L/S');
  });
}
