import 'dart:math';
import 'package:duoduo_langdu/services/reader_page_planner.dart';

/// Legacy research result shapes. The production planner owns all solving.
class FixedSpacingResearchPage {
  final int first, end;
  final double used, remaining;
  const FixedSpacingResearchPage(this.first, this.end, this.used, this.remaining);
  int get rows => end - first;
}

class FixedSpacingResearchPlan {
  final List<FixedSpacingResearchPage> pages;
  final double bandStart, bandEnd;
  final bool includeLastPage;
  final int candidateBands, probes;
  const FixedSpacingResearchPlan(this.pages, this.bandStart, this.bandEnd,
    this.includeLastPage, this.candidateBands, this.probes);

  List<FixedSpacingResearchPage> get measured => includeLastPage ? pages : pages.take(max(0, pages.length - 1)).toList();
  double get minRemaining => measured.isEmpty ? 0 : measured.map((p) => p.remaining).reduce(min);
  double get maxRemaining => measured.isEmpty ? 0 : measured.map((p) => p.remaining).reduce(max);
  double get spread => maxRemaining - minRemaining;
}

class FixedSpacingResearchPlanner {
  static const epsilon = ReaderPagePlanner.defaultEpsilon;
  final List<bool> paragraphBefore;
  final double glyph, line, paragraphExtra, height;
  late final List<double> _positions;
  late final ReaderPagePlanner _strict = _production(includeLastPage: true);
  late final ReaderPagePlanner _endExempt = _production(includeLastPage: false);

  FixedSpacingResearchPlanner(this.paragraphBefore, {
    required this.glyph, required this.line, required this.paragraphExtra, required this.height,
  }) {
    if (glyph <= 0 || line < glyph || paragraphExtra < 0 || height < glyph ||
        ![glyph, line, paragraphExtra, height].every((v) => v.isFinite)) {
      throw ArgumentError('Expected finite fixed geometry with height >= glyph and line >= glyph > 0');
    }
    var breaks = 0;
    _positions = [for (var i = 0; i < paragraphBefore.length; i++)
      i * line + ((breaks += paragraphBefore[i] ? 1 : 0) * paragraphExtra)];
  }

  double used(int first, int end) => glyph + _positions[end - 1] - _positions[first];

  ReaderPagePlanner _production({required bool includeLastPage}) => ReaderPagePlanner(
    _positions, [for (final position in _positions) position + glyph], height: height,
    exemptLastPage: !includeLastPage, epsilon: epsilon);

  FixedSpacingResearchPage _page(ReaderPlannedPage page) =>
    FixedSpacingResearchPage(page.first, page.end, page.used, page.remaining);

  List<FixedSpacingResearchPage> greedy() {
    final pages = _strict.greedy();
    if (pages == null) throw StateError('A constant-height research fixture must fit one row');
    return List.unmodifiable(pages.map(_page));
  }

  /// Retains the research API and its fixed-row geometry, while using exactly
  /// the same candidate enumeration and solver as the real reading screen.
  FixedSpacingResearchPlan solve(double spread, {bool includeLastPage = true}) {
    if (!spread.isFinite || spread < 0 || spread >= line) {
      throw ArgumentError('This prototype requires 0 <= spread < line');
    }
    final plan = (includeLastPage ? _strict : _endExempt).solve(spread);
    if (plan == null) throw StateError('A constant-height research fixture must admit one-row pages');
    return FixedSpacingResearchPlan(List.unmodifiable(plan.pages.map(_page)), plan.bandStart, plan.bandEnd,
      includeLastPage, plan.candidateBands, plan.probes);
  }
}
