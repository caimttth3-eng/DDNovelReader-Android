import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/services/app_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('reading defaults and selected modes survive restart', () {
    final settings = ReadingSettings();
    expect(settings.pageTurnMode, 'tap');
    expect(settings.retainPageLine, isFalse);
    expect(settings.mergeNonSentenceBreaks, isTrue);
    expect(settings.firstLineIndent, isTrue);
    expect(settings.informationFilter, isFalse);
    expect(settings.informationFilterLevel, 'none');
    expect(settings.prefetchSentences, 8);
    expect(settings.systemFallbackActive, isFalse);
    expect(settings.themeMode, 'system');
    settings.pageTurnMode = 'scroll'; settings.fontSize = 64;
    settings.retainPageLine = true; settings.speechRate = 2.4;
    settings.mergeNonSentenceBreaks = false; settings.firstLineIndent = false;
    settings.informationFilter = true; settings.informationFilterLevel = 'ads';
    final restored = ReadingSettings.fromJson(settings.toJson());
    expect(restored.pageTurnMode, 'scroll'); expect(restored.fontSize, 64);
    expect(restored.retainPageLine, isTrue); expect(restored.speechRate, 2.4);
    expect(restored.mergeNonSentenceBreaks, isFalse); expect(restored.firstLineIndent, isFalse);
    expect(restored.informationFilter, isTrue); expect(restored.informationFilterLevel, 'ads');
    expect(ReadingSettings.fromJson({'fontSize': 200}).fontSize, 64);
  });
  test('prefetch counts migrate, clamp and persist including disabled mode', () async {
    SharedPreferences.setMockInitialValues({});
    expect(ReadingSettings.fromJson(null).prefetchSentences, 8);
    expect(ReadingSettings.fromJson({}).prefetchSentences, 8);
    expect(ReadingSettings.fromJson({'prefetchSentences': -1}).prefetchSentences, 0);
    expect(ReadingSettings.fromJson({'prefetchSentences': 900}).prefetchSentences, 100);
    for (final count in [0, 1, 8, 100]) {
      final settings = ReadingSettings()..prefetchSentences = count;
      await AppStorage().saveSettings(settings.toJson());
      final restored = ReadingSettings.fromJson(await AppStorage().loadSettings());
      expect(restored.prefetchSentences, count);
    }
  });
  test('sticky system fallback persists separately from the selected online voice', () async {
    SharedPreferences.setMockInitialValues({});
    expect(ReadingSettings.fromJson({}).systemFallbackActive, isFalse);
    final settings = ReadingSettings()..voice = 'zh-CN-XiaoxiaoNeural'..systemFallbackActive = true;
    await AppStorage().saveSettings(settings.toJson());
    final restored = ReadingSettings.fromJson(await AppStorage().loadSettings());
    expect(restored.systemFallbackActive, isTrue);
    expect(restored.voice, 'zh-CN-XiaoxiaoNeural');
  });
  test('theme mode defaults to system and persists without losing specific page colors', () async {
    SharedPreferences.setMockInitialValues({});
    expect(ReadingSettings.fromJson(null).themeMode, 'system');
    final old = ReadingSettings.fromJson({'themeIndex': 3, 'dayThemeIndex': 2});
    expect(old.themeMode, 'system');
    expect(old.themeIndex, 3); expect(old.dayThemeIndex, 2);
    for (final invalid in <Object?>[null, '', 'unknown', 1, true]) {
      expect(ReadingSettings.fromJson({'themeMode': invalid}).themeMode, 'system');
    }
    for (final mode in ['system', 'dark', 'light']) {
      final settings = ReadingSettings()..themeMode = mode..themeIndex = 3..dayThemeIndex = 2;
      await AppStorage().saveSettings(settings.toJson());
      final restored = ReadingSettings.fromJson(await AppStorage().loadSettings());
      expect(restored.themeMode, mode);
      expect(restored.themeIndex, 3); expect(restored.dayThemeIndex, 2);
    }
  });
  test('old full-brightness defaults migrate to system brightness', () {
    final settings = ReadingSettings.fromJson({'brightness': 1.0});
    expect(settings.automaticBrightness, isTrue);
    expect(ReadingSettings.fromJson(settings.toJson()).automaticBrightness, isTrue);
  });
  test('explicit new dimming settings survive restart', () {
    final settings = ReadingSettings.fromJson({
      'brightnessControlVersion': 2, 'automaticBrightness': false, 'brightness': 0.1,
    });
    final restored = ReadingSettings.fromJson(settings.toJson());
    expect(restored.automaticBrightness, isFalse);
    expect(restored.brightness, 0.1);
  });
}
