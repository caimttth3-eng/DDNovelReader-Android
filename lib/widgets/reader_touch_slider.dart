import 'package:flutter/material.dart';

/// A quick-control slider whose entire 48px height accepts taps and drags.
/// Keep the actual Slider large, rather than padding a smaller hit-test box.
class ReaderTouchSlider extends StatelessWidget {
  static const height = 48.0;
  static const horizontalPadding = 12.0;
  final double value, min, max;
  final int? divisions;
  final ValueChanged<double>? onChanged, onChangeStart, onChangeEnd;
  final Key? sliderKey;

  const ReaderTouchSlider({super.key, required this.value, required this.onChanged,
    this.min = 0, this.max = 1, this.divisions, this.onChangeStart, this.onChangeEnd, this.sliderKey});

  @override
  Widget build(BuildContext context) => SizedBox(height: height,
    child: SliderTheme(data: SliderTheme.of(context).copyWith(
      trackHeight: 3,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 22),
    ), child: Slider(key: sliderKey, value: value.clamp(min, max).toDouble(),
      min: min, max: max, divisions: divisions,
      allowedInteraction: SliderInteraction.tapAndSlide,
      padding: const EdgeInsets.symmetric(horizontal: horizontalPadding),
      onChanged: onChanged, onChangeStart: onChangeStart, onChangeEnd: onChangeEnd)));
}
