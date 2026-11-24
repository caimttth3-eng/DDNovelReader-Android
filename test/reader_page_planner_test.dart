import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/services/reader_page_planner.dart';

void main() {
  test('real row heights choose fewest pages then the smallest maximum margin', () {
    final planner = ReaderPagePlanner([0, 10, 21, 31], [8, 18, 29, 39],
      height: 35, exemptLastPage: false);
    final plan = planner.solve(30)!;
    expect(plan.pages.map((page) => (page.first, page.end)), [(0, 2), (2, 4)]);
    expect(plan.pages.map((page) => page.used), [18, 18]);
    expect(plan.maxRemaining, 17); expect(plan.spread, 0);
    expect(plan.deterministicBands, isFalse, reason: 'A wide interval must use the general DP');
    _verify(planner, plan, 30, const []);
    expect(planner.solve(0)!.pages.length, 2);
  });

  test('terminal page exemption is explicit and changes the measured objective', () {
    final included = ReaderPagePlanner([0, 10, 21, 31], [8, 18, 29, 39],
      height: 35, exemptLastPage: false).solve(30)!;
    final excludedPlanner = ReaderPagePlanner([0, 10, 21, 31], [8, 18, 29, 39], height: 35);
    final excluded = excludedPlanner.solve(30)!;
    expect(included.maxRemaining, 17);
    expect(excluded.pages.map((page) => (page.first, page.end)), [(0, 3), (3, 4)]);
    expect(excluded.measured.length, 1); expect(excluded.maxRemaining, 6);
    expect(excluded.pages.last.remaining, 27); expect(excluded.pages.last.bandExempt, isTrue);
    _verify(excludedPlanner, excluded, 30, const []);
  });

  test('forced segments share one interval and never cross an anchor boundary', () {
    final planner = ReaderPagePlanner([0, 20, 0, 30], [10, 30, 10, 40],
      height: 100, forcedBreaks: [2], exemptLastPage: false);
    final plan = planner.solve(5)!;
    expect(plan.pages.length, 4,
      reason: 'The two individually optimal two-row pages have incompatible margin bands');
    expect(plan.pages.map((page) => page.remaining), [90, 90, 90, 90]);
    expect(plan.pages.map((page) => page.segmentIndex), [0, 0, 1, 1]);
    _verify(planner, plan, 5, [2]);
  });

  test('first and last exemptions apply separately to every anchored segment', () {
    final planner = ReaderPagePlanner([0, 20, 0, 30], [10, 30, 10, 40],
      height: 100, forcedBreaks: [2, 2, 0, 4], exemptFirstPage: true, exemptLastPage: true);
    final plan = planner.solve(0)!;
    expect(plan.pages.map((page) => (page.first, page.end)), [(0, 2), (2, 4)]);
    expect(plan.measured, isEmpty); expect(plan.minRemaining, 0); expect(plan.maxRemaining, 0);
    _verify(planner, plan, 0, [2]);
  });

  test('a fixed band can be infeasible with genuine unequal glyph heights', () {
    final planner = ReaderPagePlanner([0, 40], [10, 60], height: 25, exemptLastPage: false);
    expect(planner.solve(5), isNull);
    expect(planner.solve(10)!.pages.length, 2);
    expect(ReaderPagePlanner([0, 40], [10, 60], height: 25).solve(0)!.pages.length, 2);
    expect(ReaderPagePlanner([0], [30], height: 25).solve(5), isNull);
  });

  test('empty input and exact or just-too-tall rows have defined outcomes', () {
    final empty = ReaderPagePlanner([], [], height: 100).solve(10)!;
    expect(empty.pages, isEmpty); expect(empty.candidateBands, 0);
    expect(ReaderPagePlanner([0], [100], height: 100, exemptLastPage: false).solve(0)!.pages.single.remaining, 0);
    expect(ReaderPagePlanner([0], [100.0001], height: 100).solve(0), isNull);
  });

  test('candidate de-duplication never rounds nearby distinct margins together', () {
    final planner = ReaderPagePlanner([0, 0], [10, 10.00000005], height: 100,
      forcedBreaks: [1], exemptLastPage: false, epsilon: 0);
    expect(planner.solve(0), isNull);
    final plan = planner.solve(0.0000001)!;
    expect(plan.candidateBands, 3, reason: 'Zero and both exact actual-edge margins are retained');
    expect(plan.spread, greaterThan(0)); expect(plan.spread, lessThanOrEqualTo(0.0000001));
  });

  test('coordinates are copied and invalid geometry or numeric options are rejected', () {
    final tops = <double>[0, 20], bottoms = <double>[10, 30];
    final planner = ReaderPagePlanner(tops, bottoms, height: 100);
    tops[0] = 900; bottoms[0] = 901;
    expect(planner.solve(1)!.pages.single.used, 30);
    for (final badHeight in [0.0, -1.0, double.nan, double.infinity]) {
      expect(() => ReaderPagePlanner([0], [10], height: badHeight), throwsArgumentError);
    }
    expect(() => ReaderPagePlanner([0], [], height: 100), throwsArgumentError);
    expect(() => ReaderPagePlanner([0], [0], height: 100), throwsArgumentError);
    expect(() => ReaderPagePlanner([0, -1], [10, 20], height: 100), throwsArgumentError);
    expect(() => ReaderPagePlanner([0, 1], [10, 9], height: 100), throwsArgumentError);
    expect(() => ReaderPagePlanner([double.nan], [10], height: 100), throwsArgumentError);
    expect(() => ReaderPagePlanner([0], [10], height: 100, forcedBreaks: [2]), throwsArgumentError);
    expect(() => ReaderPagePlanner([0], [10], height: 100, epsilon: 0.01), throwsArgumentError);
    for (final width in [-1.0, double.nan, double.infinity]) {
      expect(() => planner.solve(width), throwsArgumentError);
    }
  });

  test('narrow-band fast path and wide-band DP agree with exhaustive independent partitions', () {
    final random = Random(371);
    for (var example = 0; example < 160; example++) {
      final count = 2 + random.nextInt(7);
      final tops = <double>[], bottoms = <double>[], breaks = <int>[];
      var position = 0.0;
      for (var row = 0; row < count; row++) {
        if (row > 0 && random.nextInt(5) == 0) { breaks.add(row); position = 0; }
        final height = (4 + random.nextInt(7)).toDouble();
        tops.add(position); bottoms.add(position + height);
        position += height + random.nextInt(7);
      }
      final height = (15 + random.nextInt(30)).toDouble();
      final firstExempt = example % 3 == 0, lastExempt = example % 4 != 0;
      final planner = ReaderPagePlanner(tops, bottoms, height: height, forcedBreaks: breaks,
        exemptFirstPage: firstExempt, exemptLastPage: lastExempt, epsilon: 0);
      for (final width in [0.0, 2.0, 8.0, 30.0]) {
        final expected = _brute(tops, bottoms, height, width, breaks, firstExempt, lastExempt);
        final actual = planner.solve(width);
        if (expected == null) {
          expect(actual, isNull, reason: 'example=$example width=$width');
        } else {
          expect(actual, isNotNull, reason: 'example=$example width=$width');
          expect(actual!.pages.length, expected.pages, reason: 'example=$example width=$width minimum page count');
          expect(actual.maxRemaining, expected.maximum, reason: 'example=$example width=$width maximum margin tie-break');
          _verify(planner, actual, width, breaks);
        }
      }
    }
  });

  test('chapter-scale regular rows use deterministic bands without an all-partitions search', () {
    const count = 4000;
    final tops = List<double>.generate(count, (row) => row * 60 + (row ~/ 7) * 4);
    final bottoms = [for (final top in tops) top + 39];
    final planner = ReaderPagePlanner(tops, bottoms, height: 760, exemptFirstPage: true, exemptLastPage: true);
    final plan = planner.solve(19.5)!;
    expect(plan.deterministicBands, isTrue);
    expect(plan.probes, lessThan(3000000));
    expect(plan.evaluatedBands, lessThanOrEqualTo(plan.candidateBands));
    _verify(planner, plan, 19.5, const []);
  });

  test('fixed pages are exact graph edges with no reachable interior cuts', () {
    final planner = ReaderPagePlanner([0, 10, 20, 30, 40, 50], [10, 20, 30, 40, 50, 60],
      height: 35, exemptLastPage: false,
      fixedPages: [(first: 2, end: 4, bandExempt: false)]);
    final plan = planner.solve(0)!;
    expect(plan.pages.map((page) => (page.first, page.end)), [(0, 2), (2, 4), (4, 6)]);
    expect(plan.pages.map((page) => page.segmentIndex), [0, 0, 0],
      reason: 'Fixed cut boundaries must not create new semantic segments');
    expect(plan.pages.map((page) => page.bandExempt), [false, false, false]);
    _verify(planner, plan, 0, const []);
    final expected = _brute(planner.tops, planner.bottoms, 35, 0, const [], false, false,
      fixed: planner.fixedPages);
    expect(plan.pages.length, expected!.pages); expect(plan.maxRemaining, expected.maximum);
  });

  test('fixed measured pages cannot silently become exempt at outer or forced boundaries', () {
    final tops = <double>[0, 10, 20, 30], bottoms = <double>[8, 18, 28, 38];
    final pins = <ReaderFixedPage>[(first: 0, end: 1, bandExempt: false), (first: 1, end: 4, bandExempt: false)];
    for (final segmentEdges in [false, true]) {
      expect(ReaderPagePlanner(tops, bottoms, height: 30, forcedBreaks: [1],
        exemptFirstPage: true, exemptLastPage: true, exemptSegmentEdges: segmentEdges,
        fixedPages: pins).solve(0), isNull,
        reason: 'Fixed measured margins 22 and 2 cannot share a zero-width interval');
    }
    final explicit = ReaderPagePlanner(tops, bottoms, height: 30, forcedBreaks: [1],
      exemptFirstPage: true, exemptLastPage: true, exemptSegmentEdges: false,
      fixedPages: [(first: 0, end: 1, bandExempt: true), pins.last]).solve(0)!;
    expect(explicit.pages.map((page) => page.bandExempt), [true, false]);
    expect(explicit.maxRemaining, 2);
  });

  test('outer-only exemptions do not exempt both sides of an anchor cut', () {
    final tops = <double>[0, 40, 80, 120], bottoms = <double>[10, 60, 90, 140];
    final outerOnly = ReaderPagePlanner(tops, bottoms, height: 25, forcedBreaks: [1, 3],
      exemptFirstPage: true, exemptLastPage: true, exemptSegmentEdges: false);
    expect(outerOnly.solve(0), isNull,
      reason: 'The two internal normal pages have incompatible margins 5 and 15');
    final perSegment = ReaderPagePlanner(tops, bottoms, height: 25, forcedBreaks: [1, 3],
      exemptFirstPage: true, exemptLastPage: true).solve(0)!;
    expect(perSegment.measured, isEmpty);
    final feasible = outerOnly.solve(10)!;
    expect(feasible.pages.map((page) => page.bandExempt), [true, false, false, true]);
    _verify(outerOnly, feasible, 10, [1, 3]);
  });

  test('overlapping fixed cuts and forced breaks inside them are invalid but oversized cuts are infeasible', () {
    final tops = <double>[0, 10, 20, 30], bottoms = <double>[8, 18, 28, 38];
    expect(() => ReaderPagePlanner(tops, bottoms, height: 30,
      fixedPages: [(first: 0, end: 3, bandExempt: true), (first: 2, end: 4, bandExempt: false)]), throwsArgumentError);
    expect(() => ReaderPagePlanner(tops, bottoms, height: 30, forcedBreaks: [2],
      fixedPages: [(first: 1, end: 3, bandExempt: false)]), throwsArgumentError);
    expect(() => ReaderPagePlanner(tops, bottoms, height: 30,
      fixedPages: [(first: 2, end: 2, bandExempt: false)]), throwsArgumentError);
    expect(() => ReaderPagePlanner(tops, bottoms, height: 30,
      fixedPages: [(first: -1, end: 1, bandExempt: false)]), throwsArgumentError);
    expect(ReaderPagePlanner(tops, bottoms, height: 20,
      fixedPages: [(first: 0, end: 3, bandExempt: true)]).solve(10), isNull,
      reason: 'An exempt fixed page must still fit the real body height');
  });

  test('fixed-page narrow and general paths agree with independent exhaustive constrained partitions', () {
    final random = Random(1729);
    for (var example = 0; example < 100; example++) {
      final count = 3 + random.nextInt(5);
      final tops = <double>[], bottoms = <double>[];
      var position = 0.0;
      for (var row = 0; row < count; row++) {
        final glyph = 4.0 + random.nextInt(5);
        tops.add(position); bottoms.add(position + glyph);
        position += glyph + random.nextInt(6);
      }
      final first = random.nextInt(count), end = first + 1 + random.nextInt(count - first);
      final pin = (first: first, end: end, bandExempt: example.isEven);
      final height = 15.0 + random.nextInt(25);
      final firstExempt = example % 3 == 0, lastExempt = example % 4 == 0;
      final segmentEdges = example.isEven;
      for (final width in [0.0, 3.0, 20.0]) {
        final planner = ReaderPagePlanner(tops, bottoms, height: height,
          exemptFirstPage: firstExempt, exemptLastPage: lastExempt, exemptSegmentEdges: segmentEdges,
          fixedPages: [pin], epsilon: 0);
        final expected = _brute(tops, bottoms, height, width, const [], firstExempt, lastExempt,
          fixed: [pin], exemptSegmentEdges: segmentEdges);
        final actual = planner.solve(width);
        if (expected == null) {
          expect(actual, isNull, reason: 'fixed example=$example width=$width');
        } else {
          expect(actual, isNotNull, reason: 'fixed example=$example width=$width');
          expect(actual!.pages.length, expected.pages); expect(actual.maxRemaining, expected.maximum);
          expect(actual.pages.where((page) => page.first == first).single.end, end);
          expect(actual.pages.where((page) => page.first == first).single.bandExempt, pin.bandExempt);
          _verify(planner, actual, width, const []);
        }
      }
    }
  });
}

