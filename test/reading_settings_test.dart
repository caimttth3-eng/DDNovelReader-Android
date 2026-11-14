import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/services/app_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:duoduo_langdu/services/speech_breaks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('legacy global pauses migrate to the system voice without changing online voices', () {
    final previous = const SpeechPauseSettings().withPause(SpeechPauseKind.comma, 450);
    final settings = ReadingSettings.fromJson({'speechPauses': previous.toJson()});
    expect(settings.perVoiceSpeechPauses, isEmpty);
    expect(settings.effectiveSpeechPauses, const SpeechPauseSettings());
    for (final voice in ['', ReadingSettings.defaultPauseVoice, 'zh-CN-YunxiNeural']) {
      expect(settings.speechPausesForVoice(voice), const SpeechPauseSettings());
      expect(settings.hasVoiceSpeechPauses(voice), isFalse);
    }
    expect(settings.speechPausesForVoice(ReadingSettings.systemPauseVoice), previous);
    settings.voice = ReadingSettings.systemPauseVoice;
    expect(settings.effectiveSpeechPauses, previous);
  });
  test('system policy persists and fallback uses it while old online overrides remain inactive', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = ReadingSettings()..voice = 'zh-CN-YunxiNeural';
    final online = const SpeechPauseSettings().withPause(SpeechPauseKind.comma, 550);
    final system = const SpeechPauseSettings().withPause(SpeechPauseKind.paragraph, 850);
    settings.setVoiceSpeechPauses('zh-CN-YunxiNeural', online);
    settings.setVoiceSpeechPauses(ReadingSettings.systemPauseVoice, system);
    settings.setVoiceSpeechPauses('', settings.speechPauses);
    await AppStorage().saveSettings(settings.toJson());
    final restored = ReadingSettings.fromJson(await AppStorage().loadSettings());
    expect(restored.effectiveSpeechPauses, const SpeechPauseSettings());
    expect(restored.perVoiceSpeechPauses['zh-CN-YunxiNeural'], online,
      reason: 'Historical online data may remain stored but cannot affect online playback');
    expect(restored.hasVoiceSpeechPauses(ReadingSettings.defaultPauseVoice), isFalse);
    restored.systemFallbackActive = true;
    expect(restored.speechPauseVoice, ReadingSettings.systemPauseVoice);
    expect(restored.effectiveSpeechPauses, system);
    expect(restored.voice, 'zh-CN-YunxiNeural', reason: 'Fallback must not overwrite the selected online voice');
    restored.systemFallbackActive = false;
    restored.voice = ReadingSettings.systemPauseVoice;
    expect(restored.effectiveSpeechPauses, system);
    restored.voice = '';
    expect(restored.effectiveSpeechPauses, const SpeechPauseSettings());
    expect(restored.hasVoiceSpeechPauses(''), isFalse);
  });
  test('explicit system pauses win over legacy global values and online playback always uses factory defaults', () {
    final settings = ReadingSettings();
    final system = const SpeechPauseSettings().withPause(SpeechPauseKind.dash, 700);
    final legacy = const SpeechPauseSettings().withPause(SpeechPauseKind.comma, 400);
    settings.speechPauses = legacy;
    settings.setVoiceSpeechPauses(ReadingSettings.systemPauseVoice, system);
    settings.setVoiceSpeechPauses(ReadingSettings.defaultPauseVoice, system);
    expect(settings.speechPausesForVoice(ReadingSettings.systemPauseVoice), system);
    expect(settings.speechPausesForVoice(ReadingSettings.defaultPauseVoice), const SpeechPauseSettings());
    final defaults = settings.effectiveSpeechPauses;
    expect(defaults.millisecondsFor(SpeechPauseKind.dash), 200);
    expect(defaults.millisecondsFor(SpeechPauseKind.ellipsis), 200);
    expect(defaults.millisecondsFor(SpeechPauseKind.paragraph), 300);
    settings.clearVoiceSpeechPauses(ReadingSettings.systemPauseVoice);
    expect(settings.hasVoiceSpeechPauses(ReadingSettings.systemPauseVoice), isFalse);
    expect(settings.speechPausesForVoice(ReadingSettings.systemPauseVoice), legacy);
    expect(settings.speechPausesForVoice(ReadingSettings.defaultPauseVoice), const SpeechPauseSettings());
  });
  test('malformed voice pause entries are ignored and valid stored values are normalized', () {
    final settings = ReadingSettings.fromJson({'perVoiceSpeechPauses': {
      'bad-null': null, 'bad-list': [], 'bad-string': '400',
      'bad-version': {'version': 2, 'comma': 300},
      'bad-fields': {'version': 1, 'comma': '300'},
      'bad-number': {'version': 1, 'comma': double.infinity},
      42: {'version': 1, 'comma': 300},
      'zh-CN-YunxiNeural': {'version': 1, 'comma': 327, 'dash': 9000},
    }});
    expect(settings.perVoiceSpeechPauses.keys, ['zh-CN-YunxiNeural']);
    final policy = settings.perVoiceSpeechPauses['zh-CN-YunxiNeural']!;
    expect(policy.millisecondsFor(SpeechPauseKind.comma), 350);
    expect(policy.millisecondsFor(SpeechPauseKind.dash), 3000);
    final copy = ReadingSettings.fromJson(settings.toJson());
    copy.clearVoiceSpeechPauses('zh-CN-YunxiNeural');
    expect(settings.perVoiceSpeechPauses.containsKey('zh-CN-YunxiNeural'), isTrue);
    expect(settings.hasVoiceSpeechPauses('zh-CN-YunxiNeural'), isFalse);
    expect(settings.speechPausesForVoice('zh-CN-YunxiNeural'), const SpeechPauseSettings());
  });
  test('system media spoken text defaults off and persists only explicit boolean choices', () async {
    SharedPreferences.setMockInitialValues({});
    expect(ReadingSettings().showSystemMediaText, isFalse);
    expect(ReadingSettings.fromJson(null).showSystemMediaText, isFalse);
    for (final invalid in <Object?>[null, '', 'true', 1, {}, []]) {
      expect(ReadingSettings.fromJson({'showSystemMediaText': invalid}).showSystemMediaText, isFalse);
    }
    for (final enabled in [true, false]) {
      final settings = ReadingSettings()..showSystemMediaText = enabled..voice = '__system_tts__'..fontSize = 36;
      await AppStorage().saveSettings(settings.toJson());
      final restored = ReadingSettings.fromJson(await AppStorage().loadSettings());
      expect(restored.showSystemMediaText, enabled);
      expect(restored.voice, '__system_tts__'); expect(restored.fontSize, 36);
    }
  });
  test('playback and reading preferences have independent defaults and normalized persistence', () {
    final s = ReadingSettings();
    expect(s.pageTurnAnimation, 'off'); expect(s.followSystemRotation, isFalse);
    expect(s.sentenceDragDelay, 0.2); expect(s.keepScreenMinutes, 0); expect(s.readingScreenSeconds, 0);
    s.pageTurnAnimation = 'slide'; s.followSystemRotation = true; s.sentenceDragDelay = 0.4;
    s.keepScreenMinutes = 90; s.readingScreenSeconds = 120; s.speechRate = 1.2;
    s.speechPauses = s.speechPauses.withPause(SpeechPauseKind.comma, 350);
    final restored = ReadingSettings.fromJson(s.toJson());
    expect(restored.pageTurnAnimation, 'slide'); expect(restored.followSystemRotation, isTrue);
    expect(restored.sentenceDragDelay, 0.4); expect(restored.keepScreenMinutes, 90); expect(restored.readingScreenSeconds, 120);
    expect(restored.speechRate, 1.2); expect(restored.speechPauses.millisecondsFor(SpeechPauseKind.comma), 350);
    final clamped = ReadingSettings.fromJson({'sentenceDragDelay': 9, 'pageTurnAnimation': 'unknown',
      'keepScreenMinutes': 999, 'readingScreenSeconds': 7, 'speechRate': 1.234});
    expect(clamped.sentenceDragDelay, 0.5); expect(clamped.pageTurnAnimation, 'off');
    expect(clamped.keepScreenMinutes, 120); expect(clamped.readingScreenSeconds, 0); expect(clamped.speechRate, 1.2);
  });
  test('removed short reading durations return to system while minute choices survive', () {
    for (final seconds in [5, 15, 30]) {
      expect(ReadingSettings.fromJson({'readingScreenSeconds': seconds}).readingScreenSeconds, 0);
    }
    for (final seconds in [0, 60, 120, 300, 600, 1800]) {
      expect(ReadingSettings.fromJson({'readingScreenSeconds': seconds}).readingScreenSeconds, seconds);
    }
  });
  test('level-one filtering defaults migrate old defaults while explicit disables survive', () {
    for (final json in <Map<String, dynamic>>[{}, {'informationFilter': false, 'informationFilterLevel': 'none'},
      {'informationFilter': false}, {'informationFilter': true, 'informationFilterLevel': 'none'}]) {
      final migrated = ReadingSettings.fromJson(json);
      expect(migrated.informationFilter, isTrue); expect(migrated.informationFilterLevel, 'links');
    }
    for (final level in ['links', 'ads', 'extra']) {
      final disabled = ReadingSettings.fromJson({'informationFilter': false, 'informationFilterLevel': level});
      expect(disabled.informationFilter, isFalse); expect(disabled.informationFilterLevel, level);
      expect(ReadingSettings.fromJson(disabled.toJson()).informationFilter, isFalse);
    }
    final migrated = ReadingSettings.fromJson({'informationFilter': false, 'informationFilterLevel': 'none'});
    migrated.informationFilter = false;
    expect(ReadingSettings.fromJson(migrated.toJson()).informationFilter, isFalse,
      reason: 'Migration must not repeatedly override a later explicit off choice');
  });
  test('reading defaults and selected modes survive restart', () {
    final settings = ReadingSettings();
    expect(settings.pageTurnMode, 'tap');
    expect(settings.retainPageLine, isFalse);
    expect(settings.mergeNonSentenceBreaks, isTrue);
    expect(settings.firstLineIndent, isTrue);
    expect(settings.autoExtractToc, isTrue);
    expect(settings.informationFilter, isTrue);
    expect(settings.informationFilterLevel, 'links');
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
  test('automatic TOC extraction defaults on and persists the user choice', () async {
    SharedPreferences.setMockInitialValues({});
    expect(ReadingSettings.fromJson(null).autoExtractToc, isTrue);
    expect(ReadingSettings.fromJson({'fontSize': 24}).autoExtractToc, isTrue);
    for (final invalid in <Object?>[null, '', 'false', 0, 1]) {
      expect(ReadingSettings.fromJson({'autoExtractToc': invalid}).autoExtractToc, isTrue);
    }
    for (final enabled in [false, true]) {
      final settings = ReadingSettings()..autoExtractToc = enabled..voice = 'saved-voice'..fontSize = 28;
      await AppStorage().saveSettings(settings.toJson());
      final restored = ReadingSettings.fromJson(await AppStorage().loadSettings());
      expect(restored.autoExtractToc, enabled);
      expect(restored.voice, 'saved-voice'); expect(restored.fontSize, 28);
    }
  });
  test('word highlighting defaults off and persists without changing speech preferences', () async {
    SharedPreferences.setMockInitialValues({});
    expect(ReadingSettings().wordHighlightEnabled, isFalse);
    expect(ReadingSettings.fromJson(null).wordHighlightEnabled, isFalse);
    expect(ReadingSettings.fromJson({'voice': 'saved-voice'}).wordHighlightEnabled, isFalse);
    for (final invalid in <Object?>[null, '', 'true', 0, 1]) {
      expect(ReadingSettings.fromJson({'wordHighlightEnabled': invalid}).wordHighlightEnabled, isFalse);
    }
    for (final enabled in [true, false]) {
      final settings = ReadingSettings()..wordHighlightEnabled = enabled
        ..voice = 'saved-voice'..speechRate = 1.5..systemFallbackActive = true;
      await AppStorage().saveSettings(settings.toJson());
      final restored = ReadingSettings.fromJson(await AppStorage().loadSettings());
      expect(restored.wordHighlightEnabled, enabled);
      expect(restored.voice, 'saved-voice'); expect(restored.speechRate, 1.5);
      expect(restored.systemFallbackActive, isTrue);
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
