import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 用户自选字体管理：导入 / 注册 / 删除。
///
/// - 字体文件存放在应用私有目录 `.../fonts/`，不随 APK 打包（包体零负担）。
/// - Flutter 的 FontLoader 注册仅在进程内有效，因此每次启动必须重新注册
///   （见 main.dart 的 [FontManager.registerAll]）。
/// - family 名 = 文件名（去扩展名），用于 TextStyle(fontFamily)。
class FontManager {
  FontManager._();

  static const List<String> kExtensions = ['.ttf', '.otf'];

  static Future<Directory> fontsDir() async {
    final root = await getApplicationDocumentsDirectory();
    final dir = Directory('${root.path}/fonts');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// 已导入字体文件名列表（.ttf/.otf，按名称排序）。
  static Future<List<String>> listImported() async {
    final dir = await fontsDir();
    return dir
        .listSync()
        .whereType<File>()
        .map((f) => f.path.split(Platform.pathSeparator).last)
        .where((n) => kExtensions.any((e) => n.toLowerCase().endsWith(e)))
        .toList()
      ..sort();
  }

  /// 文件名 → FontLoader family 名（去扩展名）。
  static String familyOf(String fileName) {
    final lower = fileName.toLowerCase();
    for (final e in kExtensions) {
      if (lower.endsWith(e)) return fileName.substring(0, fileName.length - e.length);
    }
    return fileName;
  }

  /// 导入字体：校验扩展名 → 复制到私有 fonts 目录 → 立即注册。
  /// 返回 family 名；非法格式返回 null。
  static Future<String?> importFont(String srcPath) async {
    final lower = srcPath.toLowerCase();
    if (!kExtensions.any((e) => lower.endsWith(e))) return null;

    final dir = await fontsDir();
    final base = srcPath.split(Platform.pathSeparator).last;
    final safe = base.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final fileName = '${DateTime.now().millisecondsSinceEpoch}_$safe';
    final dest = File('${dir.path}/$fileName');
    try {
      await File(srcPath).copy(dest.path);
    } catch (_) {
      return null;
    }
    final family = familyOf(fileName);
    try {
      await register(dest.path, family);
    } catch (_) {
      // 注册失败则删除文件，避免残留坏字体
      try {
        dest.deleteSync();
      } catch (_) {}
      return null;
    }
    return family;
  }

  /// 注册单个字体文件到全局字体表。
  static Future<void> register(String filePath, String family) async {
    final bytes = await File(filePath).readAsBytes();
    final loader = FontLoader(family)
      ..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  }

  /// 启动时注册全部已导入字体（坏文件跳过，不影响启动）。
  static Future<void> registerAll() async {
    try {
      final files = await listImported();
      for (final name in files) {
        final dir = await fontsDir();
        try {
          await register('${dir.path}/$name', familyOf(name));
        } catch (_) {
          // 单个坏字体跳过
        }
      }
    } catch (_) {}
  }

  /// 删除已导入字体文件。
  static Future<void> removeFont(String fileName) async {
    final dir = await fontsDir();
    final f = File('${dir.path}/$fileName');
    if (f.existsSync()) f.deleteSync();
  }
}
