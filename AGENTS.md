# DDNovelReader 本地约定

先遵守父目录 [`AGENTS.md`](../AGENTS.md)；目录、共享维护、隐私、锁/进程、验证和收尾的通用规则以总根为准，以下仅补充本项目细则。

## 项目边界

- 本目录是唯一源码和 Git 根，不恢复旧 `fork` 入口或复制第二份源码。ProjectId 为 `ddnovelreader`，缓存 InstanceId 为 `main`；真实路径和入口见 [本地布局](docs/local-layout.md)。当前 ARM64 产品线的完整包归 `_releases/ddnovelreader/`，增量、诊断、符号及 staging 归 `_cache/projects/ddnovelreader/main/`。
- 真实资料、个人配置和签名归 `_data/ddnovelreader/`。不读取、打印、哈希或上传其内容；保护资料迁移仅按总根要求核元数据和 ACL。
- 外部纯参考归 `references/<upstream>/`，Edge 协议资料见 [参考说明](references/edge-tts/README.md)。实际参与测试/构建的旧版本基线保留原结构，不搬动独立维护的本地项目或读取私人参考资料。
- `docs/history/initial-workspace/` 是停用的早期元数据，不是当前入口。历史清理事实及精确授权见 [布局记录](docs/evidence/local-layout-2026-11-15.json)，不扩展为后续删除许可；具体拒绝仍按总根处理。

## 构建与本地接收

- 正式构建入口为 [GitHub Actions](.github/workflows/build-apk.yml)。本地 Flutter 构建须先由共享维护者完成项目登记和工具闭包；不得自行改公共契约、借用其他项目实例或安装/回退全局 Flutter。接收 APK 只读使用共享 JDK/Android 验签工具，不表示已接入本地 Flutter 构建。
- [LocalApk.ps1](scripts/LocalApk.ps1) 是本地 `Path`、`Receive`、`Finalize` 入口：固定证书验签、原字节比对后归位，最外层成功收尾清退已替代旧包及已核实的重复归档。该入口不安装应用、不修改远程 Release、不访问签名私钥。
- 父流程仍消费时用 `KeepArtifacts` 交接，结清后用同入口 `Finalize` 收尾/重试；旧 `RetirePrevious` 仅兼容调用，不作为关闭正常收尾的开关。沿用入口的互斥锁、路径/重解析点检查、失败回退和 pending 记录，不绕过保护或具体拒绝。
- 本地 Git 使用共享 `_env/bin/Invoke-PortableGit.ps1` 和总根既定署名；目录整理仅本地提交，未经明确指示不推送或改写历史。

## 纯 UI 截图

- 普通 CI 默认不生成/上传纯 UI 截图；`retain_ui_previews` 仅在用户明确要求会话结束后继续保留时启用，不能为临时聊天看图擅自勾选。临时图的展示、父流程交接和最终清退遵守总根第 6 节，`KeepArtifacts` 不授予长期保留。
- 临时远端传输须先具备已授权、可用的父流程退役能力；实际展示和消费结束后、报告完成前清本地副本及远端传输包。能力不足时停止该传输并记录精确阻塞，不因 artifact 已上传就认定为长期交付，不扩大权限或绕过拒绝。APK 和必要符号按其真实用途保留。
- 原始图标、设计原件、真实图片及确有必要的原始证据按用途保护；普通历史临时截图不因“历史”名称豁免清退。禁止按 PNG 后缀或年龄扫目录。
