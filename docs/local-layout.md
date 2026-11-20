# 本地目录布局

本地整理遵循工作区总根的 `AGENTS.md`，ProjectId 为 `ddnovelreader`。项目根包含 `pubspec.yaml`、`lib`、`android` 和 `.git`，不再使用内部 `fork` 子目录。以下路径相对共享工作区总根，不固定盘符。

| 用途 | 路径 |
|---|---|
| 唯一源码与 Git 历史 | `DDNovelReader/` |
| 最新成功完整 ARM64 v1.3.7 成品、校验和、构建身份与许可（未安装真机） | `_releases/ddnovelreader/v1.3.7/` |
| 本地最新 APK 选择入口 | `DDNovelReader/scripts/LocalApk.ps1 -Action Path` |
| 当前构建与独立调试符号 | `_cache/projects/ddnovelreader/main/build/`（符号位于 `debug-symbols/`） |
| 当前签名资料（仅核元数据） | `_data/ddnovelreader/signing/` |

此前签名目录仅做同卷移动，通过文件数量、长度、时间和 ACL 元数据核对；未读取、打印或哈希密钥内容。先前截图资料的数量属于当时快照，本轮目录已仅含签名子目录，不再将旧截图位置写作当前入口。APK 归位前后 SHA-256 相同，不为整理重新构建或签名。

外层 7 个旧代码文件已在 Git 对象中核实；两个未匹配历史的早期说明/依赖清单完整保存在 `docs/history/initial-workspace/`，不能当作当前构建入口。旧预览、重复安装包及一次性补丁脚本先因自动审批拒绝而可恢复暂存；用户随后明确授权后，已删除清单中的 120 个旧文件，共 116295907 字节，并删除 29650 字节清单及空目录，总计删除 121 个文件、116325557 字节。暂存目录已不存在；本项目当前保留的构建缓存未清空。分组记录及授权结果见 [迁移证据](evidence/local-layout-2026-11-15.json)。

## 合并原作者 1.3.1 的本地验证（2026-11-20）

本轮合入原作者最新 `master` `3d63683bc7da42f528d8d402b084853c79f4502a`，而非把本修改版退回 1.3.1；该提交包含 `v1.3.1` 标签 `05c7a14074d33ea112e24624efd9a9665afa5bf8` 之后的调整。本修改版源码递增为 **1.3.8（42）**，保留已有分页、朗读、高亮、防闪烁、书架主题、可选系统兜底和本地构建入口。按用户确认采用在线最高 2 倍、Android 系统最高 3 倍，仍按 0.02 调整；系统音色选择、按书设置恢复、中断续读及跨章预取复用本项目已有光标、分句和缓存路径。

- 固定工具与 pub 锁未升级，离线 Restore 成功，锁 SHA-256 仍为 `b5fb94b4365c6c4a321e04f64c6dc205d60de7f12c17c6801402c8d5c3363c2e`。未访问签名凭据、触发在线构建或修改共享环境。
- 最终完整 Flutter 套件 **413 项通过、7 项可选测试跳过**。覆盖现有普通/朗读分页、手动页首起读、隐藏行高亮，以及具名系统音色、音质筛选、3 倍切在线限 2 倍、按书恢复/并发保存、跨章缓存坐标及迟到请求取消。Analyze exit 0、无 error，保留 161 条现有及上游 warning/info，不借合并扩大清理范围。
- 真实 `BuildApk` 离线编译成功，`BUILD SUCCESSFUL in 4m 35s`，421 个任务中 38 个执行、383 个 up-to-date，包含实际 `:app:compileReleaseKotlin`，并非仅任务图。入口验证了 ARM64、包名、1.3.8（42）及未签名状态；共享 Android SDK 完整树前后审计通过，包含四份 `package.xml` 和 `.knownPackages`。
- 编译后补充复现并修正 Dart 中断恢复竞态：中断暂停尚未完成时，即使已收到恢复事件，用户手动暂停仍优先；旧恢复请求也不得接管新一轮中断。修正后重新执行上述最终全套测试与 Analyze。验证 APK 不代表该后续修补的最终安装包，已清退，不交付或签名旧快照。
- 全部自有消费者自然结清后，在既有 Prepare lease 内运行 `Finalize`，删除源根 owner 测试输出 **12 文件、64,610,512 字节**；再核具名验证 APK 的身份及重复字节，清退未签名 APK/副本/元数据/对应符号 6 文件与 8 份被替代中间日志，共 **14 文件、43,308,292 字节**。未生成 UI 截图，保留可复用 Flutter/pub/Maven/Gradle 增量缓存、最终验证日志及 SDK 审计清单。

最终日志位于实例 `temp/merge-upstream131-tests-final.log`、`temp/merge-upstream131-analyze-final.log`、`temp/merge-upstream131-build.log`；中断竞态修复前复现记录为 `temp/merge-upstream131-interruption-race-before.log`。本轮仅本地合并，没有推送、PR、Release、签名、安装或真机验收；iOS 仅合入源码，Windows 未编译。最新已签名完整包及公开 Release 仍为 **1.3.7（41）**，不因合并源码清退旧成品。

### 1.3.8 再融合（2026-11-20 同日后续）

用户要求重新梳理新增与已有功能的重叠后，删除独立的“下一章固定 3 句”任务。原自动预加载窗口现可跨越多章和空章，共用原并发、音频请求、取消、词元数据和缓存坐标；设为 0 不产生额外跨章请求。自动换章按章节、原文偏移及正文内容交接已完成的内存缓冲，即使磁盘写入尚未结束也不重复请求。手动全书缓存仍是用户显式启动的下载任务，与自动预加载共用磁盘缓存，而非另一个自动窗口。

