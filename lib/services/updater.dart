import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../i18n.dart';
import '../version_info.dart';

/// 更新提示（参考 PC 版 updater.py）：启动时后台检查 GitHub 最新 Release，
/// 有新版本时弹窗（仅提示，不自动下载安装）。
/// 弹窗提供「去下载 / 稍后 / 跳过此版本」；跳过记入设置 skip_update_version，
/// 之后不再提示该版本。网络失败静默，不影响启动。
class Updater {
  static const String _repo = 'caimttth3-eng/DDNovelReader-Android';
  static const String _latestUrl =
      'https://api.github.com/repos/$_repo/releases/latest';
  static const String _skipKey = 'skip_update_version';

  /// 把版本串解析为可比较三元组 (major, minor, patch)。
  /// 兼容三段式（1.2.2 / v1.2.2）与历史格式（取数字前缀）。
  static List<int> parseVersion(String v) {
    var s = v.trim();
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    final nums = <int>[];
    for (final part in s.split('.')) {
      final m = RegExp(r'^\d+').firstMatch(part);
      nums.add(m == null ? 0 : int.parse(m.group(0)!));
    }
    while (nums.length < 3) {
      nums.add(0);
    }
    return nums.sublist(0, 3);
  }

  /// a > b 返回 1；a == b 返回 0；a < b 返回 -1。
  static int compareVersion(String a, String b) {
    final pa = parseVersion(a);
    final pb = parseVersion(b);
    for (var i = 0; i < 3; i++) {
      if (pa[i] != pb[i]) return pa[i] > pb[i] ? 1 : -1;
    }
    return 0;
  }

  /// 拉取 GitHub 最新 Release，返回 {tag, body, url}；失败返回 null。
  static Future<Map<String, String>?> fetchLatest() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(Uri.parse(_latestUrl));
      req.headers.set(HttpHeaders.userAgentHeader, 'DDNovelReader');
      final res = await req.close();
      if (res.statusCode != 200) return null;
      final body = await res.transform(utf8.decoder).join();
      final j = jsonDecode(body) as Map<String, dynamic>;
      return <String, String>{
        'tag': (j['tag_name'] as String?) ?? '',
        'body': (j['body'] as String?) ?? '',
        'url': (j['html_url'] as String?) ??
            'https://github.com/$_repo/releases/latest',
      };
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// 启动后台检查：有新版本且未被跳过 → 弹窗；网络失败/已最新静默。
  static Future<void> checkAuto(BuildContext context) async {
    final rel = await fetchLatest();
    if (rel == null || rel['tag'] == null || rel['tag']!.isEmpty) return;
    if (compareVersion(rel['tag']!, VersionInfo.version) <= 0) return;
    final prefs = await SharedPreferences.getInstance();
    final skip = prefs.getString(_skipKey);
    if (skip != null && parseVersion(skip) == parseVersion(rel['tag']!)) return;
    if (!context.mounted) return;
    _showDialog(context, rel);
  }

  /// 手动检查（关于页按钮）：有新版→弹窗；已最新→提示；失败→提示原因。
  /// 手动检查忽略 skip_update_version。
  static Future<void> checkManual(BuildContext context) async {
    final rel = await fetchLatest();
    if (!context.mounted) return;
    if (rel == null || rel['tag'] == null || rel['tag']!.isEmpty) {
      _snack(context, T('checkUpdateFail'));
      return;
    }
    if (compareVersion(rel['tag']!, VersionInfo.version) <= 0) {
      _snack(context, T('alreadyLatest'));
      return;
    }
    _showDialog(context, rel);
  }

  static void _snack(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  static Future<void> _openUrl(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  /// 更新提示弹窗：最新版本/当前版本 + 更新内容 + 去下载/稍后/跳过此版本。
  /// 去下载只打开下载页，弹窗保持打开（可继续点「稍后」或「跳过此版本」）。
  static Future<void> _showDialog(
    BuildContext context,
    Map<String, String> info,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(T('newVersion')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${T('latestVersion')}  ${info['tag']}    |    '
                '${T('currentVersion')}  ${VersionInfo.version}',
                style: const TextStyle(fontSize: 13, color: Colors.black54),
              ),
              const SizedBox(height: 10),
              Text(
                T('updateContent'),
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: SingleChildScrollView(
                  child: Text(
                    (info['body'] ?? '').trim().isEmpty
                        ? T('noUpdateContent')
                        : info['body']!,
                    style: const TextStyle(fontSize: 13, height: 1.5),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await prefs.setString(_skipKey, info['tag']!);
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: Text(T('skipVersion')),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(T('later')),
          ),
          FilledButton(
            onPressed: () => _openUrl(info['url']!),
            child: Text(T('goDownload')),
          ),
        ],
      ),
    );
  }
}
