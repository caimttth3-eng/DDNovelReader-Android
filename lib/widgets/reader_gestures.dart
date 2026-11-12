import 'package:flutter/material.dart';

/// One navigation action per completed swipe. Short drags and cancelled
/// gestures do nothing; the dominant axis decides diagonal gestures.
class ReaderGestures extends StatefulWidget {
  const ReaderGestures({
    super.key,
    required this.child,
    required this.onPreviousSentence,
    required this.onNextSentence,
    required this.onPreviousPage,
    required this.onNextPage,
    this.onTapUp,
    this.enabled = true,
    this.sentenceSwipesEnabled = true,
  });

  final Widget child;
  final VoidCallback onPreviousSentence;
  final VoidCallback onNextSentence;
  final VoidCallback onPreviousPage;
  final VoidCallback onNextPage;
  final GestureTapUpCallback? onTapUp;
  final bool enabled;
  final bool sentenceSwipesEnabled;

  @override
  State<ReaderGestures> createState() => _ReaderGesturesState();
}

class _ReaderGesturesState extends State<ReaderGestures> {
  Offset _distance = Offset.zero;
  static const double _threshold = 48;

  void _finish(DragEndDetails details) {
    final delta = _distance;
    _distance = Offset.zero;
    if (delta.dx.abs() > delta.dy.abs()) {
      if (delta.dx.abs() < _threshold) return;
      if (delta.dx < 0) {
        widget.onNextPage();
      } else {
        widget.onPreviousPage();
      }
    } else {
      if (delta.dy.abs() < _threshold) return;
      if (delta.dy < 0) {
        widget.onPreviousSentence();
      } else {
        widget.onNextSentence();
      }
    }
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapUp: widget.onTapUp,
        onPanDown: widget.enabled && widget.sentenceSwipesEnabled ? (_) => _distance = Offset.zero : null,
        onPanUpdate: widget.enabled && widget.sentenceSwipesEnabled ? (details) => _distance += details.delta : null,
        onPanEnd: widget.enabled && widget.sentenceSwipesEnabled ? _finish : null,
        onPanCancel: widget.enabled && widget.sentenceSwipesEnabled ? () => _distance = Offset.zero : null,
        onHorizontalDragDown: widget.enabled && !widget.sentenceSwipesEnabled ? (_) => _distance = Offset.zero : null,
        onHorizontalDragUpdate: widget.enabled && !widget.sentenceSwipesEnabled ? (details) => _distance += details.delta : null,
        onHorizontalDragEnd: widget.enabled && !widget.sentenceSwipesEnabled ? _finish : null,
        onHorizontalDragCancel: widget.enabled && !widget.sentenceSwipesEnabled ? () => _distance = Offset.zero : null,
        child: widget.child,
      );
}