音频中断现走已有手动暂停/续读路径，同步页面控制栏、媒体通知和亮屏状态；手动继续后可以正常处理下一次中断，迟到恢复事件不覆盖用户暂停。在线缓存按目标音色应用最高 2 倍限制，不改当前系统音色或其语速；只调语速也按书保存实际音色，恢复相同在线音色时保留原有系统兜底状态。没有新增第二套朗读位置、正文或缓存格式，仍保留本项目页首起读、分页裁切与高亮修复。

最终完整 Flutter 套件 **419 项通过、7 项可选测试跳过**，Analyze exit 0、无 error（161 条 warning/info）。新增回归实际覆盖统一窗口的数量与跨章并发、空章、关闭/缩小/断网/换音色/停止取消、磁盘未写完时的跨章内存和词边界交接、缓存命中、暂停时亮屏释放、手动继续后再次中断、在线缓存速率隔离及按书恢复兼容。日志保留在实例 `temp/speech-fusion-tests-final.log` 和 `temp/speech-fusion-analyze-final.log`。

本次仅 Dart、测试及说明调整，未变更原生工程、依赖声明、锁、共享环境或本地构建入口；沿用首轮原生编译证据，不声称再次打包或真机验收。源码仍为未发布的 1.3.8（42），没有推送、签名、安装或替换 1.3.7 成品。全部测试消费结束后通过既有 Prepare lease/Finalize 清退源根 owner 测试输出 **12 文件、64,615,528 字节**，并清退四份已被最终结果替代的中间日志 **156,083 字节**；没有截图，保留可复用依赖与增量缓存。

### 24 项整合修复接续（2026-11-20）

接续中断的同步子任务并完成此前已列出的解析、音频、缓存、同步与阅读页 24 项修复。最终完整 Flutter 套件 **487 项通过、7 项可选探测跳过**；Analyze exit 0、无 error（178 条 warning/info）。真实离线 ARM64 `BuildApk` 成功（2 分 39 秒，421 个任务：23 执行、398 已最新），版本仍为 1.3.8（42）；共享 SDK 全树前后审计通过，包含包元数据和 `.knownPackages`。没有修改依赖锁、原生工程、共享工具或本地构建入口，没有签名、安装、截图或远端发布；既有 1.3.7 已签名成品未动。

清理复合命令首次在执行前被自动审批拒绝（`blocked by policy`，未提供更具体原因）。用户随后明确允许下述精确范围，重试仍在启动前被相同工具策略拒绝，其中源根 `Finalize` 和具名验证输出删除均未执行；没有换工具、脚本或移锁绕过，也不再重复索取同一授权。已只读核实待处理范围：源根 owner 测试输出 12 文件、64,776,296 字节；实例未签名包/元数据/对应符号 6 文件、43,334,141 字节；本轮已替代中间日志 6 文件、135,732 字节，共 **24 文件、108,246,169 字节**。自有消费者自然结束，删除数为 0，待工具策略允许执行已授权范围后沿用原入口和 Prepare lease 收尾。最终日志、SDK 审计、可复用缓存及当前成功成品保留。逐项验收、兼容限制、精确文件名和退出条件见 [整合修复台账](integration-repairs-2026-11-20.md)。

## 后续开发与备份

- 备份源码、正式成品、共享固定环境及 `_data`；排除 `_cache`。排除备份不等于每次清空缓存。
- 按 2026-11-16 最新规则，开发/测试/日用/正式仅为状态；成功完整 APK 统一归 `_releases`，不能以尚未正式验收留在缓存。ARM64 是当前唯一产品线，默认仅保留最新成功完整包。
- 开发、测试与发布包均改为本地构建，不再使用 GitHub Actions，也不在本地缺项时回退在线。旧在线配方移除 push/PR/手动触发并固定跳过构建 job；下文及既有回执中的在线运行属于历史事实，不改写为本地执行。
- 共享维护者已登记 `ddnovelreader/main`，负责固定原包、许可、清单及可恢复依赖闭包；项目只读消费共享登记，不修改公共契约或回退全局工具。Flutter 可写运行树、pub/Gradle/Android 缓存和验证由项目在既有 Prepare 锁内独占维护。接收旧 APK 不代表新本地链路已验证。
- 本地 Git 使用共享 `_env/bin/Invoke-PortableGit.ps1` 和既定用户配置。目录整理只本地提交，不自动推送或改写历史。
- 新验证、下载、解压和生成预览放本项目缓存实例；私钥与凭据放 `_data`，不得进入 Git 或报告。

### 本地构建与验证入口（2026-11-19）

`scripts/LocalBuild.ps1` 提供 `Resolve`、`Prepare`、`Restore`、`Analyze`、`Test`、`BuildApk`、`SignApk`、`DeliverApk`、`Finalize`。固定 Flutter 3.50.0 官方 ZIP 随附 Dart 3.14.0，满足项目 `^3.13.2`；Gradle 仍固定 9.3.1-all，不借用其他消费者的 9.7.0。Flutter 按 `_env/manifests/flutter-3.50.0-windows-x64.json` 的归档 SHA-256 在本实例 Prepare 锁内展开并记录输入身份；已匹配运行树直接复用。Gradle 通过共享 `Tool gradle-9.3.1` 直接消费 `_env/tools/gradle/9.3.1/`，不再在实例展开。

实例内布局：`flutter/`、`pub-cache/`、`gradle-home/`、`gradle-project-cache/`、`android-home/`、`build/`、`temp/`；HOME/APPDATA/LOCALAPPDATA 也隔离在实例。Flutter 3.50.0 上游将缓存固定写在 `bin/cache`，Gradle 插件也在 Flutter SDK 源树生成构建状态，当前没有安全且受支持的外置机制，因此仅 Flutter 保留实例可写 SDK，不改上游或加联接。入口显式限定固定 Flutter/Git/JDK/pwsh 与必要 Windows 目录，不继承全局工具 PATH；除显式 `SignApk` 外不读取签名配置，不启用遥测、升级或截图。JVM 使用受控 `JAVA_TOOL_OPTIONS` 显式设置实例 `java.io.tmpdir` 和 `user.home`，并清除继承的其他 Java 选项；实际以包含空格的路径验证完整参数无截断。

