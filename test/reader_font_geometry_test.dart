import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:characters/characters.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/services/reader_font_geometry.dart';

const _text = '中文标题AgÉ，山间的小路通向村庄。abcΩЖe\u0301';
const _families = <String, List<String>>{
  'GeometryTestSans': ['msyh.ttc', 'msyhbd.ttc'],
  'GeometryTestSerif': ['simsun.ttc'],
  'GeometryTestLatin': ['arial.ttf', 'arialbd.ttf'],
};
File _font(String file) => File('${Platform.environment['SystemRoot']}\\Fonts\\$file');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final entry in _families.entries) {
      if (!_font(entry.value.first).existsSync()) continue;
      final loader = FontLoader(entry.key);
      for (final name in entry.value) {
        if (_font(name).existsSync()) {
          loader.addFont(_font(name).readAsBytes().then((bytes) => ByteData.sublistView(bytes)));
        }
      }
      await loader.load();
    }
  });

  for (final family in _families.keys) {
    for (final dimensions in <(double, double)>[(14, 1.6), (26, 1.6), (39, 1.2), (39, 1.6), (39, 2.4), (64, 1.6)]) {
      final (size, height) = dimensions;
      test('native geometry covers short/long ordinary/bold paragraphs $family F$size L$height', () {
        final geometry = ReaderFontGeometry.measure(graphemes: _text.characters,
          fontSize: size, lineHeight: height, fontFamily: family,
          fontFamilyFallback: const ['GeometryTestSans']);
        expect(geometry.supportsUniformStrut, isTrue,
          reason: 'Within and between independently shaped normal/bold paragraphs must use the same native strut');
        expect(geometry.inventoryComplete, isTrue);
        expect(geometry.measuredClusters, greaterThan(0));
        expect(geometry.unmeasuredClusters, 0);
        expect(geometry.selectionQueries, 2);
        expect(geometry.baselineStepMin, closeTo(geometry.baselineStep, 1e-3));
        expect(geometry.baselineStepMax, closeTo(geometry.baselineStep, 1e-3));

        final painters = <TextPainter>[];
        try {
          for (final weight in <FontWeight>[FontWeight.normal, FontWeight.bold]) {
            for (final text in <String>[_text.substring(0, 4), List.filled(12, _text).join()]) {
              final painter = _painter(family, size, height, weight, text)..layout(maxWidth: 328);
              painters.add(painter);
              final lines = painter.computeLineMetrics();
              expect(lines, isNotEmpty);
              expect(lines.first.baseline, closeTo(geometry.firstBaseline, 1e-3));
              expect(painter.height, closeTo(lines.length * geometry.baselineStep, 1e-3));
              for (var i = 0; i < lines.length; i++) {
                final line = lines[i];
                if (i > 0) {
                  expect(line.baseline - lines[i - 1].baseline, closeTo(geometry.baselineStep, 1e-3));
                }
                // Identify an actual wrapped native line, including its first
                // and last line. No row substring is reshaped by this oracle.
                final hit = painter.getPositionForOffset(Offset(-1, line.baseline - line.ascent * .25));
                final range = painter.getLineBoundary(hit);
                final boxes = painter.getBoxesForSelection(TextSelection(baseOffset: range.start, extentOffset: range.end),
                  boxHeightStyle: ui.BoxHeightStyle.tight);
                expect(boxes, isNotEmpty);
                for (final box in boxes.where((box) => box.bottom > box.top)) {
                  final top = box.top - line.baseline, bottom = box.bottom - line.baseline;
                  expect(top, greaterThanOrEqualTo(geometry.tightTopMin - 1e-3));
                  expect(top, lessThanOrEqualTo(geometry.tightTopMax + 1e-3));
                  expect(bottom, greaterThanOrEqualTo(geometry.tightBottomMin - 1e-3));
                  expect(bottom, lessThanOrEqualTo(geometry.tightBottomMax + 1e-3));
                }
              }
            }
          }
          for (final previous in painters) {
            for (final next in painters) {
              final step = previous.height + next.computeLineMetrics().first.baseline -
                previous.computeLineMetrics().last.baseline;
              expect(step, closeTo(geometry.baselineStep, 1e-3),
                reason: 'Normal/bold independent paragraph joins must not add a hidden rounded baseline gap');
            }
          }
        } finally { for (final painter in painters) { painter.dispose(); } }
      }, skip: !_font(_families[family]!.first).existsSync());
    }
    for (final sample in <String>[
      '中文AgÉe\u0301a\u0302\u0323👩‍💻🧑🏽‍🚀🇨🇳𝄞𠀀',
      'العربيةلاעבריתΩЖक्षกำ',
      'ffiﬃofficea\u0323\u0302e\u0301中文',
    ]) {
      test('whole-run font envelope covers independent cluster reference $family ${sample.runes.first}', () {
        final geometry = ReaderFontGeometry.measure(graphemes: sample.characters,
          fontSize: 39, lineHeight: 1.6, fontFamily: family,
          fontFamilyFallback: const ['GeometryTestSans']);
        final reference = _clusterReference(family, sample);
        expect(reference.unmeasured, 0, reason: 'The independent reference must resolve whole glyphs instead of dropping empty partial ligature selections');
        expect(geometry.inventoryComplete, isTrue);
        expect(geometry.selectionQueries, 2);
        expect(geometry.tightTopMin, lessThanOrEqualTo(reference.tmin + 1e-3));
        expect(geometry.tightTopMax, greaterThanOrEqualTo(reference.tmax - 1e-3));
        expect(geometry.tightBottomMin, lessThanOrEqualTo(reference.bmin + 1e-3));
        expect(geometry.tightBottomMax, greaterThanOrEqualTo(reference.bmax - 1e-3),
          reason: 'Raw native run metrics must cover the independently selected fallback, emoji, combining, bidi and ligature glyph metrics');
      }, skip: !_font(_families[family]!.first).existsSync());
    }
  }

  test('whole-run native selection count stays constant as inventory grows', () {
    for (final count in <int>[1, 4096]) {
      final geometry = ReaderFontGeometry.measure(
        graphemes: String.fromCharCodes(List.generate(count, (index) => 0x4e00 + index)).characters,
        fontSize: 39, lineHeight: 1.6, fontFamily: 'GeometryTestSans');
      expect(geometry.inventoryComplete, isTrue);
      expect(geometry.selectionQueries, 2);
    }
  }, skip: !_font('msyh.ttc').existsSync());

  test('empty/invisible inventory cannot masquerade as a complete font envelope', () {
    final geometry = ReaderFontGeometry.measure(graphemes: const ['', '\n', '\r\n', ' ', '\u200B', '\u200D'],
      fontSize: 26, lineHeight: 1.6);
    expect(geometry.measuredClusters, 0);
    expect(geometry.inventoryComplete, isFalse);
    expect(geometry.supportsUniformStrut, isFalse);
    expect(geometry.selectionQueries, 0);
  });

  test('invalid geometry is rejected rather than replaced with nominal font metrics', () {
    for (final size in <double>[0, -1, double.nan, double.infinity]) {
      expect(() => ReaderFontGeometry.measure(graphemes: const ['中'], fontSize: size, lineHeight: 1.6), throwsArgumentError);
    }
    for (final height in <double>[0, -1, double.nan, double.infinity]) {
      expect(() => ReaderFontGeometry.measure(graphemes: const ['中'], fontSize: 39, lineHeight: height), throwsArgumentError);
    }
  });
}

