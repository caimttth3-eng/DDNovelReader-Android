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
        androidNotificationOngoing: true,
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
