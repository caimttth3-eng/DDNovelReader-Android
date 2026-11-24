import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/services/reader_page_planner.dart';
import 'package:duoduo_langdu/services/reader_spacing_policy.dart';

List<(int, int, bool)> _cuts(ReaderPagePlan plan) =>
  [for (final page in plan.pages) (page.first, page.end, page.bandExempt)];

void main() {
  test('1000 random paragraph patterns obey the policy certificate in both directions from arbitrary boundaries', () {
    final random = Random(7204);
    for (var example = 0; example < 1000; example++) {
      final font = 14.0 + random.nextInt(51);
      final pitch = font * (12 + random.nextInt(13)) / 10;
      final topMin = -font * 0.92, topMax = -font * 0.88;
      final bottomMin = font * 0.23, bottomMax = font * 0.27;
      final rowCount = 3 + random.nextInt(28);
      final glyphMax = bottomMax - topMin, glyphMin = bottomMin - topMax;
      final freeBand = font / 2 - .5 - (glyphMax - glyphMin) - (rowCount - 1) * .002;
      final height = (rowCount - 1) * (pitch + .001) + glyphMax + freeBand / 2;
      final policy = ReaderSpacingPolicy.resolve(height: height, fontSize: font,
        baselinePitch: pitch, baselinePitchMin: pitch - .001, baselinePitchMax: pitch + .001,
        tightTopMin: topMin, tightTopMax: topMax,
        tightBottomMin: bottomMin, tightBottomMax: bottomMax, level: example % 4)!;
      final count = 1 + random.nextInt(160);
      final tops = <double>[], bottoms = <double>[];
      var baseline = 0.0;
      for (var row = 0; row < count; row++) {
        if (row > 0) baseline += pitch - .001 + random.nextDouble() * .002 +
          (random.nextBool() ? policy.spacing : 0);
        tops.add(baseline + topMin + random.nextDouble() * (topMax - topMin));
        bottoms.add(baseline + bottomMin + random.nextDouble() * (bottomMax - bottomMin));
      }
      for (final anchor in {0, count, random.nextInt(count + 1)}) {
        final plan = ReaderPagePlanner.fixedRows(tops, bottoms, rows: policy.rows,
          anchor: anchor, height: height, usedMin: policy.usedMin, usedMax: policy.usedMax)!;
        expect(plan.capacityFallback, isFalse);
        expect(plan.bandStart, height - policy.usedMax);
        expect(plan.bandEnd, height - policy.usedMin);
        expect(plan.bandStart, greaterThanOrEqualTo(-1e-8));
        expect(plan.bandEnd, lessThanOrEqualTo(font / 2 - .5 + 1e-8));
        expect(plan.bandEnd - plan.bandStart, lessThanOrEqualTo(policy.hardWidth + 1e-8));
        expect(plan.spread, lessThanOrEqualTo(policy.hardWidth + 2e-5));
        var next = 0;
        final boundaries = <int>{0};
        for (final page in plan.pages) {
          expect(page.first, next); expect(page.end, greaterThan(next));
          expect(page.used, closeTo(bottoms[page.end - 1] - tops[page.first], 1e-8));
          expect(page.used, lessThanOrEqualTo(height + 1e-5));
          if (page.bandExempt) {
            expect(page.rows, lessThan(policy.rows));
            expect(page.first == 0 || page.end == count, isTrue,
              reason: 'A short provisional fragment cannot masquerade as an ordinary interior page');
          } else {
            expect(page.rows, policy.rows);
            expect(page.used, inInclusiveRange(policy.usedMin - 1e-5, policy.usedMax + 1e-5));
          }
          next = page.end; boundaries.add(next);
        }
        expect(next, count); expect(boundaries, contains(anchor));
      }
    }
  });

  test('both anchor remainders create only provisional outer fragments', () {
    final tops = List<double>.generate(13, (row) => row * 10.0);
    final bottoms = [for (final top in tops) top + 8];
    final plan = ReaderPagePlanner.fixedRows(tops, bottoms, rows: 3, anchor: 5,
      height: 35, usedMin: 28, usedMax: 28)!;
    expect(_cuts(plan), [(0, 2, true), (2, 5, false), (5, 8, false), (8, 11, false), (11, 13, true)]);
    expect(plan.minRemaining, 7); expect(plan.maxRemaining, 7);
    expect(plan.bandStart, 7); expect(plan.bandEnd, 7);
    for (final anchor in [0, 6]) {
      final complete = ReaderPagePlanner.fixedRows(tops.sublist(0, 6), bottoms.sublist(0, 6),
        rows: 3, anchor: anchor, height: 35, usedMin: 28, usedMax: 28)!;
      expect(_cuts(complete), [(0, 3, false), (3, 6, false)],
        reason: 'A full first/last page never gains an exemption merely by touching a real book edge');
    }
  });

  test('backward grouping fills the page immediately before the anchor rather than a forward-prefix tail', () {
    final tops = List<double>.generate(11, (row) => row * 20.0);
    final bottoms = [for (final top in tops) top + 20];
    final plan = ReaderPagePlanner.fixedRows(tops, bottoms, rows: 5, anchor: 11,
      height: 100, usedMin: 100, usedMax: 100)!;
    expect(_cuts(plan), [(0, 1, true), (1, 6, false), (6, 11, false)]);
    expect(plan.pages.last.used, 100); expect(plan.pages.last.rows, 5);
  });

  test('a native full-page box outside the global certificate returns null without greedy fallback', () {
    ReaderPagePlan? plan(List<double> bottoms, {double height = 35, double low = 28, double high = 28}) =>
      ReaderPagePlanner.fixedRows([0, 10, 20], bottoms, rows: 3, anchor: 0,
        height: height, usedMin: low, usedMax: high);
    expect(plan([8, 18, 29]), isNull);
    expect(plan([8, 18, 27]), isNull);
    expect(plan([8, 18, 28.000005]), isNotNull);
    expect(plan([8, 18, 28.00002]), isNull);
    expect(plan([8, 18, 36], high: 36), isNull);
    expect(plan([8, 18, 28], low: 29, high: 28), isNull);
  });

  test('empty and short tables are explicit while malformed geometry is unsupported', () {
    ReaderPagePlan? plan(List<double> tops, List<double> bottoms,
      {int rows = 3, int anchor = 0, double height = 35, double low = 28, double high = 28}) =>
      ReaderPagePlanner.fixedRows(tops, bottoms, rows: rows, anchor: anchor,
        height: height, usedMin: low, usedMax: high);
    expect(plan([], [])!.pages, isEmpty);
    expect(_cuts(plan([0], [8])!), [(0, 1, true)]);
    expect(plan([0], []), isNull); expect(plan([0], [8], rows: 0), isNull);
    expect(plan([0], [8], rows: -2), isNull); expect(plan([0], [8], anchor: -1), isNull);
    expect(plan([0], [8], anchor: 2), isNull); expect(plan([0], [8], height: 0), isNull);
    expect(plan([0], [8], low: 0), isNull); expect(plan([0], [8], high: double.nan), isNull);
    expect(plan([double.infinity], [8]), isNull); expect(plan([0], [0]), isNull);
    expect(plan([0, -1], [8, 18]), isNull); expect(plan([0, 10], [18, 17]), isNull);
    expect(plan([0], [36]), isNull, reason: 'A provisional fragment must still physically fit the viewport');
    final shifted = plan([-100, -90, -80], [-92, -82, -72])!;
    expect(shifted.pages.single.used, 28, reason: 'A finite negative coordinate origin is valid');
  });
}