先 `Prepare`，再 `Restore`（`flutter pub get --offline --enforce-lockfile`）。当前由共享维护者接收 pub/engine/Maven 种子，项目不并行联网；只有明确交接接收职责后，才在公开依赖确缺时显式 `Restore -Online`，或在宿主 engine/font 缺失时 `Prepare -Online`。联网仅用于锁定的公开依赖接收，始终持有同一 Prepare 锁，日常 analyze/test 使用 `--no-pub`。成功恢复写入本实例 `pub-lock.json`，项目不向 `_env` 写回。

`Prepare -IncludeAndroid` 检查共享固定 Android SDK，不再恢复实例 SDK；`Environment` 的 `ANDROID_HOME` / `ANDROID_SDK_ROOT` 与 `Tool android-36-jar` 必须一致并位于共享 tools 根。当前 SDK 为 `_env/tools/android-sdk/api35-36-ndk28.2-bt36-pt37.0.1-cmake3.22.1/win-x64/`，包含 API 35/36、NDK 28.2.13676358、CMake 3.22.1、Build Tools 36.0.0、Platform Tools 37.0.1 和已接受许可。不使用 API 37 冒充 API 36，不运行 sdkmanager 向共享树安装。pub/Maven seed 分别由 `pub-dart3.14.0-windows-b5fb94b4365c.json`、`android-flutter-3.50.0-gradle9.3.1-agp9.1.1-b5fb94b4365c.json` 固定：前者恢复到本实例 `pub-cache/`，后者仅把公开 `modules-2` 恢复到 `gradle-home/caches/`，不带用户凭据、活锁、daemon 或其他项目编译输出。

Flutter 强制在项目源根生成 `.dart_tool/`、`.flutter-plugins-dependencies`、`android/local.properties` 等定位元数据，保持忽略，不复制源码或建联接。其余输出重定向到实例；唯一实测工具限制是 Windows impellerc 拒绝 `../` 输出（相同输入绝对路径成功，正反分隔符的相对路径均失败），而 Flutter 不接受绝对 `build-dir`，因此宿主 `Test` 在源根 `build/` 留带 owner 标记的临时例外。全部消费者结清后用 `LocalBuild.ps1 -Action Finalize` 精确核身份、重解析点并清退，不影响可复用实例 SDK/pub/Maven。

`BuildApk` 直接调用共享 Gradle 9.3.1 `assembleRelease --offline --no-daemon`，无须恢复缺失 wrapper 或复制第二份 Gradle。传入明确 ARM64/分离符号参数，禁止 SDK/Java 自动下载；Android Gradle 输出通过 `DDNOVEL_BUILD_DIR` 进入实例 `build/`，项目缓存也在实例。默认清空签名环境，只允许 `app-release-unsigned.apk`，实际打包后核包名、pubspec 版本/构建号、仅 ARM64 的 Flutter/应用库及确实未签名状态，写 `unsigned-build-info.json` 与明确 `UNSIGNED` 标识；该 staging 不能直接冒充 LocalApk 所需的已签名完整包。`-ConfigureOnly` 是真实项目离线任务图配置，不执行 APK 任务。`SignApk` 仅按项目持续授权使用既有固定签名资料，完整包仍由 `LocalApk.ps1` 验签、接收和收尾。

本轮已完成项目级离线工具/SDK/pub/Maven 恢复，接受 SDK 最小锁差异（新增 listen 1.0.1、test_api 0.7.14、vector_math 2.4.4），其余锁版本/镜像/hash 及应用版本不变，锁 SHA-256 为 `b5fb94b4365c6c4a321e04f64c6dc205d60de7f12c17c6801402c8d5c3363c2e`。首次离线依赖缺失失败后仅消费共享 seed，随后 mirror 离线 enforce 成功；最终 analyze exit 0、无 error（121 条 warning/info），8 个相关测试文件共 **135 项通过**，覆盖分页、页首字符、队列、系统音源、媒体控制、停顿、预取和语速。受控环境变量与 CWD 在入口执行后逐项验证恢复。

真实项目 `BuildApk -ConfigureOnly` 在最终 JVM 隔离配置下离线成功（`BUILD SUCCESSFUL`）；它不执行 APK 任务。Gradle/AGP/Kotlin 的未来弃用提示保留，不擅自升级；共享闭包验收范围仅 ARM64 release。未编译新的产品 APK、签名、安装或触发云端运行，已有 v1.2.27 完整包继续保留；共享合成 APK 验证不是本项目产品或真机验收。所有测试消费结清后，`Finalize` 已清退源根 owner 测试输出 12 文件、58,460,728 字节；另清退 5 个具名 shader 诊断/临时验证日志、95,700 字节，未生成 UI 截图，可复用 SDK/pub/Maven/增量缓存保留。

收尾限制：最初便携 Git `status` 被权限拒绝，未重试、提交或推送。最终向当前共享维护会话 `e4d68924-eec5-465a-8924-5f3f5c335484` 发送一次匹配回执时，工具返回 `Unknown chat owner`；该会话仍能只读查询，但不能据此声称回执已送达。最终匹配结果持久记录在本节，未修改共享目录或绕过路由/权限限制。

### 实际修改版 APK 编译（2026-11-19 后续）

用户随后要求交付修改后的 APK。本次实际执行 `LocalBuild.ps1 -Action BuildApk`（不是 ConfigureOnly），全程本地离线，`BUILD SUCCESSFUL in 7m 10s`，421 个任务中 417 个执行、4 个 up-to-date。已生成包含朗读分页修改的 ARM64 release 未签名 APK：`_cache/projects/ddnovelreader/main/build/app/outputs/apk/release/app-release-unsigned.apk`，19,121,306 字节，SHA-256 `e99b284999140e2d172c5f00676ef7bfb8cf8d28b02b2aa2d3e80c457b74118a`，仍为项目声明的 1.2.27（32）。

