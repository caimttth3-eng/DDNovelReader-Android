import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'i18n.dart';
import 'screens/shelf_screen.dart';
import 'services/font_manager.dart';
import 'services/app_appearance.dart';
import 'services/app_storage.dart';
import 'services/book_parser.dart';
import 'services/book_snapshot_cache.dart';
import 'services/reader_preparation.dart';
import 'services/tts_audio_handler.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  final storage = AppStorage();
  final startupSettings = AppAppearance.initialize(
    ReadingSettings.fromJson(await storage.loadSettings()),
    WidgetsBinding.instance.platformDispatcher.platformBrightness,
  );
  // Persist before the bookshelf can reopen its last book: ReaderScreen reads
  // this same setting and must not restore last session's opposite appearance.
  await storage.saveSettings(startupSettings.toJson());
  AppAppearance.nightMode.value = startupSettings.themeIndex == AppAppearance.nightThemeIndex;
  // 注册用户自选字体（FontLoader 仅进程内有效，每次启动需重新注册）
  await FontManager.registerAll();
  AppI18n.current = AppLang.detect(
    WidgetsBinding.instance.platformDispatcher.locales,
  );
  try {
    globalAudioHandler = await AudioService.init(
      builder: () => TtsAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.ddnovelreader.tts',
        androidNotificationChannelName: '多多朗读',
        androidNotificationIcon: 'drawable/ic_stat_reading',
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

class DuoduoLangduApp extends StatefulWidget {
  const DuoduoLangduApp({super.key});

  @override
  State<DuoduoLangduApp> createState() => _DuoduoLangduAppState();
}

class _DuoduoLangduAppState extends State<DuoduoLangduApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppAppearance.updateSystemBrightness(WidgetsBinding.instance.platformDispatcher.platformBrightness);
  }

  @override
  void didChangePlatformBrightness() {
    AppAppearance.updateSystemBrightness(WidgetsBinding.instance.platformDispatcher.platformBrightness);
  }

  @override
  void didHaveMemoryPressure() {
    BookParser.clearMemoryCache();
    ReaderPreparation.clearMemoryCache();
    BookSnapshotCache.shared.clearMemoryCache();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: AppAppearance.nightMode,
      builder: (context, night, child) => MaterialApp(
      title: '多多朗读',
      debugShowCheckedModeBanner: false,
      locale: AppI18n.current.locale,
      supportedLocales: AppLang.values.map((l) => l.locale).toList(),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AppAppearance.theme(night),
      home: const ShelfScreen(),
    ));
  }
}
