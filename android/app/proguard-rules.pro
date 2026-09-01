# audio_service：保留 MediaSession / 耳机媒体按钮相关原生类，防止 R8 裁剪
-keep class com.ryanheise.audioservice.** { *; }
-keep class com.ryanheise.audio_session.** { *; }
