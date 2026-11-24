# 1.3 / 1.3.1 整合问题修复与验收

基线为 `b2f6dee`（已合并原作者最新 1.3.1 并统一跨章预取）。本轮接续中断会话，对此前按根因去重的 24 项问题实施修复，不重复执行上游合并。原解析及音频子任务已经交回；同步子任务因模型服务 502 中断，接续检查保留改动后完成。各组独占文件，Flutter、静态分析和 Android 构建由主审串行执行。

## 已确认的行为与范围

- 接受另一端较新进度后，立即暂停并跳转；恢复该位置不制造本地新修改。
- 同内容重复书籍合并条目、最新真实进度、标注和最近打开引用，保留全部源文件。
- 添加兼容书签删除元数据，保留既有协议字段；旧桌面客户端可能忽略删除字段，不能保证它执行删除。
- 保留整页朗读、页首起读、分页裁切与高亮、主题、按书音色、系统兜底及本地构建能力。不推送、不远端发布、不安装。

## 根因与验收覆盖

下表编号沿用原计划，A/B/C 为子任务，M 为主审整合。状态以最后一节的实际验证为准。

| 编号 | 原问题 | 修复后的行为 | 主要回归 |
| --- | --- | --- | --- |
| A01 | 扩展区汉字 cmap 与 UTF-16 范围混用 | 每个 UTF-16 单元映射，码点计数分块，不拆代理对 | [Unicode 导入](../test/book_parser_unicode_test.dart) |
| B01 | 系统音色超时挡住在线菜单 | 在线菜单立即可用，原生枚举有界失败并保留默认入口 | [系统音源](../test/system_tts_test.dart)、[音色面板](../test/reader_voice_pauses_test.dart) |
| B02 | 原生焦点与 Dart 状态脱节 | audio_session 统一拥有焦点，手动暂停/停止释放，中断由阅读页统一决定恢复 | [焦点生命周期](../test/tts_audio_focus_test.dart)、[媒体控制](../test/reader_media_controls_test.dart) |
| B03 | 不同音频与词时间轴迁移串配 | 音频及侧车成组判冲突，被拒绝音频不提供时间轴 | [缓存存储](../test/tts_cache_store_test.dart) |
| B04 | 取消未结清，继续叠加 worker | 可等待暂停/取消，取消传输并排空写入，继续保持并发上限 | [缓存任务](../test/book_cache_task_test.dart) |
| B05 | 写失败仍显示完成 | 失败不计完成，可续传并明确报告；朗读可选落盘仍不阻塞音频 | [缓存任务](../test/book_cache_task_test.dart)、[朗读队列](../test/tts_reader_queue_test.dart) |
| C01 | 书签删除可能复活 | 持久化每个 ID 的删除版本，传播删除-only/空列表 | [同步存储](../test/sync_storage_repairs_test.dart) |
| C02 | 整条时间戳门槛漏掉书签 | 不同 ID 总是先求并集，再按各自版本/删除版本裁决 | [同步存储](../test/sync_storage_repairs_test.dart) |
| C03 | 同内容多个 ID 互相覆盖 | 稳定条目及 aliases 归并进度、标注、源路径、最近打开引用 | [同步存储](../test/sync_storage_repairs_test.dart) |
| C04 | 重新导入的复活版本缺失 | 真实导入持久化 activityAt，自动接收不制造用户修改时间 | [同步存储](../test/sync_storage_repairs_test.dart) |
| C05 | 同步结束写回旧设置 | 串行读改写，仅补丁更新同步自有键 | [同步存储](../test/sync_storage_repairs_test.dart) |
| C06 | Android 段落字段压过原文坐标 | 规范 char_offset 优先，本地视口及合法旧坐标保留兼容 | [同步存储](../test/sync_storage_repairs_test.dart)、[媒体控制](../test/reader_media_controls_test.dart) |
| C07 | DAV 根路径编码混用 | 同一解码层比较路径，错误目录项/不可读记录停止替换上传 | [同步存储](../test/sync_storage_repairs_test.dart) |
| C08 | 多引擎同时同步 | 所有引擎/连接入口共用互斥，异常释放，配置变更废弃旧事务 | [同步存储](../test/sync_storage_repairs_test.dart) |
| C09 | 读旧进度伪造现在时间 | 无时间戳保留 0，读取/回填不压过真实远端新版本 | [同步存储](../test/sync_storage_repairs_test.dart) |
| C10 | 根据数值猜百分比单位 | schema/显式单位决定转换，未知旧值保留为歧义数据 | [同步存储](../test/sync_storage_repairs_test.dart) |
| M01 | 新旧书签位置未接通 | 创建时输出规范偏移，桌面偏移映射成本地锚点 | [阅读布局](../test/reader_layout_test.dart) |
| M02 | 用书 ID 查复合键任务，取消失效 | 按任务的书 ID/内容键匹配全部任务，等待取消再删除 | [阅读布局](../test/reader_layout_test.dart)、[缓存任务](../test/book_cache_task_test.dart) |
| M03 | 同步后持续跳过保存 | 落盘事件暂停并跳转，更新本页版本，之后真实阅读可保存 | [媒体控制](../test/reader_media_controls_test.dart) |
| M04 | 关闭自动同步仍启动同步 | 启动遵守开关，显式手动操作仍可同步 | [阅读布局](../test/reader_layout_test.dart) |
| M05 | 删除未通知打开页面 | 进度/标注写入与删除排序，页面停止并关闭，不重建进度 | [媒体控制](../test/reader_media_controls_test.dart)、[同步存储](../test/sync_storage_repairs_test.dart) |
| M06 | 过滤后空末章未结束朗读 | 完整退出朗读、通知和焦点生命周期 | [媒体控制](../test/reader_media_controls_test.dart) |
| M07 | 正文设置改变后沿用旧队列 | 合并设置请求，先暂停、重建正文/队列/缓存身份再继续 | [媒体控制](../test/reader_media_controls_test.dart) |
| M08 | 书架回调再次写旧进度 | 阅读页为进度持久化所有者，书架回调只刷新显示 | [书架代码](../lib/screens/shelf_screen.dart)、[同步版本回归](../test/sync_storage_repairs_test.dart) |

## 接口和兼容

