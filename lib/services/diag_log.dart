import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 真机诊断日志：写到 App Documents 下，iOS 可在「文件」App 里直接看到
/// （Info.plist 已开 UIFileSharingEnabled / LSSupportsOpeningDocumentsInPlace）。
Future<void> diagLog(String message) async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/dd_log.txt');
    await file.writeAsString(
      '${DateTime.now().toIso8601String()} $message\n',
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {}
}
