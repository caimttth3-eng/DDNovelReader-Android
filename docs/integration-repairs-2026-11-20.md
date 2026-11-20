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
