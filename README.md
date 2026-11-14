# 多多朗读 DDNovelReader · 阅读与朗读增强版

Android 本地 TXT / EPUB 阅读器，支持 Edge 在线语音和系统文本转语音。本仓库公开维护阅读交互、排版、进度恢复和朗读控制方面的修改。

## 来源与致谢

本项目 fork 自 **[caimttth3-eng/DDNovelReader-Android](https://github.com/caimttth3-eng/DDNovelReader-Android)**。原始应用、Flutter 架构和基础阅读、Edge TTS 功能来自原作者 **caimttth3-eng**；本仓库由 **NayGnehz** 维护后续修改，不是原作者的官方发布。

- 原 Android 项目：<https://github.com/caimttth3-eng/DDNovelReader-Android>
- 原作者桌面版：<https://github.com/caimttth3-eng/DDNovelReader>
- 本修改版源码：<https://github.com/NayGnehz/DDNovelReader-Android>
- 本修改版下载：[GitHub Releases](https://github.com/NayGnehz/DDNovelReader-Android/releases)

其他方案与资源见 [来源说明](docs/SOURCES.md)。原作者及第三方权利声明保留；目前上游没有单独的 LICENSE 文件，本仓库不擅自为上游代码补授其他许可证。第三方依赖与图标分别遵守其原有许可证。

## 下载与安装

当前版本 **1.2.23（28）**：[下载 ARM64-v8a APK](https://github.com/NayGnehz/DDNovelReader-Android/releases/download/v1.2.23/DDNovelReader-v1.2.23-arm64-v8a.apk)。支持 Android 7.0（API 24）及以上的 ARM64 设备，安装包约 19.4 MB。

本分支使用固定签名，后续使用相同证书的版本可覆盖更新。与原作者版本或早期临时调试签名不同，无法直接覆盖安装；更换前请备份书籍与数据。Release 提供 SHA-256 校验文件，详见 [固定签名说明](docs/signing.md)。

## 主要功能与修改

### 阅读、排版与目录

- 保留 TXT / EPUB 导入、书架、查找、书签、划线和自选字体；逐书保存进度，重新进入继续阅读。
- 普通阅读提供“点击左右侧 / 左右滑动 / 上下滚动”三种方式，默认仅点击翻页；分页以完整文字行为边界，可选择保留上一页末行。
- 翻页动画可关闭或使用平移，默认关闭；上下工具栏覆盖正文，显隐不挤占正文空间。
- 两端对齐、允许行首标点、字号最大 64；亮度和字号有独立快捷入口。亮度 A 按钮恢复系统亮度，滑杆左侧可额外调暗。
- 自动提取 TXT 目录与章节标题，默认开启；关闭后约 5000 字分节。支持章节跳转和进度拖动。
- 文本修正、首行缩进默认开启，同时作用于显示和朗读；分级无关内容过滤默认开启一级，可关闭。通过原文坐标映射保持进度、书签和高亮位置。
- 深浅主题默认跟随系统；适配刘海和挖孔区域的章节信息，默认竖屏锁定，可手动横竖屏切换或开启跟随系统旋转。
- 自动翻页支持间隔选择、移动指示线及暂停/停止。

### 朗读与播放设置

- 支持原有 Edge 在线音色及 Android 系统文本转语音。系统音源的离线能力、可用语言及词范围回调取决于所装引擎。
- 整句高亮；可开启逐词高亮，缺少真实词边界时自动回退整句。使用实际范围与时间信息，不估算逐词时间。
- 朗读时上下滑动切句；按下后上下拖动可连续切句，触发延时默认 0.2 秒，可调整。
- 音量键正常调整媒体音量，并同步播放栏；语速按钮和滑杆按 0.1 调整，长期保存。
- 在线预加载默认后续 8 句，可设置 0–100 句；每个在线音色旁提供语音缓存入口。断网先使用缓存和预加载，用完切至系统音源，恢复联网后由用户手动切回。
- 追加停顿可按标点和“段后”调整；破折号、省略号默认各 0.20 秒，段后默认 0.30 秒，其余 0。范围 0.00–3.00 秒、步长 0.05 秒；展开后点击“应用停顿”保存，关闭菜单丢弃未应用草稿。
- 系统通知栏和锁屏支持上一句、暂停/继续、下一句、停止；可开启“在系统栏中显示播送原文”，默认关闭，随句更新。最终样式和可见行数由手机系统决定。
- 定时停止支持自定义，最长 120 分钟；阅读和朗读亮屏时长分别保存。亮屏到期释放窗口常亮，由系统处理熄屏，不申请设备管理器或辅助功能权限。

修复包括远距离跳转后空白、选章后上一页首行裁切、音源切换后高亮停滞、暂停后从段首重播、变速后位置匹配及通知暂停后无法继续等路径。两个偶发报告（念出标点名称、倍速后中央点击改变光标）的相关风险路径已有回归测试，尚未在真机完整复现其所有触发方式。

## 构建与验证

使用 Flutter 3.50.0、JDK 17 和 Android SDK；依赖版本见 `pubspec.lock`，完整在线流程见 [.github/workflows/build-apk.yml](.github/workflows/build-apk.yml)。

```sh
flutter pub get
flutter analyze --no-fatal-infos --no-fatal-warnings
flutter test --reporter expanded
flutter build apk --release --target-platform android-arm64 --split-debug-info=build/debug-symbols
```

在线构建使用仓库 Secret `DDNOVEL_SIGNING_JSON`；缺少 Secret 和 PR 构建只提供明确标记的未签名产物。私钥不进入源码、日志或 Release。`DDNovelReader-build-analysis` 单独保存 APK 体积报告与调试符号。

1.2.23 的 [GitHub 构建](https://github.com/NayGnehz/DDNovelReader-Android/actions/runs/43572352424) 通过 310 项 Flutter 测试、13 项签名脚本测试及独立在线语音探测；主套件有 1 项可选在线探测跳过。下载成品已独立核验版本、ARM64 架构、SHA-256 和固定证书。手机音源、系统通知样式及实际手感仍需真机验证。

## 文档

- [更新日志](CHANGELOG.md)
- [阅读与播放设置](docs/playback-settings.md)
- [文本处理与朗读定位](docs/reader-text-rules.md)
- [系统媒体控制与包体积](docs/media-controls.md)
- [固定签名与构建](docs/signing.md)
- [来源说明](docs/SOURCES.md)
