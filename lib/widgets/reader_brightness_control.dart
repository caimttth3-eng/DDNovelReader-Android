import 'package:flutter/material.dart';
import '../i18n.dart';

class ReaderBrightnessControl extends StatelessWidget {
  static const split = 0.25;
  final double value;
  final bool automatic;
  final ValueChanged<double> onChanged;
  final VoidCallback onAutomatic;
  final Key? sliderKey;
  const ReaderBrightnessControl({super.key, required this.value, required this.automatic,
    required this.onChanged, required this.onAutomatic, this.sliderKey});

  @override
  Widget build(BuildContext context) => Row(children: [
    Expanded(child: LayoutBuilder(builder: (context, constraints) => Stack(alignment: Alignment.center,
      children: [
        Slider(key: sliderKey, value: value.clamp(0, 1), min: 0, max: 1,
          padding: const EdgeInsets.symmetric(horizontal: 12), onChanged: onChanged),
        Positioned(left: 12 + (constraints.maxWidth - 24) * split - 2,
          child: IgnorePointer(child: Tooltip(message: T('brightnessSplit'),
            child: Container(key: const ValueKey('brightness-split'), width: 4, height: 4,
              decoration: BoxDecoration(shape: BoxShape.circle, color: Theme.of(context).colorScheme.primary))))),
      ]))),
    TextButton(key: const ValueKey('brightness-auto'), onPressed: onAutomatic,
      style: TextButton.styleFrom(minimumSize: const Size(44, 44), padding: EdgeInsets.zero),
      child: Tooltip(message: T('systemBrightness'), child: Text('A',
        style: TextStyle(fontSize: 20, color: automatic ? Theme.of(context).colorScheme.primary : null)))),
  ]);
}
