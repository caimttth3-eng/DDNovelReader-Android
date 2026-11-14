# 系统媒体卡片与安装包体积

## 通知与锁屏

使用 Android 标准 MediaSession/MediaStyle 卡片，上一句、暂停/继续、下一句、停止保持标准媒体动作语义。Android 13 起系统主要依据 PlaybackState 生成控制布局；OriginOS 等系统决定最终按钮尺寸、位置、颜色和文本可见行数。

应用侧按钮使用 Google Material Symbols Rounded 的统一 24dp 矢量资源，保留资源名称防止构建裁剪。许可证见 [Material Symbols Apache-2.0](third-party/MaterialSymbols-LICENSE.txt)。

播放设置的原文开关默认关闭，全局保存。开启后通过媒体元数据展示当前朗读原文，短句整句显示，长句随实际进度选择短片段，保留书名和章节。重复范围回调不重复发布同一片段，不增加定时刷新；关闭和停止时清除正文，不展示上一句的残留文本。这是系统媒体卡片文字，不是悬浮歌词窗口。

通知与屏幕操作共享真实 TTS 状态。通知暂停可以取消尚未完成的加载，不等待加载回调；音量读取不阻塞暂停状态和后续继续命令。停止使旧请求失效，防止迟到回包恢复播放。

参考 [Android 媒体控制](https://developer.android.com/media/implement/surfaces/mobile)、[audio_service MediaControl](https://pub.dev/documentation/audio_service/latest/audio_service/MediaControl-class.html) 和 [MediaItem](https://pub.dev/documentation/audio_service/latest/audio_service/MediaItem-class.html)。

## 原文随朗读进度切片

系统媒体卡片的横向跑马灯由系统 TextView 和厂商界面控制，MediaSession / MediaItem 没有设置其滚动速度的公共字段；提高朗读倍速也不会相应提高系统文字滚速。[AOSP TextView 的 Marquee 实现](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/core/java/android/widget/TextView.java)使用内部速度和起始等待时间，不能将其当作应用可设置的歌词时轴。

开启通知原文后，长句采用短片段随实际朗读范围切换，短句仍显示整句；仅切通知显示文本，不重新切分合成请求，不改变停顿或语音缓存。片段以约 16 个汉字的显示宽度为预算，优先在标点或英文词间分开，保留闭引号、正文内空白和原始文字（通知显示时隐藏段首排版缩进，原文及语音偏移不变），按 grapheme 边界处理组合字符与 emoji。该预算不等于系统卡片的实际像素宽度；厂商布局、大字号或长词仍可能被截断或滚动。

选择片段只使用已有在线词时间戳或系统引擎的真实范围事件；仅片段变化时发布媒体元数据，无新增定时器或后台轮询，不要求开启屏幕逐词高亮。没有有效范围信息时保留完整原句，不按字数或语速猜进度。[Android onRangeStart](https://developer.android.com/reference/android/speech/tts/UtteranceProgressListener#onRangeStart(java.lang.String,int,int,int))明确该回调取决于引擎提供时间信息。

这一同步方式参考成熟播放器按实际播放位置选择歌词行的机制，例如 [InnerTune 的 Lyrics 实现](https://github.com/z-huang/InnerTune/blob/dev/app/src/main/java/com/zionhuang/music/ui/component/Lyrics.kt)；该资料说明应用内歌词的同步方式，不代表其能控制系统通知的跑马灯。

## 包体积

1.2.22 ARM64 安装包基准为 20,456,877 字节，其中原生库占 19,285,152 字节：Flutter 引擎 11,346,352 字节，Dart 编译应用 7,799,768 字节；其余主要为较小的插件库、DEX 与资源。

已启用单 ARM64、R8 代码压缩、资源裁剪及图标树裁剪。本次增加 `--split-debug-info`，将调试符号单独作为构建产物保存，并使用 `scripts/apk_size_report.py` 输出真实体积报告；调试符号和分析报告不装进 APK。当前 Flutter 不允许将 `--analyze-size` 与 `--split-debug-info` 同时使用，因此以签名 APK 的 ZIP 条目统计实际体积。安装包仍使用原生库直接加载方式。

GitHub 的 `DDNovelReader-build-analysis` 产物包含尺寸 JSON 与对应版本的独立调试符号，便于比较与后续崩溃定位。具体缩减量以实际签名成品为准。

参考 [Flutter 官方体积分析与精简](https://docs.flutter.dev/perf/app-size)。
