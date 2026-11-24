import 'dart:math' as math;

/// Paragraph spacing for one measured layout geometry.
///
/// [fixedRows] is false for production flow pagination: [rows] is not a cap.
/// The legacy research certificate instead requires every ordinary page to
/// have [rows] rows. Its rows must share the supplied
/// baseline pitch interval, and every actual tight top/bottom relative to its baseline
/// must lie in the supplied envelope. This class does not measure fonts or
/// establish those premises; a small font probe alone cannot establish them.
/// Paragraph boundaries may occur in any of the rows-1 internal gaps.
/// A source tail containing fewer rows requires an explicit page exemption.
class ReaderSpacingPlan {
  final int rows;
  final double spacing, maxSpacing;
  final double usedMin, usedMax, remainingMin, remainingMax;
  /// Safe margin-band width after reserving native measurement tolerance.
  final double hardWidth;
  /// False for ordinary longest-fit pagination; [rows] is then not a cap.
  final bool fixedRows;
  final double rowPitch;

  const ReaderSpacingPlan._({required this.rows, required this.spacing,
    required this.maxSpacing, required this.usedMin, required this.usedMax,
    required this.remainingMin, required this.remainingMax, required this.hardWidth,
    this.fixedRows = true, this.rowPitch = 0});

  bool acceptsOrdinaryRowCount(int rowCount) => fixedRows ? rowCount == rows : rowCount > 0;
}

/// Fixed paragraph spacing for flow pagination, plus the historical strict
/// certificate retained for isolated mathematical regression tests.
class ReaderSpacingPolicy {
  /// Fixed, visible paragraph spacing with no font snapping or row-count cap.
  /// The longest-fit page leaves less than its next complete row advance;
  /// a paragraph boundary includes the chosen extra spacing in that advance.
  static ReaderSpacingPlan flow({required double height, required double fontSize,
    required double baselinePitch, required int level}) {
    if (![height, fontSize, baselinePitch].every((value) => value.isFinite && value > 0) ||
        level < 0 || level > 3) throw ArgumentError('Invalid flow spacing geometry');
    final spacing = fontSize * level / 4;
    return ReaderSpacingPlan._(rows: 0, spacing: spacing, maxSpacing: fontSize * .75,
      usedMin: 0, usedMax: height, remainingMin: 0,
      remainingMax: baselinePitch + spacing, hardWidth: baselinePitch + spacing,
      fixedRows: false, rowPitch: baselinePitch);
  }

  static const nativeAllowance = 0.5;
  static const _maximumExactInteger = 9007199254740991.0;

  /// Null explicitly means unsupported input or geometry, never a wider band.
  ///
  /// K is independent of level and is the natural maximum row count. The
  /// *absolute* distance from the last tight text bottom to the viewport bottom
  /// must stay in [0, F/2 - nativeAllowance], even with no paragraph boundaries.
  /// Never discard a fitting row to obtain a spacing budget. The caller must
  /// coordinate typography when the requested pitch cannot meet this band.
  /// When only one worst-envelope row physically fits, K=1 is legal and all
  /// spacing levels are zero; no rows are discarded to obtain that result.
  static ReaderSpacingPlan? resolve({required double height, required double fontSize,
    required double baselinePitch, double? baselinePitchMin, double? baselinePitchMax,
    required double tightTopMin, required double tightTopMax,
    required double tightBottomMin, required double tightBottomMax, required int level}) {
    final pitchMin = baselinePitchMin ?? baselinePitch;
    final pitchMax = baselinePitchMax ?? baselinePitch;
    if (level < 0 || level > 3 ||
        ![height, fontSize, baselinePitch, pitchMin, pitchMax, tightTopMin, tightTopMax,
          tightBottomMin, tightBottomMax].every((value) => value.isFinite) ||
        height <= 0 || fontSize <= 0 || baselinePitch <= 0 ||
        pitchMin <= 0 || pitchMin > baselinePitch || pitchMax < baselinePitch ||
        tightTopMin > tightTopMax || tightBottomMin > tightBottomMax ||
        tightBottomMin <= tightTopMax) return null;
    final hardWidth = fontSize / 2 - nativeAllowance;
    final glyphMin = tightBottomMin - tightTopMax;
    final glyphMax = tightBottomMax - tightTopMin;
    final fontSpread = glyphMax - glyphMin;
    if (hardWidth < 0 || fontSpread > hardWidth) return null;
    final availableRows = (height - glyphMax) / pitchMax;
    if (!availableRows.isFinite || availableRows < 0 || availableRows >= _maximumExactInteger) return null;
    final maximumRows = availableRows.floor() + 1;
    final denseRows = (height - glyphMin) / pitchMin;
    if (!denseRows.isFinite || denseRows < 0 || denseRows >= _maximumExactInteger) return null;
    final denseMaximumRows = denseRows.floor() + 1;
    // A worst-envelope page can fit fewer rows than a locally shorter/tighter
    // page. The capacity limit is against that real dense extreme, not merely
    // against the conservative maximum used to establish physical fit.
    if (maximumRows != denseMaximumRows) return null;
    final rows = maximumRows;
    final pitchSpread = pitchMax - pitchMin;
    final gaps = rows - 1;
    final usedMin = gaps * pitchMin + glyphMin;
    if (height - usedMin > hardWidth) return null;
    final widthBudget = hardWidth - fontSpread - gaps * pitchSpread;
    if (widthBudget < 0) return null;
    final baseMax = gaps * pitchMax + glyphMax;
    final maxSpacing = gaps == 0 ? 0.0 : math.max(0.0, math.min(widthBudget, height - baseMax)) / gaps;
    final spacing = maxSpacing * level / 3;
    final usedMax = baseMax + gaps * spacing;
    return ReaderSpacingPlan._(rows: rows, spacing: spacing, maxSpacing: maxSpacing,
      usedMin: usedMin, usedMax: usedMax, remainingMin: height - usedMax,
      remainingMax: height - usedMin, hardWidth: hardWidth);
  }
}
