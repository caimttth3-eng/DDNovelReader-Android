import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:characters/characters.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart' show TextSelection;

/// Native observations for one exact font/strut/scaler/locale identity.
///
/// This is an envelope of the supplied inventory and finite paragraph probes,
/// not a proof that every contextual glyph form or future fallback font is
/// covered. A caller promising a hard page bound must validate actual pages
/// against its chosen global band and reject/recompute an unsupported layout.
class ReaderFontGeometry {
  const ReaderFontGeometry({
    required this.baselineStep,
    required this.baselineStepMin,
    required this.baselineStepMax,
    required this.firstBaseline,
    required this.tightTopMin,
    required this.tightTopMax,
    required this.tightBottomMin,
    required this.tightBottomMax,
    required this.supportsUniformStrut,
    required this.measuredClusters,
    required this.unmeasuredClusters,
    this.selectionQueries = 0,
  });

  /// Native paragraph height/step, deliberately not fontSize * lineHeight.
  final double baselineStep, baselineStepMin, baselineStepMax, firstBaseline;
  final double tightTopMin, tightTopMax, tightBottomMin, tightBottomMax;
  final bool supportsUniformStrut;
  /// Inventory cluster/weight pairs covered by complete native selections.
  /// These counts do not imply an individual selection query for each cluster.
  final int measuredClusters, unmeasuredClusters;
  /// Native tight-selection queries; independent of inventory cardinality.
  final int selectionQueries;
  bool get inventoryComplete => measuredClusters > 0 && unmeasuredClusters == 0;
  double get fontSpread => tightTopMax - tightTopMin + tightBottomMax - tightBottomMin;
  double get maxGlyphHeight => tightBottomMax - tightTopMin;

