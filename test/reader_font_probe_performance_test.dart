import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:characters/characters.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/services/reader_font_geometry.dart';

const _family = 'ReaderFontProbePerformanceCjk';
const _size = 39.0, _height = 1.6;
const _strut = StrutStyle(fontFamily: _family, fontSize: _size, height: _height,
  fontWeight: FontWeight.normal, forceStrutHeight: true);

File _font(String name) => File('${Platform.environment['SystemRoot']}\\Fonts\\$name');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (!_font('msyh.ttc').existsSync()) return;
    final loader = FontLoader(_family);
    for (final name in const ['msyh.ttc', 'msyhbd.ttc']) {
      if (_font(name).existsSync()) {
        loader.addFont(_font(name).readAsBytes().then((bytes) => ByteData.sublistView(bytes)));
      }
    }
    // Read the existing OS resource into this process only; no font copies,
    // screenshots, actual books, timing reports, or other artifacts are saved.
    await loader.load();
  });

  for (final hanCount in <int>[5000, 9000]) {
    test('native font inventory cost and whole-selection envelope with $hanCount Han characters', () {
      final inventory = _inventory(hanCount);
      final text = inventory.join();
      // These are native-rendered basic Han glyphs, not a frequency-ranked
      // corpus or a promise that the same fallback fonts exist on Android.
      expect(inventory.length, greaterThan(hanCount));
      final coldClock = Stopwatch()..start();
      final cold = _measure(inventory);
      coldClock.stop();

      // Explicit order: the independent legacy cluster reference follows the
      // first current probe and may benefit from its font caches. It omits the
      // production baseline-profile checks, so this is not a full old-version
      // benchmark. Repeat both to expose steady-state selection overhead.
      final legacyClock = Stopwatch()..start();
      final legacy = _legacy(inventory);
      legacyClock.stop();
      final warmClock = Stopwatch()..start();
      final warm = _measure(inventory);
      warmClock.stop();
      final legacyWarmClock = Stopwatch()..start();
      final legacyWarm = _legacy(inventory);
      legacyWarmClock.stop();
      final whole = _whole(text);

      final measured = (tmin: warm.tightTopMin, tmax: warm.tightTopMax,
        bmin: warm.tightBottomMin, bmax: warm.tightBottomMax);
      final differences = <String, double>{
        'tmin': measured.tmin - legacyWarm.envelope.tmin, 'tmax': measured.tmax - legacyWarm.envelope.tmax,
        'bmin': measured.bmin - legacyWarm.envelope.bmin, 'bmax': measured.bmax - legacyWarm.envelope.bmax,
      };
      final equivalent = differences.values.every((difference) => difference.abs() <= 1e-3);
      final misses = <String>[
        if (measured.tmin > legacyWarm.envelope.tmin + 1e-3) 'minimumTop',
        if (measured.tmax < legacyWarm.envelope.tmax - 1e-3) 'maximumTop',
        if (measured.bmin > legacyWarm.envelope.bmin + 1e-3) 'minimumBottom',
        if (measured.bmax < legacyWarm.envelope.bmax - 1e-3) 'maximumBottom',
      ];
      print('FONT_PROBE_PERFORMANCE ${jsonEncode({
        'host': Platform.operatingSystem, 'family': _family, 'F': _size, 'L/F': _height,
        'HanInput': hanCount, 'uniqueGraphemes': inventory.length, 'utf16Units': text.length,
        'firstGeometryMicroseconds': coldClock.elapsedMicroseconds,
        'postGeometryLegacyReferenceMicroseconds': legacyClock.elapsedMicroseconds,
        'warmGeometryMicroseconds': warmClock.elapsedMicroseconds,
        'warmLegacyReferenceMicroseconds': legacyWarmClock.elapsedMicroseconds,
        'currentProductionSelectionCalls': warm.selectionQueries,
        'legacySelectionCalls': legacyWarm.queries,
        'legacyUnmeasuredClusters': legacyWarm.unmeasured,
        'rawWholeTextBoxes': whole.boxes, 'nativePitch': warm.baselineStep,
        'supportsUniformStrut': warm.supportsUniformStrut,
        'inventoryComplete': warm.inventoryComplete, 'unmeasuredClusters': warm.unmeasuredClusters,
        'currentEnvelope': {'tmin': measured.tmin, 'tmax': measured.tmax, 'bmin': measured.bmin, 'bmax': measured.bmax},
        'legacyClusterEnvelope': {'tmin': legacyWarm.envelope.tmin, 'tmax': legacyWarm.envelope.tmax,
          'bmin': legacyWarm.envelope.bmin, 'bmax': legacyWarm.envelope.bmax},
        'currentMinusLegacy': differences, 'equivalentWithin1e-3': equivalent,
        'currentMissesMeasuredExtrema': misses,
        'scope': 'Finite host observation; first-run order/cache effects and cheaper reference validation noted; not a device timing or universal contextual font certificate',
      })}');

      // Stable correctness properties, never a fragile wall-clock threshold or
      // an assumption that a cheaper font-run probe has an equal envelope.
      expect(cold.baselineStep, closeTo(warm.baselineStep, 1e-3));
      expect(cold.tightTopMin, closeTo(warm.tightTopMin, 1e-3));
      expect(cold.tightTopMax, closeTo(warm.tightTopMax, 1e-3));
      expect(cold.tightBottomMin, closeTo(warm.tightBottomMin, 1e-3));
      expect(cold.tightBottomMax, closeTo(warm.tightBottomMax, 1e-3));
      expect(cold.inventoryComplete, warm.inventoryComplete);
      expect(warm.inventoryComplete, isTrue);
      expect(warm.selectionQueries, 2);
      expect(cold.selectionQueries, 2);
      expect(legacyWarm.queries, greaterThanOrEqualTo(inventory.length * 2 + 2));
      expect(legacyWarm.unmeasured, 0);
      expect(misses, isEmpty, reason: 'The optimization must cover the independently measured cluster font extrema');
      expect(warm.measuredClusters, greaterThan(0));
      expect(whole.boxes, greaterThan(0));
      expect(legacy.envelope.tmin, closeTo(legacyWarm.envelope.tmin, 1e-3));
      expect(legacy.envelope.tmax, closeTo(legacyWarm.envelope.tmax, 1e-3));
      expect(legacy.envelope.bmin, closeTo(legacyWarm.envelope.bmin, 1e-3));
      expect(legacy.envelope.bmax, closeTo(legacyWarm.envelope.bmax, 1e-3));
    }, skip: !_font('msyh.ttc').existsSync(), timeout: const Timeout(Duration(minutes: 2)));
  }
}

