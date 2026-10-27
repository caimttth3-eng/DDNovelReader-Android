import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../i18n.dart';
import '../version_info.dart';

/// 关于页（弹窗）。参考 PC 版关于窗口：版本信息 + 作者联系方式（可复制/打开）+ 更新记录。
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => const AboutScreen(),
    );
  }

  Future<void> _copy(BuildContext context, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(T('copied', {'text': text}))),
    );
  }

  Future<void> _openUrl(BuildContext context, String url) async {
    final uri = Uri.parse(url);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(T('openFail'))),
      );
    }
  }

  Widget _contactRow({
    required BuildContext context,
    required IconData icon,
    required String label,
    required String value,
    required String actionText,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        child: Row(
          children: [
            Icon(icon, size: 20, color: const Color(0xFF5D3A1A)),
            const SizedBox(width: 10),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: label,
                      style: const TextStyle(color: Colors.black87),
                    ),
                    TextSpan(
                      text: ' $value',
                      style: const TextStyle(
                        color: Color(0xFF5D3A1A),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Text(
              actionText,
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFF5D3A1A),
                decoration: TextDecoration.underline,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final versionText = '${VersionInfo.appName} v${VersionInfo.version}';
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题栏
            Container(
              padding: const EdgeInsets.fromLTRB(20, 14, 8, 14),
              decoration: const BoxDecoration(
                color: Color(0xFF5D3A1A),
                borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.menu_book, color: Colors.white),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      T('aboutTitle'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            // 内容（可滚动）
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            color: const Color(0xFFF3E9DC),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Center(
                            child: Text(
                              'DD',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF5D3A1A),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                versionText,
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                T('aboutSub', {'ver': VersionInfo.version}),
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: Colors.black54,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const Divider(height: 1),
                    const SizedBox(height: 8),
                    // 作者联系方式
                    _contactRow(
                      context: context,
                      icon: Icons.email_outlined,
                      label: T('emailLabel'),
                      value: '230468896@qq.com',
                      actionText: T('copyAction'),
                      onTap: () => _copy(context, '230468896@qq.com'),
                    ),
                    _contactRow(
                      context: context,
                      icon: Icons.video_library_outlined,
                      label: T('biliLabel'),
                      value: 'https://space.bilibili.com/42444',
                      actionText: T('openAction'),
                      onTap: () => _openUrl(context, 'https://space.bilibili.com/42444'),
                    ),
                    _contactRow(
                      context: context,
                      icon: Icons.smart_display_outlined,
                      label: T('douyinLabel'),
                      value: '120735162',
                      actionText: T('copyAction'),
                      onTap: () => _copy(context, '120735162'),
                    ),
                    _contactRow(
                      context: context,
                      icon: Icons.link_outlined,
                      label: T('releaseLabel'),
                      value: 'github.com/caimttth3-eng/DDNovelReader-Android',
                      actionText: T('openAction'),
                      onTap: () =>
                          _openUrl(context, 'https://github.com/caimttth3-eng/DDNovelReader-Android'),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      T('feedback'),
                      style: const TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                    const SizedBox(height: 16),
                    const Divider(height: 1),
                    const SizedBox(height: 10),
                    // 更新记录（每次更新信息）
                    Text(
                      T('changelogTitle'),
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF5D3A1A),
                      ),
                    ),
                    const SizedBox(height: 6),
                    for (final line in VersionInfo.changelog)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          line,
                          style: const TextStyle(fontSize: 13, height: 1.4),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