- [存储](../lib/services/app_storage.dart)：`bookChanges` 在成功持久化后通知 progress、removed、annotations；`trySaveProgress` 串行检查版本及删除，`resolveBookId` 解析 aliases。归并完成书架、进度、最近打开引用写入后才发布事件，重复归并不改时间或重复发布。
- [标注](../lib/services/annotation_store.dart)：显式 `deleteBookmark` 产生删除版本；普通保存对未看到的书签保守求并集，不把旧快照缺项误当删除。`mergeBooks` 可在上层事务完成前抑制通知。
- [同步](../lib/services/sync_engine.dart)：保留 schema 2 字段，新增可选 `bookmark_deletions`、`bookmarks_at`、`metadata_at`、`percent_unit`、`coordinate_authority`。0.005 本地比例导出为 0.5%，读回仍为 0.005；未知旧单位不猜测。
- [缓存任务](../lib/services/book_cache_task.dart)：`pause/resume/cancel` 返回 `Future<void>`；`lastFailure` 提供可显示错误。任务取消等待 worker、音频写入和进度写入结束。
- [朗读](../lib/services/tts_reader.dart)：`pause(interrupted: true)` 保留瞬时中断恢复所需焦点所有权；显式手动暂停即使已暂停也撤销意图，媒体命令不等待前一次慢暂停。audioplayers 的 Android 自动焦点关闭，避免两个暂停所有者。

## 实际验证及限制

24 项代码修复及匹配验证已完成。最终完整 Flutter 套件 **487 项通过、7 项可选探测跳过**；Analyze exit 0，无 error，保留 **178 条 warning/info**。最后的全套复核包含归并标注向存活 ID/aliases 通知及重复归并不重复发布的回归。新增磁盘夹具通过入口重定向到实例 TEMP，不再在源码目录建立测试副本；相关 34 项测试亦独立通过。

真实 `BuildApk` 离线 ARM64 编译成功，`BUILD SUCCESSFUL in 2m 39s`，421 个任务中 23 个执行、398 个 up-to-date。Dart 编译开始前已完成最后的标注通知修补；之后未修改产品源码。入口核实 1.3.8（42）、包名、ARM64 和未签名状态；APK 为 19,705,814 字节，SHA-256 `e500c4d4fe3fb37bc0efeb6193df2dc5072ddb3866f3acc6d426f975ca70b3c4`。共享 SDK 完整树前后审计通过，包含四份包元数据及 `.knownPackages`，守护句柄保持到进程后代自然结束及后验完成。

调用端曾将 `$LASTEXITCODE` 中 apksigner 验证未签名 APK 的预期值 1 传播为 shell 状态；这是调用端的状态判断，Gradle 已明确成功，入口完成了未签名身份验证及 SDK 后验，未为此重复构建。后续完整测试和 Analyze 都正常结束。

最终日志保留在实例 `temp/integration-repair-tests-final.log`、`integration-repair-analyze-final.log`、`integration-repair-build.log`、`integration-repair-fixture-tests.log`；SDK 审计为 `temp/sdk-buildapk-before.json` / `sdk-buildapk-after.json`。依赖声明、锁字节、原生工程、共享环境及本地构建入口未改；锁 SHA-256 仍为 `b5fb94b4365c6c4a321e04f64c6dc205d60de7f12c17c6801402c8d5c3363c2e`。没有生成 UI 截图、读取签名私钥、签名、安装或远端发布。`LocalApk Path` 仍选择既有已签名 1.3.7。

### 清理已获授权，工具策略仍拒绝：未执行删除

收尾复合命令首次被自动审批在执行前拒绝，返回 `blocked by policy`，没有更具体原因。用户随后明确回复“允许”，授权下表的 24 文件精确清理范围；基于该新增授权重试后，命令仍在启动前被工具策略以相同原因拒绝。其中 `LocalBuild Finalize` 及精确产物删除均未运行。当前删除数为 **0**，不再重复索取相同授权，也不改用其他工具、间接脚本或移锁绕过。后续仅在工具策略允许执行时，按原入口、Prepare lease、身份及消费者检查完成此范围。

| 位置 | 文件数 | 字节 | 当前用途 / 退出条件 |
| --- | ---: | ---: | --- |
| 源根 `build/` | 12 | 64,776,296 | 已核 owner 为本项目 `flutter-host-tests`，无重解析点；已获授权，Finalize 执行仍受策略阻止 |
| 实例 `build/` 的本次未签名包及对应元数据/符号 | 6 | 43,334,141 | 仅编译验证，未交付；核 APK 原字节后精确退役 |
| 实例 `temp/` 的本轮中间日志 | 6 | 135,732 | 已被最终日志取代；仅清下列具名文件 |
| 合计 | **24** | **108,246,169** | 自有进程均已自然结束，仍须执行时再次核对 |

6 个编译产物为实例内 `build/app/outputs/apk/release/` 的 `app-release-unsigned.apk`、`output-metadata.json`、`SIGNING_STATUS.txt`、`unsigned-build-info.json`，以及 `build/app/outputs/flutter-apk/app-release.apk`、`build/debug-symbols/app.android-arm64.symbols`。两份 APK 的大小、SHA-256 已由入口和本轮清单确认；清理不得触及当前 1.3.7 成品或增量/依赖缓存。

源根 12 个文件的精确相对路径及字节如下，均为已结束宿主测试的编译输出、测试资源副本或 owner 标记。许可证和字体仅删除测试副本，源码许可证原件、固定依赖及当前产品资源保留：

| 相对源根 `build/` 的文件 | 字节 |
| --- | ---: |
| `.ddnovel-test-output.json` | 99 |
| `native_assets/windows/native_assets.json` | 45 |
| `test_cache/build/8b61f7661612a76fd566b4b40b3c6008.cache.dill.track.dill` | 62,728,864 |
| `unit_test_assets/AssetManifest.bin` | 220 |
| `unit_test_assets/FontManifest.json` | 208 |
| `unit_test_assets/NativeAssetsManifest.json` | 45 |
| `unit_test_assets/NOTICES.Z` | 109,749 |
| `unit_test_assets/docs/third-party/MaterialSymbols-LICENSE.txt` | 11,358 |
| `unit_test_assets/fonts/MaterialIcons-Regular.otf` | 1,645,184 |
| `unit_test_assets/packages/cupertino_icons/assets/CupertinoIcons.ttf` | 257,628 |
| `unit_test_assets/shaders/ink_sparkle.frag` | 13,432 |
| `unit_test_assets/shaders/stretch_effect.frag` | 9,464 |

