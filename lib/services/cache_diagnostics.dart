import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'tts_cache_store.dart';

class CacheDiagnosticsCancelled implements Exception {
  const CacheDiagnosticsCancelled();
}

/// Explicit, cancellable traversal; no titles, book IDs, cache keys or paths.
Future<Map<String, dynamic>> collectCacheDiagnostics(Directory root, {
  bool Function()? isCancelled,
  void Function(int)? onProgress,
}) async {
  void checkCancelled() {
    if (isCancelled?.call() ?? false) throw const CacheDiagnosticsCancelled();
  }
  checkCancelled();
  var visited = 0, audioFiles = 0, emptyAudioFiles = 0, bytes = 0;
  var wordFiles = 0, malformedProgress = 0;
  final progress = <Map<String, dynamic>>[];
  if (await root.exists()) {
    await for (final entry in root.list(recursive: true, followLinks: false)) {
      checkCancelled();
      if (entry is! File) continue;
      visited++;
      if (visited % 128 == 0) onProgress?.call(visited);
      try {
        if (entry.path.endsWith('.mp3')) {
          final length = await entry.length();
          if (length == 0) { emptyAudioFiles++; } else { audioFiles++; bytes += length; }
        } else if (entry.path.endsWith('.mp3.words.json')) {
          wordFiles++;
        } else if (entry.uri.pathSegments.last == 'progress.json') {
          try {
            final data = jsonDecode(await entry.readAsString()) as Map<String, dynamic>;
            final state = data['state'];
            const states = {'idle', 'building', 'caching', 'paused', 'done', 'cancelled'};
            progress.add({
              'total': (data['total'] as num?)?.toInt() ?? 0,
              'done': (data['done'] as num?)?.toInt() ?? 0,
              'state': states.contains(state) ? state : 'unknown',
            });
          } on FormatException { malformedProgress++; }
          on TypeError { malformedProgress++; }
        }
      } on FileSystemException catch (error) {
        if (error.osError?.errorCode != 2 && error.osError?.errorCode != 3) rethrow;
      }
    }
  }
  checkCancelled();
  onProgress?.call(visited);
  checkCancelled();
  return {
    'schema': 1, 'exportedAt': DateTime.now().toUtc().toIso8601String(),
    'filesScanned': visited, 'audioFiles': audioFiles,
    'emptyAudioFiles': emptyAudioFiles, 'audioBytes': bytes,
    'wordFiles': wordFiles, 'malformedProgress': malformedProgress,
    'progress': progress,
  };
}

/// Manual action only; no startup export or network I/O.
Future<String> exportCacheDiagnostics({
  bool Function()? isCancelled,
  void Function(int)? onProgress,
}) async {
  final report = await collectCacheDiagnostics(await TtsCacheStore.rootDir(),
    isCancelled: isCancelled, onProgress: onProgress);
  Directory target = await getApplicationDocumentsDirectory();
  if (Platform.isAndroid) target = await getExternalStorageDirectory() ?? target;
  final out = File('${target.path}${Platform.pathSeparator}cache_report.json');
  final staging = File('${out.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
  try {
    if (isCancelled?.call() ?? false) throw const CacheDiagnosticsCancelled();
    await staging.writeAsString(const JsonEncoder.withIndent('  ').convert(report), flush: true);
    if (isCancelled?.call() ?? false) throw const CacheDiagnosticsCancelled();
    await staging.rename(out.path);
    return out.path;
  } finally {
    if (await staging.exists()) await staging.delete();
  }
}
