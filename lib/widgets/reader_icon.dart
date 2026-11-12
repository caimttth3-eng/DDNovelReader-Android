import 'dart:math' as math;
import 'package:flutter/material.dart';

enum ReaderSymbol { back, headphones, moon, sun, more, bulb, smallText,
  largeText, note, search, theme, play, bookmark, rotate, settings, contents,
  previousChapter, nextChapter }

/// Thin outline controls matching the supplied reader reference.
class ReaderIcon extends StatelessWidget {
  final ReaderSymbol symbol;
  final double size;
  final Color? color;
  const ReaderIcon(this.symbol, {super.key, this.size = 26, this.color});
  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size),
    painter: _ReaderIconPainter(symbol, color ?? IconTheme.of(context).color ?? Colors.white));
}

class _ReaderIconPainter extends CustomPainter {
  final ReaderSymbol symbol;
  final Color color;
  const _ReaderIconPainter(this.symbol, this.color);
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final p = Paint()..color = color..strokeWidth = 1..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round;
    void path(List<Offset> points, {bool close = false}) {
      final q = Path()..moveTo(points.first.dx, points.first.dy);
      for (final point in points.skip(1)) { q.lineTo(point.dx, point.dy); }
      if (close) q.close();
      canvas.drawPath(q, p);
    }
    void line(double x, double y, double a, double b) => canvas.drawLine(Offset(x,y), Offset(a,b),p);
    void circle(double x, double y, double radius) => canvas.drawCircle(Offset(x,y),radius,p);
    void rect(double x, double y, double w, double h) => canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(x,y,w,h),const Radius.circular(0.8)),p);
    switch (symbol) {
      case ReaderSymbol.back:
        path([const Offset(16,2),const Offset(6,12),const Offset(16,22)]);
      case ReaderSymbol.headphones:
        canvas.drawArc(const Rect.fromLTWH(4,3,16,17),math.pi,math.pi,false,p);
        rect(3,12,4,9); rect(17,12,4,9);
      case ReaderSymbol.moon:
        canvas.drawPath(Path()..moveTo(14,2)..cubicTo(8,8,13,18,21,16)
          ..cubicTo(18,24,5,24,3,14)..cubicTo(1,7,7,1,14,2),p);
        circle(19,5,0.7);
      case ReaderSymbol.sun:
        circle(12,12,5);
        for (var i=0; i<8; i++) {
          final a=i*math.pi/4;
          line(12+8*math.cos(a),12+8*math.sin(a),12+10*math.cos(a),12+10*math.sin(a));
        }
      case ReaderSymbol.more:
        for (final x in [3.0,10.0,17.0]) { rect(x,10,4,4); }
      case ReaderSymbol.bulb:
        canvas.drawPath(Path()..moveTo(9,17)..cubicTo(9,13,5,12,5,8)
          ..cubicTo(5,0,19,0,19,8)..cubicTo(19,12,15,13,15,17)..close(),p);
        line(9,20,15,20); line(10,22,14,22);
      case ReaderSymbol.smallText:
      case ReaderSymbol.largeText:
        line(4,5,17,5); line(10.5,5,10.5,21);
        if (symbol == ReaderSymbol.largeText) { line(18,12,24,12); line(21,9,21,15); }
        else { line(18,12,23,12); }
      case ReaderSymbol.note:
        rect(3,2,16,20); line(6,7,16,7); line(6,11,16,11); line(6,15,12,15); line(12,22,23,10);
      case ReaderSymbol.search:
        circle(10,10,8); line(16,16,23,23);
      case ReaderSymbol.theme:
        path([const Offset(8,3),const Offset(3,5),const Offset(1,10),const Offset(5,12),const Offset(7,9),
          const Offset(7,22),const Offset(17,22),const Offset(17,9),const Offset(19,12),const Offset(23,10),
          const Offset(21,5),const Offset(16,3)],close:false);
        canvas.drawArc(const Rect.fromLTWH(8,0,8,7),0,math.pi,false,p);
      case ReaderSymbol.play:
        circle(12,12,10); path([const Offset(9,6),const Offset(18,12),const Offset(9,18)],close:true);
      case ReaderSymbol.bookmark:
        path([const Offset(5,2),const Offset(19,2),const Offset(19,23),const Offset(12,17),const Offset(5,23)],close:true);
      case ReaderSymbol.rotate:
        rect(2,2,9,17); rect(9,11,13,11); line(5,16,8,16); line(19,15,19,18);
      case ReaderSymbol.settings:
        circle(12,12,5);
        final points=<Offset>[];
        for(var i=0;i<32;i++) {
          final a=i*math.pi/16;
          final r=(i%4==0||i%4==3)?10.5:8.5;
          points.add(Offset(12+r*math.cos(a),12+r*math.sin(a)));
        }
        path(points,close:true);
      case ReaderSymbol.contents:
        line(4,6,20,6);line(4,12,20,12);line(4,18,20,18);
      case ReaderSymbol.previousChapter:
        line(3,5,3,19);path([const Offset(20,5),const Offset(8,12),const Offset(20,19)],close:true);
      case ReaderSymbol.nextChapter:
        line(21,5,21,19);path([const Offset(4,5),const Offset(16,12),const Offset(4,19)],close:true);
    }
  }
  @override
  bool shouldRepaint(_ReaderIconPainter old) => old.symbol != symbol || old.color != color;
}