6 份中间日志为 `integration-repair-analyze-initial.log`、`integration-repair-focus-diagnostic.log`、`integration-repair-focus-layout-tests.log`、`integration-repair-focus-tests.log`、`integration-repair-handoff-tests.log`、`integration-repair-tests-initial.log`。这些是修复过程中的初次失败/中间成功及专项诊断，已无后续消费者；最终完整测试、分析、构建、夹具日志及 SDK 审计继续保留。负责人为本轮主审；退出条件是工具策略允许执行已授权的精确范围，随后复用原入口和护栏实际清退并更新本节。用户询问具体文件后，已再次只读核对 24 文件仍在、总计 108,246,169 字节，源根无重解析点。

合成回归不连接真实 WebDAV，不读取私人配置、真实书籍或凭据。iOS、真机音频焦点/来电、旧桌面客户端及真实网盘仍需各自环境验收；本轮没有执行全部编码表的穷举验证，也不声称已找尽全部潜在问题。


## 1.3.8（42）签名交付、合规复核及当前待删清单

本节记录随后用户要求“编译最新 APK”后的当前状态，取代前面未签名阶段的状态判断，不改写旧时点结果。

已通过既有 `LocalBuild DeliverApk` 完成本地离线 ARM64 构建、固定签名、LocalApk 接收及同一 Prepare lease / SDK 守护句柄内的完整后验。Gradle 成功（42 秒，421 个任务：14 执行、407 已最新），返回 exit 0。完整包为 `D:\Dev\_releases\ddnovelreader\v1.3.8\DDNovelReader-v1.3.8-arm64-v8a.apk`，19,749,393 字节，SHA-256 `e8776a3f172fba9e41639b754048c1b8f22b7c44fc6a1c9408b7f3349c6e0e66`；固定证书 `088b9569c7e74b31dd9840b335e4755f1af5a51667d0c51ade9c5b83e0f57db1`。Path 入口、签名构建身份及独立文件哈希复核一致；未签名输入仍为前述 SHA-256。详见 [交付说明](releases/v1.3.8.md)。

已清退旧 1.3.7 完整包 5 文件、19,630,464 字节，及本次相同签名输入 5 文件、19,761,636 字节。复核发现本地接收入口未清理签名脚本额外生成的校验副本，已修补：仅精确路径且内容等于已接收 APK 身份时清退，不匹配则保留并输出 pending。17 组合成生命周期测试通过，临时夹具自动清退；随后 LocalApk Finalize 清退本次匹配校验副本 1 文件、102 字节。真实接收和该次收尾的 cleanupPending 均为空，所触及路径与此前被拒绝的 24 项范围不同。共实际删除 11 文件、39,392,202 字节；未删除任何此前被拒绝目标。

### 规则检查与调整

- 已重读总根及项目 AGENTS，使用唯一源码根和本项目 main 实例；共享工具按固定路由只读使用，不重复展开 Gradle/Android SDK，不回退全局/云端。构建、签名及接收由既有入口在 Prepare lease 内完成；包元数据、16B 缓存只读句柄及 SDK 全树后验均通过。
- 凭据仅由既有签名脚本及其本地子进程按持续授权消费，未向模型、日志、源码或成品展示；未读真实书籍/个人配置。没有安装、推送、远端发布、截图、改 ACL、杀进程或移活锁。
- 前阶段测试夹具曾位于源码目录，已在最终测试前改为实例 TEMP；34 项相关验证通过。Flutter 强制的宿主测试 build 仍为已记录工具限制例外，Finalize 被具体工具策略拒绝，保留并列明，未宣称彻底清理。
- 校验副本遗漏已修补且匹配验证通过。本次没有改动产品源码、依赖锁、原生工程或共享环境，无需重跑未受影响的 487 项套件或重编 APK。
- **调整原删除判断**：`D:\Dev\_cache\projects\ddnovelreader\main\build\debug-symbols\app.android-arm64.symbols`（3,921,320 字节）现在匹配已交付 1.3.8，是必要符号，保留且不再待删。

### 当前完整路径快照

本轮三组 **23 文件、104,324,849 字节** 仍在此前被具体工具拒绝的范围内；另发现历史 staging **11 文件、3,828,806 字节** 待协调。合计 **34 文件、108,153,655 字节**。本清单仅列明当前核实范围，不代表递归扫描全部历史缓存。负责人为项目主审；本轮范围退出条件为工具策略允许后原入口/lease/身份/消费者复核及实际清退；历史组先由共享维护者协调执行者。当前自有 Java/Dart/原生消费者已自然结束，源根 owner 输出没有重解析点。新交付日志及 SDK 清单继续留在实例 TEMP，供本次验收。

#### 本轮测试输出（12 文件，64,776,296 字节）

宿主测试已结束；这些是测试编译输出、资源副本及 owner 标记。源码许可证和依赖原件保留。必须沿用 LocalBuild Finalize 的 owner/路径/重解析点检查；此前具体工具拒绝尚未解除，不换入口绕过。

| 完整路径 | 字节 |
| --- | ---: |
| `D:\Dev\DDNovelReader\build\.ddnovel-test-output.json` | 99 |
| `D:\Dev\DDNovelReader\build\native_assets\windows\native_assets.json` | 45 |
| `D:\Dev\DDNovelReader\build\test_cache\build\8b61f7661612a76fd566b4b40b3c6008.cache.dill.track.dill` | 62,728,864 |
| `D:\Dev\DDNovelReader\build\unit_test_assets\AssetManifest.bin` | 220 |
| `D:\Dev\DDNovelReader\build\unit_test_assets\FontManifest.json` | 208 |
| `D:\Dev\DDNovelReader\build\unit_test_assets\NativeAssetsManifest.json` | 45 |
| `D:\Dev\DDNovelReader\build\unit_test_assets\NOTICES.Z` | 109,749 |
| `D:\Dev\DDNovelReader\build\unit_test_assets\docs\third-party\MaterialSymbols-LICENSE.txt` | 11,358 |
| `D:\Dev\DDNovelReader\build\unit_test_assets\fonts\MaterialIcons-Regular.otf` | 1,645,184 |
| `D:\Dev\DDNovelReader\build\unit_test_assets\packages\cupertino_icons\assets\CupertinoIcons.ttf` | 257,628 |
| `D:\Dev\DDNovelReader\build\unit_test_assets\shaders\ink_sparkle.frag` | 13,432 |
| `D:\Dev\DDNovelReader\build\unit_test_assets\shaders\stretch_effect.frag` | 9,464 |

#### 本轮已消费未签名输入（5 文件，39,412,821 字节）

两份未签名 APK 及配套元数据已由本次签名消费，正式完整包已接收，且与 unsignedSha256 匹配。仅此五个具名文件待清，不清增量树或当前调试符号；此前精确删除被工具拒绝，仍未重试。

