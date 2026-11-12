import 'dart:math' as math;
import 'package:flutter/painting.dart';

/// All dimensions are relative to the Flutter viewport in logical pixels.
class DisplayCutoutGeometry {
  final Size viewport;
  final List<Rect> cutouts;
  final EdgeInsets safeInsets;
  final double topLeftRadius;
  final double topRightRadius;
  final double statusBarTop;
  final bool statusBarVisible;

  const DisplayCutoutGeometry({required this.viewport, this.cutouts = const [],
    this.safeInsets = EdgeInsets.zero, this.topLeftRadius = 0,
    this.topRightRadius = 0, this.statusBarTop = 0, this.statusBarVisible = false});

  bool matches(Size size) => (viewport.width - size.width).abs() <= 1 &&
    (viewport.height - size.height).abs() <= 1;
}

/// Chooses a horizontal title slot from real obstruction bounds. It never
/// invents a centre camera hole from a safe inset alone.
class ReaderHeaderLayout {
  final Rect titleRect;
  final double topArea;
  final bool sharesCutoutBand;
  const ReaderHeaderLayout._(this.titleRect, this.topArea, this.sharesCutoutBand);

  static ReaderHeaderLayout compute({required Size viewport, required EdgeInsets safeInsets,
    List<Rect> cutouts = const [], double topLeftRadius = 0, double topRightRadius = 0,
    bool statusBarVisible = false, double statusBarTop = 0}) {
    const line = 24.0, clearance = 4.0;
    final width = math.max(0.0, viewport.width);
    final left = math.max(8.0, math.max(safeInsets.left, topLeftRadius)).clamp(0.0, width).toDouble();
    final right = (width - math.max(8.0, math.max(safeInsets.right, topRightRadius))).clamp(left, width).toDouble();
    final valid = cutouts.where((r) => r.isFinite && !r.isEmpty && r.overlaps(Offset.zero & viewport)).toList();
    var band = math.max(line, safeInsets.top);
    for (final r in valid) {
      final nearestTop = r.center.dy <= r.center.dx && r.center.dy <= width - r.center.dx &&
        r.center.dy <= viewport.height - r.center.dy;
      if (nearestTop) band = math.max(band, r.bottom);
    }
    ReaderHeaderLayout below(double top) => ReaderHeaderLayout._(
      Rect.fromLTWH(left, top, right - left, line), top + line, false);
    if (statusBarVisible) return below(math.max(band, statusBarTop));
    final obstacles = valid.where((r) => r.top < band && r.bottom > 0).toList()
      ..sort((a, b) => a.left.compareTo(b.left));
    if (obstacles.isEmpty) return below(math.max(0.0, safeInsets.top));
    var cursor = left;
    var bestLeft = left, bestRight = left;
    for (final r in obstacles) {
      final start = (r.left - clearance).clamp(left, right).toDouble();
      final end = (r.right + clearance).clamp(left, right).toDouble();
      if (start - cursor > bestRight - bestLeft) { bestLeft = cursor; bestRight = start; }
      cursor = math.max(cursor, end);
    }
    if (right - cursor > bestRight - bestLeft) { bestLeft = cursor; bestRight = right; }
    if (bestRight <= bestLeft) return below(band);
    return ReaderHeaderLayout._(Rect.fromLTWH(bestLeft, (band - line) / 2, bestRight - bestLeft, line), band, true);
  }
}
