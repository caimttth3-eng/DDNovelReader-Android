import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// The complete span and rendering constraints of one existing reader item.
///
/// Shaping is deliberately performed on the original span, never on page-sized
/// substrings. Call this service on the UI isolate, where Flutter shaping lives.
class ReaderParagraphShapeInput {
  ReaderParagraphShapeInput({
    required this.itemIndex,
    required this.textSpan,
    required this.textDirection,
    this.textScaler = TextScaler.noScaling,
    this.textAlign = TextAlign.justify,
    this.maxWidth,
    this.indentWidth,
    List<PlaceholderDimensions> placeholderDimensions = const [],
    this.paddingBefore = 0,
    this.paddingAfter = 0,
    this.isTitle = false,
    this.locale,
    this.strutStyle,
    this.textHeightBehavior,
    this.textWidthBasis = TextWidthBasis.parent,
  }) : placeholderDimensions = List.unmodifiable(placeholderDimensions);

  final int itemIndex;
  final InlineSpan textSpan;
  final TextDirection textDirection;
  final TextScaler textScaler;
  final TextAlign textAlign;
  final double? maxWidth;
  final double? indentWidth;
  final List<PlaceholderDimensions> placeholderDimensions;
  final double paddingBefore;
  final double paddingAfter;
  final bool isTitle;
  final ui.Locale? locale;
  final StrutStyle? strutStyle;
  final ui.TextHeightBehavior? textHeightBehavior;
  final TextWidthBasis textWidthBasis;
}

/// An actual visual row in chapter-local coordinates, including its item padding.
class ReaderMeasuredLine {
  const ReaderMeasuredLine({
    required this.itemIndex,
    required this.layoutOffset,
    required this.top,
    required this.bottom,
    required this.isTitle,
  });

  String get key => '$itemIndex/$layoutOffset';
  final int itemIndex;
  final int layoutOffset;
  final double top;
  final double bottom;
  final bool isTitle;
}

/// Numeric geometry only: no painter, span, render object, or widget is retained.
class ReaderMeasuredLayout {
  ReaderMeasuredLayout({required List<ReaderMeasuredLine> lines, required this.totalHeight})
    : lines = List.unmodifiable(lines);

  final List<ReaderMeasuredLine> lines;
  final double totalHeight;
}

class ReaderLineLayout {
  /// Measures complete items with the same tight-box union and logical row keys
  /// as the reader's RenderParagraph path. Cancellation never publishes a table.
  ///
  /// The budget is cooperative: a single native layout/selection call cannot be
  /// interrupted. Yielding defaults to an event-loop turn, never waits for a
  /// frame, and can be replaced by the caller's own UI scheduling policy.
  static Future<ReaderMeasuredLayout?> measure(
    Iterable<ReaderParagraphShapeInput> inputs, {
    required double maxWidth,
    bool Function()? isCurrent,
    Duration yieldBudget = const Duration(milliseconds: 4),
    Future<void> Function()? onYield,
  }) async {
    if (isCurrent?.call() == false) return null;
    _positiveWidth(maxWidth);
    if (yieldBudget.isNegative) throw ArgumentError.value(yieldBudget, 'yieldBudget');
    final paragraphs = List<ReaderParagraphShapeInput>.of(inputs);
    final seen = <int>{};
    for (final paragraph in paragraphs) {
      if (!seen.add(paragraph.itemIndex)) {
        throw ArgumentError.value(paragraph.itemIndex, 'itemIndex', 'Item indices must be unique');
      }
      _positiveWidth(paragraph.maxWidth ?? maxWidth);
      if (!paragraph.paddingBefore.isFinite || paragraph.paddingBefore < 0 ||
          !paragraph.paddingAfter.isFinite || paragraph.paddingAfter < 0 ||
          paragraph.indentWidth != null && (!paragraph.indentWidth!.isFinite || paragraph.indentWidth! < 0)) {
        throw ArgumentError('Reader item spacing must be finite and nonnegative');
      }
    }

    final lines = <ReaderMeasuredLine>[];
    final clock = Stopwatch()..start();
    final budget = yieldBudget.inMicroseconds;
    var cursor = 0.0;
    Future<bool> cooperate() async {
      if (isCurrent?.call() == false) return false;
      if (onYield != null) {
        await onYield();
      } else {
        await Future<void>.delayed(Duration.zero);
      }
      clock.reset();
      return isCurrent?.call() != false;
    }

    for (final input in paragraphs) {
      if (isCurrent?.call() == false) return null;
      final width = input.maxWidth ?? maxWidth;
      final painter = TextPainter(
        text: input.textSpan,
        textAlign: input.textAlign,
        textDirection: input.textDirection,
        textScaler: input.textScaler,
        locale: input.locale,
        strutStyle: input.strutStyle,
        textHeightBehavior: input.textHeightBehavior,
        textWidthBasis: input.textWidthBasis,
      );
      try {
        if (input.placeholderDimensions.isNotEmpty) {
          painter.setPlaceholderDimensions(input.placeholderDimensions);
        } else if (input.indentWidth != null) {
          painter.setPlaceholderDimensions([
            PlaceholderDimensions(size: ui.Size(input.indentWidth!, 1), alignment: ui.PlaceholderAlignment.middle),
          ]);
        }
        // Reader items fill their sliver column, including centered headings.
        painter.layout(minWidth: width, maxWidth: width);
        final rowBoxes = <int, ui.Rect>{};
        final boxes = painter.getBoxesForSelection(
          TextSelection(baseOffset: 0, extentOffset: input.textSpan.toPlainText().length),
          boxHeightStyle: ui.BoxHeightStyle.tight,
        );
        for (final box in boxes) {
          final rect = box.toRect();
          // A one-pixel indentation placeholder is not a body glyph row.
          if (rect.width >= 0.01 && rect.height >= 2) {
            final left = painter.getPositionForOffset(ui.Offset(-1, rect.center.dy)).offset;
            final right = painter.getPositionForOffset(ui.Offset(width + 1, rect.center.dy)).offset;
            final offset = math.min(left, right);
            rowBoxes.update(offset, (previous) => previous.expandToInclude(rect), ifAbsent: () => rect);
          }
          if (clock.elapsedMicroseconds >= budget && !(await cooperate())) return null;
        }
        final origin = cursor + input.paddingBefore;
        final rows = rowBoxes.entries.toList()
          ..sort((a, b) => a.value.top.compareTo(b.value.top));
        for (final row in rows) {
          lines.add(ReaderMeasuredLine(itemIndex: input.itemIndex, layoutOffset: row.key,
            top: origin + row.value.top, bottom: origin + row.value.bottom, isTitle: input.isTitle));
        }
        cursor = origin + painter.height + input.paddingAfter;
      } finally {
        painter.dispose();
      }
      if (clock.elapsedMicroseconds >= budget && !(await cooperate())) return null;
    }
    if (isCurrent?.call() == false) return null;
    return ReaderMeasuredLayout(lines: lines, totalHeight: cursor);
  }

  static void _positiveWidth(double width) {
    if (!width.isFinite || width <= 0) throw ArgumentError.value(width, 'maxWidth', 'Must be finite and positive');
  }
}
