import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/services/app_storage.dart';

void main() {
  test('reading defaults and selected modes survive restart', () {
    final settings = ReadingSettings();
    expect(settings.pageTurnMode, 'tap');
    expect(settings.mergeNonSentenceBreaks, isTrue);
    expect(settings.firstLineIndent, isTrue);
    expect(settings.informationFilter, isFalse);
    expect(settings.informationFilterLevel, 'none');
    settings.pageTurnMode = 'scroll'; settings.fontSize = 64;
    settings.mergeNonSentenceBreaks = false; settings.firstLineIndent = false;
    settings.informationFilter = true; settings.informationFilterLevel = 'ads';
    final restored = ReadingSettings.fromJson(settings.toJson());
    expect(restored.pageTurnMode, 'scroll'); expect(restored.fontSize, 64);
    expect(restored.mergeNonSentenceBreaks, isFalse); expect(restored.firstLineIndent, isFalse);
    expect(restored.informationFilter, isTrue); expect(restored.informationFilterLevel, 'ads');
    expect(ReadingSettings.fromJson({'fontSize': 200}).fontSize, 64);
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
