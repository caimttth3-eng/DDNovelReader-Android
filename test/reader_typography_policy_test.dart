import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/services/reader_font_geometry.dart';
import 'package:duoduo_langdu/services/reader_typography_policy.dart';

ReaderFontGeometry _geometry(double font, double pitch, {bool complete = true, double spread = 0}) => ReaderFontGeometry(
  baselineStep: pitch, baselineStepMin: pitch, baselineStepMax: pitch, firstBaseline: pitch * .8,
  tightTopMin: -font * .8 - spread / 2, tightTopMax: -font * .8,
  tightBottomMin: font * .2, tightBottomMax: font * .2 + spread / 2,
  supportsUniformStrut: true, measuredClusters: 10, unmeasuredClusters: complete ? 0 : 1);

// Independent interval oracle for this test's continuous P=F*L backend.
// It enumerates possible K and intersects the absolute-fit inequalities with
// both requested +/-10% limits. It does not invoke either production policy.
bool _continuousFeasible(double font, double line, double height) {
  final glyph = font * .8 + font * .2;
  final gmin = glyph - .002, gmax = glyph + .002;
  final width = font / 2 - .5;
  final requested = font * line, minimum = requested * .9, maximum = requested * 1.1;
  final maxRows = ((height - gmin) / minimum).floor() + 1;
  for (var rows = 2; rows <= maxRows; rows++) {
    final gaps = rows - 1;
    if (width - (gmax - gmin) - gaps * .002 <= 0) continue;
    final low = (height - width - gmin) / gaps + .001;
    final high = (height - gmax) / gaps - .001 - 1e-6;
    if (low <= maximum && high >= minimum && low <= high) return true;
  }
  return false;
}