| 完整路径 | 字节 |
| --- | ---: |
| `D:\Dev\_cache\projects\ddnovelreader\main\build\app\outputs\apk\release\app-release-unsigned.apk` | 19,705,814 |
| `D:\Dev\_cache\projects\ddnovelreader\main\build\app\outputs\apk\release\output-metadata.json` | 735 |
| `D:\Dev\_cache\projects\ddnovelreader\main\build\app\outputs\apk\release\SIGNING_STATUS.txt` | 110 |
| `D:\Dev\_cache\projects\ddnovelreader\main\build\app\outputs\apk\release\unsigned-build-info.json` | 348 |
| `D:\Dev\_cache\projects\ddnovelreader\main\build\app\outputs\flutter-apk\app-release.apk` | 19,705,814 |

#### 本轮已替代日志（6 文件，135,732 字节）

初次失败、专项诊断及中间结果已被最终日志取代，无后续消费者；最终测试、分析、构建、夹具和本次交付日志继续保留。仅此六份具名日志在此前被拒绝的范围内。

| 完整路径 | 字节 |
| --- | ---: |
| `D:\Dev\_cache\projects\ddnovelreader\main\temp\integration-repair-analyze-initial.log` | 37,434 |
| `D:\Dev\_cache\projects\ddnovelreader\main\temp\integration-repair-focus-diagnostic.log` | 1,632 |
| `D:\Dev\_cache\projects\ddnovelreader\main\temp\integration-repair-focus-layout-tests.log` | 10,380 |
| `D:\Dev\_cache\projects\ddnovelreader\main\temp\integration-repair-focus-tests.log` | 8,597 |
| `D:\Dev\_cache\projects\ddnovelreader\main\temp\integration-repair-handoff-tests.log` | 22,581 |
| `D:\Dev\_cache\projects\ddnovelreader\main\temp\integration-repair-tests-initial.log` | 55,108 |

#### 历史 staging 待协调（11 文件，3,828,806 字节）

只读检查发现的旧版残留。九份校验副本对应已退役产品；v1.2.27 的分析及符号仅对应已退役旧 APK，不参与当前构建/诊断。未发现源码/脚本当前消费者，历史证据仍保留原字节；总根第 8 节要求“跨项目／历史批量整理由维护者协调执行者”，因此列为待协调清退，不把原 24 项授权扩展到这里。执行前还需复核身份、引用、占用和 Prepare lease。

| 完整路径 | 字节 |
| --- | ---: |
| `D:\Dev\_cache\projects\ddnovelreader\main\build\v1.2.27\apk-size-report.json` | 3,551 |
| `D:\Dev\_cache\projects\ddnovelreader\main\build\v1.2.27\app.android-arm64.symbols` | 3,824,336 |
| `D:\Dev\_cache\projects\ddnovelreader\main\build\v1.2.28\DDNovelReader-v1.2.28-arm64-v8a.apk.sha256` | 103 |
| `D:\Dev\_cache\projects\ddnovelreader\main\build\v1.3.0\DDNovelReader-v1.3.0-arm64-v8a.apk.sha256` | 102 |
| `D:\Dev\_cache\projects\ddnovelreader\main\build\v1.3.1\DDNovelReader-v1.3.1-arm64-v8a.apk.sha256` | 102 |
| `D:\Dev\_cache\projects\ddnovelreader\main\build\v1.3.2\DDNovelReader-v1.3.2-arm64-v8a.apk.sha256` | 102 |
| `D:\Dev\_cache\projects\ddnovelreader\main\build\v1.3.3\DDNovelReader-v1.3.3-arm64-v8a.apk.sha256` | 102 |
| `D:\Dev\_cache\projects\ddnovelreader\main\build\v1.3.4\DDNovelReader-v1.3.4-arm64-v8a.apk.sha256` | 102 |
| `D:\Dev\_cache\projects\ddnovelreader\main\build\v1.3.5\DDNovelReader-v1.3.5-arm64-v8a.apk.sha256` | 102 |
| `D:\Dev\_cache\projects\ddnovelreader\main\build\v1.3.6\DDNovelReader-v1.3.6-arm64-v8a.apk.sha256` | 102 |
| `D:\Dev\_cache\projects\ddnovelreader\main\build\v1.3.7\DDNovelReader-v1.3.7-arm64-v8a.apk.sha256` | 102 |


## 1.3.9（43）合入上游缓存改进后的当前交付状态

本轮按用户批准的比较方案合入原作者 `514661efc702365afd313fbd7600c39adda35624`，保留 6 个提交的历史及本修改版现有功能。以下是新的验证/收尾记录，取代前述 1.3.8 的当前状态判断，不修改旧时点的执行事实。

- **缓存恢复与并发**：首次面板先显示后扫描；重新扫描取消并排空旧 worker/音频/进度写入，局部构建磁盘快照，确认代次未过期后一次发布及落盘。完成集合以当前分区非空 MP3 为准，补进度遗漏、剔除丢失及空文件，保留既有起点；扫描失败不覆盖旧集合，取消丢弃迟到结果。新增面板扫描期间取消的交互回归。
- **旧布局**：显式扫描会重新检查已知书籍 ID 的兼容旧目录，不被先前 marker 永久遮蔽；正文指纹、内容键、音色、语速和坐标分区仍隔离。不采用仅按书名自动收养，也不引入新的缓存登记框架；音频及词时间轴冲突继续成组保留。
- **诊断**：手动、可取消、单次遍历，报告省略书名、书籍 ID、内容键、目录路径及原始进度正文；不存在启动自动导出。失败/取消不会发布半份报告或覆盖已有报告，临时输出各自独立。
- **高亮与语速**：保留真实词范围，不将估算词位置送入分页和续读控制。首次“3 倍应快于 2 倍”的在线断言被实际响应否定，随后用两种音色独立复核，验证通过：晓晓 1/2/请求 3 倍为 16.944/8.496/8.496 秒，云希为 16.584/8.328/8.328 秒，每次 38 个词范围均满足文本/时间边界。因此保留在线 2 倍上限及 0.02 步长；不将参数格式允许 `+200%` 当作真实 3 倍速度，也不泛化为永久的协议硬限制。音频仅在内存消费，未落盘。

### 验证与成品

完整 Flutter 套件 **502 项通过、8 项可选探测跳过**；最终 Analyze exit 0、无 error，179 条 warning/info（新增在线探测输出说明计入 lint）。两音色在线特征验证另行执行并通过。最初 UI 回归两处失败分别为旧测试仍假设扫描完成后才显示面板，以及新测试使用错误按钮文案；已改为实际异步状态等待及稳定控件定位。完整首轮仅翻译占位符白名单未包含新参数，修正契约后最终全套通过。

