import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:duoduo_langdu/services/app_appearance.dart';
import 'package:duoduo_langdu/services/app_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => AppAppearance.initialize(ReadingSettings(), Brightness.light));
  tearDown(() => AppAppearance.initialize(ReadingSettings(), Brightness.light));
  test('a light launch restores the saved daylight palette after a night session', () {
    final saved = ReadingSettings()..themeIndex = 2..dayThemeIndex = 3;
    final startup = AppAppearance.applySystemStartup(saved, Brightness.light);
    expect(startup.themeIndex, 3);
    expect(startup.dayThemeIndex, 3);
    expect(saved.themeIndex, 2, reason: 'Startup derives a clone rather than mutating the caller');
  });

  test('a dark launch saves the current daylight palette before selecting black', () {
    final saved = ReadingSettings()..themeIndex = 1..dayThemeIndex = 0;
    final startup = AppAppearance.applySystemStartup(saved, Brightness.dark);
    expect(startup.themeIndex, AppAppearance.nightThemeIndex);
    expect(startup.dayThemeIndex, 1, reason: 'Older daylight settings take precedence over a stale remembered default');
    expect(AppAppearance.applySystemStartup(startup, Brightness.light).themeIndex, 1);
  });

  test('all existing daylight palettes survive both launch modes', () {
    for (final day in [0, 1, 3, 4, 5]) {
      final saved = ReadingSettings()..themeIndex = day..dayThemeIndex = 0;
      final dark = AppAppearance.applySystemStartup(saved, Brightness.dark);
      expect(dark.dayThemeIndex, day);
      expect(AppAppearance.applySystemStartup(dark, Brightness.light).themeIndex, day);
    }
  });

  test('invalid daylight indices cannot select the night palette or leave the theme table', () {
    for (final index in [-1, 2, 6, 999]) {
      final saved = ReadingSettings()..themeIndex = 2..dayThemeIndex = index;
      final light = AppAppearance.applySystemStartup(saved, Brightness.light);
      expect(light.themeIndex, 0);
      expect(light.dayThemeIndex, 0);
      expect(AppAppearance.applySystemStartup(saved, Brightness.dark).themeIndex, 2);
    }
    final invalidCurrent = ReadingSettings()..themeIndex = 999..dayThemeIndex = 5;
    expect(AppAppearance.applySystemStartup(invalidCurrent, Brightness.light).themeIndex, 5);
  });

  test('startup cloning retains all unrelated reading and speech preferences', () {
    final saved = ReadingSettings()
      ..themeIndex = 5..dayThemeIndex = 0..fontSize = 48..fontFamily = 'custom'
      ..brightness = 0.6..automaticBrightness = false..lineHeight = 1.8
      ..pageTurnMode = 'swipe'..retainPageLine = true..autoPageSeconds = 30
      ..mergeNonSentenceBreaks = false..firstLineIndent = false
      ..informationFilter = true..informationFilterLevel = 'ads'
      ..voice = 'zh-CN-XiaoxiaoNeural'..speechRate = 1.5
      ..prefetchSentences = 42..systemFallbackActive = true;
    final expected = saved.toJson()..['themeIndex'] = 2..['dayThemeIndex'] = 5;
    expect(AppAppearance.applySystemStartup(saved, Brightness.dark).toJson(), expected);
  });

  test('persisted startup appearance is the same setting read when reopening a book', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = AppStorage();
    await storage.saveSettings((ReadingSettings()..themeIndex = 2..dayThemeIndex = 4).toJson());
    final startup = AppAppearance.applySystemStartup(
      ReadingSettings.fromJson(await storage.loadSettings()), Brightness.light);
    await storage.saveSettings(startup.toJson());
    // ReaderScreen._loadSettings uses this same storage and parser after runApp.
    final readerSettings = ReadingSettings.fromJson(await AppStorage().loadSettings());
    expect(readerSettings.themeIndex, startup.themeIndex);
    expect(readerSettings.themeIndex, 4);
    expect(readerSettings.dayThemeIndex, 4);
    expect(AppAppearance.theme(readerSettings.themeIndex == AppAppearance.nightThemeIndex).brightness, Brightness.light);
  });

  test('explicit dark and light modes override opposite system brightness on launch', () {
    final dark = ReadingSettings()..themeMode = 'dark'..themeIndex = 5;
    final light = ReadingSettings()..themeMode = 'light'..themeIndex = 2..dayThemeIndex = 4;
    expect(AppAppearance.initialize(dark, Brightness.light).themeIndex, 2);
    expect(AppAppearance.themeMode.value, 'dark');
    expect(AppAppearance.nightMode.value, isTrue);
    expect(AppAppearance.initialize(light, Brightness.dark).themeIndex, 4);
    expect(AppAppearance.themeMode.value, 'light');
    expect(AppAppearance.nightMode.value, isFalse);
  });

  test('system mode follows live changes while manual overrides remain explicit', () {
    AppAppearance.initialize(ReadingSettings(), Brightness.light);
    AppAppearance.updateSystemBrightness(Brightness.dark);
    expect(AppAppearance.nightMode.value, isTrue);
    AppAppearance.setThemeMode('light');
    expect(AppAppearance.nightMode.value, isFalse);
    AppAppearance.updateSystemBrightness(Brightness.light);
    AppAppearance.updateSystemBrightness(Brightness.dark);
    expect(AppAppearance.nightMode.value, isFalse);
    AppAppearance.setThemeMode('dark');
    AppAppearance.updateSystemBrightness(Brightness.light);
    expect(AppAppearance.nightMode.value, isTrue);
    AppAppearance.setThemeMode('system');
    expect(AppAppearance.nightMode.value, isFalse);
  });

  test('live system changes apply to fresh reader settings without overwriting their preferences', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = AppStorage();
    final startup = AppAppearance.initialize(ReadingSettings()..themeIndex = 3, Brightness.light);
    await storage.saveSettings(startup.toJson());
    // Simulate font/voice changes saved after the root appearance was created.
    final latest = ReadingSettings.fromJson(await storage.loadSettings())
      ..fontSize = 64..prefetchSentences = 27..voice = '__system_tts__';
    await storage.saveSettings(latest.toJson());
    AppAppearance.updateSystemBrightness(Brightness.dark);
    final reloaded = ReadingSettings.fromJson(await storage.loadSettings());
    expect(reloaded.toJson(), latest.toJson(), reason: 'The root observer never writes its old full settings');
    final reader = AppAppearance.applyCurrentMode(reloaded);
    expect(reader.themeIndex, 2);
    expect(reader.dayThemeIndex, 3);
    expect(reader.fontSize, 64);
    expect(reader.prefetchSentences, 27);
    expect(reader.voice, '__system_tts__');
    expect(reader.themeMode, 'system');
  });
}
