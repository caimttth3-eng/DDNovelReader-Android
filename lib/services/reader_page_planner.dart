import 'dart:math' as math;

typedef ReaderFixedPage = ({int first, int end, bool bandExempt});

/// One page over a half-open range of already shaped visual rows.
class ReaderPlannedPage {
  final int first, end, segmentIndex;
  final double used, remaining;
  final bool bandExempt;
  const ReaderPlannedPage(this.first, this.end, this.used, this.remaining,
    this.segmentIndex, this.bandExempt);
  int get rows => end - first;
}

/// An immutable numerical plan. It neither changes row spacing nor shapes text.
class ReaderPagePlan {
  final List<ReaderPlannedPage> pages;
  final double bandStart, bandEnd, epsilon;
  final int candidateBands, evaluatedBands, probes;
  final bool deterministicBands;
  final bool capacityFallback;
  ReaderPagePlan._(List<ReaderPlannedPage> pages, this.bandStart, this.bandEnd,
    this.epsilon, this.candidateBands, this.evaluatedBands, this.probes, this.deterministicBands,
    {this.capacityFallback = false})
    : pages = List.unmodifiable(pages);

  List<ReaderPlannedPage> get measured => pages.where((page) => !page.bandExempt).toList(growable: false);
  double get minRemaining {
    final values = measured;
    return values.isEmpty ? 0 : values.map((page) => page.remaining).reduce(math.min);
  }
  double get maxRemaining {
    final values = measured;
    return values.isEmpty ? 0 : values.map((page) => page.remaining).reduce(math.max);
  }
  double get spread => maxRemaining - minRemaining;

  /// Convert a plan over mirrored row coordinates back to source order.
  ///
  /// The caller mirrors coordinates with `top=extent-originalBottom` and
  /// `bottom=extent-originalTop`, in reverse row order. This operation reverses
  /// page order and maps each half-open cut without reshaping or solving again.
  /// Exemptions follow their exact pages; measured bands and solver diagnostics
  /// retain their meaning. Semantic segments are renumbered in source order.
  ReaderPagePlan reversed(int rowCount) {
    if (rowCount < 0 || (pages.isEmpty ? rowCount != 0 :
        pages.first.first != 0 || pages.last.end != rowCount)) {
      throw ArgumentError.value(rowCount, 'rowCount', 'Must match the complete planned row table');
    }
    final lastSegment = pages.isEmpty ? 0 : pages.last.segmentIndex;
    return ReaderPagePlan._([
      for (final page in pages.reversed) ReaderPlannedPage(
        rowCount - page.end, rowCount - page.first, page.used, page.remaining,
        lastSegment - page.segmentIndex, page.bandExempt),
    ], bandStart, bandEnd, epsilon, candidateBands, evaluatedBands, probes,
      deterministicBands, capacityFallback: capacityFallback);
  }
}

/// Finds a shared bottom-margin band for all supplied segments.
///
/// Coordinates are real shaped-row coordinates, monotone within each segment;
/// coordinates may restart at a forced break. Occupancy is exactly
/// `bottoms[end - 1] - tops[first]`. Forced breaks are row boundaries, not rows
/// to omit. The optional first/last exemptions apply to each segment.
/// Set [exemptSegmentEdges] to false to exempt only the outer 0/N edges.
/// [fixedPages] pin exact page cuts; their explicit exemption overrides all
/// automatic policies. Fixed cuts do not create additional exempt segments.
///
/// The objective is lexicographic: fewest total pages, then the smallest maximum
/// non-exempt margin. No nearest-value rounding or spacing adjustment is used.
class ReaderPagePlanner {
  static const defaultEpsilon = 1e-7;
  final List<double> tops, bottoms;
  final double height, epsilon;
  final bool exemptFirstPage, exemptLastPage, exemptSegmentEdges;
  final List<ReaderFixedPage> fixedPages;
  final _fixedByFirst = <int, ReaderFixedPage>{};
  late final List<int> _segmentStart, _segmentEnd, _segmentIndex;
  late final List<List<_PageEdge>> _edges;
  late final double _minimumBottomStep;