真实 `DeliverApk` 完成本地离线 ARM64 编译（2 分 8 秒，421 任务：35 执行、386 已最新）、固定签名、LocalApk 独立验签及原子接收。版本 **1.3.9（43）**，APK 为 **19,749,393 字节**，SHA-256 `673c050d3e0baad0f4d2ee0d1671460b0e5b73b94a89056e2eb85a2f05cc9806`；固定证书仍为 `088b9569c7e74b31dd9840b335e4755f1af5a51667d0c51ade9c5b83e0f57db1`。共享 SDK 全树前后审核通过，包含四份包元数据及既有 16B 缓存只读句柄；未改共享工具、ACL、依赖锁、原生构建/签名配置或在线工作流。锁 SHA-256 仍为 `b5fb94b4365c6c4a321e04f64c6dc205d60de7f12c17c6801402c8d5c3363c2e`。凭据仅由既有签名脚本本地消费；没有读取真实书籍/个人配置、生成截图、安装或远端发布 APK。成品和限制见 [1.3.9 交付说明](releases/v1.3.9.md)。

### 本轮实际收尾及先前待办的归属调整

- LocalApk 已清退被替代的 1.3.8 完整包 5 文件、19,761,536 字节，及本次匹配签名输入 6 文件、19,761,638 字节，包含校验副本；`cleanupPending: []`。
- 本轮测试重建的源根 owner 输出，经既有 Prepare lease / Finalize 清退 **15 文件、212,970,576 字节**，源根 `build/` 已不存在。这是本轮新任务及重新生成输出的正常收尾；旧时点的拒绝记录保留原事实。
- 原 Prepare lease 内精确清退本轮已被最终结果替代的五份日志：`cache139-target-tests.log`、`cache139-rate-probe.log`、`cache139-ui-tests.log`、`cache139-analyze.log`、`cache139-tests-full.log`，共 **143,023 字节**。
- 当前 `build/debug-symbols/app.android-arm64.symbols`（3,943,504 字节）是 1.3.9 的必要符号，保留。此前五个未签名输出路径现已由 1.3.9 更新，既是本轮签名输入，也是 Gradle 声明的匹配增量输出，按真实复用用途保留，不再套用此前“仅验证、无后续消费者”的删除判断。
- 此前 6 份 `integration-repair-*` 中间日志的具体工具拒绝没有因此解除，未重试删除；11 份历史 staging 仍按历史批量整理规则待协调。剩余这两组 **17 文件、3,964,538 字节**的完整路径沿用上表对应两组；不把它们称为本轮已清退。

最终日志在实例 `temp/cache139-tests-final.log`、`cache139-analyze-final.log`、`cache139-rate-confirmation.log`、`cache139-delivery.log`；最新 SDK 接收审计为 `sdk-deliverapk-before.json` / `sdk-deliverapk-after.json`。本轮项目 Git 提交按用户明确授权推送至本人 master，并以该完整 master 替换旧 PR；不再提取另一份贡献源码，不强制推送或改写历史。iOS、真机焦点/来电、真实网盘和旧桌面端仍未验收。

## 1.3.10（44）系统引擎选择和音源面板

用户后续要求直接列出系统音色、切换引擎、以具体音色名替换通用离线入口、重置系统停顿，并将非当前在线语言组默认收起。本轮采用独立原生 TTS 实例枚举已安装服务，合并并发请求、限制探测数量和时限；列表不再排除普通音质、需联网及其他语言音色。选择携带引擎/音色身份，保留旧记录兼容和按书设置路径；枚举不切换播放引擎。在线组按保存的选择初始化，手动展开/收起在枚举完成时保持。停顿重置先改草稿，应用后清除系统和旧全局覆盖；回归确认在线分句、请求及缓存参数不变。

完整套件 **510 通过、8 可选探测跳过**；最终 Analyze exit 0、无 error，180 warning/info。新增模型在 lint 整理后另行 4 项通过。初轮失败属于旧断言仍寻找通用离线文案或假定所有在线组展开，另修正自动系统兜底时按原在线选择展开分组；最终全套通过。原生 Kotlin 实际编译通过，本地离线 Gradle 构建为 3 分 8 秒、421 任务（40 执行、381 已最新）。固定签名、独立验签、SDK 全树前后审计和 LocalApk 接收成功，包 **19,880,465 字节**，SHA-256 `8b653d2acfbb89dc9481418cdb1e12c229fc499bb0893295a04cbc1e4f2006b5`，证书及依赖锁身份沿用前版。

本轮按总根/项目 AGENTS 沿用唯一源码、便携固定工具、Prepare lease、SDK 四份包身份和 16B 缓存只读护栏；签名凭据只由既有本地脚本消费，未展示或外发。LocalApk 清退旧 1.3.9 完整包 5 文件、19,761,536 字节，及匹配签名 staging 6 文件、19,892,714 字节，cleanupPending 为空。Finalize 清退自有测试输出 13 文件、108,126,144 字节，Prepare lease 内精确退役 `voice140-target-initial.log`、`voice140-target-second.log`、`voice140-analyze-initial.log`、`voice140-tests-final.log`、`voice140-tests-confirmed.log`、`voice140-analyze-final.log` 六份已替代日志、266,818 字节。当前符号 4,008,656 字节和增量输出保留；前述 17 份历史待办没有重试清理。

最终证据在本实例 temp 的 `voice140-tests-passed.log`、`voice140-model-confirmed.log`、`voice140-analyze-confirmed.log`、`voice140-delivery.log`；最新 SDK 审计由本轮入口更新。完整包位置及限制见 [1.3.10 交付说明](releases/v1.3.10.md)。未生成截图、安装设备、在线构建或远端发布 APK/Release；不同厂商 TTS 引擎实际输出和 iOS 仍未验收。网络路由及远程 SHA 复核确认本人原 master 为 `791ed37`，原作者仍为 `514661e`；沿用用户授权的本人 master 和开放 PR #6 路径。

## 1.3.11（45）本地引擎与菜单修订（2026-11-21）

用户已明确纠正提交权限：今后未获明确指令不提交、不推送、不创建或更新 PR；此前 PR #6 已按用户要求关闭。本轮只在唯一工作区修改并交付本地 APK，HEAD 保持 `4dc2d62286430ddc7e66cc3816e788757971e22f`，未暂存或提交源码。

