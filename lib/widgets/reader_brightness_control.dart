import 'package:flutter/material.dart';
import '../i18n.dart';

class ReaderBrightnessControl extends StatelessWidget {
  static const split = 0.25;
  final double value;
  final bool automatic;
  final ValueChanged<double> onChanged;
  final VoidCallback onAutomatic;
  final Key? sliderKey;
  final Color? foregroundColor;
  const ReaderBrightnessControl({super.key, required this.value, required this.automatic,
    required this.onChanged, required this.onAutomatic, this.sliderKey, this.foregroundColor});

  @override
  Widget build(BuildContext context) => Row(children: [
    Expanded(child: LayoutBuilder(builder: (context, constraints) => Stack(alignment: Alignment.center,
      children: [
        Slider(key: sliderKey, value: value.clamp(0, 1), min: 0, max: 1,
          allowedInteraction: SliderInteraction.tapAndSlide,
          padding: const EdgeInsets.symmetric(horizontal: 12), onChanged: onChanged),
        Positioned(left: 12 + (constraints.maxWidth - 24) * split - 2,
          child: IgnorePointer(child: Tooltip(message: T('brightnessSplit'),
            child: Container(key: const ValueKey('brightness-split'), width: 4, height: 4,
              decoration: BoxDecoration(shape: BoxShape.circle, color: Theme.of(context).colorScheme.primary))))),
      ]))),
    SizedBox(width: 44, height: 44, child: TextButton(key: const ValueKey('brightness-auto'), onPressed: onAutomatic,
      style: TextButton.styleFrom(minimumSize: const Size(44, 44), padding: EdgeInsets.zero),
      child: Tooltip(message: T('systemBrightness'), child: CustomPaint(size: const Size(32, 32),
        painter: _AutoBulbPainter(automatic ? (foregroundColor == null ? Theme.of(context).colorScheme.primary : const Color(0xFF9BC5DD))
          : foregroundColor ?? Theme.of(context).colorScheme.onSurfaceVariant))))),
  ]);
}

class _AutoBulbPainter extends CustomPainter {
  final Color color;
  const _AutoBulbPainter(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save(); canvas.scale(size.width / 32, size.height / 32);
    final paint = Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 1.7..strokeCap = StrokeCap.round;
    final bulb = Path()..moveTo(11, 23)..lineTo(11, 20)
      ..cubicTo(3, 15, 5, 3, 16, 3)..cubicTo(27, 3, 29, 15, 21, 20)
      ..lineTo(21, 23)..close();
    canvas.drawPath(bulb, paint);
    canvas.drawLine(const Offset(11, 26), const Offset(21, 26), paint);
    canvas.drawLine(const Offset(13, 29), const Offset(19, 29), paint);
    final letter = TextPainter(text: TextSpan(text: 'A', style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w600)),
      textDirection: TextDirection.ltr)..layout();
    letter.paint(canvas, Offset(16 - letter.width / 2, 7));
    letter.dispose(); canvas.restore();
  }
  @override
  bool shouldRepaint(_AutoBulbPainter oldDelegate) => oldDelegate.color != color;
}
