# DDNovelReader 本地约定

先遵守父目录 [`AGENTS.md`](../AGENTS.md)；目录、共享维护、隐私、锁/进程、验证和收尾的通用规则以总根为准，以下仅补充本项目细则。

## 项目边界

- 本目录是唯一源码和 Git 根，不恢复旧 `fork` 入口或复制第二份源码。ProjectId 为 `ddnovelreader`，缓存 InstanceId 为 `main`；真实路径和入口见 [本地布局](docs/local-layout.md)。当前 ARM64 产品线的完整包归 `_releases/ddnovelreader/`，增量、诊断、符号及 staging 归 `_cache/projects/ddnovelreader/main/`。
- 真实资料、个人配置和签名归 `_data/ddnovelreader/`。除下述用户持续授权的本地固定签名流程外，不读取、打印、哈希或上传其内容；保护资料迁移仅按总根要求核元数据和 ACL。
- 外部纯参考归 `references/<upstream>/`，Edge 协议资料见 [参考说明](references/edge-tts/README.md)。实际参与测试/构建的旧版本基线保留原结构，不搬动独立维护的本地项目或读取私人参考资料。
- `docs/history/initial-workspace/` 是停用的早期元数据，不是当前入口。历史清理事实及精确授权见 [布局记录](docs/evidence/local-layout-2026-11-15.json)，不扩展为后续删除许可；具体拒绝仍按总根处理。

## 构建与本地接收

- 开发、测试与发布包均使用本地构建，不再启动 GitHub Actions 在线构建，也不因本地缺项回退云端。[原构建工作流](.github/workflows/build-apk.yml) 已停用；历史运行和接收证据保留原事实。
- 共享维护者负责项目登记、固定 Flutter/Dart、pub、匹配 Gradle/Maven、JDK/Android SDK 及离线闭包；项目负责本地适配、最后一次匹配验证和成品收尾。Flutter 会写 `bin/cache`，须按归档身份在本项目实例内准备可写运行树，复用既有 Prepare 锁，不向共享 SDK 回写。具体入口及未就绪项见 [本地布局](docs/local-layout.md)。不得自行改公共契约、借用其他项目实例或安装/回退全局工具；接收旧 APK 不表示本地构建已验证。
- Gradle 9.3.1 和含 API35/36、NDK28.2、CMake3.22.1 的固定 Android SDK 直接只读消费共享 `Tool gradle-9.3.1` / `Environment`，不在实例重复展开。实例只保留 Gradle/Android 用户缓存、pub/Maven、TEMP 和构建输出；Flutter 因上游将缓存和 Gradle 插件状态写入 SDK，仍保留实例可写运行树，不改上游或添加联接。
- 启动 Gradle/AGP 前必须在既有 Prepare lease 内验证共享 manifest 的四份 `package.xml`，并将既有普通 16B `.knownPackages` 以 `Open/Read/FileShare.Read` 打开；缺失、身份不符或无法打开即停止。句柄保持到自有进程后代自然结束、日志消费和完整 SDK 树后验完成，再在 `finally` 释放；审计包含元数据，不改 ACL/文件属性或忽略差异。`DeliverApk` 将构建、固定签名及 LocalApk 接收纳入同一 lease/护栏生命周期。
- [LocalApk.ps1](scripts/LocalApk.ps1) 是本地 `Path`、`Receive`、`Finalize` 入口：固定证书验签、原字节比对后归位，最外层成功收尾清退已替代旧包及已核实的重复归档。该入口不安装应用、不修改远程 Release、不访问签名私钥。
- 用户于 2026-11-19 明确持续授权：本项目本地 APK 构建交付时，直接使用既有固定签名资料进行本地签名、固定证书验签，并按 `LocalApk.ps1` 接收/收尾，无须再次询问签名授权。仅既有签名脚本及其本地子进程可为此读取所需凭据；不得把密钥、密码或私有 JSON 展示给模型/用户、写入日志/源码/成品或上传，临时签名资料沿用脚本清理机制。此授权不包括生成/更换密钥、安装应用、远端发布、读取其他私人资料或绕过具体工具拒绝。
- 父流程仍消费时用 `KeepArtifacts` 交接，结清后用同入口 `Finalize` 收尾/重试；旧 `RetirePrevious` 仅兼容调用，不作为关闭正常收尾的开关。沿用入口的互斥锁、路径/重解析点检查、失败回退和 pending 记录，不绕过保护或具体拒绝。
- 本地 Git 使用共享 `_env/bin/Invoke-PortableGit.ps1` 和总根既定署名；目录整理仅本地提交，未经明确指示不推送或改写历史。

## 纯 UI 截图

- 本地验证默认不生成纯 UI 截图；仅在有明确用途及最终清退能力时启用测试截图，不能为聊天看图启动已停用的在线构建或保留开关。临时图的展示、父流程交接和最终清退遵守总根第 6 节，`KeepArtifacts` 不授予长期保留。
- 临时远端传输须先具备已授权、可用的父流程退役能力；实际展示和消费结束后、报告完成前清本地副本及远端传输包。能力不足时停止该传输并记录精确阻塞，不因 artifact 已上传就认定为长期交付，不扩大权限或绕过拒绝。APK 和必要符号按其真实用途保留。
- 原始图标、设计原件、真实图片及确有必要的原始证据按用途保护；普通历史临时截图不因“历史”名称豁免清退。禁止按 PNG 后缀或年龄扫目录。
