import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import 'screens/shelf_screen.dart';
import 'services/tts_audio_handler.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    globalAudioHandler = await AudioService.init(
      builder: () => TtsAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.ddnovelreader.tts',
        androidNotificationChannelName: '多多朗读',
        // 关键：暂停时保持前台服务。
        // 默认 true 会在暂停时停止前台服务，Android 12+ 后台重启前台服务
        // 会被系统拦截(ForegroundServiceStartNotAllowedException)，
        // 导致通知栏"播放/继续"按钮点击无反应（能暂停不能继续的根因）。
        androidStopForegroundOnPause: false,
      ),
    );
  } catch (e) {
    print('AudioService init failed: $e');
  }
  runApp(const DuoduoLangduApp());
}

class DuoduoLangduApp extends StatelessWidget {
  const DuoduoLangduApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '多多朗读',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF8A5A2B)),
        scaffoldBackgroundColor: const Color(0xFFF5F0E8),
      ),
      home: const ShelfScreen(),
    );
  }
}
