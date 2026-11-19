# iOS 安装教程（自签）

多多朗读 iOS 版以 **未签名 IPA** 发布。苹果要求 App 必须签名才能安装，所以需要用电脑上的签名工具，用你自己的 Apple ID 签一次。

- 免费 Apple ID 即可，**不需要** 688 元/年的开发者账号
- 免费签名 **7 天有效**，到期重新签一次（覆盖安装，书架和进度保留）
- 只支持 **iOS / iPadOS 15.0 及以上**

---

## 一、先选工具

| 工具 | 电脑 | 费用 | 有效期 | 推荐场景 |
|---|---|---|---|---|
| **Sideloadly** | Windows / macOS | 免费 Apple ID | 7 天 | 第一次装、图省事 |
| **AltStore + AltServer** | Windows / macOS | 免费 Apple ID | 7 天自动续签 | 不想每 7 天手动重签 |
| **TrollStore** | 不需要电脑 | 免费 | 永久 | **仅 iOS ≤ 17.0**；18.x 不支持 |
| Apple Developer | Windows / macOS | 688 元/年 | 1 年 | 长期用、多设备、TestFlight |

> iPhone 16 Pro Max（iOS 18.7.7）用不了 TrollStore，选 **Sideloadly** 或 **AltStore**。

---

## 二、准备

1. **下载 IPA**：仓库 Releases → `DDNovelReader_v1.3.0_unsigned.ipa`
2. **电脑装 Apple 驱动**（二选一）：
   - 微软商店搜索安装 **iTunes**
   - 或安装 **Apple Devices**（微软商店）
3. **下载签名工具**：
   - Sideloadly：<https://sideloadly.io>
   - AltStore：<https://altstore.io>
4. **数据线**连接 iPhone，解锁后点「信任此电脑」

---

## 三、Sideloadly 安装（推荐）

1. 打开 Sideloadly
2. 把 `DDNovelReader_v1.3.0_unsigned.ipa` 拖进窗口（或点 IPA 图标选择文件）
3. `Apple ID` 填你的 Apple ID 邮箱
4. 点 **Start**
5. 弹出密码框：输入 Apple ID 密码
   - 开了双重认证：按提示在手机上批准，或在 Apple ID 官网生成 **App 专用密码** 填入
6. 等待进度条完成，手机桌面出现「多多朗读」

### iPhone 上还要做两步

1. **打开开发者模式**
   设置 → 隐私与安全性 → 开发者模式 → 打开 → 重启手机
   （重启后可能需要再确认一次）
2. **信任证书**
   设置 → 通用 → VPN 与设备管理 → 开发者 App → 选择你的 Apple ID → 信任

然后打开 App。

---

## 四、AltStore 自动续签（可选）

适合不想每 7 天手动重签的人：

1. 电脑安装 **AltServer**（随 AltStore 提供）
2. 电脑和 iPhone 连同一个 Wi-Fi
3. iPhone 装 AltStore（通过 AltServer 安装）
4. AltStore 里登录 Apple ID，导入本 IPA
5. 保持 AltServer 在电脑上运行，AltStore 会在后台自动续签（7 天一轮）

> 注意：AltServer 需要常驻，电脑关机/退出后无法自动续签。

---

## 五、TrollStore（仅旧系统）

- 支持范围：**iOS 14.0 – 17.0**（部分版本有限制）
- 优点：永久签名，不用电脑
- **iOS 18.7.7 不支持**，不要尝试
- 如果你的设备在支持范围内：安装 TrollStore → 用 TrollStore 打开 IPA → 安装

---

## 六、付费开发者 / TestFlight

- 有 Apple Developer 账号（688 元/年）时：
  - 证书有效期 1 年，可装多台设备
  - 也可用 TestFlight 邀请测试（90 天一轮）
- 本项目暂未上架 App Store

---

## 七、续签（免费账号 7 天）

签名到期后 App 图标还在，但点开会闪退/提示无法验证。处理：

1. 电脑打开 Sideloadly
2. 重新拖入同一个 IPA
3. 重复「三」的步骤
4. **直接覆盖安装，不要先卸载**——卸载会清空书架、进度、缓存

---

## 八、常见问题

**Q：IPA 双击打不开 / 提示损坏？**
正常。未签名 IPA 不能直接安装，必须用 Sideloadly/AltStore 签名。

**Q：安装时提示 "The application could not be installed"？**
- 检查数据线、信任此电脑
- 确认 Apple ID 密码/专用密码正确
- 先删掉旧的同名测试版（注意会丢数据），或换一个 Bundle ID（需要改工程，普通用户不建议）

**Q：桌面图标灰色 / 点击闪退？**
- 没信任证书：设置 → 通用 → VPN 与设备管理 → 信任
- 或已过 7 天：重新签一次

**Q：书架里的书打不开，提示解析失败？**
- 重新导入一次那本书（文件 → 选择 txt/epub）
- 最新版已修复「重签后书籍路径失效」问题，请使用 v1.3.0 最新 IPA

**Q：朗读提示语音播放失败？**
- 在线音源需联网；想完全离线：音源选择里选「系统语音」
- 若仍失败
- 最新版已修复 iOS 音频源格式问题；仍失败请把「文件」App → 我的 iPhone → 多多朗读 → `dd_log.txt` 内容反馈

**Q：可以离线朗读吗？**
可以。音源面板「本地语音（离线）」选择任意系统音色，使用 iOS 内置 AVSpeechSynthesizer，完全不需要网络。

**Q：怎么让离线音质更好？**
iPhone 设置 → 辅助功能 → 朗读内容 → 声音 → 中文 → 选择并下载「优化音质」音色（如语舒），回到 App 的音源面板即可选到该音色。

**Q：音量键不能逐句？**
iOS 系统不允许第三方 App 监听音量键，这是平台限制。可用锁屏/通知栏的上一句/下一句，或在播放面板拖动切句。

**Q：重签后数据还在吗？**
在。覆盖安装保留 App 数据；**卸载会清空**。

**Q：能用别人的 Apple ID 签吗？**
不建议。签名会绑定 Apple ID，且涉及账号安全；请用自己的账号。

---

## 九、安全提示

- 只从本项目 **Releases** 下载 IPA，不要用来路不明的安装包
- 不要把自己的 Apple ID 密码发给任何人
- 本项目不会收集你的 Apple ID 或签名信息