  /// Fill away from the actual entry boundary in both directions. A reverse
  /// page is the longest suffix immediately before [anchor], never a short
  /// remainder produced by paginating from a temporary window origin.
  static ReaderPagePlan? fillFromAnchor(List<double> tops, List<double> bottoms,
    {required double height, required int anchor}) {
    const tolerance = 1e-5;
    final count = tops.length;
    if (count != bottoms.length || anchor < 0 || anchor > count ||
        !height.isFinite || height <= 0) return null;
    for (var i = 0; i < count; i++) {
      if (!tops[i].isFinite || !bottoms[i].isFinite || bottoms[i] <= tops[i] ||
          bottoms[i] - tops[i] > height + tolerance ||
          i > 0 && (tops[i] < tops[i - 1] || bottoms[i] < bottoms[i - 1])) return null;
    }
    final backward = <ReaderPlannedPage>[], forward = <ReaderPlannedPage>[];
    ReaderPlannedPage page(int first, int end, bool limited) {
      final used = bottoms[end - 1] - tops[first];
      return ReaderPlannedPage(first, end, used, math.max(0, height - used), 0, limited);
    }
    for (var end = anchor; end > 0;) {
      var first = end - 1;
      while (first > 0 && bottoms[end - 1] - tops[first - 1] <= height + tolerance) { first--; }
      backward.add(page(first, end, first == 0));
      end = first;
    }
    for (var first = anchor; first < count;) {
      var end = first + 1;
      while (end < count && bottoms[end] - tops[first] <= height + tolerance) { end++; }
      forward.add(page(first, end, end == count));
      first = end;
    }
    final pages = [...backward.reversed, ...forward];
    final measured = pages.where((page) => !page.bandExempt).toList();
    return ReaderPagePlan._(pages,
      measured.isEmpty ? 0 : measured.map((page) => page.remaining).reduce(math.min),
      measured.isEmpty ? 0 : measured.map((page) => page.remaining).reduce(math.max),
      tolerance, 0, 0, count, false);
  }

  /// Partition one real row table in both directions from a fixed boundary.
  ///
  /// Ordinary pages contain exactly [rows] rows and must pass the supplied
  /// global occupancy certificate. Only outer fragments shorter than [rows]
  /// are provisional/exempt; callers decide whether a real source edge permits
  /// displaying them. No graph or greedy fallback is constructed.
  static ReaderPagePlan? fixedRows(List<double> tops, List<double> bottoms, {
    required int rows, required int anchor, required double height,
    required double usedMin, required double usedMax,
  }) {
    const tolerance = 1e-5;
    final count = tops.length;
    if (rows <= 0 || anchor < 0 || anchor > count || count != bottoms.length ||
        !height.isFinite || !usedMin.isFinite || !usedMax.isFinite ||
        height <= 0 || usedMin <= 0 || usedMin > usedMax || usedMax > height + tolerance) return null;
    for (var row = 0; row < count; row++) {
      if (!tops[row].isFinite || !bottoms[row].isFinite || bottoms[row] <= tops[row] ||
          row > 0 && (tops[row] < tops[row - 1] || bottoms[row] < bottoms[row - 1])) return null;
    }
    final pages = <ReaderPlannedPage>[];
    bool append(int first, int end) {
      final used = bottoms[end - 1] - tops[first];
      final exempt = end - first < rows;
      if (!used.isFinite || used <= 0 || used > height + tolerance ||
          !exempt && (used < usedMin - tolerance || used > usedMax + tolerance)) return false;
      pages.add(ReaderPlannedPage(first, end, used, math.max(0.0, height - used), 0, exempt));
      return true;
    }
    var first = 0;
    final leading = anchor % rows;
    if (leading > 0) {
      if (!append(0, leading)) return null;
      first = leading;
    }
    while (first < anchor) {
      if (!append(first, first + rows)) return null;
      first += rows;
    }
    while (first < count) {
      final end = math.min(first + rows, count);
      if (!append(first, end)) return null;
      first = end;
    }
    return ReaderPagePlan._(pages, height - usedMax, height - usedMin,
      tolerance, 0, 0, 0, true);
  }

