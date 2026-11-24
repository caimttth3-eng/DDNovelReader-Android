import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixed_spacing_planner_research.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final font = File('${Platform.environment['SystemRoot']}\\Fonts\\msyh.ttc');
  setUpAll(() async {
    if (font.existsSync()) {
      await (FontLoader('PagePlanningResearchCjk')
        ..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
    }
  });

  test('joint fixed-spacing plan moves a line to the next page without adding pages', () {
    final planner = FixedSpacingResearchPlanner(_paragraphs([1, 2, 6]), glyph: 20,
      line: 30, paragraphExtra: 10, height: 120);
    expect(planner.greedy().map((p) => p.rows), [3, 4, 2]);
    expect(planner.greedy().map((p) => p.remaining), [30, 10, 70]);
    final plan = planner.solve(10);
    expect(plan.pages.map((p) => p.rows), [3, 3, 3]);
    expect(plan.pages.map((p) => p.remaining), [30, 40, 40]);
    _verify(planner, plan, 9, 10);
  });

  test('end-page policy changes capacity and cannot silently be relaxed', () {
    final planner = FixedSpacingResearchPlanner(_paragraphs([1, 4]), glyph: 20,
      line: 30, paragraphExtra: 10, height: 90);
    final strict = planner.solve(10), exempt = planner.solve(10, includeLastPage: false);
    expect(strict.pages.length, 5);
    expect(exempt.pages.length, 2);
    _verify(planner, strict, 5, 10);
    _verify(planner, exempt, 5, 10);
  });

  test('optimized deterministic-band solver agrees with independent cut enumeration', () {
    for (var seed = 1; seed <= 120; seed++) {
      final bits = _randomRows(14, seed, 50);
      final planner = FixedSpacingResearchPlanner(bits, glyph: 20,
        line: 30, paragraphExtra: 10, height: 120);
      final plan = planner.solve(10);
      expect(plan.pages.length, _brute(bits, 20, 30, 10, 120, 10), reason: 'seed $seed');
      _verify(planner, plan, bits.length, 10);
    }
  });

  test('reports strict and end-exempt capacity Pareto with fixed gaps', () {
    final samples = <String, List<bool>>{
      'long': List.filled(300, false),
      'single': [false, ...List.filled(299, true)],
      'mixed': [false, for (var i = 0; i < 299; i++) i >= 99 && i < 199],
      'random30': _randomRows(300, 11, 30),
    };
    for (final entry in samples.entries) {
      for (final extra in [4.0, 20.0]) {
        final planner = FixedSpacingResearchPlanner(entry.value, glyph: 40,
          line: 60, paragraphExtra: extra, height: 686);
        for (final strict in [true, false]) {
          final plan = planner.solve(20, includeLastPage: strict);
          _verify(planner, plan, 300, 20);
          debugPrint('PLAN_CAPACITY ${jsonEncode(_summary(entry.key, extra, planner, plan))}');
        }
      }
    }
  });

  test('pure numeric planning can execute outside the UI isolate', () async {
    for (final rows in [10000, 100000]) {
      final input = _randomRows(rows, 11, 30);
      final roundTrip = Stopwatch()..start();
      final result = await Isolate.run(() {
        final planner = FixedSpacingResearchPlanner(input,
          glyph: 40, line: 60, paragraphExtra: 20, height: 686);
        final watch = Stopwatch()..start();
        final plan = planner.solve(20, includeLastPage: false);
        watch.stop();
        return (plan, watch.elapsedMicroseconds);
      });
      roundTrip.stop();
      expect(result.$1.spread, lessThanOrEqualTo(20 + 1e-7));
      debugPrint('PLAN_WORKER rows=$rows pages=${result.$1.pages.length} bands=${result.$1.candidateBands} '
        'probes=${result.$1.probes} solveMicros=${result.$2} roundTripMicros=${roundTrip.elapsedMicroseconds}');
    }
  });

  test('real CJK shaping supplies a lossless line ledger to fixed-spacing planner', () async {
    const phrase = '山间的风吹过树林，远处的小路延伸到村庄。';
    final flags = <bool>[], ledger = <(int, int, int)>[];
    var safeHeight = 0.0, baseline = 0.0, characters = 0;
    final watch = Stopwatch()..start();
    for (var paragraph = 0; paragraph < 60; paragraph++) {
      final repeats = [0, 2, 5, 12, 0, 1, 3, 8][paragraph % 8];
      final body = repeats == 0 ? '风吹。' : List.filled(repeats, phrase).join();
      final text = '　　$body';
      characters += text.length;
      final painter = TextPainter(text: TextSpan(text: text, style: const TextStyle(
        fontFamily: 'PagePlanningResearchCjk', fontSize: 39, height: 1.6)),
        textDirection: ui.TextDirection.ltr, textAlign: TextAlign.justify);
      try {
        painter.layout(maxWidth: 328);
        final metrics = painter.computeLineMetrics();
        for (final box in painter.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: text.length),
          boxHeightStyle: ui.BoxHeightStyle.tight)) {
          if (box.right - box.left > 0.01) safeHeight = max(safeHeight, box.bottom - box.top);
        }
        var previousEnd = 0;
        for (var row = 0; row < metrics.length; row++) {
          final metric = metrics[row];
          if (row > 0) baseline = max(baseline, metric.baseline - metrics[row - 1].baseline);
          final point = painter.getPositionForOffset(Offset(-1, metric.baseline - metric.ascent / 2));
          final range = painter.getLineBoundary(point);
          expect(range.start, previousEnd);
          previousEnd = range.end;
          flags.add(paragraph > 0 && row == 0);
          ledger.add((paragraph, range.start, range.end));
        }
        expect(previousEnd, text.length);
      } finally { painter.dispose(); }
    }
    watch.stop();
    expect(safeHeight, greaterThan(0)); expect(baseline, greaterThanOrEqualTo(safeHeight));
    final shapeMicros = watch.elapsedMicroseconds;
    final snapshot = (List<bool>.of(flags), safeHeight, baseline);
    final roundTrip = Stopwatch()..start();
    final result = await Isolate.run(() {
      final profiles = <(double, bool, FixedSpacingResearchPlan, int)>[];
      for (final ratio in [0.05, 0.10, 0.25, 0.50]) {
        final planner = FixedSpacingResearchPlanner(snapshot.$1, glyph: snapshot.$2,
          line: snapshot.$3, paragraphExtra: 39 * ratio, height: 700);
        for (final strict in [true, false]) {
          final timer = Stopwatch()..start();
          final plan = planner.solve(39 / 2, includeLastPage: strict);
          timer.stop(); profiles.add((ratio, strict, plan, timer.elapsedMicroseconds));
        }
      }
      return profiles;
    });
    roundTrip.stop();
    for (final profile in result) {
      final (ratio, strict, plan, micros) = profile;
      final checker = FixedSpacingResearchPlanner(flags, glyph: safeHeight,
        line: baseline, paragraphExtra: 39 * ratio, height: 700);
      _verify(checker, plan, ledger.length, 39 / 2);
      expect(plan.pages.expand((p) => ledger.sublist(p.first, p.end)).length, ledger.length);
      final natural = checker.greedy(), greedy = strict ? natural : natural.take(natural.length - 1).toList();
      debugPrint('PLAN_CJK ${jsonEncode({'paragraphs': 60, 'characters': characters, 'rows': flags.length,
        'em': 39, 'extraRatio': ratio, 'extraParagraphGap': 39 * ratio, 'spreadLimit': 39 / 2,
        'includeLast': strict, 'glyph': safeHeight, 'baseline': baseline, 'shapeMicros': shapeMicros,
        'plannerMicros': micros, 'allProfilesRoundTripMicros': roundTrip.elapsedMicroseconds, 'pages': plan.pages.length,
        'greedyPages': natural.length,
        'greedySpread': greedy.map((p) => p.remaining).reduce(max) - greedy.map((p) => p.remaining).reduce(min),
        'remainingMin': plan.minRemaining, 'remainingMax': plan.maxRemaining})}');
    }
  }, skip: !font.existsSync());
}