入口已核包名、版本、仅 ARM64 的应用/Flutter 库及未签名状态，并写同目录 `unsigned-build-info.json` 和 `SIGNING_STATUS.txt`；随后独立复核 APK 长度和 SHA-256 与记录一致。未改变业务源码或依赖锁，沿用上述 135 项已通过回归；本次不重复宣称真机验收。

尚缺本次使用既有固定签名资料的明确授权：已发起授权询问，但用户当前不可应答，不能将默认选项当作同意。因此未读取/使用签名凭据，未生成可安装成品、安装应用、发布远端或替换/删除旧包。未签名 APK 及必要符号留本实例供下一步获授权后签名使用，负责方为项目；退出条件为签名/固定证书验签及既有 LocalApk 接收收尾完成。原始构建日志已消费并清退，不保留一次性临时日志。此段为后续真实执行，不改写前一阶段仅配置验证的事实。

### 共享固定工具切换（2026-11-19 13:20，SDK 只读验证受阻）

共享发布后，项目入口已改为直接消费共享 Gradle 9.3.1 和组合 Android SDK；不再包含实例 Gradle/SDK 恢复路径。Flutter、pub/Maven、用户目录、TEMP 和构建输出仍在 main 实例，业务源码、锁及版本未因本次迁移改动。PowerShell 语法、实际 Resolve 和直接文档链接检查通过；一次真实项目离线 `BuildApk -ConfigureOnly` 成功（46 秒），未执行 APK 任务、签名或安装。既有未签名 APK 仍为 19,121,306 字节，SHA-256 `e99b284999140e2d172c5f00676ef7bfb8cf8d28b02b2aa2d3e80c457b74118a`。

完整共享树审计同时核文件 SHA-256、长度、目录及新增项，不仅检查原文件时间。Gradle 树前后匹配，但 Android SDK 不匹配：AGP 于 13:19:54 自动生成 `.knownPackages`（16 字节），以及 `build-tools/36.0.0/package.xml`（1,433 字节）、`platform-tools/package.xml`（1,436 字节）、`platforms/android-35/package.xml`（1,654 字节）、`platforms/android-36/package.xml`（1,656 字节），合计 5 文件、6,195 字节。不能将任务图成功写成“共享工具完全只读验证通过”。

只读检查固定 `repository-32.1.1.jar` 的 `LocalRepoLoaderImpl` 发现：`getPackages()` 对非空包表无条件调用 `writeHashFile()`，`.knownPackages` 固定在 SDK 根，内容哈希包含包的绝对路径；仅预热 XML 不能保证下一次不再触碰该缓存。没有手动修改上游、共享文件、ACL 或建立联接来规避自动写入。已通过现有维护会话发送缺口和精确证据，等待共享唯一 writer 确认安全冻结/消费机制后再做匹配验证。

因此本次**未删除实例旧静态副本，退役 0 文件、0 字节**：`_cache/projects/ddnovelreader/main/gradle/gradle-9.3.1/` 与 `android-sdk/` 暂留，负责方为项目；退出条件为共享 SDK 只读验证通过，且原 Prepare 独占 lease、无消费者、身份/字节及重解析点预检均通过。未杀进程、移动活锁、删除 build/pub/Maven/Flutter、凭据或既有日志。最终进程检查未发现本项目 Java/Dart/原生构建消费者。

本次日志及精确元数据记录保留于实例 `temp/shared-tools-configure-20261119.log`、`temp/shared-tools-validation-20261119.json`；只读 SDK 缓存调查输出为 `temp/sdk-repository-cache-20261119.txt`。一次性验证/退役脚本已清退，退役脚本未执行。先前缺少签名授权的段落保留为历史，现行持续授权以项目 `AGENTS.md` 为准；本次按明确范围不构建或签名新 APK。

### 1.2.28（33）交付继续（2026-11-19 13:24 更正）

用户明确更正：共享工具拆分的 ConfigureOnly 是最低匹配验证，并不取消此前修改版 APK 的交付目标；项目仍须交付 1.2.28+33，沿用既有固定签名资料的持续授权，不再询问，不远端发布或安装。当前 pubspec 与应用版本均为 1.2.28（33），但尚未重建该版本 APK，不能把上面的 1.2.27 未签名输出冒充新包。

交付前置验证已补充完成：离线 `Restore` 的精确锁校验通过，锁 SHA-256 仍为 `b5fb94b4365c6c4a321e04f64c6dc205d60de7f12c17c6801402c8d5c3363c2e`；3 个默认朗读分页/手动页首/TTS 队列测试文件共 **96 项通过**，固定签名脚本 **13 项通过**，LocalApk 文件生命周期 **15 组合成回归通过**（不冒充真实签名验收）。首次 Restore 与只读静态副本盘点同时竞争原 Prepare 锁，正常拒绝；盘点释放后重试成功，未删除/绕过锁。测试无截图，消费后 `Finalize` 已清退源根 owner 测试输出 12 文件、58,463,104 字节；Flutter/pub/Maven/build 及旧静态工具副本均保留。日志在实例 `temp/delivery-*-20261119.log`，没有读取签名凭据。

共享维护会话已通过实时 steer 接收 SDK 自动写入缺口并开始调查；此前重复排队回执已取消，避免旧消息再触发一轮处理。待共享侧确认安全只读消费机制后，项目继续离线实际 BuildApk、SignApk、固定证书验签、LocalApk Receive/Finalize；当前不因已有持续签名授权而绕过共享只读阻塞。

### 共享护栏验收及 1.2.28（33）实际交付（2026-11-19，取代上述受阻状态）

