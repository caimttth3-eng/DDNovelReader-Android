import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

/// Horizontal swipes turn pages. With preview callbacks, a vertical reading
/// drag selects sentences continuously and commits once on pointer release.
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
    this.onSentenceDragStart,
    this.onSentenceDragChange,
    this.onSentenceDragEnd,
  });

  final Widget child;
  final VoidCallback onPreviousSentence;
  final VoidCallback onNextSentence;
  final VoidCallback onPreviousPage;
  final VoidCallback onNextPage;
  final GestureTapUpCallback? onTapUp;
  final bool enabled;
  final bool sentenceSwipesEnabled;
  final VoidCallback? onSentenceDragStart;
  final ValueChanged<int>? onSentenceDragChange;
  final ValueChanged<bool>? onSentenceDragEnd;

  @override
  State<ReaderGestures> createState() => _ReaderGesturesState();
}

class _ReaderGesturesState extends State<ReaderGestures> with WidgetsBindingObserver {
  Offset _distance = Offset.zero;
  static const double _threshold = 48;
  bool _longActive = false;
  bool _panValid = false;
  Offset _panOrigin = Offset.zero;
  int _gestureEpoch = 0;
  Axis? _longAxis;
  int _longSteps = 0;
  bool get _longEnabled => widget.enabled && widget.sentenceSwipesEnabled &&
    widget.onSentenceDragStart != null && widget.onSentenceDragChange != null && widget.onSentenceDragEnd != null;

  @override
  void initState() { super.initState(); WidgetsBinding.instance.addObserver(this); }

  void _endLong(bool cancelled, {bool defer = false, ValueChanged<bool>? previousCallback}) {
    if (!_longActive) return;
    _longActive = false; _longAxis = null; _longSteps = 0; _distance = Offset.zero;
    final callback = previousCallback ?? widget.onSentenceDragEnd;
    final epoch = _gestureEpoch;
    if (defer) { WidgetsBinding.instance.addPostFrameCallback((_) { if (epoch == _gestureEpoch) callback?.call(cancelled); }); }
    else { callback?.call(cancelled); }
  }

  @override
  void didUpdateWidget(covariant ReaderGestures oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasContinuous = oldWidget.enabled && oldWidget.sentenceSwipesEnabled &&
      oldWidget.onSentenceDragStart != null && oldWidget.onSentenceDragChange != null && oldWidget.onSentenceDragEnd != null;
    if (!widget.enabled || oldWidget.sentenceSwipesEnabled != widget.sentenceSwipesEnabled || (wasContinuous && !_longEnabled)) {
      _panValid = false; _endLong(true, defer: true, previousCallback: oldWidget.onSentenceDragEnd);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) { _panValid = false; _endLong(true); }
  }

  @override
  void didChangeMetrics() { _panValid = false; _endLong(true); }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _endLong(true, defer: true);
    super.dispose();
  }

  void _beginPan(DragDownDetails details) {
    _panValid = true; _panOrigin = details.globalPosition; _distance = Offset.zero;
    _longAxis = null; _longSteps = 0;
  }

  void _movePan(DragUpdateDetails details) {
    if (!_panValid) return;
    _distance = details.globalPosition - _panOrigin;
    if (!_longEnabled) return;
    final delta = _distance;
    if (_longAxis == null && delta.distance > kTouchSlop) {
      _longAxis = delta.dx.abs() > delta.dy.abs() ? Axis.horizontal : Axis.vertical;
    }
    if (_longAxis != Axis.vertical) return;
    if (!_longActive) { _gestureEpoch++; _longActive = true; widget.onSentenceDragStart?.call(); }
    final steps = (delta.dy / _threshold).truncate();
    if (steps != _longSteps) { _longSteps = steps; widget.onSentenceDragChange?.call(steps); }
  }

  void _finish(DragEndDetails details) {
    if (_longActive) { _panValid = false; _endLong(false); return; }
    if (!_panValid || !widget.enabled) { _distance = Offset.zero; return; }
    _panValid = false;
    final delta = _distance;
    _distance = Offset.zero;
    if (_longAxis == Axis.horizontal || delta.dx.abs() > delta.dy.abs()) {
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
  Widget build(BuildContext context) => Listener(
      onPointerCancel: (_) { _panValid = false; _endLong(true); _distance = Offset.zero; },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        dragStartBehavior: DragStartBehavior.down,
        onTapUp: widget.onTapUp,
        onPanDown: widget.enabled && widget.sentenceSwipesEnabled ? _beginPan : null,
        onPanUpdate: widget.enabled && widget.sentenceSwipesEnabled ? _movePan : null,
        onPanEnd: widget.enabled && widget.sentenceSwipesEnabled ? _finish : null,
        onPanCancel: widget.enabled && widget.sentenceSwipesEnabled ? () { _panValid = false; _endLong(true); _distance = Offset.zero; } : null,
        onHorizontalDragDown: widget.enabled && !widget.sentenceSwipesEnabled ? _beginPan : null,
        onHorizontalDragUpdate: widget.enabled && !widget.sentenceSwipesEnabled ? _movePan : null,
        onHorizontalDragEnd: widget.enabled && !widget.sentenceSwipesEnabled ? _finish : null,
        onHorizontalDragCancel: widget.enabled && !widget.sentenceSwipesEnabled ? () { _panValid = false; _distance = Offset.zero; } : null,
        child: widget.child,
      ));
}