引擎与引擎内部语言分层处理：只选择引擎，不展示或展开无法可靠验证的内部条目。用户确认“仅显示优化音质”按各引擎默认音色标记筛选，开关放在本地语音标题下，管理系统音色入口保留。AiService 伪报较多语言不构成串用婷婷的证据；本轮不改播放路由或宣称真实外语能力。引擎目录请求不向 Flutter 返回完整语言表，合并请求仍有界复用探测，完整音色请求另行交接；默认 Voice API 内部仍可能读取引擎数据，不将其超时或质量标记解释为真实声学能力验收。

重置与应用并排，重置确认后直接保存，取消不变；圆点按有效值比较默认值，不按配置记录存在与否判断。三主菜单统一 85% 高度、固定左标题、16 内容边距、右侧操作，无内容分隔线与展开边框，背景和子菜单/确认框采用主题色并取消 surface tint。

最终完整套件 **523 通过、8 可选探测跳过**，Analyze exit 0、无 error（180 warning/info）。使用子代理分别处理样式回归、文档和只读复查，由主流程独占 Prepare 运行测试/构建；旧测试改为按真实滚动操作，时间序列化断言仅放宽 1 微秒机器误差，删除/幂等断言仍严格。实际 DeliverApk 为 2 分 14 秒，421 任务（35 执行、386 已最新），固定签名、独立验签、LocalApk 接收和 SDK 全树审计通过。

包位于 `_releases/ddnovelreader/v1.3.11/`，19,880,465 字节，SHA-256 `243ccb83ef24d195714c8ce7a1b3bfbba00ef2515cc98954b57e65e4e986957c`。旧 1.3.10 完整包 5 文件、19,892,611 字节及本次签名 staging 6 文件、19,892,714 字节已由原入口清退，cleanupPending 为空。Finalize 清退宿主测试输出 13 文件、127,599,376 字节；Prepare lease 内退役本轮九份中间日志、424,306 字节：`voice-filter-reset-tests.log`、`engine-reset-tests-final.log`、`engine-reset-analyze.log`、`engine-quality-tests-full.log`、`settings-unified-analyze-initial.log`、`settings-unified-tests-full.log`、`settings-unified-tests-confirmed.log`、`settings-unified-analyze-confirmed.log`、`settings-unified-android-build.log`。当前必要符号 4,010,048 字节和增量输出继续复用；之前 17 份待协调/拒绝目标没有重试清理。

最终日志在本实例 temp 的 `settings1311-tests-final.log`、`settings1311-analyze-final.log`、`settings1311-delivery.log`，最新 SDK 前后审计由本轮入口更新。详细成品与限制见 [1.3.11 交付说明](releases/v1.3.11.md)。没有安装、截图、线上构建、源码推送或远端 Release，真机及 iOS 未验收。

## 1.3.12（46）菜单层级、筛选记忆与本地音源短名（2026-11-21）

按用户后续反馈恢复重点色分组标题，统一主标题 20、分组及普通文字 16、说明 14，仅在主要层级边界分隔；浅色菜单恢复白底，深色保留中性深灰，阅读纸张背景独立。三主菜单仍统一 85% 屏高及对齐。“仅显示优化音质”通过现有全局设置持久化，其他设置及按书更新不会覆盖该偏好。本地音源控制栏按钮冷启动即可从引擎元数据提取关键词，增加宽度并保留完整名称提示，不需先打开音源设置，不初始化/探测或切换播放引擎。目录等待在退出时取消并忽略迟到结果。

最终完整 Flutter 套件 **536 通过、8 可选探测跳过**，Analyze exit 0、无 error（181 warning/info）。新增实际文字样式/颜色、主题动画、筛选跨页面和重新加载、320 窄屏关键词及未完成目录请求退出的回归。实际离线 DeliverApk 成功（2 分 12 秒，421 任务：38 执行、383 已最新），固定签名、独立验签、SDK 全树前后审计及 LocalApk 接收通过。包 19,880,465 字节，SHA-256 `46ccbf4ab4a498eefb63a947f94577499e7957a10ed9b37c6802a4075594e869`；固定证书及依赖锁不变。

原入口清退旧 1.3.11 包 5 文件、19,892,611 字节及本次匹配签名 staging 6 文件、19,892,714 字节，cleanupPending 为空。Finalize 清退自有测试输出 13 文件、121,666,888 字节；Prepare lease 内精确退役 `menus1312-tests-initial.log`、`menus1312-theme-transition.log`、`menus1312-theme-transition-confirmed.log`、`menus1312-tests-confirmed.log`、`menus1312-shortcuts-confirmed.log`、`menus1312-tests-final.log` 六份本轮已替代日志、845,476 字节。必要符号 4,011,576 字节及增量缓存保留；历史 17 项保持原拒绝/待协调状态，没有重试清理。

成品见 [1.3.12 交付说明](releases/v1.3.12.md)，最终日志位于本实例 temp 的 `menus1312-tests-passed.log`、`menus1312-analyze-final.log`、`menus1312-delivery.log`，SDK 前后审计由原入口更新。本轮无暂存、提交、推送或 PR 操作，HEAD 仍为 `4dc2d62286430ddc7e66cc3816e788757971e22f`；没有安装设备、生成截图、线上构建或远端发布，真机及 iOS 未验收。

## 1.3.13（47）中途过渡构建（2026-11-21）

恢复四个按钮等宽等距，并在 Android 播放出口解除旧记录隐藏的固定音色绑定后，已完成过渡包的实际验证：545 通过、8 可选探测跳过，Analyze exit 0、无 error（181 warning/info），离线 DeliverApk 2 分 12 秒、421 任务（35 执行、386 已最新）。固定签名、独立验签、SDK 全树审计和 LocalApk 接收通过，包 19,880,465 字节，SHA-256 `4cb3740897cdd349665881b6ab5aece9bbd6b3c19962211eab4c94aa6b3477df`，cleanupPending 为空。接收清退旧 1.3.12 完整包 5 文件、19,892,611 字节及匹配签名 staging 6 文件、19,892,714 字节。

构建途中用户追加已安装语言选择、普通网址起读行定位和通知原文分段要求，因此该过渡包不代表这些新增功能已经验证。随后自然结清消费者继续开发，最终完整包由下述 1.3.14 替代；不保留额外旧包、复制源码或改写此前验证事实。

## 1.3.14（48）语言选择、页首定位与通知原文（2026-11-21，当前）