List<String> _inventory(int hanCount) {
  final text = String.fromCharCodes(List.generate(hanCount, (index) => 0x4e00 + index)) +
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789' +
    'Ée\u0301a\u0302\u0323ΩЖالعربيةक्षกำ' +
    '👩‍💻🧑🏽‍🚀🇨🇳𝄞𠀀';
  return text.characters.where((cluster) => cluster.trim().isNotEmpty).toSet().toList();
}

ReaderFontGeometry _measure(List<String> inventory) => ReaderFontGeometry.measure(
  graphemes: inventory, fontSize: _size, lineHeight: _height,
  fontFamily: _family, strutStyle: _strut);

typedef _Envelope = ({double tmin, double tmax, double bmin, double bmax, int boxes});
typedef _Legacy = ({_Envelope envelope, int queries, int unmeasured});

_Legacy _legacy(List<String> inventory) {
  final text = inventory.join();
  var queries = 0, unmeasured = 0, boxCount = 0;
  var tmin = double.infinity, tmax = double.negativeInfinity;
  var bmin = double.infinity, bmax = double.negativeInfinity;
  TextPainter native(String value, FontWeight weight) => TextPainter(text: TextSpan(text: value,
    style: TextStyle(fontFamily: _family, fontSize: _size, height: _height,
      letterSpacing: 0, fontWeight: weight)),
    strutStyle: _strut, textDirection: TextDirection.ltr, textAlign: TextAlign.left);
  List<ui.TextBox> selected(TextPainter painter, int start, int end) {
    queries++;
    return painter.getBoxesForSelection(TextSelection(baseOffset: start, extentOffset: end),
      boxHeightStyle: ui.BoxHeightStyle.tight)
      .where((box) => box.top.isFinite && box.bottom.isFinite && box.bottom > box.top).toList();
  }
  void collect(List<ui.TextBox> boxes, double baseline) {
    for (final box in boxes) {
      boxCount++;
      tmin = math.min(tmin, box.top - baseline); tmax = math.max(tmax, box.top - baseline);
      bmin = math.min(bmin, box.bottom - baseline); bmax = math.max(bmax, box.bottom - baseline);
    }
  }
  for (final weight in const [FontWeight.normal, FontWeight.bold]) {
    final painter = native(text, weight)..layout();
    try {
      expect(painter.computeLineMetrics(), hasLength(1));
      final baseline = painter.computeLineMetrics().single.baseline;
      collect(selected(painter, 0, text.length), baseline);
      var offset = 0;
      for (final cluster in inventory) {
        var clusterBaseline = baseline;
        var boxes = selected(painter, offset, offset + cluster.length);
        if (boxes.isEmpty) {
          final isolated = native(cluster, weight)..layout();
          try {
            clusterBaseline = isolated.computeLineMetrics().single.baseline;
            boxes = selected(isolated, 0, cluster.length);
          } finally { isolated.dispose(); }
        }
        if (boxes.isEmpty) unmeasured++;
        collect(boxes, clusterBaseline);
        offset += cluster.length;
      }
    } finally { painter.dispose(); }
  }
  return (envelope: (tmin: tmin, tmax: tmax, bmin: bmin, bmax: bmax, boxes: boxCount),
    queries: queries, unmeasured: unmeasured);
}

_Envelope _whole(String text) {
  var tmin = double.infinity, tmax = double.negativeInfinity;
  var bmin = double.infinity, bmax = double.negativeInfinity;
  var count = 0;
  for (final weight in const [FontWeight.normal, FontWeight.bold]) {
    final painter = TextPainter(text: TextSpan(text: text,
      style: TextStyle(fontFamily: _family, fontSize: _size, height: _height,
        letterSpacing: 0, fontWeight: weight)),
      strutStyle: _strut, textDirection: TextDirection.ltr, textAlign: TextAlign.left);
    try {
      painter.layout();
      final metrics = painter.computeLineMetrics();
      expect(metrics, hasLength(1), reason: 'An inventory is one unwrapped native shape, not a synthetic text page');
      final baseline = metrics.single.baseline;
      final boxes = painter.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: text.length),
        boxHeightStyle: ui.BoxHeightStyle.tight);
      // Preserve every native font-run TextBox. An outer union would discard
      // tmax/bmin and cannot be compared to a per-cluster font envelope.
      for (final box in boxes) {
        if (!box.top.isFinite || !box.bottom.isFinite || box.bottom <= box.top) continue;
        count++;
        tmin = math.min(tmin, box.top - baseline); tmax = math.max(tmax, box.top - baseline);
        bmin = math.min(bmin, box.bottom - baseline); bmax = math.max(bmax, box.bottom - baseline);
      }
    } finally { painter.dispose(); }
  }
  expect(count, greaterThan(0));
  return (tmin: tmin, tmax: tmax, bmin: bmin, bmax: bmax, boxes: count);
}
