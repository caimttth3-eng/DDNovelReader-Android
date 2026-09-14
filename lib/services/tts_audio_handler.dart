import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 打原生日志（release 下 debugPrint 不输出，走 MethodChannel 到 logcat）
void _log(String msg) {
  try {
    const MethodChannel('com.ddnovelreader/debug_log')
        .invokeMethod('log', msg);
  } catch (_) {}
}

/// 把 audio_service 的 MediaSession 回调（耳机播放键、系统媒体按钮）
/// 转发给阅读页的播放/暂停/停止逻辑。
///
/// 实际音频播放由 TtsReader（Edge TTS 逐句合成）负责，这里只做控制转发
/// 并维护 MediaSession 状态，让有线/无线耳机的播放键能控制朗读。
///
/// 两类入口：
/// - [play]/[pause]/[stop]：耳机/系统媒体按钮触发 → 调用 onXxxRequested 回调
/// - [notifyPlaying]/[notifyPaused]/[notifyStopped]：屏幕操作同步状态，不触发回调
class TtsAudioHandler extends BaseAudioHandler {
  /// 阅读页注入：请求开始/恢复播放
  VoidCallback? onPlayRequested;

  /// 阅读页注入：请求暂停
  VoidCallback? onPauseRequested;

  /// 阅读页注入：请求停止并退出全屏
  VoidCallback? onStopRequested;

  /// 阅读页注入：自定义"继续播放"按钮（绕开系统 play 路由问题）
  VoidCallback? onCustomResumeRequested;

  TtsAudioHandler() {
    mediaItem.add(const MediaItem(
      id: 'duoduo_langdu',
      title: '多多朗读',
      album: '本地书籍朗读',
    ));
    playbackState.add(PlaybackState(
      playing: false,
      controls: [
        MediaControl.custom(
            androidIcon: 'mipmap/ic_launcher',
            label: '继续播放',
            name: '继续播放'),
        MediaControl.stop,
      ],
      systemActions: const {MediaAction.play, MediaAction.stop},
      processingState: AudioProcessingState.ready,
    ));
  }

  // ---- 耳机/系统媒体按钮触发（会调用回调） ----

  @override
  Future<void> play() async {
    print('AUDIO_H play called');
    _log('HANDLER play called');
    onPlayRequested?.call();
    _setPlaying(true);
  }

  @override
  Future<void> pause() async {
    print('AUDIO_H pause called');
    _log('HANDLER pause called');
    onPauseRequested?.call();
    _setPlaying(false);
  }

  @override
  Future<void> stop() async {
    _log('HANDLER stop called');
    onStopRequested?.call();
    _setStopped();
  }

  @override
  Future<dynamic> customAction(String name,
      [Map<String, dynamic>? extras]) async {
    _log('HANDLER customAction: $name');
    if (name == '继续播放') {
      onCustomResumeRequested?.call();
    }
  }

  // ---- 屏幕操作同步状态（不触发回调，避免递归） ----

  void notifyPlaying() => _setPlaying(true);
  void notifyPaused() => _setPlaying(false);
  void notifyStopped() => _setStopped();

  // ---- 内部状态更新 ----

  void _setPlaying(bool playing) {
    playbackState.add(playbackState.value.copyWith(
      playing: playing,
      controls: playing
          ? const [MediaControl.pause, MediaControl.stop]
          : [
              MediaControl.custom(
                  androidIcon: 'mipmap/ic_launcher',
                  label: '继续播放',
                  name: '继续播放'),
              MediaControl.stop,
            ],
      systemActions: playing
          ? const {MediaAction.pause, MediaAction.stop}
          : const {MediaAction.play, MediaAction.stop},
      processingState: AudioProcessingState.ready,
    ));
  }

  void _setStopped() {
    playbackState.add(playbackState.value.copyWith(
      playing: false,
      controls: const [MediaControl.play],
      systemActions: const {MediaAction.play},
      processingState: AudioProcessingState.idle,
    ));
  }
}

/// 全局音频处理器实例（在 main() 中初始化，阅读页绑定回调）。
TtsAudioHandler? globalAudioHandler;
