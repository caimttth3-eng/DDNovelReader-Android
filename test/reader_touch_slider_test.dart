import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/widgets/reader_brightness_control.dart';
import 'package:duoduo_langdu/widgets/reader_touch_slider.dart';

const _brightness = ValueKey('test-brightness-slider');
const _font = ValueKey('test-font-slider');

void main() {
  testWidgets('brightness and font tracks remain aligned and expose a full 48px native hit target', (tester) async {
    await _mount(tester, Column(mainAxisSize: MainAxisSize.min, children: [
      ReaderBrightnessControl(value: .6, automatic: false, sliderKey: _brightness,
        onChanged: (_) {}, onAutomatic: () {}),
      Row(children: [Expanded(child: ReaderTouchSlider(sliderKey: _font, value: 26,
        min: 14, max: 64, divisions: 50, onChanged: (_) {})), const SizedBox(width: 44, height: 44)]),
    ]));
    final brightness = tester.getRect(find.byKey(_brightness)), font = tester.getRect(find.byKey(_font));
    expect(brightness.height, 48); expect(font.height, 48);
    expect(font.width, closeTo(brightness.width, .01)); expect(font.left, closeTo(brightness.left, .01));
    final nativeTheme = tester.widget<SliderTheme>(find.ancestor(of: find.byKey(_brightness), matching: find.byType(SliderTheme)).first).data;
    expect(nativeTheme.trackHeight, 3);
    expect((nativeTheme.thumbShape! as RoundSliderThumbShape).enabledThumbRadius, 8);
    expect((nativeTheme.overlayShape! as RoundSliderOverlayShape).overlayRadius, 22);
  });

  for (final nearTop in <bool>[true, false]) {
    testWidgets('brightness responds near the ${nearTop ? 'top' : 'bottom'} edge and preserves extra dimming range', (tester) async {
      var value = .7;
      await _mount(tester, StatefulBuilder(builder: (context, update) =>
        ReaderBrightnessControl(value: value, automatic: false, sliderKey: _brightness,
          onChanged: (next) => update(() => value = next), onAutomatic: () {})));
      final rect = tester.getRect(find.byKey(_brightness));
      final y = nearTop ? rect.top + 2 : rect.bottom - 2;
      await tester.tapAt(Offset(rect.left + 12 + (rect.width - 24) * .125, y));
      await tester.pumpAndSettle();
      expect(value, closeTo(.125, .015), reason: 'A tap well outside the old 24px hit area must set the actual track value');
      expect(value, lessThan(ReaderBrightnessControl.split), reason: 'The lower quarter must remain available for extra dimming');
      expect(find.byKey(const ValueKey('brightness-split')), findsOneWidget);
      await tester.dragFrom(Offset(rect.left + 16, y), Offset(rect.width - 30, 0));
      await tester.pumpAndSettle();
      expect(value, greaterThan(.95), reason: 'The same expanded hit target must accept a complete horizontal drag');
    });
  }

  testWidgets('font slider accepts edge taps and drags with the original discrete range', (tester) async {
    var value = 26.0;
    double? committed;
    var started = 0;
    await _mount(tester, StatefulBuilder(builder: (context, update) =>
      ReaderTouchSlider(sliderKey: _font, value: value, min: 14, max: 64, divisions: 50,
        onChanged: (next) => update(() => value = next),
        onChangeStart: (_) => started++, onChangeEnd: (next) => committed = next)));
    final rect = tester.getRect(find.byKey(_font));
    await tester.tapAt(Offset(rect.left + 12 + (rect.width - 24) * .7, rect.top + 2));
    await tester.pumpAndSettle();
    expect(value, closeTo(49, 1)); expect(value, value.roundToDouble());
    expect(committed, value, reason: 'A track tap must dispatch the final commit callback');
    await tester.dragFrom(Offset(rect.left + 16, rect.bottom - 2), Offset(rect.width, 0));
    await tester.pumpAndSettle(); expect(value, 64); expect(committed, 64);
    await tester.tapAt(Offset(rect.left + 12, rect.top + 2));
    await tester.pumpAndSettle(); expect(value, 14); expect(committed, 14);
    expect(started, greaterThanOrEqualTo(3));
  });

  testWidgets('A rebuild replaces a manually dimmed thumb with the supplied current system position', (tester) async {
    var value = .08, automatic = false;
    var requests = 0;
    await _mount(tester, StatefulBuilder(builder: (context, update) => ReaderBrightnessControl(
      value: value, automatic: automatic, sliderKey: _brightness,
      onChanged: (next) => update(() { value = next; automatic = false; }),
      onAutomatic: () { requests++; update(() { automatic = true; value = ReaderBrightnessControl.fromSystemBrightness(.72); }); })));
    expect(tester.widget<Slider>(find.byKey(_brightness)).value, .08);
    await tester.tap(find.byKey(const ValueKey('brightness-auto'))); await tester.pumpAndSettle();
    expect(requests, 1); expect(automatic, isTrue);
    expect(tester.widget<Slider>(find.byKey(_brightness)).value, closeTo(.79, 1e-6));
    expect(value, greaterThanOrEqualTo(ReaderBrightnessControl.split));
  });

  testWidgets('split marker follows the mirrored native track in RTL', (tester) async {
    await _mount(tester, Directionality(textDirection: TextDirection.rtl, child: ReaderBrightnessControl(
      value: .5, automatic: false, sliderKey: _brightness, onChanged: (_) {}, onAutomatic: () {})));
    final slider = tester.getRect(find.byKey(_brightness));
    expect(tester.getCenter(find.byKey(const ValueKey('brightness-split'))).dx,
      closeTo(slider.left + 12 + (slider.width - 24) * .75, .01));
  });

  test('system brightness maps to hardware range without entering extra dimming', () {
    expect(ReaderBrightnessControl.fromSystemBrightness(0), .25);
    expect(ReaderBrightnessControl.fromSystemBrightness(.5), .625);
    expect(ReaderBrightnessControl.fromSystemBrightness(1), 1);
    expect(ReaderBrightnessControl.fromSystemBrightness(-.3), .25);
    expect(ReaderBrightnessControl.fromSystemBrightness(2), 1);
  });
}

Future<void> _mount(WidgetTester tester, Widget child) => tester.pumpWidget(MaterialApp(
  home: Scaffold(body: Center(child: SizedBox(width: 296, child: SliderTheme(
    data: const SliderThemeData(trackHeight: 1,
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 4),
      overlayShape: RoundSliderOverlayShape(overlayRadius: 12)), child: child))))));