  ReaderPagePlanner(List<double> tops, List<double> bottoms, {
    required this.height, Iterable<int> forcedBreaks = const [],
    this.exemptFirstPage = false, this.exemptLastPage = true,
    this.exemptSegmentEdges = true, Iterable<ReaderFixedPage> fixedPages = const [],
    this.epsilon = defaultEpsilon,
  }) : tops = List.unmodifiable(tops), bottoms = List.unmodifiable(bottoms),
       fixedPages = List.unmodifiable(fixedPages) {
    if (!height.isFinite || height <= 0 || !epsilon.isFinite || epsilon < 0 || epsilon > 1e-6 || tops.length != bottoms.length) {
      throw ArgumentError('Expected matching row arrays, finite positive height and epsilon in [0, 1e-6]');
    }
    final count = tops.length;
    final boundaries = <int>{0, count};
    for (final boundary in forcedBreaks) {
      if (boundary < 0 || boundary > count) throw ArgumentError.value(boundary, 'forcedBreaks');
      boundaries.add(boundary);
    }
    final cuts = boundaries.toList()..sort();
    final fixed = this.fixedPages.toList()..sort((a, b) => a.first.compareTo(b.first));
    final hardBoundaries = <int>{...boundaries};
    final fixedInterior = List<bool>.filled(count, false);
    var previousEnd = -1;
    for (final page in fixed) {
      if (page.first < 0 || page.end > count || page.first >= page.end || page.first < previousEnd) {
        throw ArgumentError('Fixed pages must be nonempty, within the row table and nonoverlapping');
      }
      if (boundaries.any((boundary) => boundary > page.first && boundary < page.end)) {
        throw ArgumentError('A fixed page cannot cross an explicit forced break');
      }
      previousEnd = page.end;
      _fixedByFirst[page.first] = page;
      hardBoundaries..add(page.first)..add(page.end);
      for (var row = page.first + 1; row < page.end; row++) { fixedInterior[row] = true; }
    }
    // Fixed cuts create hard graph edges, not new semantic segments. Thus they
    // do not change neighbouring pages' automatic exemption policy or indices.
    final hardCuts = hardBoundaries.toList()..sort();
    final hardEnd = List<int>.filled(count, count);
    for (var cut = 0; cut + 1 < hardCuts.length; cut++) {
      for (var row = hardCuts[cut]; row < hardCuts[cut + 1]; row++) { hardEnd[row] = hardCuts[cut + 1]; }
    }
    _segmentStart = List.filled(count, 0);
    _segmentEnd = List.filled(count, 0);
    _segmentIndex = List.filled(count, 0);
    var minimumStep = double.infinity;
    for (var segment = 0; segment + 1 < cuts.length; segment++) {
      final first = cuts[segment], end = cuts[segment + 1];
      for (var row = first; row < end; row++) {
        if (!tops[row].isFinite || !bottoms[row].isFinite || bottoms[row] <= tops[row] ||
            row > first && (tops[row] < tops[row - 1] || bottoms[row] < bottoms[row - 1])) {
          throw ArgumentError('Expected finite positive rows and nondecreasing top/bottom coordinates within each segment');
        }
        if (row > first) minimumStep = math.min(minimumStep, bottoms[row] - bottoms[row - 1]);
        _segmentStart[row] = first; _segmentEnd[row] = end; _segmentIndex[row] = segment;
      }
    }
    _minimumBottomStep = minimumStep;
    _edges = List.generate(count, (first) {
      final edges = <_PageEdge>[];
      if (fixedInterior[first]) return edges;
      final pinned = _fixedByFirst[first];
      if (pinned != null) {
        final occupied = used(first, pinned.end);
        if (occupied <= height + epsilon) edges.add(_PageEdge(pinned.end, occupied, math.max(0, height - occupied)));
        return edges;
      }
      for (var end = first + 1; end <= hardEnd[first]; end++) {
        final occupied = used(first, end);
        if (occupied > height + epsilon) break;
        edges.add(_PageEdge(end, occupied, math.max(0, height - occupied)));
      }
      return edges;
    });
  }

