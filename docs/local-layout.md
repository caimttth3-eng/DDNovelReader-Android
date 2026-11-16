# 本地目录布局

本地整理遵循工作区总根的 `AGENTS.md`，ProjectId 为 `ddnovelreader`。项目根包含 `pubspec.yaml`、`lib`、`android` 和 `.git`，不再使用内部 `fork` 子目录。以下路径相对共享工作区总根，不固定盘符。

| 用途 | 路径 |
|---|---|
| 唯一源码与 Git 历史 | `DDNovelReader/` |
| 最新成功完整 ARM64 v1.2.27 测试成品、校验和、构建身份与许可 | `_releases/ddnovelreader/v1.2.27/` |
| 本地最新 APK 选择入口 | `DDNovelReader/scripts/LocalApk.ps1 -Action Path` |
| 当前尺寸报告与独立调试符号 | `_cache/projects/ddnovelreader/main/build/v1.2.27/` |
| 原有截图资料与签名目录 | `_data/ddnovelreader/`，签名在其下 `signing/` |

此前签名目录仅做同卷移动，通过文件数量、长度、时间和 ACL 元数据核对；未读取、打印或哈希密钥内容。现有截图资料未移动、未读取内容。APK 归位前后 SHA-256 相同，不为整理重新构建或签名。

外层 7 个旧代码文件已在 Git 对象中核实；两个未匹配历史的早期说明/依赖清单完整保存在 `docs/history/initial-workspace/`，不能当作当前构建入口。旧预览、重复安装包及一次性补丁脚本先因自动审批拒绝而可恢复暂存；用户随后明确授权后，已删除清单中的 120 个旧文件，共 116295907 字节，并删除 29650 字节清单及空目录，总计删除 121 个文件、116325557 字节。暂存目录已不存在；本项目当前保留的构建缓存未清空。分组记录及授权结果见 [迁移证据](evidence/local-layout-2026-11-15.json)。

## 后续开发与备份

- 备份源码、正式成品、共享固定环境及 `_data`；排除 `_cache`。排除备份不等于每次清空缓存。
- 按 2026-11-16 最新规则，开发/测试/日用/正式仅为状态；成功完整 APK 统一归 `_releases`，不能以尚未正式验收留在缓存。ARM64 是当前唯一产品线，默认仅保留最新成功完整包。
- 正式构建继续使用 GitHub Actions；云端 checkout 的工作目录独立于本地五类目录。
- 本项目尚未登记到共享 `Invoke-Portable.ps1` 的 ProjectId 列表，也没有本地 Flutter 离线工具闭包。本次不改公共契约、不安装工具；如需本地构建，先由共享环境维护者登记和补齐，不借用其他项目实例或退回全局工具。
- 本地 Git 使用共享 `_env/bin/Invoke-PortableGit.ps1` 和既定用户配置。目录整理只本地提交，不自动推送或改写历史。
- 新验证、下载、解压和生成预览放本项目缓存实例；私钥与凭据放 `_data`，不得进入 Git 或报告。

## 本地构建收尾与 APK 选择

云端下载及验证后的本地目录使用 `_cache/projects/ddnovelreader/main/build/v<版本>/`。其中包含 APK、`build-info.json`（版本、文件名、长度、SHA-256、固定证书指纹及真实构建身份）、`SHA256SUMS.txt`、`signature-verification.txt` 和 `MaterialSymbols-LICENSE.txt`。接收入口从脚本自身定位共享总根，只读使用共享固定 JDK 与 Android Build Tools，不依赖全局工具，不访问私钥：

```powershell
# 在源码根执行；-BuildDirectory 使用当次真实构建目录。
.\scripts\LocalApk.ps1 -Action Receive -BuildDirectory ..\_cache\projects\ddnovelreader\main\build\v1.2.27 -RetirePrevious
.\scripts\LocalApk.ps1 -Action Path
```

接收时在本项目临时目录独占锁下验签，逐文件比对原字节，再原子归位版本目录；完成后移除缓存中的相同成品副本。`-RetirePrevious` 仅在旧包文件全部属于本项目已知成品布局、没有重解析点或占用且删除已获授权时清退旧包。未知文件会中止操作。选择入口按版本选择 `_releases` 中最新目录并复核 APK 长度和校验和；不另造发布注册表，不启动设备安装。`Path` 返回文件路径，可交给现有手动安装流程。

本轮实际接收已完成，请勿重复接收同一版本；目标已存在会拒绝覆盖。v1.2.27 的 5 个成品文件共 19,362,947 字节已从缓存归入 `_releases/ddnovelreader/v1.2.27/`，APK 为 19,350,477 字节，证书与原构建一致。原始构建清单的 `candidate` 状态保留为当时事实，表示尚未手机验收，不影响其作为成功完整包纳入备份。

已删除 8 个失效或重复缓存文件，共 14,323,740 字节：v1.2.26 的旧尺寸报告/符号、已结束的一次性语速诊断、v1.2.27 重复下载 ZIP 和一次性校验脚本/原始 badging 输出。当前 v1.2.27 的尺寸报告和独立符号继续用于分析/定位，不在安装包中重复携带。只有两者及正常的零字节互斥锁留在本项目缓存。

具体例外：自动审批拒绝删除 `_releases/ddnovelreader/v1.2.26/`（6 文件、19,367,572 字节），要求用户明确授权这个具体旧版本。本轮接收未启用 `-RetirePrevious`，旧成品没有删除。不得以本次通用整理授权绕过该拒绝；用户确认前临时保留，最新选择入口仍返回 v1.2.27。

`_data/ddnovelreader` 元数据核对结果为 7 张 JPG 参考截图及签名目录内 2 个文件，共 1,455,943 字节；未发现构建目录、SDK、依赖展开或合成测试资料，没有读取或哈希资料/密钥内容。本轮逐项收据见 [2026-11-16 归位记录](evidence/local-layout-2026-11-16.json)。
