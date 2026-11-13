# 固定 APK 签名

仓库只公开 `android/signing-certificate.sha256` 证书指纹，私钥及密码保存在仓库外的私有备份中；在线签名时由 GitHub Secret 提供。目前是否已配置 Secret，以仓库设置为准。Release 构建不再回退到临时调试密钥。旧版本若使用不同证书，需要先卸载；使用本固定证书的新版本可相互覆盖安装，勿重新生成密钥。

私有 `signing-secret.json` 格式：

```json
{"version":1,"storeType":"PKCS12","keystoreBase64":"<完整p12的单行Base64>","storePassword":"<密码>","keyAlias":"ddnovelreader","keyPassword":"<密码>"}
```

私钥、JSON、密码不能提交到 Git、放进构建产物或写入日志。妥善备份同一份密钥和密码；忽略规则只是防误提交，不能替代安全备份。

## GitHub 在线构建

在线构建仅生成 ARM64-v8a 安装包 `app-release.apk`。Flutter 使用 `--target-platform android-arm64`，Android 的 `ndk.abiFilters` 同时限制插件 JNI 库，构建会核验 ZIP 中的实际架构。不使用 ABI 分包版本码偏移；包名和固定签名保持不变，可覆盖使用相同证书的旧通用包。未签名构建增加 `-unsigned` 后缀。

在仓库 Settings → Secrets and variables → Actions 新建 **Repository secret** `DDNOVEL_SIGNING_JSON`，内容为完整私有 JSON。无需把密钥文件上传到仓库。

- Push / 手动构建存在 Secret：还原临时 PKCS12，使用 `keytool` 导出公有证书核对仓库指纹后签名，构建后使用 `apksigner verify` 再次检查 APK 的实际签名证书。密钥或指纹不一致会失败。
- 未设置 Secret 或 pull request：构建 `app-release-unsigned.apk`，产物状态文件明确标注 **UNSIGNED**，不能直接安装，须进行下述本地签名。PR 不接收签名 Secret。

临时签名配置由环境变量 `DDNOVEL_SIGNING_PROPERTIES` 显式传给 Gradle，Gradle 本身也校验签名证书。旧 `android/key.properties` 不再自动生效。工作流在结束时删除已还原的私有文件；日志不输出密码或私钥。

## 本地签名未签名产物

需要 Python 3.10+、JDK 17 的 `keytool/java` 与 Android SDK Build Tools 35+ 的 `zipalign/apksigner`。设置 `JAVA_HOME`、`ANDROID_HOME`，或使用脚本的 `--keytool`、`--zipalign`、`--apksigner` 指定工具路径。Windows 的 `apksigner.bat` 自动转用同目录 `lib/apksigner.jar`，也可直接传入该 JAR 路径。

在仓库根目录执行（输出路径必须尚不存在）：

```sh
python scripts/sign_apk.py --apk /path/app-release-unsigned.apk --secret-json /private/signing-secret.json --output /path/DDNovelReader-fixed.apk
```

脚本先验证密钥证书，再按 16 KiB 对齐、签名，并验证实际 APK 证书与对齐，全部成功后才发布输出文件及 `.apk.sha256`。输入 APK 保持不变。密码仅通过子进程环境变量传递，不放入命令行；临时密钥随临时目录清理。

```sh
python scripts/sign_apk.py --verify-only --apk /path/DDNovelReader-fixed.apk
python -m unittest discover -s scripts -p 'test_*.py' -v
```

只把已签名 APK 和公开校验文件交付用户；未签名 APK 名称和状态不得冒充可安装版本。若暂时无法配置 GitHub Secret，可持续使用同一私钥本地签名，以后添加 Secret 后在线构建会沿用相同证书。

参考：[Android APK 签名工具](https://developer.android.com/tools/apksigner)、[zipalign 对齐顺序与 16 KiB 支持](https://developer.android.com/tools/zipalign)。
