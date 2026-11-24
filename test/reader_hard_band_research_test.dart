import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/services/reader_page_planner.dart';

// Proof fixtures assume a constant shaped glyph envelope G=F. Actual fonts,
// fallback faces and title styles still require native measurement; fixed
// strut pitch alone does not prove equal tight glyph envelopes.
const _f = 39.0, _w = _f / 2;
typedef _Rows = ({List<double> tops, List<double> bottoms});

_Rows _rows(List<bool> paragraphBefore, double pitch, double spacing) {
  final tops = <double>[], bottoms = <double>[];
  var y = 0.0;
  for (var row = 0; row < paragraphBefore.length; row++) {
    if (row > 0) y += pitch + (paragraphBefore[row] ? spacing : 0);
    tops.add(y); bottoms.add(y + _f);
  }
  return (tops: tops, bottoms: bottoms);
}

double _maximumLocalLoss(ReaderPagePlanner planner, ReaderPagePlan plan) {
  var maximum = 0;
  for (final page in plan.measured) {
    var end = page.end;
    while (end < planner.tops.length && planner.used(page.first, end + 1) <= planner.height + planner.epsilon) { end++; }
    maximum = math.max(maximum, end - page.end);
  }
  return maximum.toDouble();
}

void main() {
  test('S equal to line pitch can force one-row ordinary pages despite a common lattice', () {
    const pitch = _f * 1.6, height = 760.0;
    final before = List<bool>.filled(100, true);
    // Inter-row units are normally 2P. Four isolated P intervals are 13 rows
    // apart, well inside the book and farther apart than a full page can span.
    for (final gap in [30, 43, 56, 69]) { before[gap + 1] = false; }
    final rows = _rows(before, pitch, pitch);
    final planner = ReaderPagePlanner(rows.tops, rows.bottoms, height: height,
      exemptFirstPage: true, exemptLastPage: true);
    final strict = planner.solve(_w)!, greedy = planner.greedy()!;
    // W<P permits only one integer span mP in all ordinary pages. Odd m
    // cannot cover long 2P-only interiors. For m=2k>0, each valid page has
    // k+1<=6 rows, with every isolated P interval outside its glyph span at a
    // page boundary. Their 13-row separation is indivisible by k+1. Thus only
    // m=0 survives; exemptions at the two distant outer ends cannot repair it.
    expect(strict.spread, lessThanOrEqualTo(_w + 1e-6));
    expect(strict.measured.every((page) => page.rows == 1), isTrue);
    expect(strict.pages.length, greaterThanOrEqualTo(80));
    expect(greedy.length, lessThanOrEqualTo(20));
    expect(_maximumLocalLoss(planner, strict), greaterThan(1));
  });

  test('quarter-font spacing cannot universally satisfy a half-font band with at most one omitted row', () {
    const pitch = _f * 1.2, spacing = _f * 0.25, height = 760.0;
    final rows = _rows([false, ...List<bool>.filled(167, false), ...List<bool>.filled(168, true)], pitch, spacing);
    final planner = ReaderPagePlanner(rows.tops, rows.bottoms, height: height,
      forcedBreaks: [168], exemptLastPage: false, exemptSegmentEdges: false);
    final longAllowedMargins = [height - (_f + 15 * pitch), height - (_f + 14 * pitch)];
    final shortAllowedMargins = [height - (_f + 12 * (pitch + spacing)), height - (_f + 11 * (pitch + spacing))];
    final nearest = [for (final a in longAllowedMargins) for (final b in shortAllowedMargins) (a - b).abs()].reduce(math.min);
    expect(nearest, closeTo(23.4, 1e-6)); expect(nearest, greaterThan(_w));
    final strict = planner.solve(_w)!;
    expect(strict.spread, lessThanOrEqualTo(_w + 1e-6));
    expect(strict.pages.where((page) => page.end <= 168).every((page) => page.rows <= 14), isTrue);
    expect(strict.pages.length, greaterThan(planner.greedy()!.length));
  });

  test('a bounded-height sufficient condition gives an honest universal small-spacing certificate', () {
    // For any paragraph pattern, K-row pages use G+(K-1)P+qS, 0<=q<=K-1.
    // K=floor((H-G)/(P+S))+1 guarantees fit. (K-1)S<=W bounds every ordinary
    // margin in the same interval. If denseCapacity-K<=1 there is no sparse
    // page losing more than one potentially fitting row. Last page is exempt.
    const spacing = _f / 48;
    for (var tenth = 12; tenth <= 24; tenth++) {
      final pitch = _f * tenth / 10;
      for (final height in [480.0, 640.0, 760.0, 880.0, 1040.0]) {
        final k = ((height - _f) / (pitch + spacing)).floor() + 1;
        final denseCapacity = ((height - _f) / pitch).floor() + 1;
        expect((k - 1) * spacing, lessThanOrEqualTo(_w));
        expect(denseCapacity - k, lessThanOrEqualTo(1));
        for (final before in [List<bool>.filled(240, false), List<bool>.filled(240, true),
          List<bool>.generate(240, (row) => row % 7 == 0 || row % 11 == 0)]) {
          final rows = _rows(before, pitch, spacing);
          final margins = <double>[];
          for (var first = 0; first + k <= rows.tops.length; first += k) {
            final used = rows.bottoms[first + k - 1] - rows.tops[first];
            expect(used, lessThanOrEqualTo(height + 1e-6));
            margins.add(height - used);
            var longest = first + k;
            while (longest < rows.tops.length && rows.bottoms[longest] - rows.tops[first] <= height + 1e-6) { longest++; }
            expect(longest - (first + k), lessThanOrEqualTo(1));
          }
          expect(margins.reduce(math.max) - margins.reduce(math.min), lessThanOrEqualTo(_w + 1e-6));
        }
      }
    }
  });

  test('integer and rational spacing ratios report actual hard-band capacity across all supported line pitches', () {
    final patterns = <String, List<bool>>{
      'long': List<bool>.filled(144, false),
      'one-line': List<bool>.filled(144, true),
      'mixed': List<bool>.generate(144, (row) => row % 7 == 0 || row % 11 == 0),
      'zones': List<bool>.generate(144, (row) => row >= 48 && row < 96),
    };
    for (var tenth = 12; tenth <= 24; tenth++) {
      final pitch = _f * tenth / 10;
      final spacings = <String, double>{
        for (final ratio in [0.125, 0.25, 0.5, 0.75, 1.0, 1.5]) 'S/F=$ratio': _f * ratio,
        for (final ratio in [0.25, 0.5, 1.0]) 'S/P=$ratio': pitch * ratio,
      };
      for (final spacing in spacings.entries) {
        var maximumInflation = 0.0, maximumLostRows = 0.0;
        var minimumMeanFill = 1.0, oneRowCases = 0;
        for (final height in [640.0, 760.0, 880.0]) {
          for (final pattern in patterns.entries) {
            final rows = _rows(pattern.value, pitch, spacing.value);
            final planner = ReaderPagePlanner(rows.tops, rows.bottoms, height: height);
            final strict = planner.solve(_w)!, greedy = planner.greedy()!;
            expect(strict.spread, lessThanOrEqualTo(_w + 1e-6));
            var next = 0;
            for (final page in strict.pages) {
              expect(page.first, next); expect(page.end, greaterThan(next));
              expect(page.used, closeTo(rows.bottoms[page.end - 1] - rows.tops[page.first], 1e-6));
              next = page.end;
            }
            expect(next, rows.tops.length);
            maximumInflation = math.max(maximumInflation, strict.pages.length / greedy.length);
            maximumLostRows = math.max(maximumLostRows, _maximumLocalLoss(planner, strict));
            minimumMeanFill = math.min(minimumMeanFill,
              strict.measured.fold<double>(0, (sum, page) => sum + page.used / height) / strict.measured.length);
            if (strict.measured.any((page) => page.rows == 1)) oneRowCases++;
          }
        }
        // Observations, not a claim that a finite grid proves universality.
        // ignore: avoid_print
        print('HARD_BAND ${jsonEncode({'L/F': tenth / 10, 'spacing': spacing.key,
          'maxPagesOverGreedy': maximumInflation, 'maxLostRows': maximumLostRows,
          'minMeanFill': minimumMeanFill, 'oneRowCases': oneRowCases})}');
      }
    }
  });
}
