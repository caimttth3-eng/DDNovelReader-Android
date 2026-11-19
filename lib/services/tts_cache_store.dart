// 来源：NayGnehz/DDNovelReader-Android 的 PR #2（commit 27b6a1e，部分代码，已修改适配本项目的缓存/同步架构）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';

import 'package:path_provider/path_provider.dart';

import '../models/book.dart';
import '../models/speech_word.dart';

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
/// 目录契约与 PC 端完全一致（novelreader/tts_engine.py WholeBookCacher）：
/// ` <appSupport>/tts_cache/<contentKey>/<voice>/<pct>/ `
/// - 一级键 contentKey：书名 + 全文口径算出，跨设备可复现（见 content_key.dart）；
/// - 语速目录 pct：直接是「传给 Edge 的百分比整数」，PC rate=300 ↔ 安卓 1.50 ↔ "50"；
/// - 文件 `{章:04d}_{章内原文偏移:08d}.mp3`：偏移按**码点**计，与 PC clean_to_orig 同口径；
/// - 原子写：先写 `.tmp` 再 rename 发布，朗读线程永远读不到半截文件；
/// - 进度 `progress.json` 同时写 `bookId` 与 `book_id`（值都是 contentKey），
///   rate 写 pct 字符串，PC 与安卓读写同一份即可续传。
class TtsCacheStore {
  /// 本机书籍 id（旧缓存目录名；只用于懒迁移兜底）
  final String bookId;

  /// 缓存一级目录 = contentKey（跨端稳定）；为空时退化为 bookId
  final String cacheKey;

  final String voice;
  final double rate;

  /// 重新格式化后的正文指纹（PR2 引入）：非空时在语速目录下再分一层，
  /// 避免改排版/过滤后旧音频错配；与 contentKey 并存（跨端目录仍按 contentKey）。
  final String? textFingerprint;

  TtsCacheStore(this.bookId, this.voice, this.rate,
      {String contentKey = '', this.textFingerprint})
      : cacheKey = (contentKey.isNotEmpty ? contentKey : bookId);

  /// 语速目录名 = 合成百分比整数（与 PC rate_dir_key 同值）
  String get rateKey => ratePctOfSpeechRate(rate).toString();

  /// 安卓倍率 → 百分比整数：1.0 → 0，1.5 → 50，0.5 → -50
  static int ratePctOfSpeechRate(double rate) {
    final pct = ((rate - 1.0) * 100).round();
    if (pct < -100) return -100;
    if (pct > 200) return 200;
    return pct;
  }

  static const _progressFile = 'progress.json';
  static const _layoutMark = '.tts_layout_v2';
  static final Map<String, Future<void>> _migrations = {};

