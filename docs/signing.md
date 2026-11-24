# 固定 APK 签名

仓库只公开 `android/signing-certificate.sha256` 证书指纹，私钥及密码保存在仓库外的受保护数据区。当前改用本地构建，不再启动 GitHub 在线构建/签名。用户于 2026-11-19 已持续授权本项目使用既有固定签名资料本地签名、验签及按 LocalApk 接收/收尾，以后无需再次询问；具体边界见 [项目约定](../AGENTS.md)。仅既有脚本在本地进程内消费凭据，不展示、记录或上传；不授权换钥、安装应用或远端发布。Release 构建不回退到临时调试密钥。旧版本若使用不同证书，需要先卸载；使用本固定证书的新版本可相互覆盖安装，勿重新生成密钥。

私有 `signing-secret.json` 格式：

```json
{"version":1,"storeType":"PKCS12","keystoreBase64":"<完整p12的单行Base64>","storePassword":"<密码>","keyAlias":"ddnovelreader","keyPassword":"<密码>"}
```

私钥、JSON、密码不能提交到 Git、放进构建产物或写入日志。妥善备份同一份密钥和密码；忽略规则只是防误提交，不能替代安全备份。

## 历史 GitHub 在线构建（已停用）

以下仅解释既有 Release 的签名来源，不是当前操作步骤；旧构建工作流现已移除自动和手动触发并固定跳过 job。当前本地入口及验证边界见 [本地布局](local-layout.md#本地构建与验证入口2026-11-19)。

在线构建仅生成 ARM64-v8a 安装包 `app-release.apk`。Flutter 使用 `--target-platform android-arm64`，Android 的 `ndk.abiFilters` 同时限制插件 JNI 库，构建会核验 ZIP 中的实际架构。不使用 ABI 分包版本码偏移；包名和固定签名保持不变，可覆盖使用相同证书的旧通用包。未签名构建增加 `-unsigned` 后缀。

历史工作流通过 **Repository secret** `DDNOVEL_SIGNING_JSON` 接收完整私有 JSON，没有把密钥文件提交到仓库；本地构建不读取或迁移这个 Secret。

- Push / 手动构建存在 Secret：还原临时 PKCS12，使用 `keytool` 导出公有证书核对仓库指纹后签名，构建后使用 `apksigner verify` 再次检查 APK 的实际签名证书。密钥或指纹不一致会失败。
- 未设置 Secret 或 pull request：构建 `app-release-unsigned.apk`，产物状态文件明确标注 **UNSIGNED**，不能直接安装，须进行下述本地签名。PR 不接收签名 Secret。

临时签名配置由环境变量 `DDNOVEL_SIGNING_PROPERTIES` 显式传给 Gradle，Gradle 本身也校验签名证书。旧 `android/key.properties` 不再自动生效。工作流在结束时删除已还原的私有文件；日志不输出密码或私钥。

## 本地签名未签名产物

本工作区改用本地构建；已签名完整包继续通过 [LocalApk 接收与选择入口](local-layout.md#本地构建收尾与-apk-选择) 归位。以下保留跨平台签名脚本的参数示例，`/path`、`/private` 是占位路径，不是本地已存在的入口；实际流程仅在上述持续授权范围内消费既有签名资料。本工作区须使用共享固定工具和本实例临时目录，不直接调用未登记的全局 Python/JDK/SDK。

已恢复本地离线依赖后，使用项目入口完成实际构建、固定签名/验签与接收：

```powershell
.\scripts\LocalBuild.ps1 -Action DeliverApk
.\scripts\LocalApk.ps1 -Action Path
```

`DeliverApk` 在同一 Prepare lease 下保持共享 SDK 的只读缓存句柄，核对 pubspec 版本、ARM64、未签名输入字节，随后仅由既有签名脚本读取固定资料，并调用 LocalApk 验签接收；最后等待所有自有 Android 消费者自然结束并执行完整 SDK 树后验，再释放句柄。缺失凭据、已有输出、签名或审计失败均停止，不生成新密钥、安装应用或远端发布。仅需未签名 staging 时仍使用 `BuildApk`；仅对已经匹配当前版本的 staging 签名可使用 `SignApk`。

需要 Python 3.10+、JDK 17 的 `keytool/java` 与 Android SDK Build Tools 35+ 的 `zipalign/apksigner`。设置 `JAVA_HOME`、`ANDROID_HOME`，或使用脚本的 `--keytool`、`--zipalign`、`--apksigner` 指定工具路径。Windows 的 `apksigner.bat` 自动转用同目录 `lib/apksigner.jar`，也可直接传入该 JAR 路径。

在仓库根目录执行（输出路径必须尚不存在）：

```sh
python -B scripts/sign_apk.py --apk /path/app-release-unsigned.apk --secret-json /private/signing-secret.json --output /path/DDNovelReader-fixed.apk
```

脚本先验证密钥证书，再按 16 KiB 对齐、签名，并验证实际 APK 证书与对齐，全部成功后才发布输出文件及 `.apk.sha256`。输入 APK 保持不变。密码仅通过子进程环境变量传递，不放入命令行；临时密钥随临时目录清理。

```sh
python -B scripts/sign_apk.py --verify-only --apk /path/DDNovelReader-fixed.apk
python -B -m unittest discover -s scripts -p 'test_*.py' -v
```

只把已签名 APK 和公开校验文件交付用户；未签名 APK 名称和状态不得冒充可安装版本。既有签名资料缺失、验签失败或工具拒绝时保留当前可用包，明确报告阻塞，不生成替代密钥或恢复在线签名兜底。

参考：[Android APK 签名工具](https://developer.android.com/tools/apksigner)、[zipalign 对齐顺序与 16 KiB 支持](https://developer.android.com/tools/zipalign)。