共享维护者已在其 Prepare 锁内正式接收四份生成的 `package.xml` 及 `.knownPackages` 当前根观察值，并核证 Windows 固定 JDK17 / Repository32.1.1 的只读句柄兼容性。入口在本项目原 Prepare lease 内验证共享 manifest 元数据，确认缓存是既有普通 16 字节文件，启动任何 Gradle/AGP 前用 `Open/Read/FileShare.Read` 获取句柄；失败即停止。句柄持续到所有自有 Java/Dart/原生消费者自然结束、同步日志消费及完整 SDK 树后验完成，最后由嵌套 `finally` 释放并恢复环境/CWD。不修改 ACL、文件属性、上游或建立联接。

最终入口语法、Resolve 和离线真实 ConfigureOnly 均通过。随后执行 `DeliverApk`，在同一 lease/护栏内实际离线编译、既有固定密钥签名、证书验签及 LocalApk 接收成功：`BUILD SUCCESSFUL in 2m 41s`，421 个任务中 43 个执行、378 个 up-to-date；不是仅配置，也不是共享合成 APK。完整包为 `_releases/ddnovelreader/v1.2.28/DDNovelReader-v1.2.28-arm64-v8a.apk`，版本 1.2.28（33）、仅 ARM64，19,163,665 字节，SHA-256 `3c341a9281c5e983a1aa5acc49baa7ca4a1589fa257bf32dea5688ff03a52362`。固定证书 SHA-256 为 `088b9569c7e74b31dd9840b335e4755f1af5a51667d0c51ade9c5b83e0f57db1`；实际签名、对齐及 LocalApk 独立 DER 验签均通过，凭据仅由既有脚本本地消费，未进入输出或日志。

配置与真实交付两轮均对共享 Gradle 全树及 Android SDK 全树做前后路径、文件长度、SHA-256、目录及修改时间比较，包含四份 XML 和 `.knownPackages`，全部匹配。Gradle 为 22,164 文件、494,004,810 字节；SDK 为 33,356 文件、2,687,383,163 字节、6,230 个子目录（持久清单另计 SDK 根目录为一行）。入口内 SDK 前后清单位于实例 `temp/sdk-configure-{before,after}.json` 和 `temp/sdk-deliverapk-{before,after}.json`，日志/紧凑结果位于 `temp/delivery-shared-{configure,delivery}-20261119.{log,json}`；护栏释放及环境/CWD 恢复均已独立复核。

LocalApk 原子接收后已清退旧 1.2.27 完整包及相同签名输入副本，回执 `previousRemoved: true`、`cleanupPending: []`。当前完整包选择入口返回 1.2.28。应用未安装、未做真机验收、未远端发布；Flutter/Gradle/AGP/Kotlin 版本及 pub 锁未升级，既有弃用警告保留。上述 96 项定向朗读测试、13 项签名单测、15 组文件生命周期回归为本次交付前验证，不冒充手机运行结果。

全链路和共享树审计通过后，在原 Prepare 独占 lease 内完成旧实例副本身份、重解析点、占用及逐文件源/共享目标字节核对；仅本地输入 marker 按清单身份核验，路径相关 `.knownPackages` 不误当可移植归档身份。所有静态资源均与共享树匹配，消费者自然结清，未杀进程或移动锁。实际删除：

| 精确实例路径（均位于 `_cache/projects/ddnovelreader/main/`） | 文件数 | 字节 | 子目录数 |
|---|---:|---:|---:|
| `gradle/gradle-9.3.1/` | 22,165 | 494,004,925 | 4,869 |
| `android-sdk/` | 33,362 | 2,687,383,869 | 6,230 |
| 合计 | **55,527** | **3,181,388,794** | **11,099** |

两条旧路径已不存在，保留 Flutter、pub/Maven、Gradle/Android 用户缓存、build 产物/符号和项目日志，未读取或变动私有凭据。精确删除回执为实例 `temp/delivery-static-retirement-20261119.json`。随后真实 `LocalApk Finalize` 再次验签成功、`cleanupPending: []`；`LocalBuild Finalize` 确认无遗留源根测试输出，签名脚本的临时目录已自行清理。自有一次性验证/退役脚本已删除，不保留无用探针；构建/签名/审计原始日志及前后清单按用户要求保留。源码未因清理丢弃或重置，未绕过此前 Git 权限拒绝重试提交。

### 合并原作者 1.3 与本地 1.3.1 交付（2026-11-19）

用户要求比较并合并原作者 1.3。已核其公开 `v1.3.0` 发布及最新 `master` `1f156914739fe09a47892108f11a37cd95175386`，共同祖先为 `9838ccb`。上游已吸收本项目较早 PR 的阅读/朗读栈，但尚无本项目最新整页朗读；不能整体覆盖。本地已验收 1.2.28 源码先保存为 `63ee903`，随后正常 merge，保留全部历史；本轮新要求构成新的 Git 操作授权，未重写旧提交或推送。

按用户随后明确的取舍：整页朗读及手动翻页首字起读保留；普通阅读默认上下滚动，可在设置改点击/滑动，已有显式选择不强制重置；网络失败自动转系统音源增加开关且默认关闭。合入 WebDAV（配置后按上游自动同步及删除传播）、最近打开排序、多编码解码、跨端内容键/码点缓存坐标、有限重试与并发预取。iOS 源码/原始图标保留，但在线 workflow 固定停用，未宣称 iOS 或手机验收。显示原始断行和缩进保留，以共享映射联结桌面规范化码点坐标、排版后位置、高亮、进度和缓存；新 `words2` 坐标分区隔离旧音频，迁移冲突不删除不同内容。

依赖仍使用已接收的完整原锁 SHA-256 `b5fb94b4365c6c4a321e04f64c6dc205d60de7f12c17c6801402c8d5c3363c2e`。`audio_session 0.2.4` 原就在同一闭包，现由 pubspec 直接声明；标准离线 `pub get --enforce-lockfile` 成功验证同一选定包集，保留锁快照的展示性 transitive 分类，实际 `package_graph` 已确认直接依赖。没有新下载、pub upgrade、工具版本变化或 `_env` 写入。曾尝试为仅依赖角色变化的新锁申请共享准入，首次路由返回 `Unknown chat owner`；最终未采用该新锁，不需更改共享清单。用户提供可用会话链接后，已成功通知维护者不要执行过期请求；未把失败发送冒充送达。

