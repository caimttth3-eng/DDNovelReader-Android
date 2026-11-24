import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// Finite native-font research, not a certificate for arbitrary book text,
// contextual shaping, fallback fonts, a different engine, or another device.
const _clusters = <String>[
  '中', '文', '第', '章', '，', '。', '“', '”', 'A', 'g', 'j', 'É',
  'e\u0301', 'a\u0302\u0323', 'Ω', 'Ж', 'ع', 'ل', 'لا', 'क', 'क्ष',
  'ก', 'กำ', '👩‍💻', '🧑🏽‍🚀', '🇨🇳', '𝄞', '𠀀',
];
const _sampleLines = <String>[
  '中文第一章，AgjÉ。',
  'é e\u0301 a\u0302\u0323 ΩЖ',
  'العربية لا क्ष กำ',
  '👩‍💻🧑🏽‍🚀🇨🇳𝄞𠀀',
  '“中文标题与正文”',
];

class _Font {
  const _Font(this.name, this.files);
  final String name;
  final List<String> files;
  File file(String name) => File('${Platform.environment['SystemRoot']}\\Fonts\\$name');
  bool get available => file(files.first).existsSync();
}

const _fonts = <_Font>[
  _Font('EnvelopeResearchSans', ['msyh.ttc', 'msyhbd.ttc']),
  _Font('EnvelopeResearchSerif', ['simsun.ttc']),
  _Font('EnvelopeResearchLatin', ['arial.ttf', 'arialbd.ttf']),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final font in _fonts.where((font) => font.available)) {
      final loader = FontLoader(font.name);
      for (final name in font.files) {
        final file = font.file(name);
        if (file.existsSync()) {
          loader.addFont(file.readAsBytes().then((bytes) => ByteData.sublistView(bytes)));
        }
      }
      // Existing OS fonts are read into this process, never copied/distributed.
      await loader.load();
    }
  });

  for (final font in _fonts) {
    for (final size in <double>[14, 26, 39, 64]) {
      for (final height in <double>[1.2, 1.6, 2.4]) {
        test('native strut envelope ${font.name} F$size L$height', () {
          _report(font, size, height, const ui.TextHeightBehavior(), 'reader-default');
        }, skip: !font.available);
      }
    }
    test('native strut paragraph edge control ${font.name}', () {
      _report(font, 39, 1.6, const ui.TextHeightBehavior(
        applyHeightToFirstAscent: false, applyHeightToLastDescent: false), 'trim-edges-control');
    }, skip: !font.available);
  }
}

typedef _Shape = ({double height, List<ui.LineMetrics> metrics, List<Rect> rows});
typedef _Envelope = ({double tmin, double tmax, double bmin, double bmax});

TextPainter _painter(_Font font, double size, double height, FontWeight weight,
  ui.TextHeightBehavior behavior, String text) => TextPainter(
    text: TextSpan(text: text, style: TextStyle(fontFamily: font.name,
      fontFamilyFallback: const ['EnvelopeResearchSans'], fontSize: size,
      height: height, letterSpacing: 0, fontWeight: weight)),
    textDirection: TextDirection.ltr,
    textAlign: weight == FontWeight.bold ? TextAlign.center : TextAlign.justify,
    textHeightBehavior: behavior,
    strutStyle: StrutStyle(fontFamily: font.name, fontSize: size, height: height,
      fontWeight: FontWeight.normal, forceStrutHeight: true),
  );

Rect? _tight(TextPainter painter, int start, int end, {bool allowEmpty = false}) {
  final boxes = painter.getBoxesForSelection(TextSelection(baseOffset: start, extentOffset: end),
    boxHeightStyle: ui.BoxHeightStyle.tight).where((box) => box.bottom > box.top).toList();
  if (boxes.isEmpty && allowEmpty) return null;
  expect(boxes, isNotEmpty, reason: 'A nonempty sample line must expose actual native tight metrics');
  return boxes.map((box) => box.toRect()).reduce((a, b) => a.expandToInclude(b));
}

_Shape _shape(_Font font, double size, double height, FontWeight weight,
  ui.TextHeightBehavior behavior, List<String> lines) {
  final painter = _painter(font, size, height, weight, behavior, lines.join('\n'));
  try {
    painter.layout(maxWidth: 16384);
    final metrics = painter.computeLineMetrics();
    expect(metrics.length, lines.length, reason: 'These explicit sample lines must not wrap unexpectedly');
    var offset = 0;
    final rows = <Rect>[];
    for (final line in lines) {
      rows.add(_tight(painter, offset, offset + line.length)!);
      offset += line.length + 1;
    }
    expect(painter.height.isFinite, isTrue);
    return (height: painter.height, metrics: metrics, rows: rows);
  } finally { painter.dispose(); }
}