  /// Runs only on the UI isolate; retains no painter, paragraph, font, or text.
  static ReaderFontGeometry measure({
    required Iterable<String> graphemes,
    required double fontSize,
    required double lineHeight,
    String? fontFamily,
    List<String>? fontFamilyFallback,
    TextStyle inheritedStyle = const TextStyle(),
    TextScaler textScaler = TextScaler.noScaling,
    TextDirection textDirection = TextDirection.ltr,
    ui.Locale? locale,
    ui.TextHeightBehavior? textHeightBehavior,
    StrutStyle? strutStyle,
    double measurementTolerance = 1e-3,
  }) {
    if (!fontSize.isFinite || fontSize <= 0 || !lineHeight.isFinite || lineHeight <= 0 ||
        !measurementTolerance.isFinite || measurementTolerance < 0) {
      throw ArgumentError('Expected finite positive font size/line height and a nonnegative measurement tolerance');
    }
    final inventory = graphemes.expand((text) => text.characters)
      .where((cluster) => cluster.isNotEmpty && !_nonGlyphControl(cluster)).toSet().toList();
    final base = inheritedStyle.merge(TextStyle(fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback, fontSize: fontSize,
      height: lineHeight, letterSpacing: 0, fontWeight: FontWeight.normal));
    final strut = strutStyle ?? StrutStyle(fontFamily: fontFamily ?? base.fontFamily,
      fontFamilyFallback: fontFamilyFallback ?? base.fontFamilyFallback,
      fontSize: fontSize, height: lineHeight, fontWeight: FontWeight.normal, forceStrutHeight: true);
    TextPainter painter(String text, FontWeight weight) => TextPainter(
      text: TextSpan(text: text, style: base.copyWith(fontWeight: weight)),
      strutStyle: strut, textScaler: textScaler, textDirection: textDirection,
      locale: locale, textHeightBehavior: textHeightBehavior, textAlign: TextAlign.left);

    final profiles = <_FontProfile>[];
    final reference = inventory.firstWhere((cluster) => cluster.trim().isNotEmpty, orElse: () => 'Hg');
    final mixed = inventory.take(24).join();
    for (final weight in <FontWeight>[FontWeight.normal, FontWeight.bold]) {
      for (final count in <int>[1, 2, 5, 11]) {
        profiles.add(_profile(painter(List.filled(count, reference).join('\n'), weight)));
      }
      if (mixed.isNotEmpty) profiles.add(_profile(painter(List.filled(5, mixed).join('\n'), weight)));
    }
    final step = profiles.first.height;
    var minimumStep = double.infinity, maximumStep = double.negativeInfinity;
    var minimumFirst = double.infinity, maximumFirst = double.negativeInfinity;
    var heightResidual = 0.0;
    for (final profile in profiles) {
      minimumFirst = math.min(minimumFirst, profile.baselines.first);
      maximumFirst = math.max(maximumFirst, profile.baselines.first);
      heightResidual = math.max(heightResidual, (profile.height - profile.baselines.length * step).abs());
      for (var i = 1; i < profile.baselines.length; i++) {
        final advance = profile.baselines[i] - profile.baselines[i - 1];
        minimumStep = math.min(minimumStep, advance); maximumStep = math.max(maximumStep, advance);
      }
      for (final next in profiles) {
        final advance = profile.height + next.baselines.first - profile.baselines.last;
        minimumStep = math.min(minimumStep, advance); maximumStep = math.max(maximumStep, advance);
      }
    }

    var tmin = double.infinity, tmax = double.negativeInfinity;
    var bmin = double.infinity, bmax = double.negativeInfinity;
    var measured = 0, unmeasured = 0, selectionQueries = 0;
    void collect(List<ui.TextBox> boxes, double baseline) {
      // Keep zero-width marks with real vertical metrics. A whole inventory
      // union would lose the short-font tmax/bmin needed by the spread bound.
      for (final box in boxes) {
        if (!box.top.isFinite || !box.bottom.isFinite || box.bottom <= box.top) continue;
        final top = box.top - baseline, bottom = box.bottom - baseline;
        tmin = math.min(tmin, top); tmax = math.max(tmax, top);
        bmin = math.min(bmin, bottom); bmax = math.max(bmax, bottom);
      }
    }
    for (final weight in <FontWeight>[FontWeight.normal, FontWeight.bold]) {
      if (inventory.isEmpty) break;
      final inventoryText = inventory.join();
      final value = painter(inventoryText, weight);
      try {
        value.layout(); // Infinite width avoids making the inventory a page.
        final lines = value.computeLineMetrics();
        if (lines.length != 1) {
          unmeasured += inventory.length;
          continue;
        }
        final baseline = lines.single.baseline;
        minimumFirst = math.min(minimumFirst, baseline); maximumFirst = math.max(maximumFirst, baseline);
        // tight returns per-run heights, unlike max's common line height.
        // Selecting the complete UTF-16 range encloses contextual ligatures
        // and combining/ZWJ glyphs that partial cluster selections may omit.
        // Preserve every raw run box: one outer union would lose tmax/bmin.
        selectionQueries++;
        final selected = value.getBoxesForSelection(
          TextSelection(baseOffset: 0, extentOffset: inventoryText.length), boxHeightStyle: ui.BoxHeightStyle.tight)
          .where((box) => box.top.isFinite && box.bottom.isFinite && box.bottom > box.top).toList();
        if (selected.isEmpty) { unmeasured += inventory.length; }
        else { collect(selected, baseline); measured += inventory.length; }
      } finally { value.dispose(); }
    }
    final hasEnvelope = measured > 0 && tmin.isFinite && bmax.isFinite;
    return ReaderFontGeometry(baselineStep: step, baselineStepMin: minimumStep,
      baselineStepMax: maximumStep, firstBaseline: profiles.first.baselines.first,
      tightTopMin: hasEnvelope ? tmin : 0, tightTopMax: hasEnvelope ? tmax : 0,
      tightBottomMin: hasEnvelope ? bmin : 0, tightBottomMax: hasEnvelope ? bmax : 0,
      supportsUniformStrut: hasEnvelope && step.isFinite && step > 0 &&
        maximumStep - minimumStep <= measurementTolerance &&
        maximumFirst - minimumFirst <= measurementTolerance && heightResidual <= measurementTolerance,
      measuredClusters: measured, unmeasuredClusters: unmeasured, selectionQueries: selectionQueries);
  }

  static bool _nonGlyphControl(String text) => text.trim().isEmpty || text.runes.every((rune) =>
    rune == 0x0a || rune == 0x0d || rune == 0x2028 || rune == 0x2029 ||
    rune == 0x200b || rune == 0x200c || rune == 0x200d || rune == 0x2060 ||
    rune == 0xfeff || rune == 0xfe0e || rune == 0xfe0f ||
    rune >= 0x202a && rune <= 0x202e || rune >= 0x2066 && rune <= 0x2069);
}

class _FontProfile {
  const _FontProfile(this.height, this.baselines);
  final double height;
  final List<double> baselines;
}

_FontProfile _profile(TextPainter painter) {
  try {
    painter.layout();
    final metrics = painter.computeLineMetrics();
    if (metrics.isEmpty) throw StateError('A native strut probe did not produce a line');
    return _FontProfile(painter.height, [for (final line in metrics) line.baseline]);
  } finally { painter.dispose(); }
}
