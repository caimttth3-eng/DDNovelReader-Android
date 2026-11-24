// 来源：NayGnehz/DDNovelReader-Android 的 PR #2（commit 27b6a1e，部分代码，已修改适配本项目的缓存/同步架构）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  static SystemUiOverlayStyle systemUiStyle(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
      statusBarBrightness: dark ? Brightness.dark : Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: dark ? Brightness.light : Brightness.dark,
    );
  }

  static ThemeData menuTheme(ThemeData base, {Color? foreground}) {
    final dark = base.brightness == Brightness.dark;
    final surface = dark ? const Color(0xFF1A1A1A) : Colors.white;
    final text = dark ? foreground ?? base.colorScheme.onSurface : const Color(0xFF222222);
    final secondary = dark ? const Color(0xFFB8B8B8) : const Color(0xFF666666);
    final titleStyle = base.textTheme.titleLarge!.copyWith(inherit: false, textBaseline: TextBaseline.alphabetic,
      fontSize: 20, fontWeight: FontWeight.w600, color: text, height: 1.3);
    final itemStyle = base.textTheme.bodyLarge!.copyWith(inherit: false, textBaseline: TextBaseline.alphabetic,
      fontSize: 16, fontWeight: FontWeight.w400, color: text, height: 1.4);
    final supportStyle = base.textTheme.bodyMedium!.copyWith(inherit: false, textBaseline: TextBaseline.alphabetic,
      fontSize: 14, fontWeight: FontWeight.w400, color: secondary, height: 1.4);
    final sectionStyle = itemStyle.copyWith(fontWeight: FontWeight.w600, color: base.colorScheme.primary);
    return base.copyWith(
      canvasColor: surface,
      colorScheme: base.colorScheme.copyWith(surface: surface,
        onSurface: text, onSurfaceVariant: secondary),
      textTheme: base.textTheme.copyWith(titleLarge: titleStyle, headlineSmall: titleStyle,
        titleMedium: itemStyle, titleSmall: sectionStyle, bodyLarge: itemStyle,
        bodyMedium: supportStyle, bodySmall: supportStyle),
      listTileTheme: base.listTileTheme.copyWith(titleTextStyle: itemStyle, subtitleTextStyle: supportStyle),
      dividerTheme: base.dividerTheme.copyWith(color: text.withValues(alpha: .12), thickness: 1, space: 1),
      bottomSheetTheme: base.bottomSheetTheme.copyWith(backgroundColor: surface,
        modalBackgroundColor: surface, surfaceTintColor: Colors.transparent),
      dialogTheme: base.dialogTheme.copyWith(backgroundColor: surface, surfaceTintColor: Colors.transparent,
        titleTextStyle: titleStyle, contentTextStyle: itemStyle),
      popupMenuTheme: base.popupMenuTheme.copyWith(color: surface, surfaceTintColor: Colors.transparent),
      menuTheme: MenuThemeData(style: (base.menuTheme.style ?? const MenuStyle()).copyWith(
        backgroundColor: WidgetStatePropertyAll(surface), surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent))),
    );
  }

  static ThemeData theme(bool dark) => menuTheme(ThemeData(
    useMaterial3: true,
    brightness: dark ? Brightness.dark : Brightness.light,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF6498B5),
      brightness: dark ? Brightness.dark : Brightness.light,
      surface: dark ? const Color(0xFF222222) : const Color(0xFFF2F2F2),
    ),
    scaffoldBackgroundColor: dark ? const Color(0xFF1A1A1A) : const Color(0xFFF2F2F2),
    appBarTheme: AppBarTheme(systemOverlayStyle: systemUiStyle(dark ? Brightness.dark : Brightness.light)),
  ));
}