  double used(int first, int end) => bottoms[end - 1] - tops[first];

  bool _exempt(int first, int end) {
    final fixed = _fixedByFirst[first];
    if (fixed != null) return fixed.bandExempt;
    return exemptFirstPage && first == (exemptSegmentEdges ? _segmentStart[first] : 0) ||
      exemptLastPage && end == (exemptSegmentEdges ? _segmentEnd[first] : tops.length);
  }

  /// Unrestricted longest-fit pagination, useful as a lower bound/comparison.
  List<ReaderPlannedPage>? greedy() {
    final pages = <ReaderPlannedPage>[];
    for (var first = 0; first < tops.length;) {
      if (_edges[first].isEmpty) return null;
      final edge = _edges[first].last;
      pages.add(ReaderPlannedPage(first, edge.end, edge.used, edge.remaining,
        _segmentIndex[first], _exempt(first, edge.end)));
      first = edge.end;
    }
    return List.unmodifiable(pages);
  }

  /// Prefer a shared margin band only when it preserves readable capacity.
  ///
  /// The strict solution must use exactly the unrestricted minimum page count,
  /// and each non-exempt page may omit at most one row that could fit from its
  /// own start. Otherwise return the exact longest-fit chain with all existing
  /// fixed/forced constraints and exemptions intact. Its [ReaderPagePlan.bandStart]
  /// and [ReaderPagePlan.bandEnd] report the actual measured margin range, which
  /// may exceed [bandWidth]; callers must not claim the preferred band holds.
  /// [solve] retains its independent strict mathematical contract.
  ReaderPagePlan? solveReadable(double bandWidth) {
    final strict = solve(bandWidth);
    final longest = greedy();
    if (longest == null) return null;
    if (strict != null && strict.pages.length == longest.length &&
        strict.measured.every((page) => _edges[page.first].last.end - page.end <= 1)) {
      return strict;
    }
    var minimum = double.infinity, maximum = 0.0;
    for (final page in longest) {
      if (page.bandExempt) continue;
      minimum = math.min(minimum, page.remaining);
      maximum = math.max(maximum, page.remaining);
    }
    if (!minimum.isFinite) minimum = 0;
    return ReaderPagePlan._(longest, minimum, maximum, epsilon,
      strict?.candidateBands ?? 0, strict?.evaluatedBands ?? 0, strict?.probes ?? 0,
      bandWidth + 2 * epsilon < _minimumBottomStep, capacityFallback: true);
  }

