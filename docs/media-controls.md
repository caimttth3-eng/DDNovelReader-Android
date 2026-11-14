# 系统媒体卡片与安装包体积

## 通知与锁屏

使用 Android 标准 MediaSession/MediaStyle 卡片，上一句、暂停/继续、下一句、停止保持标准媒体动作语义。Android 13 起系统主要依据 PlaybackState 生成控制布局；OriginOS 等系统决定最终按钮尺寸、位置、颜色和文本可见行数。

应用侧按钮使用 Google Material Symbols Rounded 的统一 24dp 矢量资源，保留资源名称防止构建裁剪。许可证见 [Material Symbols Apache-2.0](third-party/MaterialSymbols-LICENSE.txt)。

播放设置的原文开关默认关闭，全局保存。开启后通过媒体元数据展示当前朗读句的显示原文，随句切换，保留书名和章节。重复词回调不重复发布同一句，不增加定时刷新；关闭和停止时清除正文，不展示上一句的残留文本。这是系统媒体卡片文字，不是悬浮歌词窗口。

通知与屏幕操作共享真实 TTS 状态。通知暂停可以取消尚未完成的加载，不等待加载回调；音量读取不阻塞暂停状态和后续继续命令。停止使旧请求失效，防止迟到回包恢复播放。

参考 [Android 媒体控制](https://developer.android.com/media/implement/surfaces/mobile)、[audio_service MediaControl](https://pub.dev/documentation/audio_service/latest/audio_service/MediaControl-class.html) 和 [MediaItem](https://pub.dev/documentation/audio_service/latest/audio_service/MediaItem-class.html)。

## 包体积

1.2.22 ARM64 安装包基准为 20,456,877 字节，其中原生库占 19,285,152 字节：Flutter 引擎 11,346,352 字节，Dart 编译应用 7,799,768 字节；其余主要为较小的插件库、DEX 与资源。

已启用单 ARM64、R8 代码压缩、资源裁剪及图标树裁剪。本次增加 `--split-debug-info`，将调试符号单独作为构建产物保存，同时使用 `--analyze-size` 和 `scripts/apk_size_report.py` 输出真实体积报告；调试符号和分析报告不装进 APK。安装包仍使用原生库直接加载方式。

GitHub 的 `DDNovelReader-build-analysis` 产物包含尺寸 JSON 与对应版本的独立调试符号，便于比较与后续崩溃定位。具体缩减量以实际签名成品为准。

参考 [Flutter 官方体积分析与精简](https://docs.flutter.dev/perf/app-size)。
