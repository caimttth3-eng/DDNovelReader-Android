library;

// 版本信息与更新记录（安卓版）。
// 版本号与 pubspec.yaml 的 `version` 保持一致（发布一条龙第 2 步）。
// 更新记录文案：软件内「关于」页使用；发布新版本时同步追加条目。

class VersionInfo {
  static const String appName = '多多朗读';
  static const String version = '1.2.1';
  static const String build = '6';
  static const String platform = 'Android';

  /// 更新记录，新版本在最上面。
  static const List<String> changelog = [
    'v1.2.1：新增用户自选字体，支持导入 .ttf/.otf 字体文件，'
        '立即生效、重启自动加载；不内置字体，包体无增加。',
    'v1.2.0：界面支持 5 种语言（简体/繁体/英语/日语/韩语），'
        '跟随系统语言自动切换；Edge TTS 新增多语言音色'
        '（简/繁/英/日/韩共 20 个），默认语言音色置顶。',
    'v1.1.2：发布页优化，桌面版 / 安卓版互相引流；稳定化更新。',
    'v1.1.1：修复朗读相关问题。',
    'v1.0：正式版。朗读模式（播放/暂停、语速调节、定时播放、音源切换、'
        '假锁屏、退出朗读）、阅读/UI 双模式、章节跳转、句子级高亮跟随、'
        '滑动快进、书页背景切换、音量滑条、标题固定、正文缩进、'
        '加载动画与超时保护。',
  ];
}