并行子代理分别实现系统语言协议、页面/媒体流回归、通知分段及文档，主流程独占 Prepare 验证/构建并整合。语言通过用户显式点击引擎旁的按钮启动该包 `ACTION_CHECK_TTS_DATA`，仅 PASS 的有效安装清单可选，归一化 ISO3/ISO2 语言标识；不再用泛化 Voice 目录证明已安装语言。新语言选择按书保存，经支持校验后 setLanguage；默认引擎选择仍跟随系统。查询无结果、取消、配置脱离、失败及超时安全结清；内部请求 ID 避免旧取消影响新检查。真实 vivo OriginOS 7 返回清单仍未获取，不能预先保证恰好中英两项。

用户澄清的普通点分网址不含双斜线，且无需先翻页就会在起读时回退。合成普通/混排网址基线实际记录当前首行 `0.1px → 553/583px`：起读选择上一行残留行距盒，分页却选下一完整行。修正分页模式起读一次捕获已有 pageWindow / speechPositionAtPageStart 四元组，语音和页面共用该位置；滚动半行策略及保留上一页末行设置不变。独立修复重复符号压缩后实际字符起点和逆映射，保持原句段边界、音频与缓存格式。

通知原文按每个标点段显示，一两字的逗号段也独立；只对单个长段使用原宽度窗口。无词范围时显示首段，换句/句中起读在发布前种入真实起点，同句恢复保留当前段，避免先发整句再收回；测试捕获媒体流全部中间值。当前语言的沙漏入口使用该有效选择标识，仍沿用既有系统停顿规则。

最终全套 **573 通过、8 可选探测跳过**；Analyze exit 0、无 error（184 warning/info）。初轮唯一失败是旧停顿用例通过默认沙漏键找引擎，改用稳定引擎行定位后最终通过；没有删断言或放宽停顿、声音及缓存约束。实际离线 DeliverApk **2 分 9 秒、421 任务（40 执行、381 已最新）**，Kotlin 实际编译、固定签名、独立验签、完整 SDK 前后审计及接收通过。APK 19,880,465 字节，SHA-256 `94a9288c5ba5cbc296c6a0ae36b6d8137edd48dc5e05d4c96e794703bb765a60`，证书及依赖锁不变。

原入口清退过渡 1.3.13 完整包 5 文件、19,892,611 字节及本次匹配签名 staging 6 文件、19,892,714 字节，cleanupPending 为空。Finalize 清退本轮自有宿主测试输出 13 文件、122,420,864 字节；Prepare lease 内精确退役 13 份已被最终结果替代的过程日志、304,071 字节：`menus1313-tests-final.log`、`menus1313-analyze-final.log`、`menus1313-delivery.log`、`speech1314-map-unit.log`、`speech1314-link-before.log`、`speech1314-link-page-before.log`、`speech1314-link-map-after.log`、`speech1314-dotted-before.log`、`speech1314-languages-ui-initial.log`、`speech1314-languages-ui-confirmed.log`、`speech1314-link-floor-after.log`、`speech1314-language-protocol.log`、`speech1314-tests-final.log`。当前必要符号 4,017,448 字节及增量缓存保留；此前 17 项历史日志/staging 沿用原拒绝及待协调状态，未重试清理。

最终日志为本实例 temp 的 `speech1314-tests-passed.log`、`speech1314-analyze-final.log`、`speech1314-delivery.log`，另保留真实网址退页修复前证据 `speech1314-dotted-floor-before.log` 和最新 SDK 前后清单。详情见 [1.3.14 交付说明](releases/v1.3.14.md)。HEAD 仍为 `4dc2d62286430ddc7e66cc3816e788757971e22f`，无暂存、提交、推送或 PR 操作；没有安装设备、生成截图、启动在线构建或远端发布，OriginOS 实机及 iOS 未验收。

## 1.3.15（49）过滤、分页与朗读设计审查（2026-11-21）

按用户要求由子代理顺序审查映射、页面生命周期及成熟产品方案，主流程统一产品改动、Prepare 验证和交付。原文映射的 8 项合成回归通过，未确认存活正文映射故障；实际复现的是完整行与残余行距盒规则不一致、页底精度不同、旧异步状态覆盖新意图。统一行几何及 0.25 像素精度、布局/导航所有权和稳定绘制后发布；过滤准备期间保留最新普通视口，覆盖翻页和自由滚动，最新暂停撤销恢复、播放延后到新队列。相关基线、成熟 KOReader/Readium 官方来源、取舍及真机边界见 [设计审查](reader-layout-audit-2026-11-21.md)。

音色及语言选择圆点固定前置，本地标题齿轮取代底部管理行，语言和沙漏按钮中心间距 40 像素。最终完整套件 **598 通过、8 可选探测跳过**，Analyze exit 0、无 error（191 warning/info）。真实离线 DeliverApk **1 分 56 秒、421 任务（35 执行、386 已最新）**，固定签名、独立验签、LocalApk 接收及 SDK 全树前后审计通过；证书和依赖锁不变。包 19,880,465 字节，SHA-256 `f4545b31d52fa1e0867b0502aa374a24afabc239d28cffa88e327185a926ff5a`。

原入口清退旧 1.3.14 完整包 5 文件、19,892,611 字节及本次匹配签名 staging 6 文件、19,892,714 字节，cleanupPending 为空。Finalize 清退自有测试输出 13 文件、121,660,352 字节，Prepare lease 内精确退役六份已替代过程日志、57,650 字节，名称见 [1.3.15 交付记录](releases/v1.3.15.md)。必要符号 4,017,000 字节、四份独立修复前证据、最终日志及可复用缓存保留；历史 17 项没有重试删除。

最终日志为实例 temp 的 `layout1315-tests-final.log`、`layout1315-analyze-final.log`、`layout1315-delivery.log`，保留基线 `layout1315-filter-before.log`、`layout1315-geometry-and-race.log`、`layout1315-navigation-before.log`、`layout1315-scroll-before.log`；最新 SDK 前后清单由入口更新。源码仍无暂存、提交、推送或 PR 操作，HEAD 保持 `4dc2d62286430ddc7e66cc3816e788757971e22f`。未安装真机、生成截图、读取真实书籍、启动在线构建或远端发布，iOS 未编译或设备验证。

## 1.3.16（50）手机反馈后的页底与快速过滤追加修复（2026-11-21）

