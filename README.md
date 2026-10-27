# 多多朗读 DDNovelReader

安卓本地小说阅读器，支持 Edge TTS 在线朗读、智能分章、句子级高亮跟随。

- 中文名：多多朗读
- 英文名：DDNovelReader
- 包名：com.ddnovelreader

## 多平台

- **Android**：本仓库 [Releases](https://github.com/caimttth3-eng/DDNovelReader-Android/releases) 下载 APK
- **Windows / macOS / Linux**：前往 [桌面版发布页](https://github.com/caimttth3-eng/DDNovelReader) 下载（Windows 绿色免安装 exe / macOS DMG / Linux 单文件）

> 桌面版功能更全：本地离线语音 + Edge 神经语音、整本语音缓存、书签划线笔记、全文搜索、多主题、定时播放。

## 功能

### 书架
- 4 列木纹卡片展示，底部腰封显示阅读进度
- 首位固定"添加书籍"占位卡，点击调用系统文件管理器选书
- 支持 TXT / EPUB 格式导入
- 无限下滑滚动

### 阅读
- 全屏三区点击：上区上翻页、中区显隐 UI、下区下翻页
- 顶部：返回 / 播放 / 设置（亮度、字体大小、行距、查找）
- 左侧悬浮球：章节目录（打开时定位到当前章节）
- 底部进度条：滑动跳转 + 百分比显示
- 长按句子：添加书签 / 划线（蓝黄绿三色）/ 复制，均有操作提示
- 书签/划线列表：动画删除、重启不丢失
- 自动保存阅读进度，意外退出不丢失

### 朗读模式
- 点击播放按钮进入：全屏无 UI，TTS 开始朗读，高亮逐句跟随
- 点击屏幕暂停，底部弹出控制面板：
  - 语速调节（0.5x – 2.0x，滑块 + 加减按钮）
  - 定时播放（15 / 30 / 60 / 90 分钟）
  - 切换音源（简/繁/英/日/韩 20 个音色，当前界面语言音色置顶）
  - 退出朗读（电源按钮，恢复正常阅读 UI）
- 上下滑动：字符级快进/快退（每像素 2 字，句子级精度）
- 音量键：逐句跳转（朗读模式下生效）
- 耳机播放键：控制播放/暂停（MediaSession）

### 自选字体
- 设置面板「字体更换」：教程提示、导入入口、已导入字体列表（可删除）、恢复默认
- 导入 .ttf/.otf 字体文件即生效、重启自动加载；不内置字体，包体无增加

### 文本处理
- 双文本底层：显示保留原文标点/空白，TTS 朗读使用去除连续标点、空白、emoji 的纯净文本
- 智能分章：识别"第 X 章 / 第 X 卷 / Chapter N / 序章 / 楔子 / 番外"等标题格式，适配百万字级小说
- 句子级切分，高亮精确到句子

## 技术架构

```
lib/
├── main.dart                  # 入口，全局 AudioService 初始化
├── models/
│   ├── book.dart              # Book / Chapter / Paragraph / Sentence 数据模型
│   └── progress.dart          # 阅读进度模型
├── screens/
│   ├── shelf_screen.dart      # 书架页
│   └── reader_screen.dart     # 阅读页（含朗读模式、滑动 seek、高亮跟随）
├── services/
│   ├── app_storage.dart       # SharedPreferences 存储（设置 + 进度）
│   ├── book_parser.dart       # TXT / EPUB 解析
│   ├── chapterizer.dart       # 智能分章引擎（三重检测）
│   ├── edge_tts.dart          # 微软 Edge TTS 协议实现（WebSocket + SSML）
│   ├── tts_reader.dart        # TtsReader：逐句朗读、预取、暂停/恢复、跳转
│   ├── tts_audio_handler.dart # audio_service MediaSession（耳机按键）
│   └── text_cleaner.dart      # 双文本清洗（显示原文 / TTS 纯净文本）
└── widgets/
    └── book_card.dart         # 木纹书籍卡片 + 添加书籍占位卡
```

### 关键依赖
- `scrollable_positioned_list`：按 index 精确定位，句子级高亮跟随滚动
- `audio_service`：MediaSession，耳机播放键控制
- `audioplayers`：MP3 音频播放
- `crypto`：Edge TTS Sec-MS-GEC 签名
- `file_picker`：系统文件管理器选书

### Edge TTS 协议
- 端点：`https://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1`
- 20 个多语言音色：简体 7（晓晓、云希、云扬、晓伊、云健、小北、小妮）、繁体 3（曉臻、曉雨、雲哲）、英语 6（Aria、Jenny、Guy、Ana、Sonia、Ryan）、日语 2（七海、慶太）、韩语 2（鮮熙、仁俊）
- 输出格式：audio-24khz-48kbitrate-mono-mp3

## 构建

```bash
flutter pub get
flutter build apk --release
```

产物：`build/app/outputs/flutter-apk/app-release.apk`

### 环境要求
- Flutter 3.x stable
- Android SDK compileSdk 34+
- targetSdk 33（audio_service 兼容性）
- minSdk 21

## 版本

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
