import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/services/cache_diagnostics.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('cache-diagnostic-fixture-');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async => root.path);
  });
  tearDown(() async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    await root.delete(recursive: true);
  });

  test('manual report counts real audio and omits titles, IDs, paths and raw metadata', () async {
    final dir = Directory('${root.path}/tts_cache/private-book-id/voice/0')..createSync(recursive: true);
    await File('${dir.path}/0000_00000000.mp3').writeAsBytes([1, 2, 3]);
    await File('${dir.path}/0000_00000001.mp3').writeAsBytes([]);
    await File('${dir.path}/0000_00000000.mp3.words.json').writeAsString('[]');
    await File('${dir.path}/progress.json').writeAsString(jsonEncode({
      'title': 'private-title', 'bookId': 'private-book-id', 'root': root.path,
      'total': 2, 'done': 1, 'state': 'paused', 'password': 'private-secret',
    }));
    final counts = <int>[];
    final report = await collectCacheDiagnostics(root, onProgress: counts.add);
    expect(report['audioFiles'], 1); expect(report['emptyAudioFiles'], 1);
    expect(report['audioBytes'], 3); expect(report['wordFiles'], 1);
    expect(report['progress'], [{'total': 2, 'done': 1, 'state': 'paused'}]);
    final output = jsonEncode(report);
    for (final secret in ['private-title', 'private-book-id', 'private-secret', root.path]) {
      expect(output, isNot(contains(secret)));
    }
    expect(counts.last, 4);
  });

  test('malformed progress is counted without exposing raw content', () async {
    await File('${root.path}/progress.json').writeAsString('private malformed JSON');
    final report = await collectCacheDiagnostics(root);
    expect(report['malformedProgress'], 1); expect(report['progress'], isEmpty);
    expect(jsonEncode(report), isNot(contains('private malformed JSON')));
  });

  test('cancelled export keeps the previous report and leaves no partial file', () async {
    final cache = Directory('${root.path}/tts_cache')..createSync();
    for (var i = 0; i < 130; i++) {
      await File('${cache.path}/$i.mp3').writeAsBytes([1]);
    }
    final previous = File('${root.path}/cache_report.json');
    await previous.writeAsString('previous report');
    var cancelled = false;
    await expectLater(exportCacheDiagnostics(isCancelled: () => cancelled,
      onProgress: (count) { if (count >= 128) cancelled = true; }),
      throwsA(isA<CacheDiagnosticsCancelled>()));
    expect(await previous.readAsString(), 'previous report');
    expect(await File('${previous.path}.tmp').exists(), isFalse);
  });
}
