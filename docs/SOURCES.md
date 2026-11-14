# 来源说明

本仓库 fork 自 [caimttth3-eng/DDNovelReader-Android](https://github.com/caimttth3-eng/DDNovelReader-Android)。原作者为 **caimttth3-eng**，项目名称为“多多朗读 DDNovelReader”；原始 Flutter 应用、书籍解析、基础阅读和 Edge TTS 集成来自该项目。维护者 **NayGnehz** 在此基础上增加阅读设置、文本处理、系统 TTS 和媒体控制，并修复交互问题；完整变更保留在 Git 历史中。

- 原 Android 项目：<https://github.com/caimttth3-eng/DDNovelReader-Android>
- 原作者桌面版：<https://github.com/caimttth3-eng/DDNovelReader>
- 本修改版：<https://github.com/NayGnehz/DDNovelReader-Android>

截至本次发布，上游没有单独的 LICENSE 文件。本 fork 保留原有来源和权利声明，不将上游代码擅自改标为 MIT、Apache 或其他许可证。源码公开不代表本仓库可以替上游授予额外权利。

## 第三方资源与参考

- 媒体按钮使用 [Google Material Symbols Rounded](https://github.com/google/material-design-icons)，保留 [Apache-2.0 许可证](third-party/MaterialSymbols-LICENSE.txt)，许可证也随 APK 打包。
- Flutter 和 Dart 插件的名称、版本见 `pubspec.yaml` / `pubspec.lock`，各自许可证由应用第三方许可信息保留。
- TXT 目录识别与规则化净化参考 [Legado](https://github.com/LegadoTeam/legado) 的方案，在本项目自行实现；未将另一工程的语音引擎、原生库或声库打包进本应用。
- 硬换行修正参考 [calibre 启发式处理](https://manual.calibre-ebook.com/conversion.html#heuristic-processing)，规则和限制见 [文本处理说明](reader-text-rules.md)。
- 系统 TTS 与通知采用 Android 的 [TextToSpeech](https://developer.android.com/reference/android/speech/tts/TextToSpeech) 和 [媒体控制](https://developer.android.com/media/implement/surfaces/mobile) 接口。
- 追加停顿参考 [W3C SSML break](https://www.w3.org/TR/speech-synthesis11/#S3.2.3) 与 [Microsoft SSML silence](https://learn.microsoft.com/en-us/azure/cognitive-services/speech-service/speech-synthesis-markup-structure) 对自然/追加停顿的区分，调度由本应用实现。

更多技术资料在对应功能文档中列出。引用来源不代表原作者参与或认可本修改版发布。
