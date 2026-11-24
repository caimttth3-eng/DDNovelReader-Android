import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/services/reader_page_planner.dart';

typedef _Rows = ({List<double> tops, List<double> bottoms});
_Rows _mirror(List<double> tops, List<double> bottoms) {
  final extent = bottoms.isEmpty ? 0.0 : bottoms.last;
  return (tops: [for (final bottom in bottoms.reversed) extent - bottom],
    bottoms: [for (final top in tops.reversed) extent - top]);
}

List<(int, int, bool, int)> _cuts(ReaderPagePlan plan) =>
  [for (final page in plan.pages) (page.first, page.end, page.bandExempt, page.segmentIndex)];

void _verifyOriginal(ReaderPagePlan plan, List<double> tops, List<double> bottoms, double height) {
  var next = 0;
  for (final page in plan.pages) {
    expect(page.first, next); expect(page.end, greaterThan(page.first));
    expect(page.used, closeTo(bottoms[page.end - 1] - tops[page.first], 1e-7));
    expect(page.remaining, closeTo(height - page.used, 1e-7));
    next = page.end;
  }
  expect(next, tops.length);
}

void main() {
  test('mirrored prefix fills backward from the given anchor instead of exposing its forward tail fragment', () {
    final tops = List<double>.generate(11, (row) => row * 20.0);
    final bottoms = [for (final top in tops) top + 20];
    final forward = ReaderPagePlanner(tops, bottoms, height: 100).solve(10)!;
    expect(forward.pages.last.rows, 1);
    final mirror = _mirror(tops, bottoms);
    final backward = ReaderPagePlanner(mirror.tops, mirror.bottoms, height: 100,
      exemptFirstPage: false, exemptLastPage: true).solve(10)!;
    final sourceOrder = backward.reversed(tops.length);
    expect(_cuts(sourceOrder), [(0, 1, true, 0), (1, 6, false, 0), (6, 11, false, 0)]);
    expect(sourceOrder.pages.last.rows, 5);
    expect(sourceOrder.pages.last.bandExempt, isFalse,
      reason: 'The real page ending at the anchor must remain measured; only the unseen prefix tail is provisional');
    expect(sourceOrder.pages.first.bandExempt, isTrue);
    _verifyOriginal(sourceOrder, tops, bottoms, 100);
  });

  test('mirrored actual row heights and paragraph gaps retain exact source occupancy', () {
    final tops = <double>[0, 24, 48, 100, 128, 152, 210];
    final bottoms = <double>[20, 44, 72, 124, 148, 180, 230];
    final mirror = _mirror(tops, bottoms);
    final plan = ReaderPagePlanner(mirror.tops, mirror.bottoms, height: 100,
      exemptFirstPage: false, exemptLastPage: true).solveReadable(10)!;
    final restored = plan.reversed(tops.length);
    _verifyOriginal(restored, tops, bottoms, 100);
    final last = restored.pages.last;
    expect(bottoms.last - tops[last.first], lessThanOrEqualTo(100));
    if (last.first > 0) {
      expect(bottoms.last - tops[last.first - 1], greaterThan(100),
        reason: 'This fixture chooses the maximal complete incoming page from the anchor');
    }
    expect(_cuts(restored.reversed(tops.length)), _cuts(plan));
  });

  test('reversal preserves fallback band metadata fixed cuts exemptions and ordered segment identities', () {
    final plan = ReaderPagePlanner([0, 10, 20, 30, 40, 50, 60, 70],
      [8, 18, 28, 38, 48, 58, 68, 78], height: 35,
      forcedBreaks: [2], exemptSegmentEdges: false, exemptLastPage: false,
      fixedPages: [(first: 0, end: 2, bandExempt: false)]).solveReadable(0)!;
    expect(plan.capacityFallback, isTrue);
    final reversed = plan.reversed(8);
    expect(_cuts(reversed), [(0, 3, false, 0), (3, 6, false, 0), (6, 8, false, 1)]);
    expect(reversed.capacityFallback, plan.capacityFallback);
    expect(reversed.bandStart, plan.bandStart); expect(reversed.bandEnd, plan.bandEnd);
    expect(reversed.minRemaining, plan.minRemaining); expect(reversed.maxRemaining, plan.maxRemaining);
    expect(reversed.epsilon, plan.epsilon); expect(reversed.deterministicBands, plan.deterministicBands);
    expect(reversed.candidateBands, plan.candidateBands); expect(reversed.evaluatedBands, plan.evaluatedBands);
    expect(reversed.probes, plan.probes);
    expect(_cuts(reversed.reversed(8)), _cuts(plan));
  });

  test('random mirrored plans cover the same source ranges and survive double reversal', () {
    final random = Random(9041);
    for (var example = 0; example < 100; example++) {
      final tops = <double>[], bottoms = <double>[];
      var y = 0.0;
      for (var row = 0; row < 8 + example % 19; row++) {
        tops.add(y); bottoms.add(y + 8 + random.nextInt(7));
        y = bottoms.last + random.nextInt(15);
      }
      final mirror = _mirror(tops, bottoms);
      final plan = ReaderPagePlanner(mirror.tops, mirror.bottoms, height: 70,
        exemptFirstPage: false, exemptLastPage: true).solveReadable(12)!;
      final restored = plan.reversed(tops.length);
      _verifyOriginal(restored, tops, bottoms, 70);
      expect(_cuts(restored.reversed(tops.length)), _cuts(plan));
      expect(restored.spread, closeTo(plan.spread, 1e-7));
    }
  });

  test('empty reversal works and a mismatched row count is rejected', () {
    final empty = ReaderPagePlanner([], [], height: 100).solve(10)!;
    expect(empty.reversed(0).pages, isEmpty);
    expect(() => empty.reversed(1), throwsArgumentError);
    final one = ReaderPagePlanner([0], [10], height: 100).solve(10)!;
    expect(() => one.reversed(-1), throwsArgumentError);
    expect(() => one.reversed(0), throwsArgumentError);
    expect(() => one.reversed(2), throwsArgumentError);
  });
}
