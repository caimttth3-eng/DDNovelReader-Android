import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:characters/characters.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/services/reader_font_geometry.dart';
import 'package:duoduo_langdu/services/reader_line_layout.dart';
import 'package:duoduo_langdu/services/reader_page_planner.dart';
import 'package:duoduo_langdu/services/reader_typography.dart';

const _heights = [640, 700, 760, 764, 880];
const _tolerance = .001;
const _reserve = .5;
const _enabled = bool.fromEnvironment('READER_SPACING_CATALOG');
const _fineEnabled = bool.fromEnvironment('READER_SPACING_FINE');

// Opt-in numeric research. No application policy, settings or APK are changed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final font = File('${Platform.environment['SystemRoot']}\\Fonts\\msyh.ttc');
  setUpAll(() async {
    if ((!_enabled && !_fineEnabled) || !font.existsSync()) return;
    await (FontLoader('SpacingCatalogCjk')
      ..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
  });

  test('integer rational model preserves exact zero-height-remainder cases', () {
    final value = _ideal(700, 28, 16);
    expect(value['ideal_intervals'], 15);
    expect(value['ideal_spacing_max'], 0);
    expect(_ideal(700, 39, 16)['ideal_spacing_max'], closeTo(1.95, 1e-10));
    expect(_ideal(760, 64, 24)['ideal_spacing_max'], 8);
    expect(_ideal(764, 39, 24)['ideal_spacing_max'], closeTo(19.5 / 7, 1e-10));
  });

  test('catalog all font sizes, line-height steps and body heights using native font metrics', () async {
    final temp = Directory.systemTemp.absolute.path.replaceAll('\\', '/');
    expect(temp.endsWith('/projects/ddnovelreader/main/temp'), isTrue,
      reason: 'Research outputs belong to the registered portable instance temp');
    const inventory = '田中文阅读小说春风山河，。！？；：“”‘’（）《》0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
    final rows = <Map<String, Object?>>[];
    var profiles = 0, certified = 0;
    for (var size = 14; size <= 64; size++) {
      for (var step = 12; step <= 24; step++) {
        final lineHeight = step / 10;
        final geometry = ReaderFontGeometry.measure(graphemes: inventory.characters,
          fontSize: size.toDouble(), lineHeight: lineHeight, fontFamily: 'SpacingCatalogCjk',
          strutStyle: StrutStyle(fontSize: size.toDouble(), height: lineHeight,
            fontFamily: 'SpacingCatalogCjk', fontWeight: FontWeight.normal, forceStrutHeight: true));
        profiles++;
        for (final height in _heights) {
          final native = _bound(geometry, height.toDouble(), size.toDouble(), tolerance: 0, reserve: 0);
          final safe = _bound(geometry, height.toDouble(), size.toDouble(),
            tolerance: _tolerance, reserve: _reserve);
          final usable = safe == null ? null : (safe.spacing * 100).floor() / 100;
          final minimumGap = geometry.baselineStep - geometry.maxGlyphHeight;
          final row = <String, Object?>{
            'body_height': height, 'font_size': size, 'line_height_setting': lineHeight,
            'native_pitch': geometry.baselineStep,
            'actual_pitch_ratio': geometry.baselineStep / size,
            'native_glyph_min': geometry.tightBottomMin - geometry.tightTopMax,
            'native_glyph_max': geometry.maxGlyphHeight,
            'font_envelope_spread': geometry.fontSpread,
            'uniform_strut': geometry.supportsUniformStrut,
            'inventory_complete': geometry.inventoryComplete,
            ..._ideal(height, size, step),
            'native_envelope_spacing_ceiling': native?.spacing,
            'certified': safe != null,
            'native_rows': safe?.rows,
            'native_safe_spacing_ceiling': safe?.spacing,
            'usable_spacing_floor_001': usable,
            'usable_spacing_font_ratio': usable == null ? null : usable / size,
            'usable_margin_min': safe == null ? null : height -
              (safe.glyphMax + (safe.rows - 1) * safe.pitchMax + (safe.rows - 1) * usable!),
            'usable_margin_max': safe == null ? null : height -
              (safe.glyphMin + (safe.rows - 1) * safe.pitchMin),
            'native_frame_gap': minimumGap,
          };
          if (safe != null) {
            certified++;
            final usedMin = safe.glyphMin + (safe.rows - 1) * safe.pitchMin;
            final usedMax = safe.glyphMax + (safe.rows - 1) * (safe.pitchMax + usable!);
            expect(usedMax, lessThanOrEqualTo(height + 1e-8));
            expect(usedMax - usedMin, lessThanOrEqualTo(size / 2 - _reserve + 1e-8));
            expect(safe.glyphMin + safe.rows * safe.pitchMin, greaterThan(height));
            expect(usable, lessThanOrEqualTo(native!.spacing + 1e-7));
          }
          rows.add(row);
        }
      }
    }
    expect(profiles, 663);
    expect(rows, hasLength(3315));
    final output = File('${Directory.systemTemp.path}${Platform.pathSeparator}reader-spacing-catalog-2026-11-22.json');
    await output.writeAsString(jsonEncode({
      'font_profile': 'Windows Microsoft YaHei, normal and synthetic bold, CJK/Latin/punctuation sample',
      'phone_verified': false,
      'body_heights': _heights,
      'nominal_font_range': [14, 64],
      'line_height_steps': [for (var step = 12; step <= 24; step++) step / 10],
      'native_tolerance': _tolerance, 'margin_reserve': _reserve,
      'usable_spacing_quantum': .01, 'profiles': profiles, 'certified': certified,
      'rows': rows,
    }));
    print('SPACING_CATALOG profiles=$profiles combinations=${rows.length} certified=$certified '
      'path=${output.path}');
  }, skip: !_enabled || !font.existsSync());

  test('fine joint font and normal pitch catalog with compact bottom band', () async {
    final temp = Directory.systemTemp.absolute.path.replaceAll('\\', '/');
    expect(temp.endsWith('/projects/ddnovelreader/main/temp'), isTrue);
    const inventory = '田中文阅读小说春风山河，。！？；：“”‘’（）《》0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
    const bands = {'near_1_6': (1.55, 1.65), 'normal': (1.45, 1.75),
      'extended': (1.35, 1.85)};
    final best = <String, Map<String, Object?>>{};
    var profiles = 0, compactCandidates = 0;
    for (var tenth = 140; tenth <= 640; tenth++) {
      final size = tenth / 10;
      // Native Flutter strut steps in this profile are rounded. Probe every
      // integer target in the extended normal band, then verify actual steps.
      for (var target = (1.35 * size).ceil(); target <= (1.85 * size).floor(); target++) {
        final setting = target / size;
        final geometry = ReaderFontGeometry.measure(graphemes: inventory.characters,
          fontSize: size, lineHeight: setting, fontFamily: 'SpacingCatalogCjk',
          strutStyle: StrutStyle(fontSize: size, height: setting,
            fontFamily: 'SpacingCatalogCjk', fontWeight: FontWeight.normal, forceStrutHeight: true));
        profiles++;
        final ratio = geometry.baselineStep / size;
        for (final height in _heights) {
          final safe = _bound(geometry, height.toDouble(), size,
            tolerance: _tolerance, reserve: _reserve);
          if (safe == null) continue;
          final n = safe.rows - 1;
          final usable = (safe.spacing * 100).floor() / 100;
          final rmin = height - safe.glyphMax - n * (safe.pitchMax + usable);
          final rmax = height - safe.glyphMin - n * safe.pitchMin;
          // Optional compactness criterion, explicitly distinct from spread.
          if (rmax > size / 2 + 1e-8 || usable <= 0) continue;
          compactCandidates++;
          expect(rmin, greaterThanOrEqualTo(-1e-8));
          expect(rmax - rmin, lessThanOrEqualTo(size / 2 - _reserve + 1e-8));
          expect(safe.glyphMin + safe.rows * safe.pitchMin, greaterThan(height));
          final gap = geometry.baselineStep - geometry.maxGlyphHeight;
          for (final band in bands.entries) {
            if (ratio < band.value.$1 - 1e-8 || ratio > band.value.$2 + 1e-8) continue;
            // Each integer UI size gets a +/-0.5 fine-adjustment window.
            for (final nominal in {size.floor(), size.ceil()}) {
              if (nominal < 14 || nominal > 64 || (nominal - size).abs() > .500001) continue;
              final row = <String, Object?>{
                'body_height': height, 'nominal_font': nominal, 'band': band.key,
                'font_size': size, 'line_height_setting': setting,
                'native_pitch': geometry.baselineStep, 'actual_pitch_ratio': ratio,
                'safe_pitch_min': safe.pitchMin, 'safe_pitch_max': safe.pitchMax,
                'native_glyph_min': safe.glyphMin, 'native_glyph_max': safe.glyphMax,
                'rows': safe.rows, 'usable_spacing': usable,
                'safe_spacing_ceiling': safe.spacing,
                'margin_min': rmin, 'margin_max': rmax, 'margin_spread': rmax - rmin,
                'half_font_bound': size / 2, 'ordinary_frame_gap': gap,
                'paragraph_gap_increase_fraction': gap > 0 ? usable / gap : null,
              };
              for (final objective in ['max_spacing', 'max_separation']) {
                if (objective == 'max_separation' && gap <= 0) continue;
                final key = '$height/$nominal/${band.key}/$objective';
                final previous = best[key];
                final score = objective == 'max_spacing' ? usable : usable / gap;
                final oldScore = previous == null ? double.negativeInfinity :
                  (previous[objective == 'max_spacing' ? 'usable_spacing' :
                    'paragraph_gap_increase_fraction'] as double);
                if (score > oldScore + 1e-8 ||
                    ((score - oldScore).abs() < 1e-8 &&
                      (ratio - 1.6).abs() < ((previous!['actual_pitch_ratio'] as double) - 1.6).abs())) {
                  best[key] = {...row, 'objective': objective};
                }
              }
            }
          }
        }
      }
    }
    expect(best.values.where((row) => row['band'] == 'normal'), isNotEmpty);
    var shapedPages = 0;
    for (final row in best.values.where((row) =>
        [39, 40, 41].contains(row['nominal_font']) && row['band'] == 'normal')) {
      shapedPages += await _verifyFinePages(row);
    }
    final output = File('${Directory.systemTemp.path}${Platform.pathSeparator}reader-spacing-fine-2026-11-22.json');
    await output.writeAsString(jsonEncode({
      'font_profile': 'Windows Microsoft YaHei, normal and synthetic bold, CJK/Latin/punctuation sample',
      'phone_verified': false, 'body_heights': _heights,
      'font_range': [14, 64], 'font_step': .1, 'font_adjustment_radius': .5,
      'target_native_pitch_step': 1, 'bands': {
        for (final e in bands.entries) e.key: [e.value.$1, e.value.$2]},
      'compact_margin_max': 'F/2', 'native_tolerance': _tolerance,
      'margin_reserve': _reserve, 'usable_spacing_quantum': .01,
      'profiles': profiles, 'compact_candidates': compactCandidates,
      'native_shaped_pages_forward_and_reverse': shapedPages,
      'rows': best.values.toList(),
    }));
    print('SPACING_FINE profiles=$profiles compact_candidates=$compactCandidates '
      'selected=${best.length} shaped_pages=$shapedPages path=${output.path}');
  }, skip: !_fineEnabled || !font.existsSync());
}

