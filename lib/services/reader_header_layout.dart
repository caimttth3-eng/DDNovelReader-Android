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

class ChapterTitleParts {
  final String number;
  final String name;
  const ChapterTitleParts(this.number, this.name);

  /// A bare chapter number or an unnumbered heading remains one whole title.
  static ChapterTitleParts? split(String text) {
    final title = text.trim();
    final match = RegExp(r'^(第\s*[0-9０-９零〇一二三四五六七八九十百千万两兩壹贰貳叁參肆伍陆陸柒捌玖拾佰仟]+\s*(?:章节|章節|章|节|節|回|卷|部|集|篇|话|話)|[卷章]\s*[0-9０-９零〇一二三四五六七八九十百千万两兩壹贰貳叁參肆伍陆陸柒捌玖拾佰仟]+|[0-9０-９]{1,5}(?=[\s:：、.．\-—_])|(?:chapter|section|part|episode)\s*(?:\d+|[IVXLCDM]+)(?=$|[\s:：.\-—]))', caseSensitive: false).firstMatch(title);
    if (match == null) return null;
    final name = title.substring(match.end).replaceFirst(RegExp(r'^[\s:：、.．\-—_]+'), '').trim();
    if (name.isEmpty) return null;
    return ChapterTitleParts(match.group(0)!.trim(), name);
  }
}

class ChapterHeaderContent {
  final String chapterName;
  final Rect nameRect;
  final String? chapterNumber;
  final Rect? numberRect;
  const ChapterHeaderContent({required this.chapterName, required this.nameRect,
    this.chapterNumber, this.numberRect});
}

/// Chooses a horizontal title slot from real obstruction bounds. It never
/// invents a centre camera hole from a safe inset alone.
class ReaderHeaderLayout {
  static const similarSlotWidthRatio = 0.10;
  final Rect titleRect;
  final double topArea;
  final bool sharesCutoutBand;
  final List<Rect> _slots;
  const ReaderHeaderLayout._(this.titleRect, this.topArea, this.sharesCutoutBand, [this._slots = const []]);

  ChapterHeaderContent chapterTitle(String text, {double minNumberWidth = 48, double minNameWidth = 64}) {
    ChapterHeaderContent whole() => ChapterHeaderContent(chapterName: text, nameRect: titleRect);
    final parts = ChapterTitleParts.split(text);
    if (!sharesCutoutBand || parts == null || titleRect.width < minNameWidth) return whole();
    final painter = TextPainter(text: TextSpan(text: parts.number, style: const TextStyle(fontSize: 12)),
      textDirection: TextDirection.ltr, textScaler: TextScaler.noScaling, maxLines: 1)..layout();
    final needed = math.max(minNumberWidth, painter.width + 8);
    painter.dispose();
    Rect? number;
    for (final slot in _slots) {
      if (slot != titleRect && slot.width >= needed && (number == null || slot.width > number.width)) number = slot;
    }
    if (number == null) return whole();
    var name = titleRect;
    if ((name.width - number.width).abs() <= math.max(name.width, number.width) * similarSlotWidthRatio) {
      final left = name.left < number.left ? name : number;
      final right = name.left < number.left ? number : name;
      if (left.width >= needed && right.width >= minNameWidth) {
        number = left;
        name = right;
      }
    }
    return ChapterHeaderContent(chapterName: parts.name, nameRect: name,
      chapterNumber: parts.number, numberRect: number);
  }

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
    final slots = <Rect>[];
    for (final r in obstacles) {
      final start = (r.left - clearance).clamp(left, right).toDouble();
      final end = (r.right + clearance).clamp(left, right).toDouble();
      if (start > cursor) slots.add(Rect.fromLTWH(cursor, (band - line) / 2, start - cursor, line));
      if (start - cursor > bestRight - bestLeft) { bestLeft = cursor; bestRight = start; }
      cursor = math.max(cursor, end);
    }
    if (right > cursor) slots.add(Rect.fromLTWH(cursor, (band - line) / 2, right - cursor, line));
    if (right - cursor > bestRight - bestLeft) { bestLeft = cursor; bestRight = right; }
    if (bestRight <= bestLeft) return below(band);
    return ReaderHeaderLayout._(Rect.fromLTWH(bestLeft, (band - line) / 2, bestRight - bestLeft, line), band, true, List.unmodifiable(slots));
  }
}