void _verify(ReaderPagePlanner planner, ReaderPagePlan plan, double width, List<int> forced) {
  var next = 0;
  for (final page in plan.pages) {
    expect(page.first, next); expect(page.end, greaterThan(page.first));
    expect(page.used, planner.bottoms[page.end - 1] - planner.tops[page.first]);
    expect(page.used, lessThanOrEqualTo(planner.height + planner.epsilon));
    expect(page.remaining, closeTo(max(0, planner.height - page.used), 1e-9));
    expect(forced.any((boundary) => boundary > page.first && boundary < page.end), isFalse);
    if (!page.bandExempt) {
      expect(page.remaining, greaterThanOrEqualTo(plan.bandStart - planner.epsilon));
      expect(page.remaining, lessThanOrEqualTo(plan.bandEnd + planner.epsilon));
    }
    next = page.end;
  }
  expect(next, planner.tops.length);
  expect(plan.spread, lessThanOrEqualTo(width + planner.epsilon + 1e-9));
}

/// Independent exhaustive partition enumeration. It does not call planner
/// occupancy, candidate enumeration, greedy lower bounds or fixed-band DP.
({int pages, double maximum})? _brute(List<double> tops, List<double> bottoms,
    double height, double width, List<int> breaks, bool exemptFirst, bool exemptLast,
    {List<ReaderFixedPage> fixed = const [], bool exemptSegmentEdges = true}) {
  final boundaries = <int>{0, tops.length, ...breaks}.toList()..sort();
  final hardBoundaries = <int>{...boundaries, for (final page in fixed) ...[page.first, page.end]}.toList()..sort();
  ({int pages, double maximum})? best;
  void visit(int first, int pages, List<double> measured) {
    if (first == tops.length) {
      final minimum = measured.isEmpty ? 0.0 : measured.reduce(min);
      final maximum = measured.isEmpty ? 0.0 : measured.reduce(max);
      if (maximum - minimum > width) return;
      if (best == null || pages < best!.pages || pages == best!.pages && maximum < best!.maximum) {
        best = (pages: pages, maximum: maximum);
      }
      return;
    }
    if (fixed.any((page) => first > page.first && first < page.end)) return;
    final segment = boundaries.lastIndexWhere((boundary) => boundary <= first);
    final segmentStart = boundaries[segment], segmentEnd = boundaries[segment + 1];
    final pins = fixed.where((page) => page.first == first).toList();
    final pinned = pins.isEmpty ? null : pins.single;
    final ends = pinned == null
      ? [for (var end = first + 1; end <= hardBoundaries.firstWhere((boundary) => boundary > first); end++) end]
      : [pinned.end];
    for (final end in ends) {
      final used = bottoms[end - 1] - tops[first];
      if (used > height) continue;
      final exempt = pinned?.bandExempt ?? (exemptFirst && first == (exemptSegmentEdges ? segmentStart : 0) ||
        exemptLast && end == (exemptSegmentEdges ? segmentEnd : tops.length));
      visit(end, pages + 1, exempt ? measured : [...measured, max(0.0, height - used)]);
    }
  }
  visit(0, 0, const []);
  return best;
}
