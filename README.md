# 多多朗读 DDNovelReader

安卓 + iOS 本地小说阅读器，支持 Edge TTS 在线朗读、智能分章、句子级高亮跟随。

- 中文名：多多朗读
- 英文名：DDNovelReader
- 包名：`com.ddnovelreader`

---

## 🎉 iOS 版正式上线

**v1.3.0 起支持 iPhone / iPad，v1.3.1 完善系统音色选择**，与安卓共用同一套阅读、朗读与同步能力。

> iOS 版以**未签名 IPA** 形式发布（不走 App Store），需要用签名工具自签安装。
> 这是苹果的限制，不是安装包损坏；按下面的教程操作即可。

### 下载

前往 [Releases](https://github.com/caimttth3-eng/DDNovelReader-Android/releases) 下载：

- iOS：`DDNovelReader_v1.3.1_unsigned.ipa`（约 9MB）
- Android：三个架构 APK（见下方「下载」）

### 系统要求

- iOS / iPadOS **15.0 及以上**
- 首次安装需要一台 Windows 或 macOS 电脑（用于签名）
- 免费 Apple ID 即可，**不需要** 99 美元开发者账号

### 签名工具怎么选

| 工具 | 电脑端 | 费用 | 有效期 | 说明 |
|---|---|---|---|---|
| **Sideloadly**（推荐） | Windows / macOS | 免费 Apple ID | **7 天** | 最简单，拖入 IPA 即可；到期重新签一次 |
| **AltStore + AltServer** | Windows / macOS | 免费 Apple ID | 7 天，可自动续签 | 需电脑和手机在同一 Wi-Fi，AltServer 常驻 |
| **TrollStore** | 不需要电脑 | 免费 | 永久 | **仅支持 iOS ≤ 17.0**；iOS 18.7.7 等新系统不支持 |
| **Apple Developer** | Windows / macOS | 688 元/年 | 1 年 | 适合长期用、多设备；也可走 TestFlight |

> 你的 iPhone 是 iOS 18.x 的话，TrollStore 用不了，选 **Sideloadly** 或 **AltStore**。

### 三步快速安装（Sideloadly）

1. 电脑安装 **iTunes**（微软商店版）或 **Apple Devices** + [Sideloadly](https://sideloadly.io)
2. 下载上面的 `.ipa`，iPhone 连线并点「信任此电脑」
3. Sideloadly 里拖入 IPA → 填 Apple ID → Start → 输入密码

装完后在 iPhone 上：

1. 设置 → 隐私与安全性 → **开发者模式** → 打开 → 重启手机
2. 设置 → 通用 → VPN 与设备管理 → 信任你的 Apple ID 证书
3. 桌面打开「多多朗读」

**7 天后** App 会打不开，用同样步骤重新签一次即可（覆盖安装，书架和进度保留）。

👉 **完整图文教程（含 AltStore 自动续签、常见问题）**：[docs/ios-install.md](docs/ios-install.md)

### iOS 版说明

- 朗读走 Edge TTS 在线合成，首次播放需联网
- 后台播放、锁屏/通知栏控制（上一句 / 暂停 / 下一句 / 停止）可用
- **音量键逐句跳转**：iOS 不允许监听音量键，iOS 版不支持（可用耳机/锁屏控制）
- **离线系统语音**：已接入 iOS 自带的 AVSpeechSynthesizer；音源面板「本地语音（离线）」会列出系统全部音色（标注默认/优化/高级音质），选中即完全离线朗读。想更好听可在 iPhone「设置 → 辅助功能 → 朗读内容 → 声音」下载优化音质音色
- 应用内「数据同步」（WebDAV）与安卓、电脑版互通
- 卸载 App 会清空书架和进度；**重签请用覆盖安装，不要先卸载**

---

## 下载

- **Android**：本仓库 [Releases](https://github.com/caimttth3-eng/DDNovelReader-Android/releases) 下载 APK（三架构）
- **iOS**：同页下载 `DDNovelReader_v1.3.1_unsigned.ipa`，按上面的教程自签
- **Windows / macOS / Linux**：前往 [桌面版发布页](https://github.com/caimttth3-eng/DDNovelReader) 下载（Windows 绿色免安装 exe / macOS DMG / Linux 单文件）

> 桌面版功能更全：本地离线语音 + Edge 神经语音、整本语音缓存、书签划线笔记、全文搜索、多主题、定时播放。

## 功能

### 阅读（v1.3.0 重做）
- 完整行分页：翻页不裁字，末行与下一页衔接
- 翻页方式：上下滚动 / 点击翻页 / 滑动翻页；可开翻页动画
- 浮动上下栏，不挤占正文；顶部显示章节信息
- 自动目录索引，目录跳转后首行不裁切
- 字号最大 64、两端对齐、行首标点处理
- 深浅主题跟随系统，支持手动切换；刘海/安全区适配
- 逐书保存进度；左右侧点击、滑动、上下滚动可选

### 朗读
- Edge TTS 在线合成，句子级高亮 + 逐字高亮跟随
- 离线系统语音（iOS AVSpeechSynthesizer / 安卓系统 TTS），可选系统音色与音质，音源选择里切换
- 连续拖动切句；语速 0.5x–3.0x（0.02 步进）
- 播放设置长期保存（预取、逐字高亮、亮屏时长、停顿等）
- 预取并发 + 换章预取，减少「正在加载语音」
- 定时播放（15 / 30 / 60 / 90 分钟）
- 20 个多语言音色（简/繁/英/日/韩）

### 通知栏 / 锁屏
- 上一句、暂停/继续、下一句、停止
- 可选显示原文

### 数据同步
- 书架菜单「数据同步」：WebDAV 网盘（如坚果云），测试连接 / 立即同步
- 启动自动同步 + 前台每 10 分钟；书架、进度、书签双向同步，删除同步移除
- 与电脑版、iOS/安卓共用同一份远端数据
- 阅读页顶栏支持「一键同步」

### 书架
- 4 列木纹卡片，底部腰封显示进度
- 首位「添加书籍」占位卡，调用系统文件管理器
- 支持 TXT / EPUB，最近打开的书排最前
- 无限下滑滚动

### 自选字体
- 设置面板「字体更换」：导入 .ttf/.otf，立即生效、重启自动加载；不内置字体

### 文本处理
- 双文本底层：显示保留原文，TTS 使用纯净文本
- TXT 编码自动识别（UTF-8 / GBK / GB18030 / Big5）
- 智能分章：第 X 章/卷、Chapter N、序章、楔子、番外等

---

## 技术架构

```
lib/
├── main.dart                  # 入口，AudioService / 音频会话初始化
├── models/
│   ├── book.dart              # Book / Chapter / Paragraph / Sentence
│   ├── progress.dart          # 进度与书架元信息
│   └── annotation.dart        # 书签 / 划线
├── screens/
│   ├── shelf_screen.dart      # 书架
│   ├── book_opening_screen.dart # 打开书籍（先出加载页再解析）
│   ├── reader_screen.dart     # 阅读/朗读页
│   └── sync_screen.dart       # WebDAV 同步设置
├── services/
│   ├── app_storage.dart       # 本地存储（设置/进度/书架/墓碑）
│   ├── book_parser.dart       # TXT / EPUB / PDF / DOCX 解析
│   ├── chapterizer.dart       # 智能分章
│   ├── edge_tts.dart          # Edge TTS 协议（Sec-MS-GEC v2）
│   ├── tts_reader.dart        # 逐句朗读、预取、切句
│   ├── tts_cache_store.dart   # 跨端语音缓存
│   ├── sync_engine.dart       # WebDAV 同步引擎
│   ├── webdav_client.dart     # WebDAV 客户端
│   ├── reading_text.dart      # 排版/分页文本
│   └── tts_audio_handler.dart # MediaSession
└── widgets/
    └── book_card.dart         # 木纹书籍卡片
```

### 关键依赖
- `scrollable_positioned_list`、`audio_service`、`audioplayers`、`audio_session`
- `crypto`（Edge TTS 签名）、`file_picker`、`path_provider`

### Edge TTS 协议
- 端点：`https://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1`
- 20 个多语言音色（简 7 / 繁 3 / 英 6 / 日 2 / 韩 2）
- 输出：audio-24khz-48kbitrate-mono-mp3

---

## 构建

### Android

```bash
flutter pub get
flutter build apk --release --target-platform android-arm64   # 或 android-arm / android-x64
```

产物：`build/app/outputs/flutter-apk/app-release.apk`

环境：Flutter 3.x stable、Android SDK、minSdk 21、targetSdk 35。

### iOS（未签名 IPA）

```bash
flutter build ios --release --no-codesign
mkdir -p Payload && cp -R build/ios/iphoneos/Runner.app Payload/
zip -qry DuoDuoLangDu-unsigned.ipa Payload
```

没有 Mac 时用仓库的 GitHub Actions：`.github/workflows/ios-ipa.yml`（macOS runner）。

---

## 版本历史

### v1.3.2（2026-11-20）
整本语音缓存修复：重进或升级后不再显示缓存归零。打开缓存面板会扫描磁盘实际文件，校验并补全缺失句；新增「重新扫描」；进度写入书名，旧缓存可按书名自动收养；续传跳过已缓存，不重复下载。

### v1.3.1（2026-11-20）
离线系统语音升级：音源面板可列出并选择系统音色（标注默认/优化/高级音质），支持按图书记忆音色与语速；新增「仅显示优化音质」过滤与系统设置入口；来电或其他 App 占用音频后自动续读；安卓端也可枚举系统音色。iOS 版同步发布。

### v1.3.0（2026-11-18）
阅读和朗读大更新，**iOS 版首次上线**。翻页更顺：支持上下滚动、整页不裁字、可开翻页动画；新增自动目录、字号最大 64、两端对齐、深浅主题、刘海适配；朗读支持逐字高亮、拖动切句、设置记忆；通知栏和锁屏可上一句、暂停、下一句、停止；数据同步与语音缓存继续保留。

### v1.2.5（2026-11-18）
新增「数据同步」。在书架菜单里填入 WebDAV 网盘地址（如坚果云），书架、阅读进度和书签会自动同步，换设备接着读；删除的书会同步移除。手机版和电脑版可共用同一份数据。

### v1.2.4（2026-11-18）
语音缓存与桌面版统一。
- 缓存目录改用书籍内容指纹命名，语速目录改为整数百分比，进度文件键名两端兼容，桌面版已生成的整本语音缓存可直接复用
- 新增 TXT 编码自动识别（UTF-8 / GBK / GB18030 / Big5），修复部分书籍乱码与分章错乱

### v1.2.3（2026-11-03）
新增全书语音缓存增强与新版本推送。
- 整本缓存退出书籍重进后进度不丢失，自动从磁盘恢复
- 书架新增「缓存管理」：查看各书语音缓存占用、单本清除或清空全部
- 整本缓存支持「从当前进度开始缓存」
- 新增新版本推送：启动自动检查更新，关于页可手动检查；发现新版本弹窗提示（去下载/稍后/跳过此版本）

### v1.2.2（2026-10-28）
新增书签与划线笔记。
- 长按正文句子即可添加书签、划线（蓝/黄/绿三色）或复制
- 书签/划线列表支持动画删除；添加/删除/复制均有操作提示，重启不丢失

### v1.2.1（2026-10-27）
新增用户自选字体。
- 支持导入 .ttf/.otf 字体文件，立即生效、重启自动加载；不内置字体，包体无增加

### v1.2.0（2026-10-27）
- 界面支持 5 种语言（简体/繁体/英语/日语/韩语），跟随系统语言自动切换；Edge TTS 新增多语言音色（简/繁/英/日/韩共 20 个），默认语言音色置顶
- 书架菜单新增「关于」页，联系方式可复制/跳转，底部含更新记录

### v1.1.2（2026-09-14）
假锁屏 + 顶栏悬浮版。
- 新增假锁屏：暂停面板「锁屏」按钮进入全黑假锁屏（保持前台），锁屏自动继续朗读，长按 2 秒解锁防误触
- 顶栏改为悬浮窗口，不占位不挤正文，UI/朗读切换正文区不跳变
- 延续 TTS 0 bug：暂停后无法继续播放等场景已修复

### v1.0.0（2026-09-02）
首个正式可用版本。
- 书架：4 列木纹卡 + 添加书籍占位卡 + 进度腰封
- 阅读：三区翻页 + 章节目录 + 进度条 + 设置面板
- 朗读模式：Edge TTS 在线朗读 + 句子级高亮跟随 + 底部控制面板
- 滑动 seek：字符级定位，句子级精度
- 耳机播放键联动 + 音量键逐句
- 智能分章 + 双文本底层 + 进度自动保存

---

## 致谢

v1.3.0 的部分阅读与朗读改进移植自社区贡献：

- [NayGnehz/DDNovelReader-Android](https://github.com/NayGnehz/DDNovelReader-Android)
- 对应 [PR #2](https://github.com/caimttth3-eng/DDNovelReader-Android/pull/2)（参考 commit `27b6a1e`）
- 采纳：完整行分页与排版、目录索引、字词级高亮、连续拖动切句、通知栏/锁屏媒体控制（已按本项目的缓存与同步架构修改）
- 未采纳：系统 TTS 自动兜底、书架布局、解析/分章重写

详细来源、修改范围与权利说明见 [NOTICE.md](NOTICE.md)。

## 免责声明

本 App 仅提供本地文本阅读与在线语音合成能力，不提供、不内置任何书籍内容。
请使用你有权阅读的文本文件。朗读语音由微软 Edge TTS 在线合成。
