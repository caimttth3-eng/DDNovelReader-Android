import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'app_storage.dart';
import 'tts_cache_store.dart';

/// 导出语音缓存诊断：缓存根目录下每个 key 的文件数/大小/progress.json，
/// 以及当前书架书籍的 contentKey。写入 App 外部私有目录，便于 adb 拉取。
Future<String?> exportCacheDiagnostics(AppStorage storage) async {
  try {
    final books = await storage.loadBooks();
    final settings = await storage.loadSettings();
    final root = await TtsCacheStore.rootDir();
    final keys = <Map<String, dynamic>>[];
    await for (final e in root.list(followLinks: false)) {
      if (e is! Directory) continue;
      var bytes = 0;
      var files = 0;
      final voices = <String>{};
      await for (final f in e.list(recursive: true, followLinks: false)) {
        if (f is File && f.path.endsWith('.mp3')) {
          files++;
          bytes += await f.length();
        }
      }
      final progress = <dynamic>[];
      await for (final p in e.list(recursive: true, followLinks: false)) {
        if (p is File && p.path.endsWith('progress.json')) {
          try {
            progress.add({'path': p.path.substring(root.path.length), 'data': jsonDecode(await p.readAsString())});
          } catch (_) {}
        }
      }
      keys.add({
        'key': e.uri.pathSegments.last,
        'files': files,
        'bytes': bytes,
        'progress': progress,
      });
    }
    final ext = await getExternalStorageDirectory();
    final docs = await getApplicationDocumentsDirectory();
    final out = File('${(ext ?? docs).path}${Platform.pathSeparator}cache_report.json');
    final report = {
      'exportedAt': DateTime.now().toIso8601String(),
      'root': root.path,
      'settings': {
        'voice': settings['voice'],
        'speechRate': settings['speechRate'],
      },
      'books': [
        for (final b in books)
          {
            'id': b.id,
            'title': b.title,
            'contentKey': b.contentKey,
            'chapters': b.chapterCount,
          }
      ],
      'cacheKeys': keys,
    };
    await out.writeAsString(const JsonEncoder.withIndent('  ').convert(report), flush: true);
    return out.path;
  } catch (_) {
    return null;
  }
}
