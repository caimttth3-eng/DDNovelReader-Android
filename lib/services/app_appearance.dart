import 'package:flutter/material.dart';
import 'app_storage.dart';

/// Shared by the reader, its routes and the bookshelf.
class AppAppearance {
  static final nightMode = ValueNotifier<bool>(false);
  static final themeMode = ValueNotifier<String>('system');
  static const readerThemeCount = 6;
  static const nightThemeIndex = 2;
  static Brightness _systemBrightness = Brightness.light;
  static Brightness get systemBrightness => _systemBrightness;

  /// Resolve the selected mode while preserving the daylight palette, including
  /// older settings that did not keep dayThemeIndex in sync. This helper is
  /// pure; live appearance changes never save a stale copy of reader settings.
  static ReadingSettings applySystemStartup(ReadingSettings saved, Brightness brightness) {
    bool isDay(int index) => index >= 0 && index < readerThemeCount && index != nightThemeIndex;
    final settings = ReadingSettings.fromJson(saved.toJson());
    final day = isDay(saved.themeIndex) ? saved.themeIndex : isDay(saved.dayThemeIndex) ? saved.dayThemeIndex : 0;
    settings.dayThemeIndex = day;
    final mode = _validMode(settings.themeMode);
    settings.themeMode = mode;
    settings.themeIndex = mode == 'dark' || (mode == 'system' && brightness == Brightness.dark) ? nightThemeIndex : day;
    return settings;
  }

  static String _validMode(String mode) => const ['system', 'dark', 'light'].contains(mode) ? mode : 'system';

  static ReadingSettings initialize(ReadingSettings saved, Brightness brightness) {
    _systemBrightness = brightness;
    final settings = applySystemStartup(saved, brightness);
    setThemeMode(settings.themeMode);
    return settings;
  }

  static void setThemeMode(String mode) {
    themeMode.value = _validMode(mode);
    _syncNight();
  }

  static void updateSystemBrightness(Brightness brightness) {
    _systemBrightness = brightness;
    _syncNight();
  }

  static void _syncNight() {
    nightMode.value = themeMode.value == 'dark' ||
      (themeMode.value == 'system' && _systemBrightness == Brightness.dark);
  }

  /// Call when a reader loads or changes mode, using that reader's current
  /// settings. The appearance source owns only mode and brightness, not font,
  /// voice, progress or other independently changing reader preferences.
  static ReadingSettings applyCurrentMode(ReadingSettings saved) {
    final settings = ReadingSettings.fromJson(saved.toJson())..themeMode = themeMode.value;
    return applySystemStartup(settings, _systemBrightness);
  }

  static ThemeData theme(bool dark) => ThemeData(
    useMaterial3: true,
    brightness: dark ? Brightness.dark : Brightness.light,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF6498B5),
      brightness: dark ? Brightness.dark : Brightness.light,
      surface: dark ? const Color(0xFF222222) : const Color(0xFFF2F2F2),
    ),
    scaffoldBackgroundColor: dark ? const Color(0xFF1A1A1A) : const Color(0xFFF2F2F2),
  );
}
