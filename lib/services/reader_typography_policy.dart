import 'dart:math' as math;

import 'reader_font_geometry.dart';
import 'reader_spacing_policy.dart';

typedef ReaderPitchProbe = double? Function(double fontSize, double lineHeight);
typedef ReaderFontProbe = ReaderFontGeometry? Function(double fontSize, double lineHeight);

class ReaderTypographyPlan {
  final double fontSize, effectiveLineHeight;
  final ReaderFontGeometry geometry;
  final ReaderSpacingPlan spacingPlan;
  final int fullMeasurements, cheapMeasurements;
  const ReaderTypographyPlan._(this.fontSize, this.effectiveLineHeight,
    this.geometry, this.spacingPlan, this.fullMeasurements, this.cheapMeasurements);
}

/// Resolves one uniform whole-layout pitch, never per-page line stretching.
/// Cheap scalar probes only locate native candidates; a complete inventory
/// and the strict absolute-margin spacing policy make the final decision.
class ReaderTypographyPolicy {
  /// Preserve the requested font when possible, otherwise select the nearest
  /// supported integer font within the supplied bounds. Directional intent
  /// searches that side first, so a + button cannot snap back indefinitely.
  /// The returned font is explicit; callers own preference versus runtime UI.
  static ReaderTypographyPlan? resolveNearest({required double fontSize,
    required double lineHeight, required double height, required int level,
    required ReaderPitchProbe cheapPitch, required ReaderFontProbe fullInventory,
    double Function(double fontSize)? scaledFontSize, double maxPitchAdjustment = .10,
    int minFontSize = 14, int maxFontSize = 64, int fontDirection = 0}) {
    if (!fontSize.isFinite || fontSize <= 0 || minFontSize <= 0 || maxFontSize < minFontSize ||
        fontDirection < -1 || fontDirection > 1) return null;
    final fullCache = <(double, double), ReaderFontGeometry?>{};
    final pitchCache = <(double, double), double?>{};
    final scales = <double, double>{};
    var fullCount = 0, cheapCount = 0;
    ReaderFontGeometry? full(double font, double line) {
      final key = (font, line);
      if (!fullCache.containsKey(key)) { fullCount++; fullCache[key] = fullInventory(font, line); }
      return fullCache[key];
    }
    double? cheap(double font, double line) {
      final key = (font, line);
      if (!pitchCache.containsKey(key)) { cheapCount++; pitchCache[key] = cheapPitch(font, line); }
      return pitchCache[key];
    }
    ReaderTypographyPlan? tryFont(double font) {
      final plan = resolve(fontSize: font, lineHeight: lineHeight, height: height, level: level,
        cheapPitch: cheap, fullInventory: full, maxPitchAdjustment: maxPitchAdjustment,
        scaledFontSize: (value) => scales.putIfAbsent(value, () => scaledFontSize?.call(value) ?? value));
      return plan == null ? null : ReaderTypographyPlan._(plan.fontSize, plan.effectiveLineHeight,
        plan.geometry, plan.spacingPlan, fullCount, cheapCount);
    }
    if (fontSize >= minFontSize && fontSize <= maxFontSize) {
      final requested = tryFont(fontSize);
      if (requested != null) return requested;
    }
    final candidates = [for (var font = minFontSize; font <= maxFontSize; font++)
      if (font.toDouble() != fontSize) font.toDouble()];
    candidates.sort((a, b) {
      if (fontDirection != 0) {
        final aPreferred = fontDirection > 0 ? a >= fontSize : a <= fontSize;
        final bPreferred = fontDirection > 0 ? b >= fontSize : b <= fontSize;
        if (aPreferred != bPreferred) return aPreferred ? -1 : 1;
      }
      final distance = (a - fontSize).abs().compareTo((b - fontSize).abs());
      return distance == 0 ? a.compareTo(b) : distance;
    });
    for (final font in candidates) {
      final plan = tryFont(font);
      if (plan != null) return plan;
    }
    return null;
  }

