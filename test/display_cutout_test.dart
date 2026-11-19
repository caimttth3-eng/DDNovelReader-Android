import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/services/display_cutout.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(DisplayCutoutService.channel, null));

  test('native geometry remains in logical viewport coordinates', () async {
    messenger.setMockMethodCallHandler(DisplayCutoutService.channel, (call) async {
      expect(call.method, 'getDisplayCutout');
      return {'width': 400.0, 'height': 800.0,
        'cutouts': [{'left': 188.0, 'top': 8.0, 'right': 212.0, 'bottom': 32.0}],
        'safeInsets': {'left': 0, 'top': 40, 'right': 0, 'bottom': 0},
        'systemBarInsets': {'left': 0, 'top': 44, 'right': 0, 'bottom': 24},
        'topLeftRadius': 24, 'topRightRadius': 24, 'statusBarTop': 40, 'statusBarVisible': false};
    });
    final geometry = (await DisplayCutoutService.read())!;
    expect(geometry.viewport, const Size(400, 800));
    expect(geometry.cutouts.single, const Rect.fromLTRB(188, 8, 212, 32));
    expect(geometry.safeInsets.top, 40);
    expect(geometry.systemBarInsets, const EdgeInsets.only(top: 44, bottom: 24));
    expect(geometry.topLeftRadius, 24);
    expect(geometry.statusBarVisible, isFalse);
  });

  test('older hosts without normal bar geometry preserve an unknown nullable field', () async {
    messenger.setMockMethodCallHandler(DisplayCutoutService.channel, (_) async => {
      'width': 400.0, 'height': 800.0, 'safeInsets': {'left': 0, 'top': 40, 'right': 0, 'bottom': 0}});
    final geometry = (await DisplayCutoutService.read())!;
    expect(geometry.safeInsets.top, 40);
    expect(geometry.systemBarInsets, isNull);
  });

  test('unavailable platform geometry falls back without inventing cutouts', () async {
    messenger.setMockMethodCallHandler(DisplayCutoutService.channel, (_) async => throw MissingPluginException());
    expect(await DisplayCutoutService.read(), isNull);
    messenger.setMockMethodCallHandler(DisplayCutoutService.channel, (_) async => {'width': 0, 'height': 0});
    expect(await DisplayCutoutService.read(), isNull);
  });
}
