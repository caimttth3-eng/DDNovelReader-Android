# DDNovelReader 本地约定

先遵守父目录 `AGENTS.md`。本目录是唯一源码和 Git 根；旧 `fork` 子目录已上提，勿恢复旧入口或复制第二份源码。

- ProjectId 为 `ddnovelreader`，缓存 InstanceId 为 `main`。布局见 `docs/local-layout.md`。
- 最新成功完整成品（含开发/测试版）在共享总根 `_releases/ddnovelreader/` 并备份；每条产品线仅保留最新一份。真实资料和签名在 `_data/ddnovelreader/`；增量、诊断、符号和构建 staging 在 `_cache/projects/ddnovelreader/main/`。
- 本地成品接收/选择入口为 `scripts/LocalApk.ps1`，用固定共享 JDK 验签、比对原字节后归位；最外层成功收尾自动清退已替代旧包和已核实的重复归档，仅留最新。父流程尚在消费时用 `KeepArtifacts` 延后清理，结清后用同入口 `Finalize` 收尾/重试；旧 `RetirePrevious` 参数仅兼容调用。不安装应用、不修改远程 Release。具体已被安全拒绝的旧包删除必须另获授权，不能用通用整理规则重试。
- 本轮临时图片保留到全部父阶段（含实际展示交付）及消费者结清，报告完成前默认清退；仅用户明确要求本轮结束后保留才例外。`KeepArtifacts` 只是未结束父流程交接。普通 CI 默认不生成/上传纯 UI 截图；`retain_ui_previews` 只能在用户明确要求会话后保留时启用，不能为临时聊天查看擅自勾选。截图 artifact 不因上传就成为长期交付物；临时传输必须先具备已授权的父流程退役能力，实际取图/展示后、会话完成前清本地副本和远程传输包，能力不足则停止并记录具体阻塞。APK/必要符号有独立保留角色。原始图标、历史截图及真实图片不清理，禁止按 PNG 后缀或年龄扫目录。
- 纯外部源码参考归 `references/<upstream>/`；原协议摘录已原字节移入 `references/edge-tts/`。实际参与测试/构建的旧版本基线保留原结构；不移动独立维护的本地项目或读取私人参考资料。
- 不读取、打印、哈希或上传真实资料、个人配置和密钥内容。保护资料迁移只按总根规定核对元数据和 ACL。
- 正式构建使用 GitHub Actions。共享工具尚未登记本项目；新增本地构建前由共享维护者登记，不修改公共契约、不借用其他项目实例、不安装或回退全局 Flutter。
- 本地 Git 用共享 `_env/bin/Invoke-PortableGit.ps1` 和既定署名；目录整理只本地提交，未经明确指示不推送、不改写历史。
- `docs/history/initial-workspace` 是停用的早期元数据，不是当前构建入口。
- 2026-11-15 的 120 个旧物已在用户具体授权后清理，记录见 `docs/evidence/local-layout-2026-11-15.json`。此授权不扩展到其他文件；以后被安全拒绝的具体删除仍按父目录规则另行确认。
