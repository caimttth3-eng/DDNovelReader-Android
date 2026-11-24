import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/services/reader_page_planner.dart';

const _font = 39.0;
const _width = _font / 2;
typedef _Geometry = ({List<double> tops, List<double> bottoms});

_Geometry _geometry(List<int> paragraphs, double lineHeight, double spacing) {
  final tops = <double>[], bottoms = <double>[];
  var y = 0.0;
  for (var paragraph = 0; paragraph < paragraphs.length; paragraph++) {
    if (paragraph > 0) y += _font * spacing;
    for (var row = 0; row < paragraphs[paragraph]; row++) {
      tops.add(y); bottoms.add(y + _font); y += _font * lineHeight;
    }
  }
  return (tops: tops, bottoms: bottoms);
}

List<int> _mixed(int rows) {
  const pattern = [1, 2, 7, 1, 4, 11];
  final paragraphs = <int>[];
  var used = 0, index = 0;
  while (used < rows) {
    final count = math.min(pattern[index++ % pattern.length], rows - used);
    paragraphs.add(count); used += count;
  }
  return paragraphs;
}

List<(int, int, bool)> _cuts(Iterable<ReaderPlannedPage> pages) =>
  [for (final page in pages) (page.first, page.end, page.bandExempt)];

void _verify(ReaderPagePlanner planner, ReaderPagePlan plan) {
  var first = 0;
  for (final page in plan.pages) {
    expect(page.first, first); expect(page.end, greaterThan(first));
    expect(page.used, closeTo(planner.bottoms[page.end - 1] - planner.tops[first], 1e-7));
    expect(page.used, lessThanOrEqualTo(planner.height + 1e-7));
    if (!page.bandExempt) {
      var longestEnd = first + 1;
      for (var end = first + 1; end <= planner.tops.length; end++) {
        // This helper is used on unconstrained tables only. Fixed/forced
        // capacity is separately checked against the exact constrained chain.
        if (planner.used(first, end) > planner.height + planner.epsilon) break;
        longestEnd = end;
      }
      expect(longestEnd - page.end, lessThanOrEqualTo(1));
    }
    first = page.end;
  }
  expect(first, planner.tops.length);
}

