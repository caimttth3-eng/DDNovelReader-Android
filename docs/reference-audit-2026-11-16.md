# 全仓引用和目录复查（2026-11-16）

范围为当前源码根、`_cache/projects/ddnovelreader/`、`_data/ddnovelreader/` 和本项目 `_releases`。逐层核对目录及重解析点，检查当前 Markdown/HTML 本地链接、工作流脚本路径和 Dart 本项目导入。历史原件、旧收据及旧发布说明中的当时路径不改写；没有将其当作当前入口执行。

## 实际修正

- `releases/android/index.html` 不再链接已不存在的 `多多朗读_v1.1.0_android.apk`，改为本修改版 GitHub Releases 下载入口，避免固定旧版本与旧包体积误导。
- 原 HTML 先原字节归档到 `docs/history/android-v1.1.0/index.html`；SHA-256 为 `c1accae4269763b9550d72f615488e958300fc50a5a5db83ba5fe00841efae76`。已有历史文件不改字节，另加 [历史索引](history/README.md) 说明旧 APK 链接仅作历史记录。
- README 区分公开 Release 和本地成功完整 v1.2.27，不再把 v1.2.26 笼统标为当前版本。明确 Actions 是当前构建入口，固定 v1.2.26 发布脚本不是新版通用发布器。
- 本地接收示例改用当次真实完整目录变量，不再指向已经移除 APK/清单、仅余分析文件的 v1.2.27 缓存目录。
- 更新检查和关于页的“软件发布”源码入口改为 `NayGnehz/DDNovelReader-Android`；原项目链接作为来源保留，标签补齐五种语言。
- 签名说明明确占位路径与共享本地入口的区别，Python 参数示例加 `-B`，避免再次生成源码目录字节码。旧收据里的截图数量保留为历史快照，当前数据目录说明按本轮元数据核实。

## 各子目录用途与当前引用

下表包含各目录的子层；包名命名空间和资源密度层级不作为独立工程或缓存实例。

| 目录 | 当前用途 / 消费者 / 处理 |
|---|---|
| `.git/` 及其内部目录 | 便携 Git 使用的必要历史、引用和仓库元数据；保护，不清理对象、不读个人配置 |
| `.github/workflows/` | `build-apk.yml` 为当前在线构建；`publish-release.yml` 与 `scripts/publish_verified_release.py` 固定 v1.2.26，保留对应发布身份和重放流程，不作为新版发布入口 |
| `android/app/src/debug/`、`profile/` | Android 构建类型清单，由 Gradle 合并 |
| `android/app/src/main/java/com/ddnovelreader/` 及祖先层级 | 系统语速百分比编码；Kotlin 系统 TTS 调用、原生合成回归使用 |
| `android/app/src/main/kotlin/com/ddnovelreader/` 及祖先层级 | MainActivity 注册的 TTS、刘海、通知和网络等原生桥接 |
| `android/app/src/main/res/drawable/`、`drawable-v21/`、`mipmap-*/`、`raw/`、`values/`、`values-night/` | 启动、媒体图标、不同密度启动图、保留规则与深浅主题；清单/原生代码/Gradle 消费。`android/ic_launcher_512.png` 是启动图源设计资源，保留 |
| `android/gradle/wrapper/` | 固定 Gradle 分发声明；Actions 中恢复 `gradlew` 与 wrapper JAR，未提交的生成文件不是失效源码引用 |
| `docs/` | 当前用法、技术说明和原协议研究资料；原协议文本作为历史研究原件保留，当前实现是 `lib/services/edge_tts.dart` |
| `docs/evidence/`、`docs/releases/` | 对应轮次的原始归位收据、已发布版本说明，历史事实不改写 |
| `docs/history/initial-workspace/` | 已停用的早期元数据原件，历史索引引用，不恢复旧源码入口 |
| `docs/history/android-v1.1.0/` | 本轮归档的旧下载页原件，历史索引引用 |
| `docs/third-party/` | Material Symbols 许可，`pubspec.yaml` 打包并由本地接收随包保留 |
| `lib/models/`、`screens/`、`services/`、`widgets/` | 当前应用实现，Dart 导入关系逐项核对 |
| `releases/android/` | 当前下载导航及未改写的旧发布说明/原截图；历史索引明确区分当前入口与历史资源，无 APK 成品混放 |
| `scripts/` | 工作流使用的构建/签名/分析脚本、Python 辅助回归、LocalApk 接收入口及纯文件回归；脚本引用存在 |
| `test/`、`test/native/` | `flutter test` 主套件；原生 Java 探针由 `test_system_speech_rate.py` 编译验证 |
| `test/fixtures/` | `edge_tts_v126.dart` 被 `edge_live_test.dart` 用作原协议基线；`test_book.txt` 是人工导入验证分章/清理/进度的短合成样例。两者是测试源码资料，保留 |
| `_cache/projects/ddnovelreader/main/build/v1.2.27/` | 当前尺寸报告 3,551 字节、ARM64 独立符号 3,824,336 字节，共 3,827,887 字节；匹配 v1.2.27 分离符号构建，供尺寸分析和符号化；保留，无重复 APK |
| `_cache/projects/ddnovelreader/main/temp/` | LocalApk 独占打开的零字节 `local-apk.lock`；保留同步语义。没有旧实例或遗留合成夹具 |
| `_data/ddnovelreader/signing/` | 2 文件、8,319 字节，固定签名保护资料；只核目录/数量/长度/属性，不读、哈希、迁移或删除内容。当前数据根无其他文件，无 SDK/构建/实验资料混入 |
| `_releases/ddnovelreader/v1.2.27/` | 当前唯一成功完整 ARM64 包及最小校验/身份/许可，5 文件、19,362,947 字节；`LocalApk -Action Path` 消费，保留 |

## 本轮实际删除

| 路径（相对共享总根） | 删除结果 |
|---|---|
| `DDNovelReader/scripts/__pycache__/` | 删除 `prepare_signing.cpython-312.pyc`、`sign_apk.cpython-312.pyc`、`test_signing.cpython-312.pyc`，共 3 文件、37,070 字节，再移除空目录；对应 Python 源码均保留 |
| `DDNovelReader/integration_test/` | 无文件、无调用、未声明 integration_test 依赖，删除空目录 |
| `_cache/projects/ddnovelreader/main/temp/hsperfdata_NayGnehz/` | 已无 JVM 文件，删除空目录 |

合计删除 3 文件、37,070 字节和 3 个目录。删除前核精确绝对路径、无重解析点、无文件占用，并持有本项目 LocalApk 锁；未触及真实资料、Git 历史、当前成品或当前符号。此前已删除的旧目录未重复计入。

## 验证范围

本轮检查通过：28 个 Markdown 本地链接、1 个 HTML 本地链接、264 个本项目 Dart 导入、6 处工作流脚本引用、6 个 Python 文件语法、五语言新增标签，以及 12 份历史原件的原字节比对（旧 HTML 按归档映射核对）；另核当前本地 APK 选择入口。当前输入没有已删除脚本、旧实验目录或旧缓存实例的执行依赖；历史文字提及和 Flutter SDK 自身 `bin/cache/artifacts` 不属于本项目失效目录。

未重新构建或安装 APK、未发起网络请求；URL 与关于页调整属于本轮源码修正，现有 v1.2.27 APK 不包含这些新修改。本地尚无完整 Flutter 闭包，未将静态校验冒称 Flutter/真机运行验证。
