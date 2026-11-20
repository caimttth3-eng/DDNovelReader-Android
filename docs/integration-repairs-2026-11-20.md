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

### 清理受阻：未执行删除

收尾复合命令被自动审批在执行前拒绝，返回 `blocked by policy`，没有更具体原因；其中 `LocalBuild Finalize` 及精确产物删除均未运行。遵守项目“具体拒绝不得绕过”约定，未改用其他工具、间接脚本或移锁重试。当前删除数为 **0**，以下为待用户明确批准后，按原入口、Prepare lease、身份及消费者检查完成的范围：

| 位置 | 文件数 | 字节 | 当前用途 / 退出条件 |
| --- | ---: | ---: | --- |
| 源根 `build/` | 12 | 64,776,296 | 已核 owner 为本项目 `flutter-host-tests`，无重解析点；原入口 Finalize 待批准 |
| 实例 `build/` 的本次未签名包及对应元数据/符号 | 6 | 43,334,141 | 仅编译验证，未交付；核 APK 原字节后精确退役 |
| 实例 `temp/` 的本轮中间日志 | 6 | 135,732 | 已被最终日志取代；仅清下列具名文件 |
| 合计 | **24** | **108,246,169** | 自有进程均已自然结束，仍须执行时再次核对 |

6 个编译产物为实例内 `build/app/outputs/apk/release/` 的 `app-release-unsigned.apk`、`output-metadata.json`、`SIGNING_STATUS.txt`、`unsigned-build-info.json`，以及 `build/app/outputs/flutter-apk/app-release.apk`、`build/debug-symbols/app.android-arm64.symbols`。两份 APK 的大小、SHA-256 已由入口和本轮清单确认；清理不得触及当前 1.3.7 成品或增量/依赖缓存。

6 份中间日志为 `integration-repair-analyze-initial.log`、`integration-repair-focus-diagnostic.log`、`integration-repair-focus-layout-tests.log`、`integration-repair-focus-tests.log`、`integration-repair-handoff-tests.log`、`integration-repair-tests-initial.log`。最终测试、分析、构建、夹具日志和 SDK 审计保留在实例缓存。负责人为本轮主审；退出条件是此精确删除范围获新授权，随后复用原入口和护栏实际清退并更新本节。

合成回归不连接真实 WebDAV，不读取私人配置、真实书籍或凭据。iOS、真机音频焦点/来电、旧桌面客户端及真实网盘仍需各自环境验收；本轮没有执行全部编码表的穷举验证，也不声称已找尽全部潜在问题。