四项大字号回归确认：完整文字行可以容纳，却被其额外下半行距挤出页底；分页、起读及可见性统一改用同行最大字体高度，保持既有实际行距、段距、页脚和标点规则。新增九项顺序/异步回归确认并修正过滤准备与翻页交接、安装恢复期间输入、RawImage 触摸拦截及旧草稿发布；最终切回原状态而不重排时也保留最新跨段进度和起读。过程与成熟方案取舍见 [设计审查](reader-layout-audit-2026-11-21.md)。

最终完整套件 **611 通过、8 可选探测跳过**，Analyze exit 0、无 error（198 warning/info）。实际离线 DeliverApk **2 分 52 秒、421 任务（35 执行、386 已最新）**，固定签名、独立验签、LocalApk 接收和 SDK 全树前后审计通过。APK 19,880,465 字节，SHA-256 `f1fe9cacf18abe5247d3478670ca765a3e58e1346cd081af2d3c5540f4bd3fde`，固定证书和依赖锁未变。

旧 1.3.15 完整包 5 文件、19,892,611 字节及本次签名 staging 6 文件、19,892,714 字节由原入口清退，cleanupPending 为空。Finalize 清退自有宿主测试输出 13 文件、121,979,808 字节，Prepare lease 内精确退役六份被替代中间日志、43,195 字节，完整名称见 [1.3.16 交付记录](releases/v1.3.16.md)。必要符号 4,019,144 字节、匹配增量/依赖缓存保留；历史 17 项未重试删除。

最终日志为本实例 temp 的 `layout1316-tests-final.log`、`layout1316-analyze-final.log`、`layout1316-delivery.log`；保留 `layout1316-bottom-before-valid.log`、`layout1316-sequence-before.log`（前两项有效，第三项为夹具问题）、`layout1316-draft-before.log`。SDK 清单由既有入口更新；源码 HEAD 不变，未暂存、提交、推送或操作 PR，未安装真机、生成截图、读取私人书籍、触发在线构建或远端发布。

## 1.3.17（51）真实字体、实际像素和首末游标复核（2026-11-21，当前）

再次按用户反馈由三个子代理分块复核成熟方案、完整字符/像素、真实语音准备链，主流程独占产品修改与 Prepare 验证。真实 CJK 四项先失败，改同行 tight 安全范围后通过；透明快照消融产生 12.335% 像素差，现改为带纸张底色的整页捕获与覆盖；自然段距反例由 B40..71 回成32..71，现按已确认切片返回；暂停翻页后的继续播放先等待异步 seek，明确暂停仍能取消恢复。保留用户排版和原文/音频/缓存模型，未复制 GPL 阅读器实现。证据与成熟方案取舍见 [设计审查](reader-layout-audit-2026-11-21.md)。

新增 23 项，最终全套 **634 通过、8 可选探测跳过**，Analyze exit 0、无 error（208 warning/info）。实际离线 DeliverApk **2 分 4 秒、421 任务（35 执行、386 已最新）**，固定签名、独立验签、LocalApk 接收和 SDK 全树前后审计通过。成品 19,946,001 字节，SHA-256 `d89ff1f2123d282241a196f3f58b44942caae0f3f97be4ff2bfac5836cd1a7e1`，证书与依赖锁不变。

原入口清退旧 1.3.16 完整包 5 文件、19,892,611 字节及本次签名 staging 6 文件、19,958,250 字节，cleanupPending 为空。Finalize 清退自有测试输出 13 文件、121,789,672 字节；Prepare lease 内精确退役 18 份已替代日志、295,555 字节，完整清单见 [1.3.17 交付记录](releases/v1.3.17.md)。必要符号 4,028,544 字节、匹配增量/依赖缓存保留；历史 17 项未重试清理。

最终日志 `layout1317-tests-passed.log`、`layout1317-analyze-passed.log`、`layout1317-delivery.log`，另保留真实字体、透明快照、段距切片及旧 seek 的四份有效修复前证据。旧测试对缩进占位、cached paint transform、跨章前驱及调试角标的错误假设已修正；平移像素参考改用同后端独立合成，所有像素仅允同坐标1级舍入，无原先12级/150处例外。HEAD 不变，无暂存、提交、推送或 PR 操作；未安装真机、生成图片文件、读取私人书籍或远端发布。页历史容量256，未知或失效切片仍按当前布局计算，未宣称全书永久页目录或所有设备绝对无误。

### 1.3.18（52）段距与长段打开性能（2026-11-21，当前）

针对字号 39、默认行距/字体的两张非连续截图，开启首行缩进时取消额外 12 逻辑像素段距；关闭缩进保留块段落间隔。正文行几何改为按排版身份缓存视口附近范围，远原文进度直接查询目标字形窗口；保留过滤事务、页面切片及真实朗读游标。修复前有效反例和 W3C/KOReader 依据见 [阅读审查](reader-layout-audit-2026-11-21.md)。

匹配界面回归 123 项通过；完整套件 **643 通过、8 可选探测跳过**，Analyze exit 0、无 error（214 warning/info）。新增 9 项覆盖实际 CJK 段距、长段工作量、宽度/字号失效、前后各 12 页，以及第 20,000 字恢复和过滤往返。首次长段入书 caret 从点击26,696/滚动13,348降至86，远进度恢复218；这是主机几何开销证据，不是实际手机秒数。

离线 DeliverApk **1 分 58 秒、421 任务（35 执行、386 已最新）**，固定签名、独立验签、LocalApk 接收及共享 SDK 全树审计通过，cleanupPending 为空。最新完整包为 `_releases/ddnovelreader/v1.3.18/DDNovelReader-v1.3.18-arm64-v8a.apk`，19,946,001 字节，SHA-256 `2059aa11cfa9658ab63d36e61cc4289619c6cb050f661da7d70ebc47038814ef`；固定证书及依赖锁未变。

原入口清退旧1.3.17完整包5文件19,958,147字节、匹配签名staging6文件19,958,250字节；Finalize清退宿主测试输出13文件121,740,800字节，Prepare lease内退役6份已替代日志79,664字节。保留必要符号4,034,288字节、增量/依赖缓存、三份最终日志及两份有效修复前证据，文件名与边界见 [1.3.18 交付记录](releases/v1.3.18.md)。此前17项历史待办未重试清理。

本轮重新核对共享根和项目 AGENTS：唯一源码/Git根、已登记实例、固定工具/离线依赖、Prepare lease、SDK四份package.xml与既有16B缓存只读句柄、固定签名私密边界及成品收尾均沿用既有入口。未升级工具/依赖、回写共享SDK、生成截图或读取私人书籍；无暂存、提交、推送、PR、安装设备及远端发布。OriginOS 7字体、实际打开时间和手势体验仍待真机验收。