Future<int> _verifyFinePages(Map<String, Object?> row) async {
  final size = row['font_size'] as double, setting = row['line_height_setting'] as double;
  final spacing = row['usable_spacing'] as double;
  final height = (row['body_height'] as int).toDouble();
  final expectedRows = row['rows'] as int;
  const width = 358.0;
  final perLine = (width / size).floor();
  final strut = StrutStyle(fontSize: size, fontFamily: 'SpacingCatalogCjk',
    height: setting, fontWeight: FontWeight.normal, forceStrutHeight: true);
  var checked = 0;
  for (final counts in [<int>[240], List.filled(240, 1),
      List.generate(80, (i) => [1, 2, 7, 3][i % 4])]) {
    final layout = (await ReaderLineLayout.measure([
      for (var i = 0; i < counts.length; i++) ReaderParagraphShapeInput(
        itemIndex: i, textDirection: TextDirection.ltr, strutStyle: strut,
        paddingBefore: i == 0 ? 0 : spacing,
        textSpan: TextSpan(text: ReaderTypography.layout(List.filled(counts[i] * perLine, '田').join()),
          style: TextStyle(fontFamily: 'SpacingCatalogCjk', fontSize: size,
            height: setting, fontWeight: FontWeight.normal))),
    ], maxWidth: width, yieldBudget: const Duration(days: 1)))!;
    expect(layout.lines, hasLength(counts.fold<int>(0, (sum, value) => sum + value)));
    final mirrored = ReaderMeasuredLayout(totalHeight: layout.totalHeight,
      lines: [for (final line in layout.lines.reversed) ReaderMeasuredLine(
        itemIndex: line.itemIndex, layoutOffset: line.layoutOffset, isTitle: false,
        top: layout.totalHeight - line.bottom, bottom: layout.totalHeight - line.top)]);
    for (final measured in [layout, mirrored]) {
      final pages = ReaderPagePlanner(measured.lines.map((line) => line.top).toList(),
        measured.lines.map((line) => line.bottom).toList(), height: height).greedy()!;
      for (final page in pages.where((page) => page.end < measured.lines.length)) {
        expect(page.end - page.first, expectedRows);
        expect(page.remaining, greaterThanOrEqualTo(-.001));
        expect(page.remaining, lessThanOrEqualTo(size / 2 + .001));
        expect(measured.lines[page.end].bottom - measured.lines[page.first].top, greaterThan(height));
        checked++;
      }
    }
  }
  return checked;
}