void main() {
  test('readable capacity policy covers 420 fixed-spacing geometries without extra pages or omitted fitting rows', () {
    final patterns = [[240], List<int>.filled(240, 1), _mixed(240), [80, ...List<int>.filled(80, 1), 80]];
    var cases = 0;
    for (final lineHeight in [1.2, 1.4, 1.6, 1.8, 2.0, 2.2, 2.4]) {
      for (final spacing in [0.25, 0.5, 0.75, 1.0, 1.5]) {
        for (final height in [640.0, 760.0, 880.0]) {
          for (final paragraphs in patterns) {
            final geometry = _geometry(paragraphs, lineHeight, spacing);
            final planner = ReaderPagePlanner(geometry.tops, geometry.bottoms, height: height);
            final greedy = planner.greedy()!, readable = planner.solveReadable(_width)!;
            expect(readable.pages.length, greedy.length,
              reason: 'L=$lineHeight S=$spacing H=$height paragraphs=${paragraphs.length}');
            if (readable.capacityFallback) {
              expect(_cuts(readable.pages), _cuts(greedy));
              expect(readable.bandStart, readable.minRemaining);
              expect(readable.bandEnd, readable.maxRemaining);
            } else {
              expect(readable.spread, lessThanOrEqualTo(_width + 1e-6));
            }
            _verify(planner, readable);
            cases++;
          }
        }
      }
    }
    expect(cases, 420);
  });

  test('an acceptable strict plan remains preferred with one fewer row than local longest fit', () {
    final planner = ReaderPagePlanner([0, 10, 21, 31], [8, 18, 29, 39],
      height: 35, exemptLastPage: false);
    final strict = planner.solve(0)!, readable = planner.solveReadable(0)!;
    expect(_cuts(strict.pages), [(0, 2, false), (2, 4, false)]);
    expect(_cuts(readable.pages), _cuts(strict.pages));
    expect(readable.bandStart, strict.bandStart); expect(readable.bandEnd, strict.bandEnd);
    expect(readable.spread, 0);
    expect(strict.capacityFallback, isFalse); expect(readable.capacityFallback, isFalse);
    _verify(planner, readable);
  });

  test('large paragraph spacing falls back to exact greedy cuts instead of adding sparse pages', () {
    final geometry = _geometry([192, ...List<int>.filled(192, 1)], 1.2, 1.5);
    final planner = ReaderPagePlanner(geometry.tops, geometry.bottoms, height: 760,
      forcedBreaks: [192], exemptLastPage: false, exemptSegmentEdges: false);
    final strict = planner.solve(_width)!, greedy = planner.greedy()!;
    final readable = planner.solveReadable(_width)!;
    expect(strict.capacityFallback, isFalse); expect(readable.capacityFallback, isTrue);
    expect(strict.pages.length, 48); expect(greedy.length, 40);
    expect(_cuts(readable.pages), _cuts(greedy));
    expect(readable.bandStart, readable.minRemaining);
    expect(readable.bandEnd, readable.maxRemaining);
    expect(readable.bandEnd - readable.bandStart, readable.spread);
    expect(readable.spread, greaterThan(_width), reason: 'Fallback must expose the real range instead of claiming the preferred band');
    expect(readable.pages.every((page) => page.first < 192 ? page.end <= 192 : page.first >= 192), isTrue);
  });

  test('matching total page count cannot hide a page that discards several fitting rows', () {
    final planner = ReaderPagePlanner([0, 10, 20, 22, 24, 26], [8, 18, 24, 28, 32, 38],
      height: 35, exemptLastPage: false);
    final strict = planner.solve(0)!, greedy = planner.greedy()!;
    expect(_cuts(strict.pages), [(0, 2, false), (2, 6, false)]);
    expect(strict.pages.length, greedy.length);
    expect(greedy.first.end - strict.pages.first.end, 3);
    final readable = planner.solveReadable(0)!;
    expect(strict.capacityFallback, isFalse); expect(readable.capacityFallback, isTrue);
    expect(_cuts(readable.pages), [(0, 5, false), (5, 6, false)]);
    expect(readable.spread, 20);
    _verify(planner, readable);
  });

  test('fallback retains exact fixed pages and their explicit exemption policy', () {
    final planner = ReaderPagePlanner([0, 10, 20, 30, 40, 50, 60, 70],
      [8, 18, 28, 38, 48, 58, 68, 78], height: 35,
      forcedBreaks: [2], exemptSegmentEdges: false, exemptLastPage: false,
      fixedPages: [(first: 0, end: 2, bandExempt: false)]);
    final readable = planner.solveReadable(0)!;
    expect(readable.capacityFallback, isTrue);
    expect(_cuts(readable.pages), _cuts(planner.greedy()!));
    expect(_cuts(readable.pages), [(0, 2, false), (2, 5, false), (5, 8, false)]);
    expect(readable.spread, 10); expect(readable.bandStart, 7); expect(readable.bandEnd, 17);
    final exempt = ReaderPagePlanner([0, 10, 20, 30], [8, 18, 28, 38], height: 35,
      fixedPages: [(first: 0, end: 1, bandExempt: true)], exemptLastPage: true).solveReadable(0)!;
    expect(exempt.pages.first.bandExempt, isTrue);
    expect(exempt.pages.first.end, 1);
  });

  test('strict band infeasibility still permits readable fixed geometry while oversized rows remain null', () {
    final planner = ReaderPagePlanner([0, 40], [10, 60], height: 25, exemptLastPage: false);
    expect(planner.solve(5), isNull);
    final readable = planner.solveReadable(5)!;
    expect(readable.capacityFallback, isTrue);
    expect(_cuts(readable.pages), [(0, 1, false), (1, 2, false)]);
    expect(readable.bandStart, 5); expect(readable.bandEnd, 15); expect(readable.spread, 10);
    expect(ReaderPagePlanner([0], [30], height: 25).solveReadable(5), isNull);
    final empty = ReaderPagePlanner([], [], height: 100).solveReadable(19.5)!;
    expect(empty.pages, isEmpty); expect(empty.measured, isEmpty);
    expect(empty.capacityFallback, isFalse);
    expect(() => planner.solveReadable(double.nan), throwsArgumentError);
  });
}
