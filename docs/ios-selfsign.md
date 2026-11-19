# iOS 自签安装（无 Mac / 免费 Apple ID）

> 此文为上游流程参考，不是本工作区的执行入口。本工作区在线 workflow 已停用，当前没有本地 iOS 构建/签名验收；不要依下文启动 Actions。

当前只支持 **自签安装**（Sideloadly / AltStore），不走 App Store。
适用设备：iPhone 16 Pro Max，iOS 18.7.7（TrollStore 不支持 18.x，只能 7 天重签）。

## 1. 取未签名 IPA

1. 打开仓库 Actions → `iOS unsigned IPA` → 最新一次运行
2. 下载 artifact `DuoDuoLangDu-unsigned-ipa`（zip），解压得到 `DuoDuoLangDu-unsigned.ipa`
3. 如果还没有构建记录：Actions → 选该工作流 → Run workflow → 分支 `feat/ios` 或 `master`

## 2. Windows 电脑准备

- 安装 **iTunes**（微软商店版即可，提供 Apple 驱动）或 **Apple Devices**
- 安装 **Sideloadly**：<https://sideloadly.io>
- iPhone 用数据线连接电脑，解锁并点「信任此电脑」

## 3. 签名并安装

1. 打开 Sideloadly，把 `.ipa` 拖进去
2. Apple ID 填你的 Apple ID（免费账号即可，不需要开发者账号）
3. 点 Start，输入 Apple ID 密码（如开了双重认证，用 App 专用密码或按提示授权）
4. 等待安装完成

## 4. iPhone 上首次运行

1. 设置 → 隐私与安全性 → **开发者模式** → 打开 → 重启手机
2. 设置 → 通用 → VPN 与设备管理 → 信任你的 Apple ID 证书
3. 桌面出现「多多朗读」即可打开

## 5. 续签

- 免费 Apple ID 签名 **7 天过期**，过期后 App 打不开
- 到期前用同样步骤重新 Sideloadly 安装一次即可（数据保留）
- 想免续签只能买 Apple Developer（$99/年，1 年有效）或上 TestFlight

## 已知限制（iOS 首版）

- 音量键逐句跳转：iOS 不允许监听音量键，已禁用
- 系统 TTS 兜底：未接 AVSpeechSynthesizer（在线 Edge 朗读正常）
- 亮度调节：iOS 暂未接 UIScreen（用系统亮度）
- 自签 7 天过期；无后台常驻限制以外的额外权限

## 构建排错

- Actions 失败先看 `Build iOS (no codesign)` 步骤日志
- 常见：CocoaPods 依赖下载慢（重跑）；Flutter 版本与 Xcode 不匹配（改 workflow 里的 `flutter-version`）
