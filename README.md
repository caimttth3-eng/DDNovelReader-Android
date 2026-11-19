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

公开安装包请从本修改版的 [GitHub Releases](https://github.com/NayGnehz/DDNovelReader-Android/releases) 下载；仓库不再存放 APK。已发布的 **1.2.26（31）** 可从其 [Release 页面](https://github.com/NayGnehz/DDNovelReader-Android/releases/tag/v1.2.26) 获取。支持 Android 7.0（API 24）及以上的 ARM64 设备，安装包约 19.4 MB。

本地最新成功完整包为 **1.3.6（40）**，修复翻页时页底半行闪现，保存在共享总根的 `_releases/ddnovelreader/v1.3.6/`；使用 `scripts/LocalApk.ps1 -Action Path` 获取经校验的实际路径。该包已本地离线构建、固定签名和验签，不代表已安装真机或创建同版本 GitHub Release，详见 [本地布局与接收入口](docs/local-layout.md)。

本分支使用固定签名，后续使用相同证书的版本可覆盖更新。与原作者版本或早期临时调试签名不同，无法直接覆盖安装；更换前请备份书籍与数据。Release 提供 SHA-256 校验文件，详见 [固定签名说明](docs/signing.md)。

## 主要功能与修改

### 阅读、排版与目录

- 主页右上角可切换深色／浅色和书架／列表，两项选择均会保存。列表保留原版的文件图标、格式、一位小数进度及长按删除。数据同步、关于和缓存管理等页面随应用主题切换。

- 保留 TXT / EPUB 导入、书架、查找、书签、划线和自选字体；逐书保存进度，重新进入继续阅读。
- 普通阅读提供“点击左右侧 / 左右滑动 / 上下滚动”三种方式，默认上下滚动，可在阅读设置调整；已有显式选择保留。点击/滑动分页以完整文字行为边界，可选择保留上一页末行。
- 翻页动画可关闭或使用平移，默认关闭；上下工具栏覆盖正文，显隐不挤占正文空间。
- 两端对齐、允许行首标点、字号最大 64；亮度和字号有独立快捷入口。亮度 A 按钮恢复系统亮度，滑杆左侧可额外调暗。
- 自动提取 TXT 目录与章节标题，默认开启；关闭后约 5000 字分节。支持章节跳转和进度拖动。
- 文本修正、首行缩进默认开启，同时作用于显示和朗读；分级无关内容过滤默认开启一级，可关闭。通过原文坐标映射保持进度、书签和高亮位置。
- 深浅主题默认跟随系统；适配刘海和挖孔区域的章节信息，默认竖屏锁定，可手动横竖屏切换或开启跟随系统旋转。
- 自动翻页支持间隔选择、移动指示线及暂停/停止。

### 朗读与播放设置

- 支持原有 Edge 在线音色及 Android 系统文本转语音。系统音源的离线能力、可用语言及词范围回调取决于所装引擎。
- 整句高亮；可开启逐词高亮，缺少真实词边界时自动回退整句。使用实际范围与时间信息，不估算逐词时间。
- 前台朗读只整页翻页，跨页同一句连续播放，不为翻页切断音频。有实际词位置时按页界翻页；没有词位置时到下一句再定位。手动翻页时，系统及在线音源仍从目标页首字起读。
- 朗读时上下滑动切句；按下后上下拖动可连续切句，触发延时默认 0.2 秒，可调整。
- 音量键正常调整媒体音量，并同步播放栏；语速按钮和滑杆从 v1.2.27 起按 0.02 调整，显示并保存两位小数。
- 在线预加载默认后续 8 句，可设置 0–100 句，并按上游策略并发预取；每个在线音色旁提供语音缓存入口。网络失败先用已有音频；“网络失败时转系统音源”默认关闭，开启后缓存用完自动切换，恢复联网后由用户手动切回。关闭时有限重试后提示错误，不悄悄换音源。
- 系统音色旁的沙漏提供追加停顿，点击后直接展开；可按标点和“段后”调整，仅作用于系统音色。破折号、省略号默认各 0.20 秒，段后默认 0.30 秒，其余 0。范围 0.00–3.00 秒、步长 0.05 秒；展开后点击“应用停顿”保存，关闭菜单丢弃未应用草稿。
- 系统通知栏和锁屏支持上一句、暂停/继续、下一句、停止；可开启“在系统栏中显示播送原文”，默认关闭，短句整句显示、长句按真实朗读进度在标点处分段，通知隐藏段首缩进。最终样式和可见行数由手机系统决定。
- 定时停止支持自定义，最长 120 分钟；阅读和朗读亮屏时长分别保存。亮屏到期释放窗口常亮，由系统处理熄屏，不申请设备管理器或辅助功能权限。

修复包括远距离跳转后空白、选章后上一页首行裁切、音源切换后高亮停滞、暂停后从段首重播、变速后位置匹配及通知暂停后无法继续等路径。两个偶发报告（念出标点名称、倍速后中央点击改变光标）的相关风险路径已有回归测试，尚未在真机完整复现其所有触发方式。

### 上游 1.3 新增能力

- WebDAV 与桌面端同步书架、阅读进度、书签、书籍原文件和删除记录；音频不上传。配置后默认启动及每10分钟自动同步，也可在书架设置关闭自动同步，阅读菜单可手动同步。首次配置前请了解书源上传及删除传播范围。
- TXT 支持 UTF-8 / UTF-16 / GBK / GB18030 / Big5 识别；采用跨端内容指纹、整数语速目录和原文码点坐标，同时保留本项目原始断行/缩进及处理开关。新 `words2` 指纹隔离旧坐标音频，迁移冲突保留旧文件而非覆盖/删除。
- iOS 工程和上游说明随源码保留，当前只验收 Android ARM64；未进行 iOS 编译、签名或设备验收，iOS 在线 workflow 同样停用。

## 构建与验证

开发、测试及发布包均改为本地构建，不再使用 GitHub Actions；[旧在线构建配方](.github/workflows/build-apk.yml) 已移除 push、PR、手动触发，并固定跳过构建 job。历史运行、Release 和验证记录不改写，也不因环境缺项回退在线或全局工具。

固定输入为 Flutter 3.50.0（官方 Windows 包随附 Dart 3.14.0，满足项目 `^3.13.2`）、Gradle 9.3.1-all、AGP 9.1.1、Kotlin 2.4.0；依赖以 `pubspec.lock` 为准。共享维护者登记并接收不可变工具/离线闭包，项目在 `ddnovelreader/main` 实例的 Prepare 锁下恢复可写 Flutter 运行树和缓存，不在共享 SDK 的 `bin/cache` 执行写入。Android 使用精确 API 36、NDK 28.2.13676358，不用现有 API 37 冒充。

官方 SDK 的最小锁兼容调整仅为 listen 1.0.1、test_api 0.7.14、vector_math 2.4.4；本次合并沿用该冻结包集、镜像和锁字节。上游直接使用的 audio_session 0.2.4 已在闭包中，现于 pubspec 明确声明；`--enforce-lockfile` 保留原锁中展示性的传递依赖分类，实际依赖图已验证其为直接依赖，不新增/升级包。`PUB_HOSTED_URL` 固定为 `https://pub.flutter-io.cn`，不换源重解或执行 `pub upgrade`。

项目入口（默认离线，固定闭包由共享维护者接收；命令存在不等于某次产品构建已经通过）：

```powershell
.\scripts\LocalBuild.ps1 -Action Prepare -IncludeAndroid
.\scripts\LocalBuild.ps1 -Action Restore
.\scripts\LocalBuild.ps1 -Action Analyze
.\scripts\LocalBuild.ps1 -Action Test
.\scripts\LocalBuild.ps1 -Action BuildApk -ConfigureOnly
# 需要实际未签名 ARM64 APK 时再执行：
.\scripts\LocalBuild.ps1 -Action BuildApk
# 完整本地交付（既有固定签名持续授权，不安装或远端发布）：
.\scripts\LocalBuild.ps1 -Action DeliverApk
.\scripts\LocalBuild.ps1 -Action Finalize
```

`Test` 默认覆盖本轮朗读分页、手动翻页定位及 TTS 队列回归，可通过 `-TestPaths` 指定现有测试文件。入口默认离线，先执行离线恢复。当前闭包由共享维护者接收种子，项目不并行联网接收同一份依赖；只有明确交接接收职责后，才可在确缺依赖时显式使用 `Restore -Online` 接收锁定 pub 依赖，或 `Prepare -Online` 接收宿主 engine/font。联网准备仍持有本项目 Prepare 锁，不升级依赖或读取凭据。

`BuildApk` 通过共享 `Tool gradle-9.3.1` 直接只读使用精确 Gradle 9.3.1 分发执行 `assembleRelease --offline --no-daemon`，不依赖缺失的项目 wrapper，也不回退 Gradle 9.7.0。Android SDK 直接使用共享 `Environment` 的固定路径，包含 API 35/36、NDK 28.2.13676358、CMake 3.22.1、Build Tools 36.0.0、Platform Tools 37.0.1 和许可；不自动调用 sdkmanager，不向实例重复恢复 Gradle/SDK。`GRADLE_USER_HOME`、`ANDROID_USER_HOME`、pub/Maven、TEMP 和构建输出仍留本实例；Flutter 的缓存及 Gradle 插件状态固定写入 SDK，因此保留实例可写树，不改上游或加联接。共享闭包仅验收 ARM64 release，不冒称 debug/profile 全闭包。默认清空签名配置，只接受明确未签名、版本匹配、仅 ARM64 且包含 Flutter/应用库的 staging APK，并保存实际校验信息；`-ConfigureOnly` 仅验证任务图，不生成 APK。

共享维护者已正式接收四份 `package.xml`，并核证固定 Repository 对只读缓存写入失败的兼容性。入口在 Prepare lease 内验证这些元数据，以只读共享句柄保护既有 16B `.knownPackages`；缺失或无法保护即停止。句柄持有至进程后代自然结束、日志消费和完整 SDK 树后验完成，不忽略任何元数据差异，也不改 ACL/属性/联接。`DeliverApk` 将构建、固定签名和 LocalApk 接收放在同一护栏生命周期。精确结果见 [本地布局](docs/local-layout.md)。

**1.3.6（40）已离线构建、固定签名、验签及本地接收**，ARM64 安装包 19,618,321 字节。78 项定向 Flutter 测试通过，覆盖关闭动画时双向翻页的首个可见帧、末行裁切、朗读与手势回归。静态分析无错误，共享 Android SDK 完整审计通过；未安装真机或远端发布。细节见 [固定签名说明](docs/signing.md) / [本地布局](docs/local-layout.md)。

Windows 原生 shader 编译器无法写 `../` 输出，而 Flutter 不接受绝对 `build-dir`。因此仅宿主 `Test` 使用带 owner 标记的源根 `build/` 临时例外，全部测试消费完成后用 `Finalize` 清退；源码不复制、不开联接，其余可重定向输出仍在实例。`Finalize` 不清理可复用 SDK/pub/Maven 缓存或已发布包。

本地默认不生成 UI 截图，布局断言仍执行；临时图仅在实际需要且能完成展示和最终清退时生成，不为看图重启在线构建。旧 `retain_ui_previews` 仅为已停用配方的历史输入，不是当前构建入口。

`publish-release.yml` 与 `publish_verified_release.py` 是固定 **v1.2.26** 输入身份的历史发布流程；它们不是任意新版的一键发布入口，不能用来发布 v1.2.27，也不用于本轮本地迁移。新版验证以 `LocalBuild.ps1` 为入口，完整包归位继续使用 `LocalApk.ps1`，不自行启动远端发布。

1.2.26 的 [GitHub 构建](https://github.com/NayGnehz/DDNovelReader-Android/actions/runs/43622578197) 通过 351 项 Flutter 测试、13 项签名脚本测试及独立在线语音探测；主套件有 1 项可选在线探测跳过。下载成品已独立核验版本、ARM64 架构、SHA-256 和固定证书。手机音源、系统通知样式及实际手感仍需真机验证。

## 文档

- [更新日志](CHANGELOG.md)
- [阅读与播放设置](docs/playback-settings.md)
- [文本处理与朗读定位](docs/reader-text-rules.md)
- [系统媒体控制与包体积](docs/media-controls.md)
- [固定签名与构建](docs/signing.md)
- [来源说明](docs/SOURCES.md)
- [本地布局与当前入口](docs/local-layout.md)
- [历史资料索引](docs/history/README.md)