  /// Null means the fixed geometry has no page chain in a shared band.
  ///
  /// Candidate starts are actual feasible-edge margins (plus zero). They are
  /// deduplicated only by exact double equality. Epsilon tolerates at most
  /// 1e-6 logical pixels in comparisons; it never merges distinct candidates.
  ReaderPagePlan? solve(double bandWidth) {
    if (!bandWidth.isFinite || bandWidth < 0) throw ArgumentError.value(bandWidth, 'bandWidth');
    final count = tops.length;
    final deterministic = bandWidth + 2 * epsilon < _minimumBottomStep;
    if (count == 0) return ReaderPagePlan._([], 0, bandWidth, epsilon, 0, 0, 0, deterministic);
    final unrestricted = greedy();
    if (unrestricted == null) return null;
    final candidates = <double>{0};
    final enters = <double>[], leaves = <double>[];
    for (var first = 0; first < count; first++) {
      for (final edge in _edges[first]) {
        if (_exempt(first, edge.end)) continue;
        candidates.add(edge.remaining);
        // A measured edge is valid for A in [R-W-epsilon, R]. Thus every
        // selected set with spread <= W+epsilon has candidate A=min(R).
        enters.add(edge.remaining - bandWidth - epsilon);
        leaves.add(edge.remaining);
      }
    }
    final bands = candidates.toList()..sort();
    enters.sort(); leaves.sort();
    List<ReaderPlannedPage>? bestPages;
    var bestMaximum = double.infinity, bestBand = 0.0;
    var evaluated = 0, probes = 0, oldEnters = -1, oldLeaves = -1;
    final unreachable = count + 1;
    for (final low in bands) {
      if (bestPages != null && bestPages.length == unrestricted.length && low > bestMaximum + epsilon) break;
      final entered = _upperBound(enters, low), departed = _lowerBound(leaves, low);
      if (entered == oldEnters && departed == oldLeaves) continue;
      // No membership event means exactly the same allowed edge set. This is
      // exact event deduplication, not a rounding tolerance over candidate A.
      oldEnters = entered; oldLeaves = departed; evaluated++;
      final costs = List<int>.filled(count + 1, unreachable);
      final maxima = List<double>.filled(count + 1, double.infinity);
      final next = List<int>.filled(count, -1);
      costs[count] = 0; maxima[count] = 0;
      for (var first = count - 1; first >= 0; first--) {
        final edges = _edges[first];
        void consider(_PageEdge edge) {
          probes++;
          final exempt = _exempt(first, edge.end);
          if (costs[edge.end] == unreachable || !exempt &&
              (low < edge.remaining - bandWidth - epsilon || low > edge.remaining)) { return; }
          final cost = costs[edge.end] + 1;
          final maximum = math.max(exempt ? 0.0 : edge.remaining, maxima[edge.end]);
          if (cost < costs[first] || cost == costs[first] &&
              (maximum < maxima[first] || maximum == maxima[first] && edge.end > next[first])) {
            costs[first] = cost; maxima[first] = maximum; next[first] = edge.end;
          }
        }
        if (_fixedByFirst.containsKey(first)) {
          // A fixed measured page must still pass the shared band test; an
          // explicitly exempt fixed page must not enter the normal binary path.
          if (edges.isNotEmpty) consider(edges.single);
        } else if (!deterministic || exemptFirstPage && first == (exemptSegmentEdges ? _segmentStart[first] : 0)) {
          for (final edge in edges) { consider(edge); }
        } else if (exemptLastPage && edges.isNotEmpty &&
            edges.last.end == (exemptSegmentEdges ? _segmentEnd[first] : count)) {
          // Finishing this segment is one page and dominates all detours.
          consider(edges.last);
        } else {
          var left = 0, right = edges.length;
          while (left < right) {
            probes++;
            final middle = (left + right) ~/ 2;
            if (edges[middle].remaining - bandWidth - epsilon > low) { left = middle + 1; }
            else { right = middle; }
          }
          if (left < edges.length) consider(edges[left]);
        }
      }
      if (costs[0] == unreachable || bestPages != null &&
          (costs[0] > bestPages.length || costs[0] == bestPages.length && maxima[0] >= bestMaximum)) { continue; }
      final pages = <ReaderPlannedPage>[];
      for (var first = 0; first < count;) {
        final end = next[first];
        pages.add(ReaderPlannedPage(first, end, used(first, end), math.max(0, height - used(first, end)),
          _segmentIndex[first], _exempt(first, end)));
        first = end;
      }
      bestPages = pages; bestMaximum = maxima[0]; bestBand = low;
      if (bestPages.length == unrestricted.length && bestMaximum == 0) break;
    }
    return bestPages == null ? null : ReaderPagePlan._(bestPages, bestBand, bestBand + bandWidth,
      epsilon, bands.length, evaluated, probes, deterministic);
  }
}

class _PageEdge {
  final int end;
  final double used, remaining;
  const _PageEdge(this.end, this.used, this.remaining);
}
int _lowerBound(List<double> values, double target) {
  var left = 0, right = values.length;
  while (left < right) {
    final middle = (left + right) ~/ 2;
    if (values[middle] < target) { left = middle + 1; } else { right = middle; }
  }
  return left;
}
int _upperBound(List<double> values, double target) {
  var left = 0, right = values.length;
  while (left < right) {
    final middle = (left + right) ~/ 2;
    if (values[middle] <= target) { left = middle + 1; } else { right = middle; }
  }
  return left;
}