  static Future<Directory> rootDir() async {
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}${Platform.pathSeparator}tts_cache');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// 当前语音/语速目录（含旧目录懒迁移）
  Future<Directory> dir() async {
    final root = await rootDir();
    await _migrateLegacyLayout(root);
    final d = Directory([
      root.path,
      _safe(cacheKey),
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

  // ---------- 旧布局懒迁移（只动本书，不扫全盘）----------

  /// 把本机旧布局搬到新契约：
  /// 1) 一级目录 `<book.id>` → `<contentKey>`；
  /// 2) 语速目录 `1.00` / `1.50` → `0` / `50`（纯整数的目录视为已是新格式，跳过）。
  /// 已迁移过（有标记文件）就只做一次 exists 判断，后续零成本。
  Future<void> _migrateLegacyLayout(Directory root) {
    final key = '${root.path}/$bookId/$cacheKey';
    return _migrations.putIfAbsent(key, () async {
      try { await _performLegacyMigration(root); }
      finally { _migrations.remove(key); }
    });
  }

  Future<void> _performLegacyMigration(Directory root) async {
    try {
      final sep = Platform.pathSeparator;
      final keyDir = Directory('${root.path}$sep${_safe(cacheKey)}');
      final mark = File('${keyDir.path}$sep$_layoutMark');
      if (await mark.exists()) return;

      if (cacheKey != bookId) {
        final oldDir = Directory('${root.path}$sep${_safe(bookId)}');
        if (await oldDir.exists()) {
          if (!await keyDir.exists()) {
            await oldDir.rename(keyDir.path);
          } else {
            await _moveDirInto(oldDir, keyDir);
          }
        }
      }

      if (await keyDir.exists()) await _migrateRateDirs(keyDir);
      if (!await keyDir.exists()) await keyDir.create(recursive: true);
      await mark.writeAsString('2', flush: true);
    } on FileSystemException catch (error) {
      debugPrint('Speech cache migration failed; existing audio retained: $error');
      rethrow;
    }
  }

  static Future<void> _migrateRateDirs(Directory keyDir) async {
    final sep = Platform.pathSeparator;
    final rateNameRe = RegExp(r'^([0-9]+)\.([0-9]+)$');
    await for (final voiceDir in keyDir.list(followLinks: false)) {
      if (voiceDir is! Directory) continue;
      await for (final sub in voiceDir.list(followLinks: false)) {
        if (sub is! Directory) continue;
        final name = sub.uri.pathSegments.where((segment) => segment.isNotEmpty).last;
        final m = rateNameRe.firstMatch(name);
        if (m == null) continue; // 纯整数 pct 目录：已是新格式
        final r = double.tryParse(name);
        if (r == null) continue;
        final target = Directory(
            '${voiceDir.path}$sep${ratePctOfSpeechRate(r).toString()}');
        final children = await sub.list(followLinks: false).toList();
        if (children.any((entry) => entry is File && entry.path.endsWith('.mp3'))) {
          // Legacy raw audio used TTS offsets, not desktop source offsets.
          // Preserve it without exposing it under the new coordinate scheme.
          await target.create(recursive: true);
          for (final child in children.whereType<Directory>()) {
            final leaf = child.uri.pathSegments.where((part) => part.isNotEmpty).last;
            if (leaf.startsWith('text-')) await _moveDirInto(child, Directory('${target.path}$sep$leaf'));
          }
          debugPrint('Legacy unversioned audio retained at ${sub.path}; new source-coordinate audio will be rebuilt.');
          continue;
        }
        if (!await target.exists()) {
          await sub.rename(target.path);
        } else {
          await _moveDirInto(sub, target);
        }
      }
    }
  }

  static Future<void> _moveDirInto(Directory src, Directory dst) async {
    final sep = Platform.pathSeparator;
    await dst.create(recursive: true);
    await for (final e in src.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final rel = e.path.substring(src.path.length + 1);
      final target = File('${dst.path}$sep$rel');
      await target.parent.create(recursive: true);
      if (!await target.exists()) {
        await e.rename(target.path);
      } else if (listEquals(await e.readAsBytes(), await target.readAsBytes())) {
        await e.delete();
      } else {
        debugPrint('Speech cache migration kept a differing legacy file: ${e.path}');
      }
    }
    final directories = await src.list(recursive: true, followLinks: false).where((entry) => entry is Directory).cast<Directory>().toList();
    directories.sort((a, b) => b.path.length.compareTo(a.path.length));
    for (final directory in [...directories, src]) {
      if (await directory.list(followLinks: false).isEmpty) await directory.delete();
    }
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
  Future<void> write(int ci, int off, Uint8List audio,
      {List<SpeechWord>? words}) async {
    try {
      final d = await dir();
      final finalPath = '${d.path}${Platform.pathSeparator}${fileName(ci, off)}';
      final tmpPath = '$finalPath.tmp';
      final tmp = File(tmpPath);
      if (words != null) {
        final metadata = File('$finalPath.words.json.tmp');
        await metadata.writeAsString(
            jsonEncode(words.map((w) => w.toJson()).toList()),
            flush: true);
        await metadata.rename('$finalPath.words.json');
      }
      await tmp.writeAsBytes(audio, flush: true);
      await tmp.rename(finalPath);
    } catch (_) {}
  }

  /// 读取某段音频的字级时间轴（PR2 引入，系统/在线词级高亮共用）
  Future<List<SpeechWord>> readWords(int ci, int off) async {
    try {
      final file = File('${await _pathOf(ci, off)}.words.json');
      if (!await file.exists()) return [];
      final raw = jsonDecode(await file.readAsString()) as List<dynamic>;
      return raw
          .map((w) => SpeechWord.fromJson(w as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  // ---------- 进度持久化 ----------

  /// 返回进度记录；无进度或 voice 不匹配返回 null。
  /// bookId / rate 允许旧值（懒迁移前的 book.id 与 "1.00"），以免丢进度。
  Future<CacheProgress?> loadProgress() async {
    try {
      final d = await dir();
      final p = File('${d.path}${Platform.pathSeparator}$_progressFile');
      if (!await p.exists()) return null;
      final data = jsonDecode(await p.readAsString()) as Map<String, dynamic>;
      if (data['voice'] != voice) return null;
      final bid = data['book_id'] ?? data['bookId'];
      if (bid != null && bid != cacheKey && bid != bookId) return null;
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
        // 双键：PC 读 book_id，安卓历史版本读 bookId，值统一为 contentKey
        'bookId': cacheKey,
        'book_id': cacheKey,
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

  /// 当前 contentKey/voice/rate 目录占用字节数（排除 progress.json 与 .tmp）
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

  /// 当前 contentKey/voice/rate 目录下全部 mp3 文件名（不含 progress.json/.tmp），
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

  /// 目录名安全化（公开版，供书架按 contentKey 匹配缓存目录）
  static String safeId(String s) => _safe(s);

  /// 每本书缓存占用：[(contentKey 目录名, bytes)]，按占用降序
  static Future<List<(String, int)>> listBookSizes() async {
    final result = <(String, int)>[];
    try {
      final root = await rootDir();
      if (!await root.exists()) return result;
      await for (final e in root.list(followLinks: false)) {
        if (e is! Directory) continue;
        final bookId = e.uri.pathSegments.where((segment) => segment.isNotEmpty).last;
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

  /// 清除某本书（contentKey 目录名）的全部语音缓存，返回删除文件数
  static Future<int> clearBook(String cacheKeyName) async {
    var n = 0;
    try {
      final root = await rootDir();
      final d = Directory(
          [root.path, cacheKeyName].join(Platform.pathSeparator));
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

/// 章节内所有句子的「原文偏移」（与 PC WholeBookCacher 的文件名坐标同口径）。
///
/// - 偏移按 Unicode 码点计（PC 是 Python 字符串下标 = 码点）；
/// - 起点是「章内正文」中被清洗保留的首字符位置，等价 PC clean_to_orig；
/// - 段落之间补 1 个 '\n'，与 PC content 的段落分隔一致。
/// 播放与缓存任务共用同一套坐标，保证命中。
List<int> chapterSentenceOffsets(Chapter ch) {
  final offs = <int>[];
  final whitespace = RegExp(r'\s');
  var acc = 0;
  for (final p in ch.paragraphs) {
    for (final s in p.sentences) {
      var ds = s.displayStart.clamp(0, p.display.length);
      while (ds < p.display.length && whitespace.hasMatch(p.display[ds])) { ds++; }
      offs.add(ch.sourceCoordinates[acc + ds]);
    }
    acc += p.display.length + 1;
  }
  return offs;
}

/// 章节内所有句子的 tts 累计字符偏移（与阅读页/缓存任务同一坐标）。
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