完整 Flutter 套件 **401 项通过、3 项显式可选探测跳过**；本轮真实 HTTP WebDAV 服务仅监听自动分配的 `127.0.0.1` 端口，使用进程内合成数据和固定测试账号，没有探测其他服务、连接真实网盘、读取真实书籍或私人配置。严格新目录联调发现并修复上游未先创建 remoteDir 根目录导致 409 的问题，因此最终应用补丁版为 **1.3.1（35）**；先前 1.3.0（34）本地构建保留为历史执行事实，随后被正常替代。Analyze exit 0，无 error，158 条 warning/info 保留。日志为实例 `temp/upstream131-full-tests.log`、`upstream131-analyze.log`，测试可用 `LocalBuild -Action Test -TestName ... -DartDefines DD_MOCK_DAV_PORT=...` 定向选择；端口必须是本轮自有、已就绪的 mock。

合并提交为 **`a09ac75`**，已验证 `upstream/master` 是其祖先；无 merge 冲突残留。最终 1.3.1 源码执行本地离线 `DeliverApk` 成功，`BUILD SUCCESSFUL in 2m 38s`，421 任务中 35 执行、386 up-to-date。成品 `_releases/ddnovelreader/v1.3.1/DDNovelReader-v1.3.1-arm64-v8a.apk` 为 **19,548,689 字节**，SHA-256 **`d72f10aa139b125fc7826df85847980cd4fe53ee246ab60929423c100e85e451`**，固定证书仍为 `088b9569c7e74b31dd9840b335e4755f1af5a51667d0c51ade9c5b83e0f57db1`。版本/包名/ARM64、签名及对齐、LocalApk 独立证书验签均通过；完整 SDK 树（包括 XML 和 `.knownPackages`）前后未变，守护句柄保持到进程后代自然退出及后验完成。接收回执 `previousRemoved: true`、`cleanupPending: []`，未远端发布或安装。

本轮源码 Git 操作均为本地：未创建/推送 PR。若向原仓库贡献，应从其 1.3 基线整理通用朗读/可选兜底/兼容修复及测试的增量，不把本项目固定证书、AGENTS、共享环境入口、本地版本号或成品记录混入上游 PR；这不是 APK 二进制补丁。

父消费者结束后，自有 mock 已停止；核对合成书籍的固定内容后退役 4 文件、244 字节及相应临时目录，源根 owner 测试输出经 `Finalize` 清退 15 文件、231,069,304 字节。另在原 Prepare lease 下核无重解析点/占用后，清退三条已中止测试的 Flutter 临时编译/监听根（12 文件、335,308,532 字节）及空 JVM 性能目录，精确回执在实例 `temp/upstream13-abandoned-test-cleanup.json`。合并解析器、mock 脚本/端口和换行对照差异文件清退；SDK/pub/Maven/增量缓存、必要符号及日志保留，没有新增纯 UI 截图。最新 APK 选择入口已指向 1.3.1。

### 主页主题与视图切换：1.3.2（36）

本地离线 `DeliverApk` 成功（2 分 43 秒，421 个任务：37 执行、384 已最新），使用既有固定签名验签并归位。当前 APK 为 `_releases/ddnovelreader/v1.3.2/DDNovelReader-v1.3.2-arm64-v8a.apk`，19,618,321 字节，SHA-256 `4c256f82902ab7f6833bf8073fb8d34c20fa0b516d65560827a76b6e50c7120d`。共享 Android SDK 完整树审计通过，旧包已清退，接收无待处理项。未安装设备或远端发布。

106 项定向测试通过，涵盖主页主题与视图记忆、状态栏返回恢复、数据同步表单、关于和缓存管理。静态分析退出码 0，无错误（保留 160 条 warning/info）；锁文件未改。源根临时测试输出经 `Finalize` 清退 12 文件、65,025,928 字节；未生成 UI 截图。

### 跨页连续朗读：1.3.3（37）

129 项定向测试通过，静态分析无错误。离线 `DeliverApk` 成功（1 分 53 秒），固定证书验签及共享 Android SDK 完整树审计均通过。当前 ARM64 APK 为 19,618,321 字节，SHA-256 `c8e1c8e843a9b2fdf7d4ad5480c6df3bd42ac1e60704e8cef7d44aaada77b1d8`。旧包已清退，接收无待处理项；源根测试输出已清退。未安装设备或远端发布。

### 共享阅读页分页：1.3.4（38）

77 项定向测试通过，静态分析无错误。离线 `DeliverApk` 成功（2 分 40 秒），固定证书验签及共享 Android SDK 完整树审计均通过。当前 ARM64 APK 为 19,618,321 字节，SHA-256 `b44e5d1a6f4ad3921f40dd03fe3480b7ccce1a60c88a60dec88c473b92bbe8b4`。接收无待处理项，源根测试输出已清退；未安装设备或远端发布。

### 普通阅读双向翻页回归：1.3.5（39）

85 项定向测试通过，静态分析无错误。合成回归覆盖普通阅读视口恢复到两行之间、底部裁切和两个方向的一次相邻定位；用户报告的原页面尚未在真机复核。离线 `DeliverApk` 成功（1 分 55 秒），固定证书验签及共享 Android SDK 完整树审计均通过。当前 ARM64 APK 为 19,618,321 字节，SHA-256 `37139569eca45fd26405d7e75a6aa9e7faa85d714779e3a8da217c01e5fde266`。接收无待处理项，源根测试输出已清退；未安装设备或远端发布。

### 新页裁切后显示：1.3.6（40）

