# DDNovelReader 本地约定

先遵守父目录 `AGENTS.md`。本目录是唯一源码和 Git 根；旧 `fork` 子目录已上提，勿恢复旧入口或复制第二份源码。

- ProjectId 为 `ddnovelreader`，缓存 InstanceId 为 `main`。布局见 `docs/local-layout.md`。
- 成品在共享总根 `_releases/ddnovelreader/`；真实资料和签名在 `_data/ddnovelreader/`；生成内容在 `_cache/projects/ddnovelreader/main/`。
- 不读取、打印、哈希或上传真实资料、个人配置和密钥内容。保护资料迁移只按总根规定核对元数据和 ACL。
- 正式构建使用 GitHub Actions。共享工具尚未登记本项目；新增本地构建前由共享维护者登记，不修改公共契约、不借用其他项目实例、不安装或回退全局 Flutter。
- 本地 Git 用共享 `_env/bin/Invoke-PortableGit.ps1` 和既定署名；目录整理只本地提交，未经明确指示不推送、不改写历史。
- `docs/history/initial-workspace` 是停用的早期元数据，不是当前构建入口。
- 2026-11-15 的 120 个旧物已在用户具体授权后清理，记录见 `docs/evidence/local-layout-2026-11-15.json`。此授权不扩展到其他文件；以后被安全拒绝的具体删除仍按父目录规则另行确认。