Map<String, Object?> _ideal(int height, int size, int step) {
  // All nominal inputs are rational tenths. Integer arithmetic avoids the
  // exact 15*44.8=672 boundary accidentally becoming 14 intervals in IEEE754.
  final numerator = 10 * (height - size);
  final pitchNumerator = size * step;
  final intervals = numerator ~/ pitchNumerator;
  final remaining = (numerator - intervals * pitchNumerator) / 10;
  final spacing = math.min(size / 2, remaining) / intervals;
  return {
    'ideal_intervals': intervals, 'ideal_rows': intervals + 1,
    'ideal_spacing_max': spacing,
    'ideal_margin_min': remaining - intervals * spacing,
    'ideal_margin_max': remaining,
  };
}

typedef _Bound = ({int rows, double spacing, double glyphMin, double glyphMax,
  double pitchMin, double pitchMax});

_Bound? _bound(ReaderFontGeometry geometry, double height, double fontSize,
  {required double tolerance, required double reserve}) {
  if (!geometry.supportsUniformStrut || !geometry.inventoryComplete) return null;
  final glyphMin = geometry.tightBottomMin - geometry.tightTopMax - 2 * tolerance;
  final glyphMax = geometry.tightBottomMax - geometry.tightTopMin + 2 * tolerance;
  final pitchMin = geometry.baselineStepMin - tolerance;
  final pitchMax = geometry.baselineStepMax + tolerance;
  if (pitchMin <= 0 || height < glyphMax) return null;
  final n = ((height - glyphMin) / pitchMin).floor();
  if (n < 1 || n != ((height - glyphMax) / pitchMax).floor()) return null;
  final widthBudget = fontSize / 2 - reserve - (glyphMax - glyphMin) - n * (pitchMax - pitchMin);
  final fitBudget = height - glyphMax - n * pitchMax;
  if (widthBudget < 0 || fitBudget < 0) return null;
  return (rows: n + 1, spacing: math.min(widthBudget, fitBudget) / n,
    glyphMin: glyphMin, glyphMax: glyphMax, pitchMin: pitchMin, pitchMax: pitchMax);
}
