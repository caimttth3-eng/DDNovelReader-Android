import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../models/book.dart';

/// 恢复的进度记录（total 与当前任务不符即作废；from* 记录缓存起点）
typedef CacheProgress = ({
  int total,
  int done,
  Set<int> completed,
  String state,
  int? fromChapter,
  int? fromOffset,
});

/// 全书语音缓存：磁盘持久化的 Edge TTS 合成音频缓存。
///
/// 设计对齐 PC 端（novelreader/tts_engine.py WholeBookCacher）：
/// - 目录：`<appSupport>/tts_cache/<bookId>/<voice>/<rateKey>/`
/// - 文件：`{章:04d}_{章内tts偏移:08d}.mp3`——坐标即指纹：
///   书重新解析、切句规则变化时，只要句子文本没动，偏移不变缓存仍命中；
///   文本动了偏移自然变 → 自动失效防错位。
/// - 原子写：先写 `.tmp` 再 rename 发布，朗读线程永远读不到半截文件。
/// - 进度持久化 `progress.json`（bookId/voice/rate/total/done/completed/state），
///   total 不匹配即作废；续传时剔除「标记完成但文件缺失」的任务防谎报。
class TtsCacheStore {
  final String bookId;
  final String voice;
  final double rate;
  final String? textFingerprint;

  TtsCacheStore(this.bookId, this.voice, this.rate, {this.textFingerprint});

  /// 缓存目录 key：语速按两位小数定值，与合成参数一一对应
  String get rateKey => rate.toStringAsFixed(2);

  static const _progressFile = 'progress.json';

  static Future<Directory> rootDir() async {
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}${Platform.pathSeparator}tts_cache');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<Directory> dir() async {
    final root = await rootDir();
    final d = Directory([
      root.path,
      _safe(bookId),
      _safe(voice),
      rateKey,
      if (textFingerprint != null) 'text-${_safe(textFingerprint!)}',
    ].join(Platform.pathSeparator));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// 目录名安全化：只保留字母数字和 `-_.`，其余转 `_`（防止路径穿越/非法字符）
  static String _safe(String s) {
    final b = StringBuffer();
    for (final c in s.codeUnits) {
      final ch = String.fromCharCode(c);
      b.write(RegExp(r'[A-Za-z0-9\-_.]').hasMatch(ch) ? ch : '_');
    }
    return b.toString();
  }

  static String fileName(int ci, int off) =>
      '${ci.toString().padLeft(4, '0')}_${off.toString().padLeft(8, '0')}.mp3';

  Future<String> _pathOf(int ci, int off) async {
    final d = await dir();
    return '${d.path}${Platform.pathSeparator}${fileName(ci, off)}';
  }

  /// 读缓存音频；未命中或空文件返回 null
  Future<Uint8List?> read(int ci, int off) async {
    try {
      final p = await _pathOf(ci, off);
      final f = File(p);
      if (!await f.exists()) return null;
      final bytes = await f.readAsBytes();
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    }
  }

  /// 缓存文件是否存在（续传跳过已缓存用）
  Future<bool> exists(int ci, int off) async {
    try {
      final p = await _pathOf(ci, off);
      final f = File(p);
      return await f.exists() && await f.length() > 0;
    } catch (_) {
      return false;
    }
  }

  /// 原子写入：先写 `.tmp` 再 rename 发布
  Future<void> write(int ci, int off, Uint8List audio) async {
    try {
      final d = await dir();
      final finalPath = '${d.path}${Platform.pathSeparator}${fileName(ci, off)}';
      final tmpPath = '$finalPath.tmp';
      final tmp = File(tmpPath);
      await tmp.writeAsBytes(audio, flush: true);
      await tmp.rename(finalPath);
    } catch (_) {}
  }

  // ---------- 进度持久化 ----------