78 项定向测试通过，静态分析无错误。新增逐帧断言覆盖关闭动画时向两个方向翻页，以及旧页遮盖撤下后的首个可见帧。离线 `DeliverApk` 成功（2 分 8 秒），固定证书验签及共享 Android SDK 完整树审计均通过。当前 ARM64 APK 为 19,618,321 字节，SHA-256 `e2164ac1ded844ba3a1c365bf0e4b0f4472486bf812fd23a715dca7888e53e82`。接收无待处理项，源根测试输出已清退；未安装设备或远端发布。

### 朗读手动翻页与高亮：1.3.7（41）

106 项定向测试通过，覆盖双向手动翻页的实际系统音源请求、旧语音回调和隐藏行的背景。离线构建、固定证书验签及共享 Android SDK 审计通过。当前 ARM64 APK 为 19,618,321 字节，SHA-256 `ffda06151210737f53c4c8b79f31fafbb9487ea6de29c82febb753fe8d3b3e06`；无待清理接收项。未安装设备或远端发布。

## 本地构建收尾与 APK 选择

云端下载及验证后的本地目录使用 `_cache/projects/ddnovelreader/main/build/v<版本>/`。其中包含 APK、`build-info.json`（版本、文件名、长度、SHA-256、固定证书指纹及真实构建身份）、`SHA256SUMS.txt`、`signature-verification.txt` 和 `MaterialSymbols-LICENSE.txt`。接收入口从脚本自身定位共享总根，只读使用共享固定 JDK 与 Android Build Tools，不依赖全局工具，不访问私钥：

```powershell
# 在源码根执行；下载完成后先将 $buildDirectory 设为当次完整构建目录。
# 已归位版本的缓存只保留分析文件，不可再次作为 Receive 输入。
.\scripts\LocalApk.ps1 -Action Receive -BuildDirectory $buildDirectory
.\scripts\LocalApk.ps1 -Action Path
```

接收时在本项目临时目录独占锁下验签，逐文件比对原字节，核完整包及校验记录，再原子归位版本目录；复核现有选择入口后才执行最外层收尾。同步验签子进程此时已返回，脚本没有另起后台 Job，也不新增项目登记、lease 或清理框架。收尾移除缓存中的相同成品副本、已核实全为重复内容的 `apk-artifact.zip` / `build-analysis.zip`，并清退已替代旧包；保留当前尺寸报告、符号和增量/依赖缓存；临时图不在接收子阶段扫删，由其生产/父流程在最终收尾默认清退。旧包文件必须全部属于本项目已知成品布局，没有重解析点或占用且删除已获授权；未知文件会中止接收。旧参数 `-RetirePrevious` 仅兼容调用，不能关闭正常最外层收尾。具体曾被安全拒绝的删除仍必须先获授权。选择入口按版本选择 `_releases` 中最新目录并复核 APK 长度和校验和；不另造发布注册表，不启动设备安装。

父流程在完整包已可接收但仍消费输入/预览时，传 `-KeepArtifacts` 保留旧包和输入；待其 Job/消费者自然结清，由父流程在自己的最外层调用同一脚本 `-Action Finalize -BuildDirectory $buildDirectory`。`Finalize` 只接收当前已选版本，重新核签名/完整包，不依赖已删的源 APK/清单，可用于收尾重试。`cleanupPending` 记录占用或内容尚未确认的保留项，清理失败不会把已验证的新包伪报为构建失败；`removed` 列出实际路径、文件数及字节。带额外预览的 ZIP 不当成重复归档删除。

接收失败保留原可用包；已关闭自有复制操作的部分 staging 在最外层 `finally` 内清理。原子移动后若复核失败，先退回本次 staging，恢复旧版选择；若被消费者阻塞则明确告警保留，不杀进程。`KeepArtifacts` 的失败 staging 仍归父流程保留/结清，不擅自删除。接收入口不扫描其他 run、未知图片目录或共享依赖；这不是明确自有临时图在本轮结束后长期保留的授权。

`scripts/test_local_apk.ps1` 提供纯文件生命周期回归，在本实例临时目录内运行后清理。15 组夹具覆盖默认接收、旧参数 true/false、校验与完整包失败、原子切换后失败回退、文件/锁占用、已有版本、归档额外预览、父流程保留与重试；各组都核对 22 个合成预览未被阶段清理。执行真实接收脚本的文件操作，只在隔离脚本副本中替换原生验签区段。此回归不编译、不签名、不联网、不接触真实成品，不作为密码学或手机运行验证；当前 v1.2.27 仍沿用此前真实验签结果。

在线构建的批量去重位于 `build-apk.yml` 最后一步，必须在验签及 APK/分析产物上传成功后才运行；只移除与交付 APK 字节相同的输出副本。交付包、符号及增量/SDK 缓存不删。UI 临时图在单独的最后一步、全部步骤返回后清退；存储位置不同不构成纯截图 artifact 会话后保留授权；其远程传输包仍由父 owner 在实际展示后结清。固定 v1.2.26 发布流程也仅在上传与远端资产验证成功后清理已消费的四个下载输入文件，失败不执行该收尾；临时签名秘密的正常清除仍是单独的安全释放，不等同于批量产物清理。本轮未触发云端运行。

本轮实际接收已完成，请勿重复接收同一版本；目标已存在会拒绝覆盖。v1.2.27 的 5 个成品文件共 19,362,947 字节已从缓存归入 `_releases/ddnovelreader/v1.2.27/`，APK 为 19,350,477 字节，证书与原构建一致。原始构建清单的 `candidate` 状态保留为当时事实，表示尚未手机验收，不影响其作为成功完整包纳入备份。

已删除 8 个失效或重复缓存文件，共 14,323,740 字节：v1.2.26 的旧尺寸报告/符号、已结束的一次性语速诊断、v1.2.27 重复下载 ZIP 和一次性校验脚本/原始 badging 输出。当前 v1.2.27 的尺寸报告和独立符号继续用于分析/定位，不在安装包中重复携带。只有两者及正常的零字节互斥锁留在本项目缓存。