void _verify(ReaderTypographyPlan plan, double requestedL, double height, double scaledFont) {
  expect(plan.effectiveLineHeight, inInclusiveRange(requestedL * .9 - 1e-8, requestedL * 1.1 + 1e-8));
  expect(plan.spacingPlan.remainingMin, greaterThanOrEqualTo(-1e-8));
  expect(plan.spacingPlan.remainingMax, lessThanOrEqualTo(scaledFont / 2 - .5 + 1e-8));
  final rows = plan.spacingPlan.rows;
  final dense = ((height - (plan.geometry.tightBottomMin - plan.geometry.tightTopMax - .002)) /
    (plan.geometry.baselineStepMin - .001)).floor() + 1;
  expect(rows, dense, reason: 'No N-1 line sacrifice may be hidden in the resolved uniform pitch');
  expect(plan.fullMeasurements, lessThanOrEqualTo(4)); expect(plan.cheapMeasurements, lessThanOrEqualTo(24));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final nativeFont = File('${Platform.environment['SystemRoot']}\\Fonts\\msyh.ttc');
  setUpAll(() async {
    if (!nativeFont.existsSync()) return;
    await (FontLoader('TypographyPolicyNative')
      ..addFont(nativeFont.readAsBytes().then((bytes) => ByteData.sublistView(bytes)))).load();
  });
  test('an already close-to-bottom layout preserves the requested font and line height without cheap probes', () {
    final plan = ReaderTypographyPolicy.resolve(fontSize: 40, lineHeight: 1.5, height: 710, level: 2,
      cheapPitch: (font, line) => (font * line).floorToDouble(),
      fullInventory: (font, line) => _geometry(font, (font * line).floorToDouble()))!;
    expect(plan.fontSize, 40); expect(plan.effectiveLineHeight, 1.5);
    expect(plan.fullMeasurements, 1); expect(plan.cheapMeasurements, 0);
    _verify(plan, 1.5, 710, 40);
  });

  test('quantized native pitch coordinates a useful spacing budget without hiding a whole line', () {
    final plans = [for (var level = 0; level < 4; level++) ReaderTypographyPolicy.resolve(
      fontSize: 39, lineHeight: 1.6, height: 760, level: level,
      cheapPitch: (font, line) => (font * line).floorToDouble(),
      fullInventory: (font, line) => _geometry(font, (font * line).floorToDouble()))!];
    expect(plans.map((plan) => plan.effectiveLineHeight).toSet(), hasLength(1),
      reason: 'Cached effective typography cannot change when only the spacing level changes');
    expect(plans.map((plan) => plan.spacingPlan.rows).toSet(), hasLength(1));
    for (var level = 0; level < 4; level++) {
      final plan = plans[level];
      expect(plan.fontSize, 39); expect(plan.geometry.baselineStep, inInclusiveRange(62 * .9, 62 * 1.1));
      expect(plan.spacingPlan.maxSpacing, greaterThan(0));
      expect(plan.spacingPlan.spacing, closeTo(plans[3].spacingPlan.maxSpacing * level / 3, 1e-9));
      _verify(plan, 1.6, 760, 39);
    }
  });

  test('all integer font sizes and requested line-height steps are swept with measured continuous and quantized pitch', () {
    var count = 0, expectedContinuous = 0, continuousSupported = 0, quantizedSupported = 0;
    for (var font = 14; font <= 64; font++) {
      for (var tenth = 12; tenth <= 24; tenth++) {
        for (final height in [480.0, 640.0, 760.0, 880.0, 1040.0]) {
          count++;
          for (final quantized in [false, true]) {
            double pitch(double size, double line) => quantized ? (size * line).floorToDouble() : size * line;
            final plan = ReaderTypographyPolicy.resolve(fontSize: font.toDouble(), lineHeight: tenth / 10,
              height: height, level: 3, cheapPitch: pitch,
              fullInventory: (size, line) => _geometry(size, pitch(size, line)));
            if (!quantized) {
              final feasible = _continuousFeasible(font.toDouble(), tenth / 10, height);
              if (feasible) expectedContinuous++;
              expect(plan != null, feasible,
                reason: 'Independent K/P interval feasibility at F=$font L=${tenth / 10} H=$height');
            }
            if (plan == null) {
              if (!quantized) {
                // ignore: avoid_print
                print('TYPOGRAPHY_CONTINUOUS_UNSUPPORTED F=$font L=${tenth / 10} H=$height');
              }
              continue; // Native quantization may have no attainable pitch in the required interval.
            }
            _verify(plan, tenth / 10, height, font.toDouble());
            expect(plan.fontSize, font.toDouble());
            if (quantized) { quantizedSupported++; } else { continuousSupported++; }
          }
        }
      }
    }
    expect(count, 3315);
    expect(continuousSupported, expectedContinuous,
      reason: 'Every mathematically feasible interval must be realized; impossible intervals must remain unsupported');
    expect(expectedContinuous, greaterThan(0)); expect(expectedContinuous, lessThan(count));
    expect(quantizedSupported, greaterThan(0));
    // A finite font/pitch sweep is a coverage observation, not an assertion that
    // every native face and device has enough compatible font choices.
    // ignore: avoid_print
    print('TYPOGRAPHY_COVERAGE cases=$count feasible=$expectedContinuous continuous=$continuousSupported quantized=$quantizedSupported');
  });

  test('cheap approximation cannot bypass complete-inventory geometry or the absolute margin gate', () {
    final rejected = ReaderTypographyPolicy.resolve(fontSize: 39, lineHeight: 1.6, height: 760, level: 3,
      cheapPitch: (font, line) => font * line,
      fullInventory: (font, line) => _geometry(font, 62));
    expect(rejected, isNull, reason: 'The full native measurement, not the estimated target pitch, decides whether a page fits');
    expect(ReaderTypographyPolicy.resolve(fontSize: 39, lineHeight: 1.6, height: 760, level: 3,
      cheapPitch: (font, line) => font * line,
      fullInventory: (font, line) => _geometry(font, font * line, complete: false)), isNull);
  });

  test('scaled font size controls the hard bound while the returned UI font stays truthful', () {
    final plan = ReaderTypographyPolicy.resolve(fontSize: 32, lineHeight: 1.6, height: 760, level: 3,
      scaledFontSize: (font) => font * 1.25,
      cheapPitch: (font, line) => font * 1.25 * line,
      fullInventory: (font, line) => _geometry(font * 1.25, font * 1.25 * line))!;
    expect(plan.fontSize, 32); _verify(plan, 1.6, 760, 40);
  });

  test('invalid inputs and physically unfillable one-row geometry fail explicitly', () {
    ReaderTypographyPlan? resolve({double font = 39, double line = 1.6, double height = 760,
      int level = 3, double adjustment = .1}) => ReaderTypographyPolicy.resolve(fontSize: font,
        lineHeight: line, height: height, level: level, maxPitchAdjustment: adjustment,
        cheapPitch: (size, leading) => size * leading,
        fullInventory: (size, leading) => _geometry(size, size * leading));
    expect(resolve(font: double.nan), isNull); expect(resolve(line: 0), isNull);
    expect(resolve(height: -1), isNull); expect(resolve(level: 4), isNull);
    expect(resolve(adjustment: -.1), isNull); expect(resolve(adjustment: .3), isNull);
    expect(resolve(height: 100, line: 2.4), isNull,
      reason: 'Only one physical row with a large absolute blank is not an acceptable hard-band solution');
  });

  ReaderTypographyPlan? nearest(Set<double> supported, {double requested = 21, int direction = 0,
    int minimum = 14, int maximum = 64, List<double>? visited}) => ReaderTypographyPolicy.resolveNearest(
      fontSize: requested, lineHeight: 1.6, height: 710, level: 3,
      minFontSize: minimum, maxFontSize: maximum, fontDirection: direction,
      cheapPitch: (font, line) => supported.contains(font) ? (710 - font * 1.25) / 9 : null,
      fullInventory: (font, line) {
        visited?.add(font);
        return supported.contains(font) ? _geometry(font, (710 - font * 1.25) / 9) : null;
      });

  test('nearest font preserves a supported fractional request and resolves integer ties toward the smaller font', () {
    expect(nearest({20.5}, requested: 20.5)!.fontSize, 20.5);
    expect(nearest({20, 21}, requested: 20.5)!.fontSize, 20);
    expect(nearest({20, 22})!.fontSize, 20);
    expect(nearest({20, 22}, requested: 21.2)!.fontSize, 22);
  });

  test('directional font intent skips unsupported fonts and falls back across sides only if necessary', () {
    expect(nearest({20, 22}, direction: 1)!.fontSize, 22);
    expect(nearest({20, 22}, direction: -1)!.fontSize, 20);
    expect(nearest({20, 24}, direction: 1)!.fontSize, 24,
      reason: 'A plus action requesting unsupported 21 must not snap back to valid 20 before trying 24');
    expect(nearest({18, 22}, direction: -1)!.fontSize, 18);
    expect(nearest({20}, direction: 1)!.fontSize, 20);
    expect(nearest({22}, direction: -1)!.fontSize, 22);
  });

  test('nearest font obeys explicit font boundaries including out-of-range and invalid requests', () {
    final visited = <double>[];
    expect(nearest({14, 21}, requested: 13, minimum: 14, maximum: 20, visited: visited)!.fontSize, 14);
    expect(visited.every((font) => font >= 14 && font <= 20), isTrue);
    expect(nearest({21}, requested: 19, maximum: 20), isNull);
    expect(nearest({20}, minimum: 22, maximum: 20), isNull);
    expect(nearest({20}, direction: 2), isNull);
    expect(nearest({20}, requested: double.nan), isNull);
  });

  test('nearest font aggregates unique native calls and applies scaling separately to the chosen font', () {
    var fullCalls = 0, cheapCalls = 0;
    final scales = <double, int>{}, fullKeys = <(double, double)>{};
    final plan = ReaderTypographyPolicy.resolveNearest(fontSize: 20, lineHeight: 1.6, height: 710, level: 3,
      scaledFontSize: (font) { scales.update(font, (count) => count + 1, ifAbsent: () => 1); return font * 1.5; },
      cheapPitch: (font, line) { cheapCalls++; return (710 - font * 1.5 * 1.25) / 9; },
      fullInventory: (font, line) {
        fullCalls++; expect(fullKeys.add((font, line)), isTrue, reason: 'Identical native callbacks must use the cache');
        return font == 19 ? _geometry(font * 1.5, (710 - font * 1.5 * 1.25) / 9) : null;
      })!;
    expect(plan.fontSize, 19);
    expect(plan.fullMeasurements, fullCalls); expect(plan.cheapMeasurements, cheapCalls);
    expect(fullCalls, 2); expect(scales.values.every((count) => count == 1), isTrue);
    expect(plan.spacingPlan.hardWidth, 19 * 1.5 / 2 - .5);
    expect(plan.spacingPlan.remainingMax, lessThanOrEqualTo(plan.spacingPlan.hardWidth));
  });

  test('spacing level cannot select a different nearest effective font or line height', () {
    final plans = [for (var level = 0; level < 4; level++) ReaderTypographyPolicy.resolveNearest(
      fontSize: 21, lineHeight: 1.6, height: 710, level: level,
      cheapPitch: (font, line) => (710 - font * 1.25) / 9,
      fullInventory: (font, line) => font == 20 || font == 22 ? _geometry(font, (710 - font * 1.25) / 9) : null)!];
    expect(plans.map((plan) => plan.fontSize).toSet(), {20});
    expect(plans.map((plan) => plan.effectiveLineHeight).toSet(), hasLength(1));
    expect(plans.map((plan) => plan.spacingPlan.rows).toSet(), hasLength(1));
    expect(plans.first.spacingPlan.spacing, 0);
    expect(plans.last.spacingPlan.spacing, greaterThan(0));
  });

  test('real CJK native callbacks retain hard capacity across tall measurement and phone viewport heights', () {
    final cache = <(double, double, bool), ReaderFontGeometry>{};
    ReaderFontGeometry measure(double font, double line, bool full, double scale) =>
      cache.putIfAbsent((font * scale, line, full), () => ReaderFontGeometry.measure(
        graphemes: full ? ['段落行距第一章甲段晨光照在山坡上，微风吹过树梢。乙段山间的小路通向村庄，远处有人慢慢走来。丙段溪水绕过石桥流向远方，岸边草木随风轻摆。'] : ['国Hg'],
        fontSize: font, lineHeight: line, fontFamily: 'TypographyPolicyNative',
        textScaler: TextScaler.linear(scale), textDirection: TextDirection.ltr,
        strutStyle: StrutStyle(fontSize: font, height: line, fontFamily: 'TypographyPolicyNative',
          forceStrutHeight: true, fontWeight: FontWeight.normal)));
    for (final font in [20.0, 39.0, 64.0]) {
      for (final line in [1.2, 1.6, 2.4]) {
        for (final height in [764.0, 3920.0]) {
          final initial = measure(font, line, true, 1);
          final plan = ReaderTypographyPolicy.resolve(fontSize: font, lineHeight: line, height: height, level: 3,
            cheapPitch: (size, leading) => measure(size, leading, false, 1).baselineStep,
            fullInventory: (size, leading) => measure(size, leading, true, 1));
          // ignore: avoid_print
          print('NATIVE_TYPOGRAPHY F=$font L=$line H=$height P0=${initial.baselineStep} '
            'effectiveL=${plan?.effectiveLineHeight} P=${plan?.geometry.baselineStep} '
            'K=${plan?.spacingPlan.rows} R=${plan?.spacingPlan.remainingMin}..${plan?.spacingPlan.remainingMax} '
            'cheap=${plan?.cheapMeasurements} full=${plan?.fullMeasurements}');
          expect(plan, isNotNull, reason: 'Actual msyh callback coverage at F=$font L=$line H=$height');
          _verify(plan!, line, height, font);
        }
      }
    }
    for (final height in [764.0, 3920.0]) {
      final plan = ReaderTypographyPolicy.resolve(fontSize: 39, lineHeight: 1.6, height: height, level: 3,
        scaledFontSize: (size) => size * 1.25,
        cheapPitch: (size, leading) => measure(size, leading, false, 1.25).baselineStep,
        fullInventory: (size, leading) => measure(size, leading, true, 1.25));
      expect(plan, isNotNull, reason: 'Actual scaled msyh callback coverage at H=$height');
      _verify(plan!, 1.6, height, 39 * 1.25);
    }
  }, skip: !nativeFont.existsSync());
}