  static ReaderTypographyPlan? resolve({required double fontSize,
    required double lineHeight, required double height, required int level,
    required ReaderPitchProbe cheapPitch, required ReaderFontProbe fullInventory,
    double Function(double fontSize)? scaledFontSize, double maxPitchAdjustment = .10}) {
    final scaled = scaledFontSize?.call(fontSize) ?? fontSize;
    if (![fontSize, lineHeight, height, scaled, maxPitchAdjustment].every((value) => value.isFinite) ||
        fontSize <= 0 || lineHeight <= 0 || height <= 0 || scaled <= 0 ||
        level < 0 || level > 3 || maxPitchAdjustment < 0 || maxPitchAdjustment > .25) return null;
    var fullCount = 1, cheapCount = 0;
    final initial = fullInventory(fontSize, lineHeight);
    if (!_valid(initial)) return null;
    final first = initial!;
    ReaderSpacingPlan? spacing(ReaderFontGeometry geometry, int selection) {
      if (!_valid(geometry)) return null;
      final plan = ReaderSpacingPolicy.resolve(height: height, fontSize: scaled,
        baselinePitch: geometry.baselineStep,
        baselinePitchMin: math.max(.001, geometry.baselineStepMin - .001),
        baselinePitchMax: geometry.baselineStepMax + .001,
        tightTopMin: geometry.tightTopMin - .001, tightTopMax: geometry.tightTopMax + .001,
        tightBottomMin: geometry.tightBottomMin - .001, tightBottomMax: geometry.tightBottomMax + .001,
        level: selection);
      return plan != null && plan.remainingMin >= -1e-8 && plan.remainingMax <= plan.hardWidth + 1e-8 ? plan : null;
    }
    ReaderTypographyPlan? result(ReaderFontGeometry geometry, double effective) {
      final plan = spacing(geometry, level);
      return plan == null ? null : ReaderTypographyPlan._(fontSize, effective, geometry, plan, fullCount, cheapCount);
    }
    double freeBand(ReaderFontGeometry geometry, int rows) => scaled / 2 - .5 -
      (geometry.fontSpread + .004) - (rows - 1) * (geometry.baselineStepMax - geometry.baselineStepMin + .002);
    final original = spacing(first, 3);
    if (original != null && (original.rows == 1 || original.maxSpacing * (original.rows - 1) >=
        math.max(0, freeBand(first, original.rows)) / 2)) return result(first, lineHeight);
    if (maxPitchAdjustment == 0) return original != null && original.maxSpacing > 1e-6 ? result(first, lineHeight) : null;
    final p0 = first.baselineStep;
    final pmin = p0 * (1 - maxPitchAdjustment), pmax = p0 * (1 + maxPitchAdjustment);
    final lowerL = lineHeight * (1 - maxPitchAdjustment), upperL = lineHeight * (1 + maxPitchAdjustment);
    final gmin = first.tightBottomMin - first.tightTopMax - .002;
    final gmax = first.tightBottomMax - first.tightTopMin + .002;
    final width = scaled / 2 - .5;
    final pitchError = math.max((p0 - first.baselineStepMin).abs(), (first.baselineStepMax - p0).abs()) + .001;
    final count = (height - gmin) / pmin;
    if (!count.isFinite || count > 4096) return null;
    final cache = <double, double?>{lineHeight: p0};
    double? probe(double value) {
      if (cache.containsKey(value)) return cache[value];
      if (cheapCount >= 24) return null;
      cheapCount++;
      final measured = cheapPitch(fontSize, value);
      return cache[value] = measured != null && measured.isFinite && measured > 0 ? measured : null;
    }
    // Search the whole hard-feasible interval first. A desired spacing reserve
    // is secondary to a nearby attainable native pitch, not a separate phase
    // allowed to exhaust all probes on empty quantization gaps.
    final candidates = <({double low, double high, double target, int rows})>[];
    for (var rows = 2; rows <= count.floor() + 1; rows++) {
      final gaps = rows - 1;
      final available = width - (gmax - gmin) - gaps * 2 * pitchError;
      if (available <= 0) continue;
      final low = math.max(pmin, (height - width - gmin) / gaps + pitchError);
      final high = math.min(pmax, (height - gmax) / gaps - pitchError);
      if (low > high) continue;
      final integerLow = low.ceilToDouble(), integerHigh = high.floorToDouble();
      // Integers are cheap useful targets for commonly rounded native pitch;
      // intervals without one remain candidates for genuine fractional pitch.
      final target = integerLow <= integerHigh
        ? p0.roundToDouble().clamp(integerLow, integerHigh).toDouble() : (low + high) / 2;
      candidates.add((low: low, high: high, target: target, rows: rows));
    }
    candidates.sort((a, b) {
      // Native paragraph pitches commonly occupy integer plateaus. Try all
      // intervals containing such a reachable target before spending bounded
      // probes on narrower intervals between two plateaus. Fractional targets
      // remain searchable for backends with genuinely continuous pitch.
      final aInteger = a.low.ceilToDouble() <= a.high.floorToDouble();
      final bInteger = b.low.ceilToDouble() <= b.high.floorToDouble();
      if (aInteger != bInteger) return aInteger ? -1 : 1;
      final delta = (a.target - p0).abs().compareTo((b.target - p0).abs());
      return delta == 0 ? b.rows.compareTo(a.rows) : delta;
    });
    final complete = <double, ReaderFontGeometry?>{lineHeight: first};
    ReaderTypographyPlan? accept(double trial, int expectedRows, double measuredPitch) {
      final gaps = expectedRows - 1;
      // Do not spend scarce complete-inventory checks on a target already at
      // the height boundary with no positive spacing reserve. The complete
      // measurement remains the only acceptance authority for other targets.
      if (height - gaps * (measuredPitch + pitchError) - gmax <= gaps * 1e-6) return null;
      if (!complete.containsKey(trial)) {
        if (fullCount >= 4) return null;
        fullCount++; complete[trial] = fullInventory(fontSize, trial);
      }
      final geometry = complete[trial];
      if (!_valid(geometry) || geometry!.baselineStep < pmin || geometry.baselineStep > pmax) return null;
      final maximum = spacing(geometry, 3);
      if (maximum == null || maximum.rows != expectedRows || maximum.maxSpacing <= 1e-6) return null;
      return result(geometry, trial);
    }
    // First give every nearby interval two inexpensive feedback probes. Keep
    // eight probes for deeper searches; one unattainable platform must not
    // starve all later row counts. Cached measurements are shared by every K.
    for (var pass = 0; pass < 2; pass++) {
      final limit = pass == 0 ? 16 : 24;
      for (final candidate in candidates) {
        final known = cache.entries.where((entry) => entry.value != null &&
          entry.value! >= candidate.low && entry.value! <= candidate.high).toList()
          ..sort((a, b) => (a.key - lineHeight).abs().compareTo((b.key - lineHeight).abs()));
        for (final measurement in known) {
          final accepted = accept(measurement.key, candidate.rows, measurement.value!);
          if (accepted != null) return accepted;
        }
        var left = lowerL, right = upperL;
        for (final measurement in cache.entries) {
          if (measurement.value == null) continue;
          if (measurement.value! < candidate.low) left = math.max(left, measurement.key);
          if (measurement.value! > candidate.high) right = math.min(right, measurement.key);
        }
        if (left >= right) continue;
        var trial = (lineHeight * candidate.target / p0).clamp(left, right).toDouble();
        for (var attempt = 0; attempt < (pass == 0 ? 2 : 8) && cheapCount < limit; attempt++) {
          final measured = probe(trial);
          if (measured == null) break;
          if (measured >= candidate.low && measured <= candidate.high) {
            final accepted = accept(trial, candidate.rows, measured);
            if (accepted != null) return accepted;
            break;
          }
          if (measured < candidate.low) { left = math.max(left, trial); } else { right = math.min(right, trial); }
          final feedback = trial * candidate.target / measured;
          final next = pass == 0 && feedback > left && feedback < right
            ? feedback : (left + right) / 2;
          if ((next - trial).abs() < 1e-8) break;
          trial = next;
        }
      }
    }
    return original != null && original.maxSpacing > 1e-6 ? result(first, lineHeight) : null;
  }

  static bool _valid(ReaderFontGeometry? value) => value != null && value.inventoryComplete &&
    value.supportsUniformStrut && value.baselineStep.isFinite && value.baselineStep > 0 &&
    value.baselineStepMin.isFinite && value.baselineStepMax.isFinite &&
    value.baselineStepMin > 0 && value.baselineStepMin <= value.baselineStepMax &&
    [value.tightTopMin, value.tightTopMax, value.tightBottomMin, value.tightBottomMax].every((number) => number.isFinite);
}