typedef _Reference = ({double tmin, double tmax, double bmin, double bmax, int unmeasured});

_Reference _clusterReference(String family, String sample) {
  final clusters = sample.characters.where((cluster) => cluster.trim().isNotEmpty).toSet().toList();
  final text = clusters.join();
  var tmin = double.infinity, tmax = double.negativeInfinity;
  var bmin = double.infinity, bmax = double.negativeInfinity;
  var unmeasured = 0;
  List<ui.TextBox> selected(TextPainter painter, int start, int end) => painter.getBoxesForSelection(
    TextSelection(baseOffset: start, extentOffset: end), boxHeightStyle: ui.BoxHeightStyle.tight)
    .where((box) => box.bottom > box.top).toList();
  for (final weight in const [FontWeight.normal, FontWeight.bold]) {
    final painter = _painter(family, 39, 1.6, weight, text)..layout(maxWidth: 16384);
    try {
      expect(painter.computeLineMetrics(), hasLength(1));
      var offset = 0;
      for (final cluster in clusters) {
        var baseline = painter.computeLineMetrics().single.baseline;
        var boxes = selected(painter, offset, offset + cluster.length);
        if (boxes.isEmpty) {
          final isolated = _painter(family, 39, 1.6, weight, cluster)..layout(maxWidth: 16384);
          try {
            baseline = isolated.computeLineMetrics().single.baseline;
            boxes = selected(isolated, 0, cluster.length);
          } finally { isolated.dispose(); }
        }
        if (boxes.isEmpty) unmeasured++;
        for (final box in boxes) {
          tmin = math.min(tmin, box.top - baseline); tmax = math.max(tmax, box.top - baseline);
          bmin = math.min(bmin, box.bottom - baseline); bmax = math.max(bmax, box.bottom - baseline);
        }
        offset += cluster.length;
      }
    } finally { painter.dispose(); }
  }
  return (tmin: tmin, tmax: tmax, bmin: bmin, bmax: bmax, unmeasured: unmeasured);
}

TextPainter _painter(String family, double size, double height, FontWeight weight, String text) => TextPainter(
  text: TextSpan(text: text, style: TextStyle(fontFamily: family,
    fontFamilyFallback: const ['GeometryTestSans'], fontSize: size, height: height, letterSpacing: 0, fontWeight: weight)),
  textDirection: TextDirection.ltr, textAlign: weight == FontWeight.bold ? TextAlign.center : TextAlign.justify,
  strutStyle: StrutStyle(fontFamily: family, fontSize: size, height: height,
    fontWeight: FontWeight.normal, forceStrutHeight: true));