List<bool> _paragraphs(List<int> lengths) => [
  for (var paragraph = 0; paragraph < lengths.length; paragraph++)
    for (var row = 0; row < lengths[paragraph]; row++) paragraph > 0 && row == 0,
];

List<bool> _randomRows(int count, int seed, int percent) {
  var state = seed;
  return [false, for (var i = 1; i < count; i++)
    ((state = (state * 1664525 + 1013904223) & 0xffffffff) / 4294967296) * 100 < percent];
}

void _verify(FixedSpacingResearchPlanner planner, FixedSpacingResearchPlan plan, int total, double width) {
  var expected = 0;
  for (final page in plan.pages) {
    expect(page.first, expected); expect(page.end, greaterThan(page.first));
    expect(page.used, closeTo(planner.used(page.first, page.end), 1e-7));
    expect(page.remaining, greaterThanOrEqualTo(-1e-7));
    expect(page.used + page.remaining, closeTo(planner.height, 1e-7));
    expected = page.end;
  }
  expect(expected, total);
  expect(plan.spread, lessThanOrEqualTo(width + 1e-7));
}

int _brute(List<bool> bits, double glyph, double line, double extra, double height, double width) {
  var best = bits.length + 1;
  void walk(int start, int count, double low, double high) {
    if (count >= best) return;
    if (start == bits.length) { best = count; return; }
    var used = glyph;
    for (var end = start; end < bits.length; end++) {
      if (end > start) used += line + (bits[end] ? extra : 0);
      if (used > height + 1e-7) break;
      final remaining = height - used, lo = min(low, remaining), hi = max(high, remaining);
      if (hi - lo <= width + 1e-7) walk(end + 1, count + 1, lo, hi);
    }
  }
  walk(0, 0, double.infinity, double.negativeInfinity);
  return best;
}

Map<String, Object> _summary(String name, double extra, FixedSpacingResearchPlanner planner, FixedSpacingResearchPlan plan) {
  final counted = plan.measured;
  return {'name': name, 'extra': extra, 'includeLast': plan.includeLastPage,
    'greedyPages': planner.greedy().length, 'pages': plan.pages.length,
    'rowsMin': counted.map((p) => p.rows).reduce(min), 'rowsMax': counted.map((p) => p.rows).reduce(max),
    'remainingMin': plan.minRemaining, 'remainingMax': plan.maxRemaining,
    'bands': plan.candidateBands, 'probes': plan.probes};
}
