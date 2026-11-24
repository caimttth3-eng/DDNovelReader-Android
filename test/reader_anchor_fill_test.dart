import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/services/reader_page_planner.dart';

const _tolerance = 1e-5;

List<(int, int, bool)> _cuts(ReaderPagePlan plan) => [
  for (final page in plan.pages) (page.first, page.end, page.bandExempt),
];

void _verify(List<double> tops, List<double> bottoms, double height, int anchor,
    ReaderPagePlan plan) {
  final covered = <int>[];
  final boundaries = <int>{0};
  var next = 0;
  for (final page in plan.pages) {
    expect(page.first, next);
    expect(page.end, greaterThan(page.first));
    expect(page.end, lessThanOrEqualTo(tops.length));
    expect(page.first < anchor && page.end > anchor, isFalse,
      reason: 'The entry boundary must remain a cut, including interior entries.');
    final used = bottoms[page.end - 1] - tops[page.first];
    expect(page.used, closeTo(used, 1e-8));
    expect(used, lessThanOrEqualTo(height + _tolerance));
    expect(page.remaining, closeTo(max(0.0, height - used), 1e-8));
    covered.addAll(List.generate(page.rows, (offset) => page.first + offset));
    boundaries.add(page.end);

    // Enumerate every possible extension, independently of the production
    // scan. A backward cut is a maximal suffix; a forward cut is a maximal
    // prefix. These are different contracts when paragraph gaps vary.
    if (page.end <= anchor) {
      for (var first = 0; first < page.first; first++) {
        expect(bottoms[page.end - 1] - tops[first],
          greaterThan(height + _tolerance),
          reason: 'Backward page ${page.first}..${page.end} can fit row $first.');
      }
      expect(page.bandExempt, page.first == 0);
    } else {
      for (var end = page.end + 1; end <= tops.length; end++) {
        expect(bottoms[end - 1] - tops[page.first],
          greaterThan(height + _tolerance),
          reason: 'Forward page ${page.first}..${page.end} can fit through $end.');
      }
      expect(page.bandExempt, page.end == tops.length);
    }
    next = page.end;
  }
  expect(covered, List.generate(tops.length, (index) => index),
    reason: 'Every source row must occur once, without gaps or duplication.');
  expect(next, tops.length);
  expect(boundaries, contains(anchor));
  expect(plan.capacityFallback, isFalse);
  expect(plan.bandStart, closeTo(plan.minRemaining, 1e-8));
  expect(plan.bandEnd, closeTo(plan.maxRemaining, 1e-8));
}