  /// 返回进度记录；无进度或 bookId/voice/rate 不匹配返回 null
  Future<CacheProgress?> loadProgress() async {
    try {
      final d = await dir();
      final p = File('${d.path}${Platform.pathSeparator}$_progressFile');
      if (!await p.exists()) return null;
      final data = jsonDecode(await p.readAsString()) as Map<String, dynamic>;
      if (data['bookId'] != bookId ||
          data['voice'] != voice ||
          data['rate'] != rateKey) {
        return null;
      }
      final done = (data['done'] as num?)?.toInt() ?? 0;
      final completed =
          (data['completed'] as List<dynamic>? ?? const [])
              .map((e) => (e as num).toInt())
              .toSet();
      final state = data['state'] as String? ?? 'paused';
      return (
        total: (data['total'] as num?)?.toInt() ?? 0,
        done: done,
        completed: completed,
        state: state,
        fromChapter: (data['fromChapter'] as num?)?.toInt(),
        fromOffset: (data['fromOffset'] as num?)?.toInt(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> saveProgress({
    required int total,
    required int done,
    required Set<int> completed,
    required String state,
    int? fromChapter,
    int? fromOffset,
  }) async {
    try {
      final d = await dir();
      final data = {
        'bookId': bookId,
        'voice': voice,
        'rate': rateKey,
        'total': total,
        'done': done,
        'completed': completed.toList()..sort(),
        'state': state,
        'fromChapter': ?fromChapter,
        'fromOffset': ?fromOffset,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      };
      final finalPath = '${d.path}${Platform.pathSeparator}$_progressFile';
      final tmpPath = '$finalPath.tmp';
      final tmp = File(tmpPath);
      await tmp.writeAsString(jsonEncode(data), flush: true);
      await tmp.rename(finalPath);
    } catch (_) {}
  }

  /// 删除本书当前语音/语速的进度文件（清除缓存时调用）
  Future<void> removeProgress() async {
    try {
      final d = await dir();
      final p = File('${d.path}${Platform.pathSeparator}$_progressFile');
      if (await p.exists()) await p.delete();
    } catch (_) {}
  }

  // ---------- 大小统计与清理 ----------

  /// 当前 bookId/voice/rate 目录占用字节数（排除 progress.json 与 .tmp）
  Future<int> sizeBytes() async {
    try {
      final d = await dir();
      var total = 0;
      await for (final e in d.list(recursive: true, followLinks: false)) {
        if (e is File) {
          final name = e.uri.pathSegments.last;
          if (name == _progressFile || name.endsWith('.tmp')) continue;
          try {
            total += await e.length();
          } catch (_) {}
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// 清除本书当前语音/语速的全部缓存（含进度），返回删除文件数
  Future<int> clear() async {
    var n = 0;
    try {
      final d = await dir();
      if (await d.exists()) {
        await for (final e in d.list(followLinks: false)) {
          try {
            if (e is File) {
              await e.delete();
              n++;
            }
          } catch (_) {}
        }
      }
      await removeProgress();
    } catch (_) {}
    return n;
  }

  /// 当前 bookId/voice/rate 目录下全部 mp3 文件名（不含 progress.json/.tmp），
  /// 一次性列出供恢复进度时内存判断，避免逐文件 exists 的 IO 扫描。
  Future<Set<String>> listMp3Names() async {
    final result = <String>{};
    try {
      final d = await dir();
      if (await d.exists()) {
        await for (final e in d.list(followLinks: false)) {
          if (e is File) {
            final name = e.uri.pathSegments.last;
            if (name == _progressFile || name.endsWith('.tmp')) continue;
            result.add(name);
          }
        }
      }
    } catch (_) {}
    return result;
  }

  /// 全部书/语音/语速的缓存总字节数
  static Future<int> totalSize() async {
    try {
      final root = await rootDir();
      if (!await root.exists()) return 0;
      var total = 0;
      await for (final e in root.list(recursive: true, followLinks: false)) {
        if (e is File) {
          final name = e.uri.pathSegments.last;
          if (name == _progressFile || name.endsWith('.tmp')) continue;
          try {
            total += await e.length();
          } catch (_) {}
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// 清空全部缓存，返回删除文件数
  static Future<int> clearAll() async {
    var n = 0;
    try {
      final root = await rootDir();
      if (await root.exists()) {
        await for (final e in root.list(followLinks: false)) {
          try {
            if (e is Directory) {
              await e.delete(recursive: true);
              n++;
            } else {
              await e.delete();
              n++;
            }
          } catch (_) {}
        }
      }
    } catch (_) {}
    return n;
  }

  /// 目录名安全化（公开版，供书架按 bookId 匹配缓存目录）
  static String safeId(String s) => _safe(s);

  /// 每本书缓存占用：[(bookId目录名, bytes)]，按占用降序
  static Future<List<(String, int)>> listBookSizes() async {
    final result = <(String, int)>[];
    try {
      final root = await rootDir();
      if (!await root.exists()) return result;
      await for (final e in root.list(followLinks: false)) {
        if (e is! Directory) continue;
        final bookId = e.uri.pathSegments.last;
        var total = 0;
        await for (final f in e.list(recursive: true, followLinks: false)) {
          if (f is File) {
            final name = f.uri.pathSegments.last;
            if (name == _progressFile || name.endsWith('.tmp')) continue;
            try {
              total += await f.length();
            } catch (_) {}
          }
        }
        if (total > 0) result.add((bookId, total));
      }
      result.sort((a, b) => b.$2.compareTo(a.$2));
    } catch (_) {}
    return result;
  }

  /// 清除某本书（bookId 目录名）的全部语音缓存，返回删除文件数
  static Future<int> clearBook(String bookId) async {
    var n = 0;
    try {
      final root = await rootDir();
      final d = Directory([root.path, bookId].join(Platform.pathSeparator));
      if (await d.exists()) {
        await for (final e in d.list(recursive: true, followLinks: false)) {
          if (e is File) {
            try {
              await e.delete();
              n++;
            } catch (_) {}
          }
        }
        await d.delete(recursive: true);
      }
    } catch (_) {}
    return n;
  }
}

/// 章节内所有句子的 tts 累计字符偏移（与 reader 的 _chapterTtsSentences 同序）。
/// 播放与缓存任务共用同一套坐标，保证命中。
List<int> chapterTtsSentenceOffsets(Chapter ch) {
  final offs = <int>[];
  var acc = 0;
  for (final p in ch.paragraphs) {
    for (final s in p.sentences) {
      offs.add(acc);
      acc += s.tts.length;
    }
  }
  return offs;
}
