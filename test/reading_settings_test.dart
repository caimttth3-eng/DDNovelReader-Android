import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/services/app_storage.dart';

void main() {
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