void main() {
  test('1080 varied native row tables fill both directions from arbitrary anchors', () {
    final random = Random(230523);
    for (var example = 0; example < 360; example++) {
      final font = 14.0 + random.nextInt(51);
      final pitch = font * (1.2 + random.nextDouble() * 1.2);
      final height = pitch * (3 + random.nextInt(12)) + random.nextDouble() * font;
      final count = 8 + random.nextInt(90);
      // Each setting has one fixed spacing throughout its row table. Actual
      // glyph tops/bottoms vary independently, as they do with different runs.
      for (final ratio in [0.0, .25, .75]) {
        final spacing = ratio * font;
        final tops = <double>[], bottoms = <double>[];
        var baseline = -height / 3;
        for (var row = 0; row < count; row++) {
          if (row > 0) {
            baseline += pitch + (random.nextInt(4) == 0 ? spacing : 0);
          }
          tops.add(baseline - font * (.7 + random.nextDouble() * .2));
          bottoms.add(baseline + font * (.15 + random.nextDouble() * .15));
        }
        for (final anchor in {0, count, count ~/ 2, random.nextInt(count + 1)}) {
          final plan = ReaderPagePlanner.fillFromAnchor(tops, bottoms,
            height: height, anchor: anchor);
          expect(plan, isNotNull, reason: 'F=$font P=$pitch S=$spacing H=$height anchor=$anchor');
          _verify(tops, bottoms, height, anchor, plan!);
        }
      }
    }
  });

  test('reverse page before an interior anchor is full rather than a prefix remainder', () {
    final tops = List<double>.generate(13, (row) => row * 10.0);
    final bottoms = [for (final top in tops) top + 10];
    final plan = ReaderPagePlanner.fillFromAnchor(tops, bottoms,
      height: 32, anchor: 11)!;
    expect(_cuts(plan), [
      (0, 2, true), (2, 5, false), (5, 8, false),
      (8, 11, false), (11, 13, true),
    ]);
    final previous = plan.pages.singleWhere((page) => page.end == 11);
    expect(previous.rows, 3);
    expect(previous.used, 30);
    _verify(tops, bottoms, 32, 11, plan);
  });

  test('changing a temporary window origin does not shorten the previous anchored page', () {
    final tops = List<double>.generate(18, (row) => row * 10.0);
    final bottoms = [for (final top in tops) top + 10];
    for (final start in [0, 1, 2, 5, 7]) {
      final plan = ReaderPagePlanner.fillFromAnchor(tops.sublist(start), bottoms.sublist(start),
        height: 32, anchor: 14 - start)!;
      final previous = plan.pages.singleWhere((page) => page.end == 14 - start);
      expect((previous.first + start, previous.end + start), (11, 14));
      expect(previous.rows, 3);
      expect(previous.bandExempt, isFalse);
    }
  });

  test('mirror swaps prefix and suffix rules while preserving exact source slices', () {
    final random = Random(232324);
    for (var example = 0; example < 180; example++) {
      final tops = <double>[], bottoms = <double>[];
      var cursor = -50.0;
      final count = 5 + random.nextInt(70);
      for (var row = 0; row < count; row++) {
        final glyph = 8 + random.nextDouble() * 9;
        tops.add(cursor); bottoms.add(cursor + glyph);
        cursor += 20 + random.nextDouble() * 15 + (random.nextBool() ? 12 : 0);
      }
      final height = 75 + random.nextDouble() * 140;
      final anchor = random.nextInt(count + 1);
      final original = ReaderPagePlanner.fillFromAnchor(tops, bottoms,
        height: height, anchor: anchor)!;
      final extent = bottoms.last;
      final mirrored = ReaderPagePlanner.fillFromAnchor(
        [for (final bottom in bottoms.reversed) extent - bottom],
        [for (final top in tops.reversed) extent - top],
        height: height, anchor: count - anchor)!.reversed(count);
      expect(_cuts(mirrored), _cuts(original));
      for (var index = 0; index < original.pages.length; index++) {
        expect(mirrored.pages[index].used, closeTo(original.pages[index].used, 1e-8));
        expect(mirrored.pages[index].remaining, closeTo(original.pages[index].remaining, 1e-8));
      }
      _verify(tops, bottoms, height, anchor, original);
    }
  });

  test('mixed paragraph gaps do not pretend independently greedy directions are inverses', () {
    final tops = [for (var row = 0; row < 9; row++) row * 20.0, 192.0];
    final bottoms = [for (final top in tops) top + 20];
    final forward = ReaderPagePlanner.fillFromAnchor(tops, bottoms,
      height: 100, anchor: 0)!;
    expect(_cuts(forward), [(0, 5, false), (5, 9, false), (9, 10, true)]);
    final reverse = ReaderPagePlanner.fillFromAnchor(tops, bottoms,
      height: 100, anchor: 9)!;
    expect(_cuts(reverse), [(0, 4, true), (4, 9, false), (9, 10, true)]);
    expect(reverse.pages.singleWhere((page) => page.end == 9).first, 4);
    expect(forward.pages.singleWhere((page) => page.end == 9).first, 5,
      reason: 'The reader must reuse committed history, rather than reinterpret its cut as a new reverse entry.');
    _verify(tops, bottoms, 100, 0, forward);
    _verify(tops, bottoms, 100, 9, reverse);
  });

  test('real source tails are recorded but interior pages are not shortened', () {
    final tops = List<double>.generate(14, (row) => row * 10.0);
    final bottoms = [for (final top in tops) top + 10];
    final forward = ReaderPagePlanner.fillFromAnchor(tops, bottoms,
      height: 32, anchor: 0)!;
    expect(forward.pages.map((page) => page.rows), [3, 3, 3, 3, 2]);
    expect(_cuts(forward).last, (12, 14, true));
    expect(forward.pages.last.remaining, 12);
    final backward = ReaderPagePlanner.fillFromAnchor(tops, bottoms,
      height: 32, anchor: 14)!;
    expect(backward.pages.map((page) => page.rows), [2, 3, 3, 3, 3]);
    expect(_cuts(backward).first, (0, 2, true));
    // This flag means the scan reached its available window edge, not that
    // every flagged page must be short, or that the caller proved a book edge.
    final fullEdge = ReaderPagePlanner.fillFromAnchor(tops.sublist(0, 3), bottoms.sublist(0, 3),
      height: 32, anchor: 0)!;
    expect(_cuts(fullEdge), [(0, 3, true)]);
  });

  test('empty input and shifted origins are valid while malformed or oversized rows are rejected', () {
    ReaderPagePlan? fill(List<double> tops, List<double> bottoms,
      {double height = 32, int anchor = 0}) => ReaderPagePlanner.fillFromAnchor(
        tops, bottoms, height: height, anchor: anchor);
    final empty = fill([], [])!;
    expect(empty.pages, isEmpty);
    expect(empty.bandStart, 0); expect(empty.bandEnd, 0);
    expect(fill([0], []), isNull);
    expect(fill([], [], anchor: 1), isNull);
    expect(fill([0], [10], anchor: -1), isNull);
    expect(fill([0], [10], anchor: 2), isNull);
    for (final height in [0.0, -1.0, double.nan, double.infinity]) {
      expect(fill([0], [10], height: height), isNull);
    }
    expect(fill([double.nan], [10]), isNull);
    expect(fill([0], [double.nan]), isNull);
    expect(fill([double.negativeInfinity], [10]), isNull);
    expect(fill([0], [double.infinity]), isNull);
    expect(fill([0], [0]), isNull);
    expect(fill([1], [0]), isNull);
    expect(fill([0, -1], [10, 20]), isNull);
    expect(fill([0, 10], [20, 19]), isNull);
    expect(fill([0], [33]), isNull);
    expect(fill([0, 50], [10, 83], anchor: 1), isNull,
      reason: 'An oversized row cannot be hidden in an exempt edge page.');
    expect(_cuts(fill([-100, -90, -80], [-90, -80, -70], anchor: 2)!),
      [(0, 2, true), (2, 3, true)]);
  });
}