_Envelope _probe(_Font font, double size, double height, ui.TextHeightBehavior behavior) {
  var tmin = double.infinity, tmax = double.negativeInfinity;
  var bmin = double.infinity, bmax = double.negativeInfinity;
  for (final weight in <FontWeight>[FontWeight.normal, FontWeight.bold]) {
    // Select each complete cluster individually in the same native shaped
    // paragraph. A whole-line union would conceal tmax/bmin and is insufficient
    // for the proposed difference-of-envelopes bound. No synthetic space is
    // inserted into the selected cluster or used as a surrogate glyph.
    final painter = _painter(font, size, height, weight, behavior, _clusters.join());
    try {
      painter.layout(maxWidth: 16384);
      final metrics = painter.computeLineMetrics();
      expect(metrics, hasLength(1));
      final baseline = metrics.single.baseline;
      var offset = 0;
      for (final cluster in _clusters) {
        var box = _tight(painter, offset, offset + cluster.length, allowEmpty: true);
        var selectedBaseline = baseline;
        if (box == null) {
          // A selection may be only part of a contextually merged glyph even
          // though its input was a complete grapheme. Measure it independently
          // rather than inventing zero height or dropping its fallback font.
          final isolated = _painter(font, size, height, weight, behavior, cluster);
          try {
            isolated.layout(maxWidth: 16384);
            selectedBaseline = isolated.computeLineMetrics().single.baseline;
            box = _tight(isolated, 0, cluster.length, allowEmpty: true);
          } finally { isolated.dispose(); }
        }
        if (box == null) {
          print('STRUT_NO_CLUSTER_BOX ${jsonEncode({'font': font.name, 'F': size,
            'L/F': height, 'weight': weight.value, 'runes': cluster.runes.toList()})}');
          offset += cluster.length;
          continue;
        }
        final top = box.top - selectedBaseline, bottom = box.bottom - selectedBaseline;
        tmin = math.min(tmin, top); tmax = math.max(tmax, top);
        bmin = math.min(bmin, bottom); bmax = math.max(bmax, bottom);
        offset += cluster.length;
      }
    } finally { painter.dispose(); }
  }
  return (tmin: tmin, tmax: tmax, bmin: bmin, bmax: bmax);
}

void _report(_Font font, double size, double height, ui.TextHeightBehavior behavior, String policy) {
  final envelope = _probe(font, size, height, behavior);
  final shapes = <_Shape>[
    for (final weight in <FontWeight>[FontWeight.normal, FontWeight.bold]) ...[
      _shape(font, size, height, weight, behavior, const ['中文Ag']),
      _shape(font, size, height, weight, behavior, List.filled(7, '中文Ag')),
      _shape(font, size, height, weight, behavior, _sampleLines),
    ],
  ];
  final within = <double>[];
  final joins = <double>[];
  final firstBaselines = <double>[];
  final metricHeights = <double>[];
  var worstEnvelopeExcess = 0.0;
  for (final shape in shapes) {
    firstBaselines.add(shape.metrics.first.baseline);
    metricHeights.addAll(shape.metrics.map((metric) => metric.height));
    for (var i = 0; i < shape.metrics.length; i++) {
      final baseline = shape.metrics[i].baseline, row = shape.rows[i];
      final top = row.top - baseline, bottom = row.bottom - baseline;
      worstEnvelopeExcess = math.max(worstEnvelopeExcess, math.max(
        math.max(envelope.tmin - top, top - envelope.tmax),
        math.max(envelope.bmin - bottom, bottom - envelope.bmax)));
      if (i > 0) within.add(baseline - shape.metrics[i - 1].baseline);
    }
    for (final next in shapes) {
      // Independent paragraph widgets begin after the preceding painter.height.
      // This is the actual cross-paragraph baseline step when S=0, including
      // first/last line treatment, native rounding and normal/bold transitions.
      joins.add(shape.height + next.metrics.first.baseline - shape.metrics.last.baseline);
    }
  }
  final pmin = [...within, ...joins].reduce(math.min);
  final pmax = [...within, ...joins].reduce(math.max);
  final p = within.first;
  final uniform = pmax - pmin <= 1e-3 && firstBaselines.reduce(math.max) - firstBaselines.reduce(math.min) <= 1e-3;
  final deltaFont = envelope.tmax - envelope.tmin + envelope.bmax - envelope.bmin;
  final maxGlyphHeight = envelope.bmax - envelope.tmin;
  final budgets = <Map<String, Object?>>[];
  for (final viewport in <double>[640, 760, 880]) {
    final k = math.max(1, ((viewport - maxGlyphHeight) / pmax).floor() + 1);
    final cap = k == 1 ? null : math.max(0.0, math.min(
      (size / 2 - deltaFont) / (k - 1) - (pmax - pmin),
      (viewport - maxGlyphHeight) / (k - 1) - pmax));
    budgets.add({'H': viewport, 'K': k, 'SUpperBoundFiniteSample': cap,
      'fontBudgetAlreadyExceeded': deltaFont > size / 2,
      'note': 'Finite-sample budget only; needs certified font/context closure and actual-page validation'});
  }
  // Numerical observations stay visible even when they falsify an assumption.
  // These tests do not assert that this finite inventory proves all book text.
  print('STRUT_ENVELOPE ${jsonEncode({
    'font': font.name, 'F': size, 'L/F': height, 'policy': policy,
    'nominalFtimesL': size * height, 'observedP': p,
    'withinMin': within.reduce(math.min), 'withinMax': within.reduce(math.max),
    'crossParagraphMin': joins.reduce(math.min), 'crossParagraphMax': joins.reduce(math.max),
    'firstBaselineMin': firstBaselines.reduce(math.min), 'firstBaselineMax': firstBaselines.reduce(math.max),
    'metricHeightMin': metricHeights.reduce(math.min), 'metricHeightMax': metricHeights.reduce(math.max),
    'painterHeights': shapes.map((shape) => shape.height).toList(),
    'lineCounts': shapes.map((shape) => shape.metrics.length).toList(),
    'tmin': envelope.tmin, 'tmax': envelope.tmax, 'bmin': envelope.bmin, 'bmax': envelope.bmax,
    'deltaFont': deltaFont, 'supportsUniformStrutFiniteSample': uniform,
    'sampleEnvelopeExcess': worstEnvelopeExcess, 'budgets': budgets,
  })}');
  expect(pmin, greaterThan(0)); expect(pmax.isFinite, isTrue);
  expect(deltaFont.isFinite, isTrue); expect(maxGlyphHeight, greaterThan(0));
}