已解决的审批例外：首次删除 `_releases/ddnovelreader/v1.2.26/` 被自动审批拒绝，接收时未启用 `-RetirePrevious`，先保留旧包。用户随后明确回答“允许删除这个旧版本目录”；再次核对精确文件清单、旧 APK 身份、新版校验和及无重解析点/占用后，已实际删除该目录的 6 文件、19,367,572 字节。连同上述缓存，本轮共清理 14 文件、33,691,312 字节。本地成品目录现在仅保留 v1.2.27，选择入口返回该版。

此前归位时的元数据快照为 7 张 JPG 参考截图及签名目录内 2 个文件，共 1,455,943 字节，原始收据保留在 [2026-11-16 归位记录](evidence/local-layout-2026-11-16.json)。本轮复查实际仅有签名目录的 2 个文件、8,319 字节；未发现构建目录、SDK、依赖展开或合成测试资料，没有读取、哈希或修改资料/密钥内容，也未寻找或处理已不在此目录的截图。当前各子目录用途与引用、删除结果见 [全仓引用和目录复查](reference-audit-2026-11-16.md)。
## 临时图片最终收尾（2026-11-17 最新更正）

实际生产入口是 `test/reader_layout_test.dart` 的三处捕获和 `test/reader_pause_settings_test.dart` 的捕获，均写入 runner 自有 `build/ui-previews`。`build-apk.yml` 保留生成、验证和上传阶段所需文件，新增最后一步 `Retire runner-local temporary UI previews`，成功/失败流程的所有步骤均返回后才清理这个已知生产根的临时文件和空根；不在单个测试、图片写入后或接收子阶段提前清理。未知内容/重解析点会停止并记录异常，不通过后缀或年龄扫描其他目录。上传到云端不改变纯截图的临时属性。APK/必要符号有独立保留角色；纯截图只有用户明确要求本轮结束后继续保留才例外。

生成数量、上传数量和纯路径不作为用户已看到图片的证明。聊天图片必须实际打开并核实展示；模型取图和展示交付也是父阶段，不能子命令结束就删源图再向模型给坏路径。全部父阶段和自有消费者结束后，在报告本轮完成前默认清理本轮自有临时副本；只有用户明确要求本轮结束后保留才例外。KeepArtifacts/ParentRun 仅作尚未结束的父流程交接，不能永久保留。LocalApk 不生产截图，不把未知图片或含额外内容的 ZIP 当重复包扫删；其已知自有临时图仍由生产/父 owner 按上述时点结清。

此前 [2026-11-17 收尾回执](build-finalization-2026-11-17.md) 中“保留预览”的记录保留当时原字节，不作为现行保留授权。本项目本轮缓存仅有 v1.2.27 报告、符号和零字节锁，没有临时图、预览根或待退役图片登记，实际图片删除数为 0；没有为审计生成截图，未进入 Data 或处理源码图标/历史截图/其他项目。本地纯文件验证的合成查看文件由最外层 finally 清完后才打印 PASS。
### 纯截图 artifact 默认关闭与云端实际清退

普通 push、PR 和默认手动 CI 不再生成或上传 UI 截图：workflow 默认 `retain_ui_previews: false`，四处 PNG 捕获由 `DD_READER_CAPTURE_UI_PREVIEWS == 1` 门控，布局/高亮等断言仍执行。只有用户明确要求会话结束后保留截图，才可启用该手动输入。它不是临时聊天看图的开关，不得为了绕过清退能力缺口擅自选择保留。

若只是把图从 CI 传给父会话查看，必须先确认父 owner 有已授权、可用的 artifact 删除能力，再按 repo/run/artifact ID 交接，待真实取图/展示和后续消费全部结束、报告会话完成之前删除远程纯截图包及本地临时副本。仅削短 TTL 或只删 runner 本地文件都不等于截图已全部清理。连接器本身仍只有列举/下载能力；本次在用户明确要求使用接口清理后，通过独立临时分支的一次性 Actions 工作流调用官方 REST API，使用该 job 自有临时 GITHUB_TOKEN，不读取个人凭据或签名 Secret，不通过浏览器隐藏接口执行写操作。

2026-11-17 已实际删除全部 150 个 `DDNovelReader-ui-previews`，共 599,990,489 字节：网页操作确认 3 个，其余 147 个由 [清理运行 44029719246](https://github.com/NayGnehz/DDNovelReader-Android/actions/runs/44029719246) 按 ID、名称、run、大小逐项验证后删除；完整仓库 artifact 列表复核截图剩余 0。该阶段全部 99 个非截图 artifact 的名称、大小和 digest 均保持不变。

用户随后扩大清理范围，[清理运行 44030804206](https://github.com/NayGnehz/DDNovelReader-Android/actions/runs/44030804206) 删除 95 个已被替代的 CI 安装包/分析包（1,890,711,820 字节）、已删除分支和已合并 PR 的 5 个不可复用缓存（3,566,641,529 字节），以及旧 v1.2.23 Release 和两个资产（19,350,508 字节）。连同截图共清退 6,076,694,346 字节，保留全部源码提交和历史 tag，不删除运行审计记录。

云端保留 4 个必要 artifact：最新成功 v1.2.27 的 APK/匹配符号（run `43810378191`），当前公开 v1.2.26 的原始 APK 输入/匹配符号（run `43622578197`，固定发布流程仍引用）。保留公开 v1.2.26 Release 的 APK/校验和，以及 master 正在复用的 2 个 Flutter/依赖缓存。没有按年龄删除仍复用的缓存，也未访问账号资料、真实数据或签名私钥。精确 ID、字节和保留角色见 [云端清退记录](evidence/cloud-retirement-2026-11-17.json)。临时清理分支在源码交接完成后退役；它不进入产品或上游 PR。旧执行回执维持其原时点、原字节。
