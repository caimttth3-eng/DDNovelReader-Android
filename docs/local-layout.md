# 本地目录布局

本地整理遵循工作区总根的 `AGENTS.md`，ProjectId 为 `ddnovelreader`。项目根包含 `pubspec.yaml`、`lib`、`android` 和 `.git`，不再使用内部 `fork` 子目录。以下路径相对共享工作区总根，不固定盘符。

| 用途 | 路径 |
|---|---|
| 唯一源码与 Git 历史 | `DDNovelReader/` |
| 已接受的 ARM64 v1.2.26 成品、校验和、说明与许可 | `_releases/ddnovelreader/v1.2.26/` |
| 当前尺寸报告与独立调试符号 | `_cache/projects/ddnovelreader/main/build/v1.2.26/` |
| 原有截图资料与签名目录 | `_data/ddnovelreader/`，签名在其下 `signing/` |
| 待确认删除的旧物 | `_cache/projects/ddnovelreader/main/temp/layout-review/` |

签名目录仅做同卷移动，通过文件数量、长度、时间和 ACL 元数据核对；未读取、打印或哈希密钥内容。现有截图资料未移动、未读取内容。正式 APK 移动前后 SHA-256 相同，未重新构建或更换版本。

外层 7 个旧代码文件已在 Git 对象中核实；两个未匹配历史的早期说明/依赖清单完整保存在 `docs/history/initial-workspace/`，不能当作当前构建入口。旧预览、重复安装包及一次性补丁脚本的批量删除被自动审批拒绝，现暂存待确认；未删除任何文件。清单包含 120 个旧文件，共 116295907 字节，另有清单自身与空目录。明细见暂存目录内 `cleanup-manifest.json`，简报见 [迁移证据](evidence/local-layout-2026-11-15.json)。

## 后续开发与备份

- 备份源码、正式成品、共享固定环境及 `_data`；排除 `_cache`。排除备份不等于每次清空缓存。
- 正式构建继续使用 GitHub Actions；云端 checkout 的工作目录独立于本地五类目录。
- 本项目尚未登记到共享 `Invoke-Portable.ps1` 的 ProjectId 列表，也没有本地 Flutter 离线工具闭包。本次不改公共契约、不安装工具；如需本地构建，先由共享环境维护者登记和补齐，不借用其他项目实例或退回全局工具。
- 本地 Git 使用共享 `_env/bin/Invoke-PortableGit.ps1` 和既定用户配置。目录整理只本地提交，不自动推送或改写历史。
- 新验证、下载、解压和生成预览放本项目缓存实例；私钥与凭据放 `_data`，不得进入 Git 或报告。
