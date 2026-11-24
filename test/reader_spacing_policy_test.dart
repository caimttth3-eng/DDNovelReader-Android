import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/services/reader_page_planner.dart';
import 'package:duoduo_langdu/services/reader_spacing_policy.dart';

void main() {
  test('production flow uses fixed visible spacing with variable page capacity', () {
    for (final font in [14.0, 39.0, 64.0]) {
      for (final height in [320.0, 761.0, 1040.0]) {
        for (final lineHeight in [1.2, 1.6, 2.4]) {
          for (var level = 0; level < 4; level++) {
            final plan = ReaderSpacingPolicy.flow(height: height, fontSize: font,
              baselinePitch: font * lineHeight, level: level);
            expect(plan.fixedRows, isFalse);
            expect(plan.spacing, font * level / 4);
            expect(plan.rowPitch, font * lineHeight);
            expect(plan.acceptsOrdinaryRowCount(0), isFalse);
            for (final rows in [1, 2, 7, 20]) {
              expect(plan.acceptsOrdinaryRowCount(rows), isTrue);
            }
            expect(plan.remainingMax, font * lineHeight + plan.spacing,
              reason: 'The next complete row advance includes paragraph spacing');
          }
        }
      }
    }
  });

  test('production flow rejects invalid dimensions and spacing levels', () {
    for (final invalid in [0.0, -1.0, double.nan, double.infinity]) {
      expect(() => ReaderSpacingPolicy.flow(height: invalid, fontSize: 39,
        baselinePitch: 62.4, level: 0), throwsArgumentError);
      expect(() => ReaderSpacingPolicy.flow(height: 760, fontSize: invalid,
        baselinePitch: 62.4, level: 0), throwsArgumentError);
      expect(() => ReaderSpacingPolicy.flow(height: 760, fontSize: 39,
        baselinePitch: invalid, level: 0), throwsArgumentError);
    }
    for (final level in [-1, 4]) {
      expect(() => ReaderSpacingPolicy.flow(height: 760, fontSize: 39,
        baselinePitch: 62.4, level: level), throwsArgumentError);
    }
  });

  test('more than 1000 geometries certify every internal paragraph count at all four levels', () {
    var geometries = 0, supported = 0, unsupported = 0;
    for (final font in [14.0, 18.0, 24.0, 32.0, 39.0, 48.0, 64.0]) {
      for (var tenth = 12; tenth <= 24; tenth++) {
        final pitch = font * tenth / 10;
        for (final height in [320.0, 480.0, 640.0, 760.0, 880.0, 1040.0]) {
          for (final envelope in [
            (topMin: -0.9 * font, topMax: -0.9 * font, bottomMin: 0.25 * font, bottomMax: 0.25 * font),
            (topMin: -0.92 * font, topMax: -0.9 * font, bottomMin: 0.24 * font, bottomMax: 0.26 * font),
            (topMin: -0.95 * font, topMax: -0.8 * font, bottomMin: 0.2 * font, bottomMax: 0.35 * font),
          ]) {
            final candidates = [for (var level = 0; level < 4; level++) ReaderSpacingPolicy.resolve(
              height: height, fontSize: font, baselinePitch: pitch,
              tightTopMin: envelope.topMin, tightTopMax: envelope.topMax,
              tightBottomMin: envelope.bottomMin, tightBottomMax: envelope.bottomMax, level: level)];
            geometries++;
            final glyphMax = envelope.bottomMax - envelope.topMin;
            final glyphMin = envelope.bottomMin - envelope.topMax;
            final maximumRows = ((height - glyphMax) / pitch).floor() + 1;
            final denseMaximumRows = ((height - glyphMin) / pitch).floor() + 1;
            final safe = font / 2 - .5;
            final canSupport = maximumRows == denseMaximumRows && glyphMax - glyphMin <= safe &&
              height - ((maximumRows - 1) * pitch + glyphMin) <= safe;
            if (!canSupport) {
              expect(candidates.every((plan) => plan == null), isTrue);
              unsupported++; continue;
            }
            expect(candidates.every((plan) => plan != null), isTrue);
            supported++;
            final plans = [for (final plan in candidates) plan!];
            expect(plans.map((plan) => plan.rows).toSet(), hasLength(1));
            for (var level = 0; level < 4; level++) {
              final plan = plans[level];
              expect(plan.rows, greaterThanOrEqualTo(2));
              expect(plan.rows, maximumRows); expect(plan.rows, denseMaximumRows);
              expect(plan.spacing, closeTo(plans[3].maxSpacing * level / 3, 1e-9));
              expect(plan.hardWidth, font / 2 - 0.5);
              expect(plan.usedMax - plan.usedMin, lessThanOrEqualTo(plan.hardWidth + 1e-8));
              expect(plan.usedMax, lessThanOrEqualTo(height + 1e-8));
              expect(plan.remainingMin, closeTo(height - plan.usedMax, 1e-8));
              expect(plan.remainingMax, closeTo(height - plan.usedMin, 1e-8));
              expect(plan.remainingMax, lessThanOrEqualTo(plan.hardWidth + 1e-8));
              // Every binary paragraph pattern is covered by its gap count q.
              // Top/bottom envelope extrema bound every actual font choice.
              for (var q = 0; q < plan.rows; q++) {
                for (final top in [envelope.topMin, envelope.topMax]) {
                  for (final bottom in [envelope.bottomMin, envelope.bottomMax]) {
                    final actual = (plan.rows - 1) * pitch + bottom - top + q * plan.spacing;
                    expect(actual, greaterThanOrEqualTo(plan.usedMin - 1e-8));
                    expect(actual, lessThanOrEqualTo(plan.usedMax + 1e-8));
                    expect(height - actual, greaterThanOrEqualTo(plan.remainingMin - 1e-8));
                    expect(height - actual, lessThanOrEqualTo(plan.remainingMax + 1e-8));
                  }
                }
              }
            }
          }
        }
      }
    }
    expect(geometries, 1638);
    expect(supported, greaterThan(0)); expect(unsupported, greaterThan(0));
  });

  test('actual arbitrary row envelopes and paragraph positions stay inside the certified ordinary-page band', () {
    final random = Random(6214);
    final plan = ReaderSpacingPolicy.resolve(height: 740, fontSize: 39, baselinePitch: 62.4,
      tightTopMin: -36, tightTopMax: -33, tightBottomMin: 8, tightBottomMax: 11, level: 3)!;
    for (var example = 0; example < 1000; example++) {
      var baseline = 0.0, top = double.infinity, bottom = double.negativeInfinity;
      for (var row = 0; row < plan.rows; row++) {
        if (row > 0) baseline += 62.4 + (random.nextBool() ? plan.spacing : 0);
        top = min(top, baseline - 36 + random.nextDouble() * 3);
        bottom = max(bottom, baseline + 8 + random.nextDouble() * 3);
      }
      final actual = bottom - top;
      expect(actual, inInclusiveRange(plan.usedMin - 1e-8, plan.usedMax + 1e-8));
      expect(740 - actual, inInclusiveRange(plan.remainingMin - 1e-8, plan.remainingMax + 1e-8));
      expect(740 - actual, lessThanOrEqualTo(plan.hardWidth + 1e-8));
    }
  });

  test('row choice never drops a line and rejects a large absolute bottom margin', () {
    ReaderSpacingPlan? resolve(double height, int level) => ReaderSpacingPolicy.resolve(
      height: height, fontSize: 40, baselinePitch: 60,
      tightTopMin: -30, tightTopMax: -30, tightBottomMin: 10, tightBottomMax: 10, level: level);
    expect(resolve(730, 3), isNull, reason: 'A constant 30px blank is not acceptable merely because its spread is zero');
    for (var level = 0; level < 4; level++) { expect(resolve(705, level)!.rows, 12); }
    expect(resolve(705, 0)!.spacing, 0);
    expect(resolve(705, 3)!.spacing, closeTo(5 / 11, 1e-9));
  });

  test('a partial source tail is explicitly outside the ordinary-page guarantee', () {
    final plan = ReaderSpacingPolicy.resolve(height: 740, fontSize: 39, baselinePitch: 62.4,
      tightTopMin: -30, tightTopMax: -30, tightBottomMin: 9, tightBottomMax: 9, level: 3)!;
    expect(plan.acceptsOrdinaryRowCount(plan.rows), isTrue);
    for (var tail = 1; tail < plan.rows; tail++) {
      expect(plan.acceptsOrdinaryRowCount(tail), isFalse);
      final used = (tail - 1) * 62.4 + 39;
      expect(740 - used, greaterThan(plan.remainingMax));
    }
    expect(plan.acceptsOrdinaryRowCount(0), isFalse);
    expect(plan.acceptsOrdinaryRowCount(plan.rows + 1), isFalse);
  });

  test('row capacity compares against the real minimum glyph and pitch envelope at threshold heights', () {
    for (var level = 0; level < 4; level++) {
      final native = ReaderSpacingPolicy.resolve(height: 640, fontSize: 40, baselinePitch: 60,
        tightTopMin: -35, tightTopMax: -30, tightBottomMin: 10, tightBottomMax: 10, level: level);
      expect(native, isNull, reason: 'Worst capacity ten differs from dense capacity eleven');
      // General numerical input with P<W exposes the boundary that the old
      // conservative-N-only check missed. These overlapping glyph envelopes
      // are not presented as a measured native-font configuration.
      final narrowPitch = ReaderSpacingPolicy.resolve(height: 60, fontSize: 40, baselinePitch: 10,
        tightTopMin: -20, tightTopMax: -15, tightBottomMin: 5, tightBottomMax: 5, level: level);
      expect(narrowPitch, isNull, reason: 'No envelope-dependent loss of even one full row is permitted');
    }
    expect(ReaderSpacingPolicy.resolve(height: 70, fontSize: 40, baselinePitch: 5,
      tightTopMin: -30, tightTopMax: -15, tightBottomMin: 5, tightBottomMax: 5, level: 3), isNull,
      reason: 'Worst-envelope capacity eight is already more than one row below dense capacity eleven');
  });

  test('native pitch variation is accumulated across every internal row gap', () {
    const pitchMin = 62.399, pitchMax = 62.401;
    final random = Random(1307);
    for (var level = 0; level < 4; level++) {
      final plan = ReaderSpacingPolicy.resolve(height: 740, fontSize: 39, baselinePitch: 62.4,
        baselinePitchMin: pitchMin, baselinePitchMax: pitchMax,
        tightTopMin: -30, tightTopMax: -30, tightBottomMin: 9, tightBottomMax: 9, level: level)!;
      expect(plan.usedMin, closeTo((plan.rows - 1) * pitchMin + 39, 1e-9));
      expect(((740 - 39) / pitchMin).floor() + 1, plan.rows);
      expect(plan.usedMax, closeTo((plan.rows - 1) * pitchMax + 39 + (plan.rows - 1) * plan.spacing, 1e-9));
      expect(plan.usedMax - plan.usedMin, lessThanOrEqualTo(plan.hardWidth + 1e-9));
      for (var example = 0; example < 250; example++) {
        var used = 39.0;
        for (var gap = 1; gap < plan.rows; gap++) {
          used += pitchMin + random.nextDouble() * (pitchMax - pitchMin) + (random.nextBool() ? plan.spacing : 0);
        }
        expect(used, inInclusiveRange(plan.usedMin - 1e-8, plan.usedMax + 1e-8));
      }
    }
  });

  test('large row counts reject accumulated pitch error instead of hiding it inside a per-row tolerance', () {
    ReaderSpacingPlan? resolve({double height = 100000, double low = 19.999, double high = 20.001}) =>
      ReaderSpacingPolicy.resolve(height: height, fontSize: 14, baselinePitch: 20,
        baselinePitchMin: low, baselinePitchMax: high,
        tightTopMin: -10, tightTopMax: -10, tightBottomMin: 4, tightBottomMax: 4, level: 3);
    expect(resolve(), isNull, reason: 'Roughly 5000 gaps accumulate about 10px uncertainty, above the 6.5px safe band');
    final supported = resolve(height: 10000)!;
    expect(supported.usedMax - supported.usedMin, lessThanOrEqualTo(6.5 + 1e-8));
    expect(resolve(low: 20.001), isNull); expect(resolve(high: 19.999), isNull);
    expect(resolve(low: double.nan), isNull); expect(resolve(high: double.infinity), isNull);
  });

  test('a physically one-row viewport keeps legal pagination with zero spacing at all levels', () {
    for (var level = 0; level < 4; level++) {
      final plan = ReaderSpacingPolicy.resolve(height: 40, fontSize: 39, baselinePitch: 93.6,
        tightTopMin: -30, tightTopMax: -27, tightBottomMin: 8, tightBottomMax: 10, level: level)!;
      expect(plan.rows, 1);
      expect(plan.spacing, 0); expect(plan.maxSpacing, 0);
      expect(plan.usedMin, 35); expect(plan.usedMax, 40);
      expect(plan.remainingMin, 0); expect(plan.remainingMax, 5);
      expect(plan.usedMax - plan.usedMin, lessThanOrEqualTo(plan.hardWidth));
      expect(plan.acceptsOrdinaryRowCount(1), isTrue);
      expect(plan.acceptsOrdinaryRowCount(0), isFalse);
      final pages = ReaderPagePlanner.fixedRows([-30, 63.6, 157.2], [10, 103.6, 197.2],
        rows: plan.rows, anchor: 1, height: 40, usedMin: plan.usedMin, usedMax: plan.usedMax)!;
      expect(pages.pages.map((page) => page.rows), [1, 1, 1]);
      expect(pages.pages.every((page) => !page.bandExempt), isTrue);
      expect(pages.capacityFallback, isFalse);
    }
  });

  test('unsupported envelopes and insufficient one-row height never widen the hard constraint', () {
    ReaderSpacingPlan? resolve({double height = 760, double font = 39, double pitch = 62.4,
      double topMin = -30, double topMax = -30, double bottomMin = 9, double bottomMax = 9, int level = 3}) =>
      ReaderSpacingPolicy.resolve(height: height, fontSize: font, baselinePitch: pitch,
        tightTopMin: topMin, tightTopMax: topMax, tightBottomMin: bottomMin,
        tightBottomMax: bottomMax, level: level);
    for (final bad in [double.nan, double.infinity, double.negativeInfinity]) {
      expect(resolve(height: bad), isNull); expect(resolve(font: bad), isNull);
      expect(resolve(pitch: bad), isNull); expect(resolve(topMin: bad), isNull);
      expect(resolve(bottomMax: bad), isNull);
    }
    expect(resolve(height: 38.999), isNull);
    expect(resolve(height: 39)!.rows, 1);
    expect(resolve(height: 100), isNull, reason: 'A one-row page with 61px empty below it violates the absolute margin bound');
    expect(resolve(height: 101.4), isNotNull);
    expect(resolve(height: 0), isNull); expect(resolve(font: 0), isNull);
    expect(resolve(pitch: 0), isNull); expect(resolve(topMin: -29), isNull);
    expect(resolve(bottomMin: 10), isNull); expect(resolve(bottomMin: -31), isNull);
    expect(resolve(topMin: -50), isNull); // Font envelope alone exceeds 19px.
    expect(resolve(level: -1), isNull); expect(resolve(level: 4), isNull);
    expect(resolve(height: double.maxFinite, pitch: double.minPositive), isNull);
    final two = resolve(height: 102)!;
    expect(two.rows, 2); expect(two.usedMax, lessThanOrEqualTo(102 + 1e-9));
    expect(two.usedMax - two.usedMin, lessThanOrEqualTo(two.hardWidth + 1e-9));
  });
}
